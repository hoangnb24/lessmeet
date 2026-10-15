import Combine
import Foundation

@MainActor
final class LocalTranscriptionModel: ObservableObject {
    enum RecordingState: Equatable {
        case idle, queued, running(LocalTranscriptionProgress), completed, cancelled, failed(String)

        var isPending: Bool {
            switch self {
            case .queued, .running: return true
            default: return false
            }
        }

        var showsPreviousTranscript: Bool {
            switch self {
            case .queued, .running, .cancelled, .failed: return true
            default: return false
            }
        }
    }

    enum Activity: Equatable {
        case idle, waitingForModels(String), transcribing(UUID), draining
    }

    @Published private(set) var revision = 0
    @Published private(set) var completedRecordingID: UUID?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var error: String?
    @Published private(set) var recordingStates: [UUID: RecordingState] = [:]

    private weak var app: AppModel?
    private let store: RecordingStore?
    private let manager: LocalModelManager
    private let engine: any LocalTranscriptionProcessing
    private var observation: AnyCancellable?
    private var pending: [UUID] = []
    private var activeID: UUID?
    private var generation = UUID()
    private var operation: Task<Void, Never>?

    init(app: AppModel, manager: LocalModelManager,
         engine: any LocalTranscriptionProcessing = LocalTranscriptionEngine()) {
        self.app = app
        self.store = app.store
        self.manager = manager
        self.engine = engine
        observation = manager.$state.combineLatest(manager.$installed).sink { [weak self] _ in
            // Published sends in willSet. Read both committed properties on the next actor turn.
            Task { @MainActor [weak self] in self?.advance() }
        }
    }

    deinit { operation?.cancel() }

    var canCancel: Bool { activeID != nil || !pending.isEmpty }

    func state(for recordingID: UUID) -> RecordingState {
        recordingStates[recordingID] ?? .idle
    }

    func loadTranscript(recordingID: UUID) throws -> LocalTranscript? {
        guard let store else { throw ControllerError.libraryUnavailable }
        return try store.loadLocalTranscript(for: recordingID)
    }

    func transcribe(recordingID: UUID) {
        guard activeID != recordingID, !pending.contains(recordingID) else { return }
        do {
            _ = try audioURL(for: recordingID)
            pending.append(recordingID)
            recordingStates[recordingID] = .queued
            error = nil
            advance()
        } catch {
            fail(recordingID, error)
        }
    }

    func cancel() {
        generation = UUID()
        let cancelledIDs = pending + (activeID.map { [$0] } ?? [])
        pending.removeAll()
        activeID = nil
        for id in cancelledIDs { recordingStates[id] = .cancelled }
        operation?.cancel()
        activity = operation == nil ? .idle : .draining
    }

    private func advance() {
        guard operation == nil else {
            if activeID == nil { activity = .draining }
            return
        }
        guard !pending.isEmpty else { activity = .idle; return }
        guard manager.state == .ready, let models = manager.installed else {
            let message: String
            switch manager.state {
            case .failed: message = "Model setup failed. Open model setup to retry."
            case .cancelled, .cancelling: message = "Model setup is paused. Open model setup to resume."
            default: message = "Waiting for local models to be ready."
            }
            activity = .waitingForModels(message)
            return
        }
        while !pending.isEmpty {
            let id = pending.removeFirst()
            do {
                let url = try audioURL(for: id)
                let token = UUID()
                generation = token
                activeID = id
                recordingStates[id] = .running(.init(fraction: 0, message: "Starting local transcription…"))
                activity = .transcribing(id)
                operation = Task { [weak self, engine] in
                    let result: Result<LocalTranscript, Error>
                    do {
                        try Task.checkCancellation()
                        result = .success(try await engine.transcribe(audioURL: url, models: models) { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token, self.activeID == id else { return }
                                let fraction = progress.fraction.isFinite ? min(1, max(0, progress.fraction)) : 0
                                self.recordingStates[id] = .running(.init(fraction: fraction, message: progress.message))
                            }
                        })
                    } catch { result = .failure(error) }
                    guard let self else { return }
                    if self.generation == token, self.activeID == id, !Task.isCancelled {
                        switch result {
                        case .success(let transcript):
                            do {
                                _ = try self.audioURL(for: id)
                                guard let store = self.store else { throw ControllerError.libraryUnavailable }
                                // No suspension between the final cancellation check and atomic publication.
                                guard self.generation == token, !Task.isCancelled else { break }
                                try store.saveLocalTranscript(transcript, for: id)
                                self.completedRecordingID = id
                                self.revision += 1
                                self.recordingStates[id] = .completed
                            } catch { self.fail(id, error) }
                        case .failure(let error):
                            if error is CancellationError { self.recordingStates[id] = .cancelled }
                            else { self.fail(id, error) }
                        }
                    }
                    // Keep this slot occupied even when a cancelled engine ignores cancellation.
                    self.activeID = nil
                    self.operation = nil
                    self.advance()
                }
                return
            } catch { fail(id, error) }
        }
        activity = .idle
    }

    private func fail(_ id: UUID, _ failure: Error) {
        let message = failure.localizedDescription
        recordingStates[id] = .failed(message)
        error = message
    }

    private func audioURL(for id: UUID) throws -> URL {
        guard let app, let store else { throw ControllerError.libraryUnavailable }
        guard !app.isCapturing(id) else { throw ControllerError.recordingNotReady }
        let metadata = store.directory(for: id).appendingPathComponent("recording.json")
        let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: metadata))
        // Interruption describes capture, not whether its saved audio can be decoded.
        // The engine validates audio before publishing a transcript.
        guard recording.id == id, recording.status != .recording else { throw ControllerError.recordingNotReady }
        let url = store.audioURL(for: id)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0, FileManager.default.isReadableFile(atPath: url.path) else {
            throw ControllerError.audioUnavailable
        }
        return url
    }

    private enum ControllerError: LocalizedError {
        case libraryUnavailable, recordingNotReady, audioUnavailable
        var errorDescription: String? {
            switch self {
            case .libraryUnavailable: return "The recording library is unavailable."
            case .recordingNotReady: return "This saved recording is not ready for transcription."
            case .audioUnavailable: return "The saved combined.m4a audio is unavailable or empty."
            }
        }
    }
}

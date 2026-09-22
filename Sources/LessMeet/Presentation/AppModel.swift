import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, stopping }
    @Published var recordings: [Recording] = []
    @Published var selection: UUID?
    @Published var phase: Phase = .idle
    @Published var error: String?
    @Published var startedAt: Date?
    let playback = AudioPlayback()
    private let capture = CaptureService()
    private(set) var store: RecordingStore?
    private var activeID: UUID?

    var selected: Recording? { recordings.first { $0.id == selection } }
    var canQuit: Bool { phase == .idle }

    init(store suppliedStore: RecordingStore? = nil) {
        do {
            let store = try suppliedStore ?? RecordingStore()
            self.store = store
            var issues: [String] = []
            recordings = try store.load { issues.append($0) }
            if !issues.isEmpty { error = issues.joined(separator: "\n") }
            selection = recordings.first?.id
        } catch { self.error = "Could not open the recording library: \(error.localizedDescription)" }
        capture.onFailure = { [weak self] message in
            guard let self else { return }
            self.error = message
            if self.phase == .recording {
                Task { await self.stopRecording(interruption: message) }
            }
        }
    }

    func startRecording() async {
        guard phase == .idle, let store else { return }
        phase = .starting
        playback.stop()
        error = nil
        var recording = Recording(title: "Recording \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        do {
            try store.save(recording)
            recordings.insert(recording, at: 0)
            selection = recording.id
            activeID = recording.id
            try await capture.start(directory: store.directory(for: recording.id))
            startedAt = .now
            phase = .recording
        } catch {
            recording.status = .interrupted
            recording.failure = error.localizedDescription
            persist(recording)
            self.error = error.localizedDescription
            activeID = nil
            phase = .idle
        }
    }

    func stopRecording(interruption: String? = nil) async {
        guard phase == .recording, let id = activeID,
              var recording = recordings.first(where: { $0.id == id }) else { return }
        phase = .stopping
        do {
            let result = try await capture.stop()
            recording.duration = result.duration
            recording.failure = [interruption, result.warning].compactMap { $0 }.joined(separator: "\n")
            if recording.failure?.isEmpty == true { recording.failure = nil }
            recording.status = interruption == nil ? .ready : .interrupted
        } catch {
            recording.status = .interrupted
            recording.duration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
            recording.failure = error.localizedDescription
            self.error = error.localizedDescription
        }
        persist(recording)
        activeID = nil
        startedAt = nil
        phase = .idle
        selection = id
        loadPlayback()
    }

    func rename(_ title: String) {
        guard var recording = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recording.title = trimmed
        persist(recording)
    }

    func persist(_ recording: Recording) {
        do {
            guard let store else { return }
            try store.save(recording)
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
            else { recordings.insert(recording, at: 0) }
        } catch { self.error = "Could not save recording details: \(error.localizedDescription)" }
    }

    func loadPlayback() {
        guard phase == .idle, let id = selection, let store else { playback.stop(); return }
        playback.load(store.audioURL(for: id))
    }

    func revealSelected() {
        guard let id = selection, let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)])
    }

    func openPermissions() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

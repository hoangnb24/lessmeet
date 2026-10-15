import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LessMeet

private actor ControlledTranscriptionEngine: LocalTranscriptionProcessing {
    struct Call {
        let url: URL
        let models: InstalledLocalModels
        let progress: @Sendable (LocalTranscriptionProgress) -> Void
    }
    private(set) var calls: [Call] = []
    private var continuations: [Int: CheckedContinuation<LocalTranscript, Error>] = [:]
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var returnedAfterCancellation = false

    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript {
        let index = calls.count
        calls.append(.init(url: audioURL, models: models, progress: progress))
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer {
            activeCount -= 1
            returnedAfterCancellation = returnedAfterCancellation || Task.isCancelled
        }
        // Intentionally ignore cancellation until the test releases the model work.
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func finish(_ index: Int, _ result: Result<LocalTranscript, Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }

    func report(_ index: Int, fraction: Double = 0.5, message: String = "Test progress") {
        calls[index].progress(.init(fraction: fraction, message: message))
    }
}

private final class NoControllerNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Controller test attempted network access")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@MainActor
private final class ManualControllerCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    var duringStart: (() throws -> Void)?
    var duringStop: (() -> Void)?
    func start(directory: URL) async throws { try duringStart?() }
    func stop() async throws -> CaptureResult {
        duringStop?()
        return .init(duration: 1, warning: nil)
    }
}

final class LocalTranscriptionModelTests: XCTestCase {
    private struct Fixture {
        let app: AppModel
        let store: RecordingStore
        let manager: LocalModelManager
        let engine: ControlledTranscriptionEngine
        let model: LocalTranscriptionModel
        let ids: [UUID]
    }

    private enum TestFailure: Error { case inference }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        let done = expectation(description: "controller scenario")
        Task { @MainActor in
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
    }

    @MainActor private func settle(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Controller did not reach the expected state")
        throw TestFailure.inference
    }

    @MainActor private func fixture(ready: Bool = true, count: Int = 2,
                                   capture: (any RecordingCapture)? = nil) async throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("LessMeet-controller-test-" + UUID().uuidString)
        // Retain generated fixtures. This scope does not authorize file deletion.
        let store = try RecordingStore(root: root.appendingPathComponent("recordings"))
        var ids: [UUID] = []
        for index in 0..<count {
            let recording = Recording(title: "Generated \(index)", status: .ready)
            try store.save(recording)
            try Data("synthetic audio for injected engine".utf8).write(to: store.audioURL(for: recording.id))
            ids.append(recording.id)
        }
        let payload = Data("tiny local model fixture".utf8)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let catalog = ["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"].map { id in
            let path = id == "whisper-large-v3" ? "openai_whisper-large-v3/model.bin" : "model.bin"
            return LocalModelArtifact(id: id, name: id, repository: "test/models", revision: String(repeating: "a", count: 40),
                                      directory: id, files: [.init(path: path, bytes: Int64(payload.count), sha256: sha)])
        }
        let modelRoot = root.appendingPathComponent("models")
        for artifact in catalog {
            let file = modelRoot.appendingPathComponent(artifact.directory).appendingPathComponent(artifact.files[0].path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: file)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoControllerNetwork.self]
        let manager = LocalModelManager(root: modelRoot, catalog: catalog, configuration: config)
        if ready {
            await manager.prepare()
            XCTAssertEqual(manager.state, .ready, manager.error ?? "")
            guard manager.state == .ready else { throw TestFailure.inference }
        }
        let app = AppModel(store: store, capture: capture)
        let engine = ControlledTranscriptionEngine()
        let model = LocalTranscriptionModel(app: app, manager: manager, engine: engine)
        return Fixture(app: app, store: store, manager: manager, engine: engine, model: model, ids: ids)
    }

    private func transcript(_ text: String = "Hello", speaker: String? = nil) -> LocalTranscript {
        .init(segments: [.init(startMs: 1200, endMs: 3456, speaker: speaker, text: text)])
    }

    private func writePlayableAudio(_ url: URL) throws {
        let writer = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.0576)) * 0.1
        }
        try writer.write(from: buffer)
    }

    func testInterruptedAndRecoveredAudioReopensIdleAndTranscribesOnlyOnRequest() {
        run {
            for status in [Recording.Status.interrupted, .recording] {
                let f = try await self.fixture()
                let id = f.ids[0]
                var recording = try XCTUnwrap(f.app.recordings.first { $0.id == id })
                recording.status = status
                recording.failure = "Synthetic sleep interruption"
                try f.store.save(recording)
                let audio = f.store.audioURL(for: id)
                try self.writePlayableAudio(audio)
                let originalAudio = try Data(contentsOf: audio)
                let reader = try LocalPCMReader(url: audio)
                var samples = 0
                while true {
                    let block = try reader.read(maxSamples: 16_384)
                    if block.isEmpty { break }
                    samples += block.count
                }
                XCTAssertGreaterThan(samples, 0)
                let reopenedApp = AppModel(store: f.store)
                let reopened = LocalTranscriptionModel(app: reopenedApp, manager: f.manager, engine: f.engine)
                let metadataURL = f.store.directory(for: id).appendingPathComponent("recording.json")
                let metadata = try Data(contentsOf: metadataURL)
                XCTAssertEqual(reopenedApp.recordings.first { $0.id == id }?.status, .interrupted)
                XCTAssertNotNil(reopenedApp.recordings.first { $0.id == id }?.failure)
                if status == .interrupted {
                    XCTAssertEqual(reopenedApp.recordings.first { $0.id == id }?.failure, recording.failure)
                }
                await f.manager.prepare()
                for _ in 0..<10 { await Task.yield() }
                XCTAssertEqual(reopened.state(for: id), .idle)
                let initialCalls = await f.engine.calls.count
                XCTAssertEqual(initialCalls, 0)
                XCTAssertNil(try f.store.loadLocalTranscript(for: id))
                reopened.transcribe(recordingID: id)
                try await self.settle { await f.engine.calls.count == 1 }
                await f.engine.finish(0, .success(self.transcript("Explicit request")))
                try await self.settle { reopened.state(for: id) == .completed }
                XCTAssertEqual(try f.store.loadLocalTranscript(for: id), self.transcript("Explicit request"))
                XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
                XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
            }
        }
    }

    func testInterruptedCorruptAudioFailsRealDecoderAndPreservesPreviousTranscript() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            var recording = try XCTUnwrap(f.app.recordings.first { $0.id == id })
            recording.status = .interrupted
            recording.failure = "Synthetic sleep interruption"
            try f.store.save(recording)
            try f.store.saveLocalTranscript(self.transcript("Previous"), for: id)
            let metadata = try Data(contentsOf: f.store.directory(for: id).appendingPathComponent("recording.json"))
            let audio = try Data(contentsOf: f.store.audioURL(for: id))
            let model = LocalTranscriptionModel(app: f.app, manager: f.manager)
            model.transcribe(recordingID: id)
            try await self.settle { if case .failed = model.state(for: id) { return true }; return false }
            XCTAssertTrue(model.error?.contains("Cannot read local audio") == true, model.error ?? "")
            XCTAssertEqual(try f.store.loadLocalTranscript(for: id), self.transcript("Previous"))
            XCTAssertEqual(try Data(contentsOf: f.store.audioURL(for: id)), audio)
            XCTAssertEqual(try Data(contentsOf: f.store.directory(for: id).appendingPathComponent("recording.json")), metadata)
        }
    }

    func testInterruptedMissingEmptyAndLinkedAudioNeverReachesEngine() {
        run {
            let f = try await self.fixture()
            for kind in ["missing", "empty", "linked"] {
                let recording = Recording(title: kind, status: .interrupted, failure: "Synthetic interruption")
                try f.store.save(recording)
                let url = f.store.audioURL(for: recording.id)
                if kind == "empty" { try Data().write(to: url) }
                if kind == "linked" {
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.store.audioURL(for: f.ids[0]))
                }
                f.model.transcribe(recordingID: recording.id)
                guard case .failed = f.model.state(for: recording.id) else { return XCTFail("Accepted \(kind) audio") }
                XCTAssertNil(try f.store.loadLocalTranscript(for: recording.id))
            }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testActiveCaptureCannotTranscribeEvenWithInterruptedMetadataOrChangedSelection() {
        run {
            let capture = ManualControllerCapture()
            let f = try await self.fixture(capture: capture)
            capture.duringStart = {
                let id = try XCTUnwrap(f.app.selected?.id)
                var recording = try XCTUnwrap(f.app.selected)
                recording.status = .interrupted
                try f.store.save(recording)
                try self.writePlayableAudio(f.store.audioURL(for: id))
                f.app.selection = f.ids[0]
                f.model.transcribe(recordingID: id)
                guard case .failed = f.model.state(for: id) else { return XCTFail("Starting capture accepted") }
            }
            await f.app.startRecording()
            let id = try XCTUnwrap(f.app.recordings.first { !f.ids.contains($0.id) }?.id)
            f.model.transcribe(recordingID: id)
            guard case .failed = f.model.state(for: id) else { return XCTFail("Active capture accepted") }
            capture.duringStop = {
                f.model.transcribe(recordingID: id)
                guard case .failed = f.model.state(for: id) else { return XCTFail("Stopping capture accepted") }
            }
            await f.app.stopRecording(interruption: "Synthetic sleep interruption")
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(f.model.activity, .idle)
            XCTAssertNil(try f.store.loadLocalTranscript(for: id))
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .success(self.transcript()))
            try await self.settle { f.model.state(for: id) == .completed }
        }
    }

    func testQueueWaitsForCommittedReadinessAndDeduplicatesPendingAndActive() {
        run {
            let f = try await self.fixture(ready: false)
            let id = f.ids[0]
            f.model.transcribe(recordingID: id)
            f.model.transcribe(recordingID: id)
            XCTAssertEqual(f.model.state(for: id), .queued)
            XCTAssertEqual(f.model.activity, .waitingForModels("Waiting for local models to be ready."))
            let before = await f.engine.calls.count
            XCTAssertEqual(before, 0)
            var sawWillSet = false
            let observation = f.manager.$installed.sink { installed in
                if installed != nil {
                    sawWillSet = true
                    XCTAssertNotEqual(f.manager.state, .ready)
                    XCTAssertEqual(f.model.state(for: id), .queued)
                }
            }
            await f.manager.prepare()
            XCTAssertTrue(sawWillSet)
            try await self.settle { await f.engine.calls.count == 1 }
            f.model.transcribe(recordingID: id)
            await f.engine.finish(0, .success(self.transcript()))
            try await self.settle { f.model.revision == 1 }
            XCTAssertEqual(f.model.activity, .idle)
            let calls = await f.engine.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].models, f.manager.installed)
            withExtendedLifetime(observation) {}
        }
    }

    func testCancelWhileUnreadyClearsAllQueuedIDsAndNeverAutoRetries() {
        run {
            let f = try await self.fixture(ready: false)
            for id in f.ids { f.model.transcribe(recordingID: id) }
            f.model.cancel()
            for id in f.ids { XCTAssertEqual(f.model.state(for: id), .cancelled) }
            await f.manager.prepare()
            for _ in 0..<10 { await Task.yield() }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(f.model.canCancel)
            XCTAssertEqual(f.model.revision, 0)
            XCTAssertNil(f.model.completedRecordingID)
        }
    }

    func testCancelRejectsLateSuccessAndProgressAndPreservesPreviousBytes() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            try f.store.saveLocalTranscript(self.transcript("Previous"), for: id)
            let path = f.store.directory(for: id).appendingPathComponent("transcript.json")
            let before = try Data(contentsOf: path)
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            f.model.cancel()
            XCTAssertEqual(f.model.activity, .draining)
            await f.engine.report(0, message: "Must not appear")
            await f.engine.finish(0, .success(self.transcript("Stale")))
            try await self.settle { f.model.activity == .idle }
            XCTAssertEqual(f.model.state(for: id), .cancelled)
            XCTAssertTrue(f.model.state(for: id).showsPreviousTranscript)
            XCTAssertEqual(try Data(contentsOf: path), before)
            XCTAssertEqual(f.model.revision, 0)
            XCTAssertNil(f.model.completedRecordingID)
            let cancelled = await f.engine.returnedAfterCancellation
            XCTAssertTrue(cancelled)
        }
    }

    func testNewRequestAfterCancelWaitsForOldEngineAndCanReuseSameID() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            f.model.cancel()
            f.model.transcribe(recordingID: id)
            f.model.transcribe(recordingID: id)
            XCTAssertEqual(f.model.state(for: id), .queued)
            for _ in 0..<10 { await Task.yield() }
            let duringDrain = await f.engine.calls.count
            XCTAssertEqual(duringDrain, 1)
            await f.engine.finish(0, .success(self.transcript("Discard")))
            try await self.settle { await f.engine.calls.count == 2 }
            XCTAssertEqual(f.model.revision, 0)
            await f.engine.report(0, message: "Stale first job")
            await f.engine.report(1, message: "New job")
            try await self.settle { f.model.state(for: id) == .running(.init(fraction: 0.5, message: "New job")) }
            await f.engine.finish(1, .success(self.transcript("New")))
            try await self.settle { f.model.revision == 1 }
            XCTAssertEqual(try f.model.loadTranscript(recordingID: id), self.transcript("New"))
            let maximum = await f.engine.maximumActiveCount
            XCTAssertEqual(maximum, 1)
        }
    }

    func testTwoIDsStayBoundAcrossSelectionChangesAndNotifyAfterSave() {
        run {
            let f = try await self.fixture()
            let first = f.ids[0], second = f.ids[1]
            let firstMetadata = try Data(contentsOf: f.store.directory(for: first).appendingPathComponent("recording.json"))
            var notifications: [UUID] = []
            let observation = f.model.$revision.dropFirst().sink { revision in
                guard let id = f.model.completedRecordingID else { XCTFail("Missing completion ID"); return }
                notifications.append(id)
                XCTAssertNotNil(try? f.store.loadLocalTranscript(for: id))
                XCTAssertEqual(revision, notifications.count)
            }
            f.app.selection = first
            f.model.transcribe(recordingID: first)
            f.app.selection = second
            f.model.transcribe(recordingID: second)
            f.app.selection = nil
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .success(self.transcript("First", speaker: "Speaker1")))
            try await self.settle { await f.engine.calls.count == 2 }
            XCTAssertEqual(f.model.completedRecordingID, first)
            XCTAssertNil(try f.model.loadTranscript(recordingID: second))
            await f.engine.finish(1, .success(self.transcript("Second")))
            try await self.settle { f.model.revision == 2 }
            let calls = await f.engine.calls
            XCTAssertEqual(calls.map(\.url), [f.store.audioURL(for: first), f.store.audioURL(for: second)])
            XCTAssertEqual(notifications, [first, second])
            XCTAssertEqual(try f.model.loadTranscript(recordingID: first), self.transcript("First", speaker: "Speaker1"))
            XCTAssertEqual(try f.model.loadTranscript(recordingID: second), self.transcript("Second"))
            XCTAssertEqual(try Data(contentsOf: f.store.directory(for: first).appendingPathComponent("recording.json")), firstMetadata)
            XCTAssertNil(f.app.selection)
            withExtendedLifetime(observation) {}
        }
    }

    func testInferenceFailureKeepsPreviousAndDoesNotRetry() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            try f.store.saveLocalTranscript(self.transcript("Old"), for: id)
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .failure(TestFailure.inference))
            try await self.settle { f.model.activity == .idle }
            guard case .failed = f.model.state(for: id) else { return XCTFail("Expected failure") }
            XCTAssertNotNil(f.model.error)
            XCTAssertTrue(f.model.state(for: id).showsPreviousTranscript)
            XCTAssertEqual(try f.model.loadTranscript(recordingID: id), self.transcript("Old"))
            XCTAssertEqual(f.model.revision, 0)
            XCTAssertNil(f.model.completedRecordingID)
            await f.manager.prepare()
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 1)
        }
    }

    func testSaveValidationFailurePreservesBytesAndExistingCompletionFields() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .success(self.transcript("Accepted")))
            try await self.settle { f.model.revision == 1 }
            let path = f.store.directory(for: id).appendingPathComponent("transcript.json")
            let bytes = try Data(contentsOf: path)
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 2 }
            await f.engine.finish(1, .success(.init(version: 99, segments: [])))
            try await self.settle { f.model.activity == .idle }
            guard case .failed = f.model.state(for: id) else { return XCTFail("Expected save failure") }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
            XCTAssertEqual(f.model.revision, 1)
            XCTAssertEqual(f.model.completedRecordingID, id)
            f.model.cancel()
            XCTAssertEqual(f.model.revision, 1)
            XCTAssertEqual(f.model.completedRecordingID, id)
        }
    }

    func testFilesystemSaveFailurePreservesPreviousSidecar() {
        run {
            guard geteuid() != 0 else { throw XCTSkip("POSIX permission failure requires a non-root test process") }
            let f = try await self.fixture()
            let id = f.ids[0]
            try f.store.saveLocalTranscript(self.transcript("Previous"), for: id)
            let folder = f.store.directory(for: id)
            let path = folder.appendingPathComponent("transcript.json")
            let bytes = try Data(contentsOf: path)
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            XCTAssertEqual(chmod(folder.path, 0o500), 0)
            defer { _ = chmod(folder.path, 0o700) }
            await f.engine.finish(0, .success(self.transcript("Must not replace")))
            try await self.settle { f.model.activity == .idle }
            guard case .failed = f.model.state(for: id) else { return XCTFail("Expected filesystem save failure") }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
            XCTAssertEqual(f.model.revision, 0)
            XCTAssertNil(f.model.completedRecordingID)
        }
    }

    func testReadReopenDistinguishesMissingEmptyAndMalformedWithoutCloudFallback() {
        run {
            let f = try await self.fixture()
            let id = f.ids[0]
            var recording = try XCTUnwrap(f.app.recordings.first { $0.id == id })
            recording.transcript = "Cloud text must not be used"
            XCTAssertTrue(f.app.persist(recording))
            XCTAssertNil(try f.model.loadTranscript(recordingID: id))
            f.model.transcribe(recordingID: id)
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .success(.init(segments: [])))
            try await self.settle { f.model.revision == 1 }
            let reopenedStore = try RecordingStore(root: f.store.root)
            let reopenedApp = AppModel(store: reopenedStore)
            let reopened = LocalTranscriptionModel(app: reopenedApp, manager: f.manager, engine: f.engine)
            XCTAssertEqual(try reopened.loadTranscript(recordingID: id), .init(segments: []))
            XCTAssertNil(try reopened.loadTranscript(recordingID: f.ids[1]))
            try Data("invalid JSON".utf8).write(to: f.store.directory(for: f.ids[1]).appendingPathComponent("transcript.json"))
            XCTAssertThrowsError(try reopened.loadTranscript(recordingID: f.ids[1]))
            XCTAssertEqual(reopened.revision, 0)
        }
    }

    func testRejectsUnsavedNotReadyMismatchedAndMissingAudioRecordings() {
        run {
            let f = try await self.fixture()
            let unknown = UUID()
            f.model.transcribe(recordingID: unknown)
            guard case .failed = f.model.state(for: unknown) else { return XCTFail("Unsaved ID accepted") }
            var recording = try XCTUnwrap(f.app.recordings.first { $0.id == f.ids[0] })
            recording.status = .recording
            try f.store.save(recording)
            let metadata = f.store.directory(for: recording.id).appendingPathComponent("recording.json")
            let bytes = try Data(contentsOf: metadata)
            f.model.transcribe(recordingID: recording.id)
            guard case .failed = f.model.state(for: recording.id) else { return XCTFail("Unready recording accepted") }
            XCTAssertEqual(try Data(contentsOf: metadata), bytes)
            recording.status = .ready
            recording.id = UUID()
            try JSONEncoder().encode(recording).write(to: metadata)
            f.model.transcribe(recordingID: f.ids[0])
            guard case .failed = f.model.state(for: f.ids[0]) else { return XCTFail("Mismatched ID accepted") }
            let noAudio = Recording(title: "Missing audio", status: .ready)
            try f.store.save(noAudio)
            f.model.transcribe(recordingID: noAudio.id)
            guard case .failed = f.model.state(for: noAudio.id) else { return XCTFail("Missing audio accepted") }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(f.model.revision, 0)
        }
    }

    func testQueuedRecordingIsRevalidatedBeforeEngineStarts() {
        run {
            let f = try await self.fixture(ready: false)
            let id = f.ids[0]
            f.model.transcribe(recordingID: id)
            var recording = try XCTUnwrap(f.app.recordings.first { $0.id == id })
            recording.status = .recording
            try f.store.save(recording)
            await f.manager.prepare()
            try await self.settle { if case .failed = f.model.state(for: id) { return true }; return false }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
        }
    }

    func testFailedFirstRecordingDoesNotDropSecondAndOldStatesRemain() {
        run {
            let f = try await self.fixture()
            for id in f.ids { f.model.transcribe(recordingID: id) }
            try await self.settle { await f.engine.calls.count == 1 }
            await f.engine.finish(0, .failure(TestFailure.inference))
            try await self.settle { await f.engine.calls.count == 2 }
            await f.engine.finish(1, .success(self.transcript("Second")))
            try await self.settle { f.model.revision == 1 }
            guard case .failed = f.model.state(for: f.ids[0]) else { return XCTFail("Lost first failure") }
            XCTAssertEqual(f.model.state(for: f.ids[1]), .completed)
            XCTAssertEqual(f.model.completedRecordingID, f.ids[1])
        }
    }

    func testControllerDoesNotRetainAppAndRejectsRequestsWithoutIt() {
        run {
            let f = try await self.fixture()
            var app: AppModel? = AppModel(store: f.store)
            let weakApp = { [weak app] in app }
            let model = LocalTranscriptionModel(app: try XCTUnwrap(app), manager: f.manager, engine: f.engine)
            app = nil
            XCTAssertNil(weakApp())
            model.transcribe(recordingID: f.ids[0])
            guard case .failed = model.state(for: f.ids[0]) else { return XCTFail("Missing app accepted") }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
        }
    }
}

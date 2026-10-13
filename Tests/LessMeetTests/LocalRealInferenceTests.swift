import Foundation
import XCTest
@testable import LessMeet

/// Opt-in real-model check. Capture uses a supplied synthetic M4A, never a microphone.
final class LocalRealInferenceTests: XCTestCase {
    @MainActor
    func testFinalizationThroughRealModelsSavesAndReopensSidecar() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["LOCAL_INFERENCE_MODEL_ROOT"],
              let audioPath = environment["LOCAL_INFERENCE_AUDIO"],
              let evidencePath = environment["LOCAL_INFERENCE_OUTPUT_ROOT"] else {
            throw XCTSkip("Set explicit model, synthetic M4A and private evidence paths for real inference.")
        }
        guard [modelPath, audioPath, evidencePath].allSatisfy({ $0.hasPrefix("/") }),
              audioPath.hasSuffix(".m4a") else {
            throw CheckFailure("Real inference requires absolute paths and a synthetic .m4a input.")
        }
        let audio = URL(fileURLWithPath: audioPath)
        let root = URL(fileURLWithPath: evidencePath, isDirectory: true)
            .appendingPathComponent("recordings-" + UUID().uuidString, isDirectory: true)
        let duration = try LocalPCMReader(url: audio).duration
        let store = try RecordingStore(root: root)
        let capture = SyntheticFinalizationCapture(audio: audio, duration: duration)
        let app = AppModel(store: store, capture: capture)
        let manager = LocalModelManager(root: URL(fileURLWithPath: modelPath, isDirectory: true))
        await manager.prepare()
        guard manager.state == .ready else {
            throw CheckFailure(manager.error ?? "Pinned model cache is not ready; no download attempted.")
        }
        let controller = LocalTranscriptionModel(app: app, manager: manager)
        defer { controller.cancel() }
        var finalized: [UUID] = []
        app.onRecordingFinalized = { id in
            finalized.append(id)
            controller.transcribe(recordingID: id)
        }
        let started = Date()
        await app.startRecording()
        guard app.phase == .recording, let id = app.selected?.id else {
            throw CheckFailure(app.error ?? "Synthetic capture did not start.")
        }
        XCTAssertNil(try store.loadLocalTranscript(for: id))
        await app.stopRecording()
        XCTAssertEqual(finalized, [id])
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(app.selected?.status, .ready)
        let metadataURL = store.directory(for: id).appendingPathComponent("recording.json")
        let metadata = try Data(contentsOf: metadataURL)
        // Retain evidence even on failure. Do not use or clean up the default library.
        print("Real inference private library: \(root.path)")
        fflush(stdout)
        var lastState = ""
        while controller.revision == 0, controller.error == nil,
              Date().timeIntervalSince(started) < 1_200 {
            try Task.checkCancellation()
            let state = String(describing: controller.state(for: id))
            if state != lastState {
                print("Real inference state: \(state)")
                fflush(stdout)
                lastState = state
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard controller.revision == 1 else {
            throw CheckFailure(controller.error ?? "Real inference exceeded the 1,200-second check limit.")
        }
        XCTAssertEqual(controller.completedRecordingID, id)
        XCTAssertEqual(controller.state(for: id), .completed)
        let transcript = try XCTUnwrap(store.loadLocalTranscript(for: id))
        XCTAssertFalse(transcript.segments.isEmpty, "Use the generated speech fixture for this check.")
        try transcript.validate()
        XCTAssertLessThanOrEqual(Set(transcript.segments.compactMap(\.speaker)).count, 8)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        let reopened = try RecordingStore(root: root)
        XCTAssertEqual(try reopened.loadLocalTranscript(for: id), transcript)
        XCTAssertEqual(try reopened.load().first?.status, .ready)
        print("Real finalization-to-sidecar result elapsedSeconds=\(Date().timeIntervalSince(started)) segments=\(transcript.segments.count) path=\(store.directory(for: id).appendingPathComponent("transcript.json").path)")
    }

    private struct CheckFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

@MainActor
private final class SyntheticFinalizationCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    private let audio: URL
    private let duration: TimeInterval
    private(set) var stopCount = 0

    init(audio: URL, duration: TimeInterval) {
        self.audio = audio
        self.duration = duration
    }

    func start(directory: URL) async throws {
        try FileManager.default.copyItem(at: audio, to: directory.appendingPathComponent("combined.m4a"))
    }

    func stop() async throws -> CaptureResult {
        stopCount += 1
        return CaptureResult(duration: duration, warning: nil)
    }
}

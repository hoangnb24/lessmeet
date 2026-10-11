import XCTest
@testable import LessMeet

@MainActor
private final class FinalizationCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    var result: Result<CaptureResult, Error> = .success(.init(duration: 12, warning: nil))
    var stopCount = 0
    var duringStop: (() async -> Void)?
    func start(directory: URL) async throws {}
    func stop() async throws -> CaptureResult {
        stopCount += 1
        await duringStop?()
        return try result.get()
    }
}

final class RecordingFinalizationTests: XCTestCase {
    @MainActor
    func testCallbackSeesDurableReadyMetadataAndFiresOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let capture = FinalizationCapture()
        let model = AppModel(store: store, capture: capture)
        var callbacks: [UUID] = []
        model.onRecordingFinalized = { id in
            callbacks.append(id)
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(try? store.load().first?.id, id)
            XCTAssertEqual(try? store.load().first?.status, .ready)
            XCTAssertEqual(try? store.load().first?.duration, 12)
        }
        await model.startRecording()
        let id = try XCTUnwrap(model.selected?.id)
        // A repeated stop during the first stop must not finalize twice.
        capture.duringStop = { await model.stopRecording() }
        await model.stopRecording()
        await model.stopRecording()
        XCTAssertEqual(callbacks, [id])
        XCTAssertEqual(capture.stopCount, 1)
    }

    @MainActor
    func testFailedReadySaveDoesNotNotifyOrPublishReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root, beforeSave: { recording in
            if recording.status == .ready { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let model = AppModel(store: store, capture: FinalizationCapture())
        var callbacks = 0
        model.onRecordingFinalized = { _ in callbacks += 1 }
        await model.startRecording()
        await model.stopRecording()
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(model.selected?.status, .recording)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor
    func testInterruptedFailedAndWarningStopsDoNotNotify() async throws {
        for scenario in 0..<3 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try RecordingStore(root: root)
            let capture = FinalizationCapture()
            if scenario == 1 { capture.result = .failure(CocoaError(.fileReadCorruptFile)) }
            if scenario == 2 { capture.result = .success(.init(duration: 12, warning: "Synthetic stop warning")) }
            let model = AppModel(store: store, capture: capture)
            var callbacks = 0
            model.onRecordingFinalized = { _ in callbacks += 1 }
            await model.startRecording()
            await model.stopRecording(interruption: scenario == 0 ? "Synthetic interruption" : nil)
            XCTAssertEqual(callbacks, 0)
            XCTAssertNotNil(model.selected?.failure)
            XCTAssertEqual(model.phase, .idle)
            XCTAssertEqual(capture.stopCount, 1)
        }
    }

    @MainActor
    func testSelectionCannotRedirectFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let capture = FinalizationCapture()
        let model = AppModel(store: store, capture: capture)
        var callbacks: [UUID] = []
        model.onRecordingFinalized = { callbacks.append($0) }
        await model.startRecording()
        let id = try XCTUnwrap(model.selected?.id)
        capture.duringStop = { model.selection = UUID() }
        await model.stopRecording()
        XCTAssertEqual(callbacks, [id])
        XCTAssertEqual(model.selection, id)
    }
}

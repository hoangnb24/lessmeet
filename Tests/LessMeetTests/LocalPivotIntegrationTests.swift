import Combine
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LessMeet

@MainActor
final class LocalPivotIntegrationTests: XCTestCase {
    private enum Failure: Error { case timeout }

    private struct Fixture {
        let store: RecordingStore
        let app: AppModel
        let manager: LocalModelManager
        let engine: PivotEngine
        let transcription: LocalTranscriptionModel
        let wire: PivotWire
        let chat: LocalChatModel
        let capture: PivotCapture
    }

    private func fixture() throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("LocalPivotIntegration-\(UUID())", isDirectory: true)
        // Keep synthetic files for inspection. Never open the user's library.
        print("LocalPivotIntegration fixture: \(root.path)")
        let store = try RecordingStore(root: root.appendingPathComponent("recordings"))
        let payload = Data("synthetic model bytes; never used for inference".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let catalog = ["whisper-large-v3", "whisper-tokenizer", "nemotron3-int8"].map { id in
            LocalModelArtifact(id: id, name: id, repository: "test/models",
                revision: String(repeating: "a", count: 40), directory: id,
                files: [.init(path: id == "whisper-large-v3" ? "openai_whisper-large-v3/model.bin" : "model.bin",
                              bytes: Int64(payload.count), sha256: digest)])
        }
        let modelRoot = root.appendingPathComponent("models")
        for artifact in catalog {
            let file = modelRoot.appendingPathComponent(artifact.directory).appendingPathComponent(artifact.files[0].path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: file)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PivotDenyNetwork.self]
        let manager = LocalModelManager(root: modelRoot, catalog: catalog, configuration: configuration)
        let capture = PivotCapture()
        let app = AppModel(store: store, capture: capture)
        let engine = PivotEngine()
        let transcription = LocalTranscriptionModel(app: app, manager: manager, engine: engine)
        let wire = PivotWire()
        return Fixture(store: store, app: app, manager: manager, engine: engine,
                       transcription: transcription, wire: wire, chat: makeChat(store, wire), capture: capture)
    }

    private func makeChat(_ store: RecordingStore, _ wire: PivotWire) -> LocalChatModel {
        // Intentionally omit transcriptText: the production reader must read the sidecar.
        LocalChatModel(store: store, client: ResponsesClient(transport: { wire.open($0) }),
                       sessionID: { "synthetic-session" }, accessToken: { "synthetic-token" })
    }

    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for integration state")
        throw Failure.timeout
    }

    private func capture(_ f: Fixture) async throws -> UUID {
        await f.app.startRecording()
        XCTAssertEqual(f.app.phase, .recording)
        let id = try XCTUnwrap(f.app.selection)
        await f.app.stopRecording()
        await f.app.stopRecording()
        XCTAssertEqual(f.app.phase, .idle)
        let saved = try XCTUnwrap(f.store.load().first { $0.id == id })
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.duration, 8)
        XCTAssertEqual(f.transcription.state(for: id), .idle)
        XCTAssertNil(try f.store.loadLocalTranscript(for: id))
        return id
    }

    private func transcript(_ label: String) -> LocalTranscript {
        .init(segments: [
            .init(startMs: 125, endMs: 2300, speaker: "Speaker A", text: "\(label): first line"),
            .init(startMs: 3100, endMs: 7800, speaker: "Speaker B", text: "\(label): last line — đầy đủ")
        ])
    }

    func testReadyModelsNeverStartTranscriptionOnStopOrCaptureFailureOrReopen() async throws {
        for interrupted in [false, true] {
            let f = try fixture()
            await f.manager.startup()
            await f.app.startRecording()
            let id = try XCTUnwrap(f.app.selection)
            if interrupted {
                f.capture.onFailure?("Synthetic sleep interruption")
                try await settle { f.app.phase == .idle }
            } else {
                await f.app.stopRecording()
            }
            let reopenedApp = AppModel(store: f.store)
            let reopened = LocalTranscriptionModel(app: reopenedApp, manager: f.manager, engine: f.engine)
            await f.manager.startup()
            for _ in 0..<10 { await Task.yield() }
            let calls = await f.engine.calls.count
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(f.transcription.state(for: id), .idle)
            XCTAssertEqual(reopened.state(for: id), .idle)
            XCTAssertNil(try f.store.loadLocalTranscript(for: id))
            XCTAssertEqual(reopenedApp.selected?.status, interrupted ? .interrupted : .ready)
            if interrupted { XCTAssertEqual(reopenedApp.selected?.failure, "Synthetic sleep interruption") }
            reopened.transcribe(recordingID: id)
            try await settle { await f.engine.calls.count == 1 }
            await f.engine.finish(transcript("Explicit after reopen"))
            try await settle { reopened.state(for: id) == .completed }
        }
    }

    private func assertInput(_ wire: PivotWire, transcript: LocalTranscript,
                             historyAndQuestion: [String], roles: [String]) throws {
        let body = try wire.lastBody()
        XCTAssertEqual(body["model"] as? String, "pivot-model")
        let input = try XCTUnwrap(body["input"] as? [[String: String]])
        let content = try XCTUnwrap(input.first?["content"])
        let prefix = "Transcript data:\n"
        XCTAssertTrue(content.hasPrefix(prefix))
        let decoded = try JSONDecoder().decode(LocalTranscript.self, from: Data(content.dropFirst(prefix.count).utf8))
        // Equality checks every segment, including speaker, timing and the final line.
        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(input.dropFirst().compactMap { $0["content"] }, historyAndQuestion)
        XCTAssertEqual(input.dropFirst().compactMap { $0["role"] }, roles)
    }

    func testExplicitRequestWaitsForSharedModelsThenSendsFullSidecarAndReopensHistory() async throws {
        let f = try fixture()
        let id = try await capture(f)
        let expected = transcript("Captured recording")
        f.transcription.transcribe(recordingID: id)
        XCTAssertEqual(f.transcription.state(for: id), .queued)
        XCTAssertEqual(f.transcription.activity, .waitingForModels("Waiting for local models to be ready."))
        XCTAssertNil(try f.store.loadLocalTranscript(for: id))
        let initialCalls = await f.engine.calls
        XCTAssertTrue(initialCalls.isEmpty)
        f.chat.select(recordingID: id)
        XCTAssertEqual(f.wire.requests.count, 0)

        var publishedIDs: [UUID] = []
        let observation = f.transcription.$revision.dropFirst().sink { _ in
            publishedIDs.append(f.transcription.completedRecordingID!)
            // The complete sidecar must already be readable at publication.
            XCTAssertEqual(try? f.store.loadLocalTranscript(for: id), expected)
        }
        await f.manager.startup()
        await f.manager.startup()
        XCTAssertEqual(f.manager.state, .ready, f.manager.error ?? "")
        XCTAssertEqual(f.manager.fileCount, 3)
        try await settle { await f.engine.calls.count == 1 }
        let calls = await f.engine.calls
        XCTAssertEqual(calls[0].url, f.store.audioURL(for: id))
        XCTAssertEqual(calls[0].models, f.manager.installed)
        await f.engine.finish(expected)
        try await settle { f.transcription.state(for: id) == .completed }
        XCTAssertEqual(publishedIDs, [id])
        XCTAssertEqual(f.wire.requests.count, 0)
        withExtendedLifetime(observation) {}

        await f.chat.loadModels()
        f.chat.selectedModelSlug = "pivot-model"
        XCTAssertEqual(f.wire.requests.count, 1)
        XCTAssertEqual(f.wire.requests.first?.httpMethod, "GET")
        XCTAssertNil(f.wire.requests.first?.httpBody)
        XCTAssertEqual(f.wire.postCount, 0)
        let sending = Task { await f.chat.send("Summarize") }
        try await settle { f.wire.postCount == 1 }
        try assertInput(f.wire, transcript: expected, historyAndQuestion: ["Summarize"], roles: ["user"])
        f.wire.event(["type": "response.output_text.delta", "delta": "Summary"])
        try await settle { f.chat.partialAnswer == "Summary" }
        XCTAssertTrue(f.chat.messages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.directory(for: id).appendingPathComponent("chat.json").path))
        f.wire.complete("Summary answer")
        let saved = await sending.value
        XCTAssertTrue(saved, f.chat.error ?? "")

        let reopenedStore = try RecordingStore(root: f.store.root)
        XCTAssertEqual(try reopenedStore.loadLocalTranscript(for: id), expected)
        let reopened = makeChat(reopenedStore, f.wire)
        reopened.select(recordingID: id)
        XCTAssertEqual(reopened.messages.map(\.text), ["Summarize", "Summary answer"])
        XCTAssertEqual(reopened.messages, f.chat.messages)
        XCTAssertEqual(f.wire.postCount, 1)
        await reopened.loadModels()
        reopened.selectedModelSlug = "pivot-model"
        let followup = Task { await reopened.send("What next?") }
        try await settle { f.wire.postCount == 2 }
        try assertInput(f.wire, transcript: expected,
                        historyAndQuestion: ["Summarize", "Summary answer", "What next?"],
                        roles: ["user", "assistant", "user"])
        f.wire.complete("Next action")
        let followupSaved = await followup.value
        XCTAssertTrue(followupSaved)
        let finalStore = try RecordingStore(root: f.store.root)
        XCTAssertEqual(try ConversationStore(recordingStore: finalStore).load(for: id).messages.map(\.text),
                       ["Summarize", "Summary answer", "What next?", "Next action"])
    }

    func testSelectionDoesNotRedirectQueuedTranscriptsOrPersistStaleResponses() async throws {
        let f = try fixture()
        let first = try await capture(f)
        let second = try await capture(f)
        f.transcription.transcribe(recordingID: first)
        f.transcription.transcribe(recordingID: second)
        f.app.selection = second
        f.chat.select(recordingID: second)
        await f.manager.startup()
        try await settle { await f.engine.calls.count == 1 }
        await f.engine.finish(transcript("First only"))
        try await settle { await f.engine.calls.count == 2 }
        XCTAssertEqual(f.transcription.completedRecordingID, first)
        XCTAssertNil(try f.store.loadLocalTranscript(for: second))
        f.app.selection = first
        await f.engine.finish(transcript("Second only"))
        try await settle { f.transcription.revision == 2 }
        let calls = await f.engine.calls
        XCTAssertEqual(calls.map(\.url), [f.store.audioURL(for: first), f.store.audioURL(for: second)])
        XCTAssertTrue(calls.allSatisfy { $0.models == f.manager.installed })
        XCTAssertEqual(try f.store.loadLocalTranscript(for: first), transcript("First only"))
        XCTAssertEqual(try f.store.loadLocalTranscript(for: second), transcript("Second only"))
        XCTAssertEqual(f.wire.requests.count, 0)
        await f.chat.loadModels()
        f.chat.selectedModelSlug = "pivot-model"
        let stale = Task { await f.chat.send("Second question") }
        try await settle { f.wire.postCount == 1 }
        try assertInput(f.wire, transcript: transcript("Second only"),
                        historyAndQuestion: ["Second question"], roles: ["user"])
        f.chat.select(recordingID: first)
        f.wire.complete("Stale second answer")
        let staleSaved = await stale.value
        XCTAssertFalse(staleSaved)
        for id in [first, second] {
            XCTAssertTrue(try ConversationStore(recordingStore: f.store).load(for: id).messages.isEmpty)
        }
        let fresh = Task { await f.chat.send("First question") }
        try await settle { f.wire.postCount == 2 }
        try assertInput(f.wire, transcript: transcript("First only"),
                        historyAndQuestion: ["First question"], roles: ["user"])
        f.wire.complete("First answer")
        let freshSaved = await fresh.value
        XCTAssertTrue(freshSaved)
        let reopenedStore = try RecordingStore(root: f.store.root)
        let reopened = makeChat(reopenedStore, f.wire)
        reopened.select(recordingID: second)
        XCTAssertTrue(reopened.messages.isEmpty)
        reopened.select(recordingID: first)
        XCTAssertEqual(reopened.messages.map(\.text), ["First question", "First answer"])
        XCTAssertEqual(f.wire.postCount, 2)
    }

    func testRejectedTranscriptReplacementKeepsDurableSidecarForExplicitSend() async throws {
        let f = try fixture()
        let id = try await capture(f)
        f.transcription.transcribe(recordingID: id)
        await f.manager.startup()
        try await settle { await f.engine.calls.count == 1 }
        let expected = transcript("Keep every segment")
        await f.engine.finish(expected)
        try await settle { f.transcription.revision == 1 }
        let sidecar = f.store.directory(for: id).appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: sidecar)
        f.transcription.transcribe(recordingID: id)
        try await settle { await f.engine.calls.count == 2 }
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
        await f.engine.finish(.init(version: 99, segments: []))
        try await settle { f.transcription.activity == .idle }
        guard case .failed = f.transcription.state(for: id) else {
            return XCTFail("Invalid replacement must fail before publication")
        }
        XCTAssertEqual(f.transcription.revision, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
        let reopenedStore = try RecordingStore(root: f.store.root)
        XCTAssertEqual(try reopenedStore.loadLocalTranscript(for: id), expected)
        let chat = makeChat(reopenedStore, f.wire)
        chat.select(recordingID: id)
        XCTAssertEqual(f.wire.requests.count, 0)
        await chat.loadModels()
        chat.selectedModelSlug = "pivot-model"
        XCTAssertEqual(f.wire.postCount, 0)
        let sending = Task { await chat.send("Use saved transcript") }
        try await settle { f.wire.postCount == 1 }
        try assertInput(f.wire, transcript: expected,
                        historyAndQuestion: ["Use saved transcript"], roles: ["user"])
        f.wire.complete("Saved transcript answer")
        let saved = await sending.value
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }
}

@MainActor
private final class PivotCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    func start(directory: URL) async throws {
        // Nonempty synthetic bytes satisfy the controller's file check. No device is opened.
        try Data("synthetic audio for injected engine".utf8).write(to: directory.appendingPathComponent("combined.m4a"))
    }
    func stop() async throws -> CaptureResult { .init(duration: 8, warning: nil) }
}

private actor PivotEngine: LocalTranscriptionProcessing {
    struct Call { let url: URL; let models: InstalledLocalModels }
    private(set) var calls: [Call] = []
    private var continuation: CheckedContinuation<LocalTranscript, Error>?
    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript {
        calls.append(.init(url: audioURL, models: models))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ transcript: LocalTranscript) {
        continuation?.resume(returning: transcript)
        continuation = nil
    }
}

private final class PivotDenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Integration test attempted a model download")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private final class PivotWire: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var post: AsyncThrowingStream<ResponsesTransportEvent, Error>.Continuation?
    var requests: [URLRequest] { lock.withLock { recorded } }
    var postCount: Int { requests.filter { $0.httpMethod == "POST" }.count }
    func open(_ request: URLRequest) -> ResponsesStream {
        let pair = AsyncThrowingStream<ResponsesTransportEvent, Error>.makeStream()
        let isPost = request.httpMethod == "POST"
        lock.withLock {
            recorded.append(request)
            if isPost { post = pair.continuation }
        }
        pair.continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isPost ? "text/event-stream" : "application/json"])!))
        if !isPost {
            pair.continuation.yield(.data(Data("{\"models\":[{\"slug\":\"pivot-model\",\"display_name\":\"Synthetic\",\"visibility\":\"list\"}]}".utf8)))
            pair.continuation.finish()
        }
        return ResponsesStream(events: pair.stream, cancel: { pair.continuation.finish(throwing: CancellationError()) })
    }
    func event(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        lock.withLock { post }?.yield(.data(Data("data: ".utf8) + data + Data("\n\n".utf8)))
    }
    func complete(_ text: String) {
        event(["type": "response.completed", "response": [
            "id": "resp_pivot", "object": "response", "status": "completed",
            "output": [["id": "msg_pivot", "type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]
        ]])
        lock.withLock { post }?.finish()
    }
    func lastBody() throws -> [String: Any] {
        let request = try XCTUnwrap(requests.last { $0.httpMethod == "POST" })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

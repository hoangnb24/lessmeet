import XCTest
@testable import LessMeet

@MainActor
final class LocalChatModelTests: XCTestCase {
    private var root: URL!
    private var store: RecordingStore!
    private var wire: ChatWire!
    private var account: String?
    private var tokenGate: ChatTokenGate?
    private var tokenFailure = false
    private let recording = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalChatTests-\(UUID())")
        store = try RecordingStore(root: root)
        wire = ChatWire()
        account = "synthetic-session-a"
        tokenGate = nil
        tokenFailure = false
        try writeTranscript("Initial transcript")
    }

    override func tearDown() async throws {
        tokenGate?.release()
        try FileManager.default.removeItem(at: root)
    }

    private func makeModel(transcript: ((UUID) throws -> String)? = nil) -> LocalChatModel {
        LocalChatModel(store: store, client: ResponsesClient(transport: { [wire = wire!] in wire.open($0) }),
            sessionID: { [unowned self] in self.account }, accessToken: { [unowned self] in
                if let gate = self.tokenGate { await gate.wait() }
                if self.tokenFailure { throw NSError(domain: "SECRET-TOKEN", code: 1) }
                return "synthetic-token"
            }, transcriptText: transcript)
    }

    private func ready(_ model: LocalChatModel) async {
        model.select(recordingID: recording)
        await model.loadModels()
        model.selectedModelSlug = "fixture-model"
        XCTAssertTrue(model.canSend)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for fixture state", file: file, line: line)
    }

    private func writeTranscript(_ text: String) throws {
        let folder = store.directory(for: recording)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Synthetic bytes only. The controller never uses the production transcript writer.
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "segments": [
            ["startMs": 1200, "endMs": 2400, "speaker": "Speaker fixture", "text": text]
        ]])
        try data.write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private var chatURL: URL { store.directory(for: recording).appendingPathComponent("chat.json") }

    private func seedHistory() throws -> [ChatMessage] {
        let messages = [ChatMessage(role: .user, text: "Earlier question"), ChatMessage(role: .assistant, text: "Earlier answer")]
        try ConversationStore(recordingStore: store).save(LocalConversation(recordingID: recording, messages: messages))
        return messages
    }

    func testCompletedSaveReopenAndHistorySent() async throws {
        let earlier = try seedHistory()
        let model = makeModel()
        await ready(model)
        let sending = Task { await model.send("Summary?") }
        await waitFor { self.wire.postCount == 1 }
        wire.delta("Final")
        await waitFor { model.partialAnswer == "Final" }
        XCTAssertEqual(model.messages, earlier)
        XCTAssertEqual(try ConversationStore(recordingStore: store).load(for: recording).messages, earlier)
        XCTAssertEqual(model.pendingQuestion, "Summary?")
        XCTAssertTrue(model.busy)
        wire.complete("Final answer")
        let saved = await sending.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.messages.map(\.text), ["Earlier question", "Earlier answer", "Summary?", "Final answer"])
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.pendingQuestion)
        XCTAssertEqual(model.partialAnswer, "")
        XCTAssertNil(model.error)
        let reopened = makeModel()
        reopened.select(recordingID: recording)
        XCTAssertEqual(reopened.messages, model.messages)
        let input = try wire.input()
        XCTAssertEqual(input.dropFirst().map { $0["content"]! }, ["Earlier question", "Earlier answer", "Summary?"])
        let json = String(input[0]["content"]!.dropFirst("Transcript data:\n".count))
        let transcript = try JSONDecoder().decode(LocalTranscript.self, from: Data(json.utf8))
        XCTAssertEqual(transcript.segments[0].startMs, 1200)
        XCTAssertEqual(transcript.segments[0].endMs, 2400)
        XCTAssertEqual(transcript.segments[0].speaker, "Speaker fixture")
        XCTAssertEqual(transcript.segments[0].text, "Initial transcript")
    }

    func testNilMIMECompletedSaveReopenAndIncompletePreservesHistory() async throws {
        wire = ChatWire(postMIME: nil)
        let model = makeModel()
        await ready(model)
        let sending = Task { await model.send("Synthetic question") }
        await waitFor { self.wire.postCount == 1 }
        wire.delta("Final")
        await waitFor { model.partialAnswer == "Final" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatURL.path))
        wire.complete("Final answer")
        let saved = await sending.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.messages.map(\.text), ["Synthetic question", "Final answer"])
        let original = try Data(contentsOf: chatURL)
        let reopened = makeModel()
        reopened.select(recordingID: recording)
        XCTAssertEqual(reopened.messages, model.messages)

        for terminal in ["eof", "bare", "response.failed", "response.incomplete", "response.refusal.delta"] {
            wire = ChatWire(postMIME: nil)
            let failing = makeModel()
            await ready(failing)
            let attempt = Task { await failing.send("Another synthetic question") }
            await waitFor { self.wire.postCount == 1 }
            wire.delta("Partial")
            await waitFor { failing.partialAnswer == "Partial" }
            if terminal == "eof" { wire.finish() }
            else { wire.event(["type": terminal == "bare" ? "response.completed" : terminal]) }
            let result = await attempt.value
            XCTAssertFalse(result, terminal)
            XCTAssertEqual(try Data(contentsOf: chatURL), original)
            XCTAssertEqual(failing.messages, model.messages)
            XCTAssertFalse(failing.busy)
            XCTAssertEqual(failing.partialAnswer, "")
        }
    }

    func testFailureRefusalIncompleteEOFAndDivergenceNeverSave() async throws {
        let earlier = try seedHistory()
        let original = try Data(contentsOf: chatURL)
        for terminal in ["response.failed", "response.refusal.delta", "response.incomplete", "eof", "divergent", "bare"] {
            wire = ChatWire()
            let model = makeModel()
            await ready(model)
            let sending = Task { await model.send("Question") }
            await waitFor { self.wire.postCount == 1 }
            wire.delta("Partial")
            await waitFor { model.partialAnswer == "Partial" }
            switch terminal {
            case "eof": wire.finish()
            case "divergent": wire.complete("Different answer")
            case "bare": wire.event(["type": "response.completed"])
            default: wire.event(["type": terminal])
            }
            let result = await sending.value
            XCTAssertFalse(result, terminal)
            XCTAssertNotNil(model.error, terminal)
            XCTAssertEqual(model.messages, earlier)
            XCTAssertEqual(try Data(contentsOf: chatURL), original)
            XCTAssertFalse(model.busy)
            XCTAssertEqual(model.partialAnswer, "")
            XCTAssertNil(model.pendingQuestion)
            XCTAssertTrue(model.canSend)
        }
    }

    func testCancelStopsTransportAndAllowsNextSend() async throws {
        let model = makeModel()
        await ready(model)
        let first = Task { await model.send("Cancel this") }
        await waitFor { self.wire.postCount == 1 }
        wire.delta("Partial")
        await waitFor { model.partialAnswer == "Partial" }
        model.cancel()
        await waitFor { self.wire.postCancellations > 0 }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.partialAnswer, "")
        XCTAssertNil(model.pendingQuestion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatURL.path))
        let second = Task { await model.send("Keep this") }
        await waitFor { self.wire.postCount == 2 }
        wire.complete("Kept")
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(model.messages.map(\.text), ["Keep this", "Kept"])
    }

    func testCallerCancellationStopsOwnedTransport() async {
        let model = makeModel()
        await ready(model)
        let task = Task { await model.send("Question") }
        await waitFor { self.wire.postCount == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertGreaterThan(wire.postCancellations, 0)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.error)
    }

    func testSelectionChangeDuringTokenWaitCannotSendOrClearNewTask() async {
        let model = makeModel()
        await ready(model)
        let gate = ChatTokenGate()
        tokenGate = gate
        let old = Task { await model.send("Old") }
        await waitFor { gate.waiting }
        let nextRecording = UUID()
        model.select(recordingID: nextRecording)
        tokenGate = nil
        let next = Task { await model.loadModels() }
        await next.value
        model.select(recordingID: recording)
        model.selectedModelSlug = "fixture-model"
        let fresh = Task { await model.send("New") }
        await waitFor { self.wire.postCount == 1 }
        gate.release()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.pendingQuestion, "New")
        wire.complete("Fresh")
        let freshResult = await fresh.value
        XCTAssertTrue(freshResult)
        XCTAssertEqual(wire.postCount, 1)
    }

    func testAccountChangeDuringTokenWaitPreservesHistoryAndResetsModels() async throws {
        let earlier = try seedHistory()
        let model = makeModel()
        await ready(model)
        let gate = ChatTokenGate()
        tokenGate = gate
        let sending = Task { await model.send("Old account") }
        await waitFor { gate.waiting }
        account = "synthetic-session-b"
        model.accountChanged()
        XCTAssertEqual(model.messages, earlier)
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertNil(model.selectedModelSlug)
        XCTAssertFalse(model.canSend)
        gate.release()
        let result = await sending.value
        XCTAssertFalse(result)
        XCTAssertEqual(wire.postCount, 0)
        XCTAssertFalse(model.busy)
        tokenGate = nil
        await model.loadModels()
        XCTAssertEqual(model.models.map(\.slug), ["fixture-model"])
        XCTAssertNil(model.selectedModelSlug)
    }

    func testSessionIdentityRecheckWithoutNotification() async {
        let model = makeModel()
        await ready(model)
        let gate = ChatTokenGate()
        tokenGate = gate
        let sending = Task { await model.send("Question") }
        await waitFor { gate.waiting }
        account = "changed-without-notification"
        gate.release()
        let result = await sending.value
        XCTAssertFalse(result)
        XCTAssertEqual(wire.postCount, 0)
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertFalse(model.busy)
    }

    func testSelectionAndAccountChangesDuringStreamStopAndDiscard() async throws {
        for change in ["selection", "account", "identity-only"] {
            wire = ChatWire()
            account = "synthetic-session-a"
            let model = makeModel()
            await ready(model)
            let sending = Task { await model.send("Stale") }
            await waitFor { self.wire.postCount == 1 }
            wire.delta("Partial")
            await waitFor { model.partialAnswer == "Partial" }
            if change == "selection" { model.select(recordingID: UUID()) }
            else {
                account = "synthetic-session-b"
                if change == "account" { model.accountChanged() }
            }
            wire.complete("Partial stale answer")
            let result = await sending.value
            XCTAssertFalse(result, change)
            XCTAssertTrue(model.messages.isEmpty)
            XCTAssertEqual(model.partialAnswer, "")
            XCTAssertFalse(model.busy)
            XCTAssertGreaterThan(wire.postCancellations, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: chatURL.path))
        }
    }

    func testTranscriptAndHistorySnapshotsSurviveTokenWait() async throws {
        let model = makeModel()
        await ready(model)
        // Reread disk even when published history predates this complete exchange.
        let earlier = try seedHistory()
        let gate = ChatTokenGate()
        tokenGate = gate
        let sending = Task { await model.send("Snapshot") }
        await waitFor { gate.waiting }
        try writeTranscript("Changed after submission")
        model.selectedModelSlug = "different-picker-selection"
        gate.release()
        await waitFor { self.wire.postCount == 1 }
        let input = try wire.input()
        XCTAssertTrue(input[0]["content"]!.contains("Initial transcript"))
        XCTAssertFalse(input[0]["content"]!.contains("Changed after submission"))
        XCTAssertEqual(input.dropFirst().prefix(2).map { $0["content"]! }, earlier.map(\.text))
        XCTAssertEqual(try wire.body()["model"] as? String, "fixture-model")
        wire.complete("Answer")
        let result = await sending.value
        XCTAssertTrue(result)
    }

    func testCorruptHistoryBlocksInferenceAndIsNotEmptyReady() async throws {
        let model = makeModel()
        await ready(model)
        let corrupt = Data("not conversation JSON".utf8)
        try corrupt.write(to: chatURL)
        model.select(recordingID: recording)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.canSend)
        let result = await model.send("Question")
        XCTAssertFalse(result)
        XCTAssertEqual(wire.postCount, 0)
        XCTAssertEqual(try Data(contentsOf: chatURL), corrupt)
        model.accountChanged()
        XCTAssertNotNil(model.error)
    }

    func testReadFailureAfterSelectionRetainsPreviouslyVisibleHistory() async throws {
        let earlier = try seedHistory()
        let model = makeModel()
        await ready(model)
        try Data("corrupt".utf8).write(to: chatURL)
        let result = await model.send("Question")
        XCTAssertFalse(result)
        XCTAssertEqual(model.messages, earlier)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(wire.postCount, 0)
    }

    func testSaveFailureDoesNotPublishOrRetry() async throws {
        let earlier = try seedHistory()
        let model = makeModel()
        await ready(model)
        let sending = Task { await model.send("Unsaved") }
        await waitFor { self.wire.postCount == 1 }
        // A directory at the sidecar path forces a real store failure without permission assumptions.
        let backup = chatURL.appendingPathExtension("fixture-backup")
        try FileManager.default.moveItem(at: chatURL, to: backup)
        try FileManager.default.createDirectory(at: chatURL, withIntermediateDirectories: false)
        wire.complete("Completed but unsaved")
        let result = await sending.value
        XCTAssertFalse(result)
        XCTAssertEqual(model.messages, earlier)
        XCTAssertTrue(model.error?.contains("Could not save") == true)
        XCTAssertEqual(model.partialAnswer, "")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(wire.postCount, 1)
        try FileManager.default.removeItem(at: chatURL)
        try FileManager.default.moveItem(at: backup, to: chatURL)
        XCTAssertEqual(try ConversationStore(recordingStore: store).load(for: recording).messages, earlier)
    }

    func testMissingEmptyAndInvalidTranscriptFailBeforeInference() async throws {
        let model = makeModel()
        await ready(model)
        let url = store.directory(for: recording).appendingPathComponent("transcript.json")
        for data in [nil, Data("{\"version\":1,\"segments\":[]}".utf8), Data("invalid".utf8)] as [Data?] {
            if let data { try data.write(to: url) }
            else { try FileManager.default.removeItem(at: url) }
            let result = await model.send("Question")
            XCTAssertFalse(result)
            XCTAssertNotNil(model.error)
        }
        try writeTranscript(" \n ")
        let result = await model.send("Question")
        XCTAssertFalse(result)
        XCTAssertEqual(wire.postCount, 0)
    }

    func testInjectedTranscriptAndDuplicateSend() async {
        let model = makeModel(transcript: { _ in "In-memory rehearsal" })
        await ready(model)
        let first = Task { await model.send("First") }
        await waitFor { self.wire.postCount == 1 }
        let duplicate = await model.send("Duplicate")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.pendingQuestion, "First")
        XCTAssertTrue(model.busy)
        XCTAssertEqual(wire.postCount, 1)
        wire.complete("Answer")
        let result = await first.value
        XCTAssertTrue(result)
        XCTAssertEqual(model.messages.map(\.text), ["First", "Answer"])
    }

    func testNoAutoRequestAndValidationAndSafeTokenError() async {
        let model = makeModel()
        model.select(recordingID: recording)
        XCTAssertEqual(wire.requestCount, 0)
        account = nil
        var result = await model.send("Question")
        XCTAssertFalse(result)
        await model.loadModels()
        XCTAssertEqual(wire.requestCount, 0)
        account = "synthetic-session-a"
        await model.loadModels()
        model.selectedModelSlug = "unknown"
        result = await model.send("Question")
        XCTAssertFalse(result)
        model.selectedModelSlug = "fixture-model"
        result = await model.send(" \n")
        XCTAssertFalse(result)
        tokenFailure = true
        result = await model.send("Question")
        XCTAssertFalse(result)
        XCTAssertFalse(model.error?.contains("SECRET-TOKEN") ?? true)
        XCTAssertEqual(account, "synthetic-session-a")
        XCTAssertEqual(model.models.count, 1)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(wire.postCount, 0)
    }

    func testLateCatalogTokenDoesNotRepopulateAfterAccountChange() async {
        let model = makeModel()
        let gate = ChatTokenGate()
        tokenGate = gate
        let loading = Task { await model.loadModels() }
        await waitFor { gate.waiting }
        account = "synthetic-session-b"
        model.accountChanged()
        tokenGate = nil
        await model.loadModels()
        model.selectedModelSlug = "fixture-model"
        gate.release()
        await loading.value
        XCTAssertEqual(model.models.count, 1)
        XCTAssertEqual(model.selectedModelSlug, "fixture-model")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(wire.requestCount, 1)
    }

    func testCatalogTransportIsCanceledOnContextChange() async {
        wire = ChatWire(holdModels: true)
        let model = makeModel()
        let loading = Task { await model.loadModels() }
        await waitFor { self.wire.requestCount == 1 }
        model.accountChanged()
        wire.finishModels()
        await loading.value
        XCTAssertTrue(model.models.isEmpty)
        XCTAssertNil(model.selectedModelSlug)
        XCTAssertFalse(model.busy)
        XCTAssertGreaterThan(wire.catalogCancellations, 0)
    }

    func testQuotaErrorKeepsSessionCatalogAndAllowsExplicitRetry() async {
        let model = makeModel()
        await ready(model)
        let sending = Task { await model.send("Question") }
        await waitFor { self.wire.postCount == 1 }
        wire.event(["type": "response.failed", "response": ["error": [
            "code": "subscription_sharing_usage_limit_exceeded", "message": "SECRET-SERVER-TEXT"
        ]]])
        let result = await sending.value
        XCTAssertFalse(result)
        XCTAssertTrue(model.error?.contains("Usage") == true)
        XCTAssertFalse(model.error?.contains("SECRET-SERVER-TEXT") ?? true)
        XCTAssertEqual(account, "synthetic-session-a")
        XCTAssertEqual(model.selectedModelSlug, "fixture-model")
        XCTAssertTrue(model.canSend)
        let retry = Task { await model.send("Explicit retry") }
        await waitFor { self.wire.postCount == 2 }
        wire.complete("Success")
        let retried = await retry.value
        XCTAssertTrue(retried)
        XCTAssertNil(model.error)
    }

    func testHistoryReadErrorSurvivesCatalogLoadAndRecoversOnReselection() async throws {
        try Data("broken".utf8).write(to: chatURL)
        let model = makeModel()
        model.select(recordingID: recording)
        await model.loadModels()
        model.selectedModelSlug = "fixture-model"
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.canSend)
        model.select(recordingID: UUID())
        XCTAssertNil(model.error)
        XCTAssertTrue(model.canSend)
        model.select(recordingID: nil)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.messages.isEmpty)
    }
}

@MainActor
private final class ChatTokenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ChatWire: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var posts: [AsyncThrowingStream<ResponsesTransportEvent, Error>.Continuation] = []
    private var cancellations = 0
    private var modelCancellations = 0
    private var catalogs: [AsyncThrowingStream<ResponsesTransportEvent, Error>.Continuation] = []
    private let holdModels: Bool
    private let postMIME: String?
    init(holdModels: Bool = false, postMIME: String? = "text/event-stream") {
        self.holdModels = holdModels
        self.postMIME = postMIME
    }
    var requestCount: Int { lock.withLock { requests.count } }
    var postCount: Int { lock.withLock { posts.count } }
    var postCancellations: Int { lock.withLock { cancellations } }
    var catalogCancellations: Int { lock.withLock { modelCancellations } }

    func open(_ request: URLRequest) -> ResponsesStream {
        let pair = AsyncThrowingStream<ResponsesTransportEvent, Error>.makeStream()
        let isPost = request.httpMethod == "POST"
        lock.withLock {
            requests.append(request)
            if isPost { posts.append(pair.continuation) }
            else { catalogs.append(pair.continuation) }
        }
        let mime = isPost ? postMIME : "application/json"
        pair.continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: mime.map { ["Content-Type": $0] } ?? [:])!))
        if !isPost, !holdModels { finishModels() }
        return ResponsesStream(events: pair.stream, cancel: { [self] in
            if isPost { lock.withLock { cancellations += 1 } }
            else { lock.withLock { modelCancellations += 1 } }
            pair.continuation.finish(throwing: CancellationError())
        })
    }

    func event(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let continuation = lock.withLock { posts.last }
        continuation?.yield(.data(Data("data: ".utf8) + data + Data("\n\n".utf8)))
    }
    func delta(_ text: String) { event(["type": "response.output_text.delta", "delta": text]) }
    func complete(_ text: String) {
        event(["type": "response.completed", "response": [
            "id": "resp_fixture", "object": "response", "status": "completed",
            "output": [["id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]
        ]])
    }
    func finish() { lock.withLock { posts.last }?.finish() }
    func finishModels() {
        let continuation = lock.withLock { catalogs.last }
        continuation?.yield(.data(Data("{\"models\":[{\"slug\":\"fixture-model\",\"display_name\":\"Fixture model\",\"visibility\":\"list\"}]}".utf8)))
        continuation?.finish()
    }
    func body() throws -> [String: Any] {
        let data = lock.withLock { requests.last(where: { $0.httpMethod == "POST" })!.httpBody! }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func input() throws -> [[String: String]] { try body()["input"] as! [[String: String]] }
}

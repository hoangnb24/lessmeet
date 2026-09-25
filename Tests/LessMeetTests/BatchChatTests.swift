import XCTest
import SwiftUI
@testable import LessMeet

private final class ChatProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@MainActor (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            do {
                let (code, data) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { }
}

@MainActor private final class ChatHarness {
    let root: URL; let store: RecordingStore; let app: AppModel; let session: URLSession
    var model: RecordingCloudModel!
    var identity = CloudIdentity(owner: "alice", session: "a")
    var calls: [String] = []; var payloads: [BatchChatRequest] = []
    var status: BatchChatStatus
    var receipts: [String: BatchChatOperation] = [:]
    var loseBefore = false; var loseAfter = false; var postState = "succeeded"
    var postHTTP = 202; var gateOff = false
    var postFailure: Int?
    var oversizeRoute: String?
    var operationTransform: ((BatchChatOperation) -> BatchChatOperation)?
    var beforeReply: (() -> Void)?
    var failSave: (Recording) -> Bool = { _ in false }
    let key = "batch-v1|https://fixture.convex.site|alice"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LessMeet-Chat-\(UUID())")
        var saveHook: ((Recording) throws -> Void)?
        store = try RecordingStore(root: root, beforeSave: { try saveHook?($0) })
        let manifest = try JSONDecoder().decode(BatchManifest.self, from: Data("{\"version\":1,\"source\":{\"sha256\":\"\(String(repeating: "a", count: 64))\",\"bytes\":1,\"duration\":{\"value\":3,\"timescale\":1}},\"chunks\":[{\"sha256\":\"\(String(repeating: "b", count: 64))\",\"bytes\":1}]}".utf8))
        let id = "00000000-0000-4000-8000-000000000001"
        var local = LocalBatch(clientBatchId: id, manifest: manifest, chunkPaths: ["batch-\(id)/chunk-00.m4a"])
        local.status = .init(version: 1, batchId: "batch-chat", clientBatchId: id, manifestDigest: try manifest.digest, revision: 1, state: "complete", quotaSeconds: 3, chunks: [.init(index: 0, state: "succeeded", attempt: 1, fence: 1, retryAllowed: false, resultAvailable: true, error: nil)], aggregate: .init(state: "complete", available: true), cleanupPending: false)
        local.aggregate = .init(version: 1, batchId: "batch-chat", revision: 1, status: "complete", missingChunks: [], aggregate: .init(version: 1, durationMs: 3000, missingChunks: [], timed: [], untimed: []))
        local.results = ["0:1": .init(version: 1, batchId: "batch-chat", index: 0, attempt: 1, rawText: #" {"version":1,"segments":[{"startMs":null,"endMs":null,"speaker":"A","text":"Keep originals."}]} "#)]
        status = .init(version: 1, batchId: "batch-chat", revision: 0, contextDigest: try BatchChatValidation.digest(local), availability: "ready", exchanges: [], pending: nil)
        var recording = Recording(title: "Synthetic chat metadata"); recording.status = .ready
        recording.batches = [key: local]
        recording.cloud = ["alice": .init(recordingId: "legacy", status: "ready", transcript: "Legacy", messages: [], error: nil)]
        try store.save(recording); app = AppModel(store: store)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatProtocol.self]
        session = URLSession(configuration: config)
        saveHook = { [weak self] value in if self?.failSave(value) == true { throw CocoaError(.fileWriteOutOfSpace) } }
        model = makeModel()
        ChatProtocol.handler = { [weak self] in try self!.respond($0) }
    }
    func makeModel(app replacement: AppModel? = nil, backend: String = "https://fixture.convex.site") -> RecordingCloudModel {
        .init(app: replacement ?? app, client: .init(baseURL: URL(string: backend)!, session: session), identity: { [weak self] in self?.identity }, token: { "offline-token" })
    }
    func close() { session.invalidateAndCancel(); ChatProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
    func saved() throws -> LocalBatch { try XCTUnwrap(store.load().first?.batches?[key]) }
    func wait(_ chosen: RecordingCloudModel? = nil) async throws {
        for _ in 0..<1000 { if !(chosen ?? model).busy { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Chat fixture timed out")
    }
    func setAvailability(_ value: String) {
        status = .init(version: 1, batchId: status.batchId, revision: status.revision, contextDigest: status.contextDigest, availability: value, exchanges: status.exchanges, pending: status.pending)
    }
    func complete(_ request: BatchChatRequest, state: String = "succeeded") {
        let revision = status.revision + (state == "succeeded" ? 1 : 0)
        let operation = BatchChatOperation(version: 1, batchId: request.batchId, clientMessageId: request.clientMessageId, revision: (receipts[request.clientMessageId]?.revision ?? 0) + 1, contextDigest: request.expectedContextDigest, state: state, quota: state == "succeeded" ? "consumed" : (state == "failed" ? "released" : "reserved"), text: state == "succeeded" ? "Keep the original sources." : nil, error: state == "failed" ? .init(code: "known_failure", message: "Known failure") : nil)
        receipts[request.clientMessageId] = operation
        var exchanges = status.exchanges
        if state == "succeeded", !exchanges.contains(where: { $0.clientMessageId == request.clientMessageId }) {
            exchanges.append(.init(clientMessageId: request.clientMessageId, contextDigest: request.expectedContextDigest, message: request.message, reply: operation.text!))
        }
        status = .init(version: 1, batchId: request.batchId, revision: revision, contextDigest: request.expectedContextDigest, availability: operation.unresolved ? (state == "unknown" ? "attention" : "busy") : "ready", exchanges: exchanges, pending: operation.unresolved ? operation : nil)
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        calls.append("\(request.httpMethod!) \(request.url!.path)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-token")
        beforeReply?()
        func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        if request.url!.path.hasSuffix("/chat") {
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try encoded(status) + Data(repeating: 32, count: oversizeRoute == "status" ? 256 * 1024 : 0))
        }
        XCTAssertTrue(request.url!.path.hasSuffix("/chat/message"))
        if request.httpMethod == "POST" {
            let payload = try JSONDecoder().decode(BatchChatRequest.self, from: body(request))
            let object = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            XCTAssertEqual(Set(object.keys), ["batchId", "clientMessageId", "expectedContextDigest", "expectedHistoryRevision", "message"])
            XCTAssertEqual(try saved().chat?.request, payload) // durable before every POST
            XCTAssertFalse(try saved().chat!.confirmedAbsent)
            payloads.append(payload)
            if let postFailure { return (postFailure, Data()) }
            if gateOff { return (503, Data()) }
            if loseBefore { loseBefore = false; throw URLError(.networkConnectionLost) }
            if receipts[payload.clientMessageId] == nil { complete(payload, state: postState) }
            if loseAfter { loseAfter = false; throw URLError(.networkConnectionLost) }
            let operation = receipts[payload.clientMessageId]!
            return (postHTTP, try encoded(operationTransform?(operation) ?? operation) + Data(repeating: 32, count: oversizeRoute == "operation" ? 64 * 1024 : 0))
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.count, 2)
        XCTAssertEqual(query.first { $0.name == "batchId" }?.value, "batch-chat")
        let id = query.first { $0.name == "clientMessageId" }!.value!
        guard let operation = receipts[id] else { return (404, Data()) }
        return (200, try encoded(operationTransform?(operation) ?? operation))
    }
    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

final class BatchChatTests: XCTestCase {
    private func discoveredOperation(revision: Int64 = 3, state: String = "unknown", context: String = String(repeating: "a", count: 64), quota: String = "reserved", id: String = "00000000-0000-4000-8000-000000000009", error: String = "é") -> BatchChatOperation {
        .init(version: 1, batchId: "batch-chat", clientMessageId: id, revision: revision, contextDigest: context, state: state, quota: quota, text: nil, error: .init(code: "unresolved", message: error))
    }
    private func discoveredStatus(_ pending: BatchChatOperation?) -> BatchChatStatus {
        .init(version: 1, batchId: "batch-chat", revision: 0, contextDigest: pending?.contextDigest, availability: pending == nil ? "disabled" : "attention", exchanges: [], pending: pending)
    }
    private var regressedDiscoveredStatuses: [BatchChatStatus] {
        [discoveredStatus(discoveredOperation(revision: 2, state: "running")),
         discoveredStatus(discoveredOperation(quota: "not_enforced")),
         discoveredStatus(discoveredOperation(revision: 4, context: String(repeating: "b", count: 64))),
         discoveredStatus(discoveredOperation(revision: 4, state: "running")),
         discoveredStatus(discoveredOperation(error: "e\u{301}")),
         discoveredStatus(nil),
         discoveredStatus(discoveredOperation(id: "00000000-0000-4000-8000-000000000008"))]
    }
    func testStatusOnlyRegressionDirectMonotonicityAndDisappearance() throws {
        let prior = discoveredStatus(discoveredOperation())
        for incoming in regressedDiscoveredStatuses { XCTAssertThrowsError(try incoming.validate(batchID: "batch-chat", previous: prior)) }
    }
    @MainActor func testStatusOnlyRegressionPreservesDiskPublicationAndReopen() async throws {
        for incoming in regressedDiscoveredStatuses {
            let h = try ChatHarness(); defer { h.close() }
            h.status = discoveredStatus(discoveredOperation())
            h.model.refreshBatchChat(); try await h.wait(); XCTAssertNil(h.model.error)
            let prior = try h.saved().chat
            XCTAssertNil(prior?.request)
            h.status = incoming
            let app = AppModel(store: h.store), model = h.makeModel(app: app)
            model.refreshBatchChat(); try await h.wait(model)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(try h.saved().chat, prior)
            XCTAssertEqual(Array(try h.saved().chat?.status?.pending?.error?.message.utf8 ?? "".utf8), Array(prior?.status?.pending?.error?.message.utf8 ?? "".utf8))
            XCTAssertEqual(model.batch(app.selected!)?.chat, prior)
            let reopened = AppModel(store: h.store)
            XCTAssertEqual(h.makeModel(app: reopened).batch(reopened.selected!)?.chat, prior)
            XCTAssertTrue(h.payloads.isEmpty)
        }
    }
    @MainActor func testActualSendSaveReopenAndLegacyIsolation() async throws {
        let h = try ChatHarness(); defer { h.close() }
        let original = try h.saved()
        XCTAssertEqual(try BatchChatValidation.digest(original), "4a195290a6dc1ce464d0b85052bda62331d13f17a293cb7eb7005a79f4cae2e0") // independent Node crypto/JSON.stringify vector
        h.model.sendBatchQuestion("  What was decided?\n"); try await h.wait()
        XCTAssertNil(h.model.error)
        let saved = try h.saved()
        XCTAssertNil(saved.chat?.request); XCTAssertEqual(saved.chat?.status?.exchanges.first?.message, "  What was decided?\n")
        XCTAssertEqual(saved.results, original.results); XCTAssertEqual(saved.aggregate, original.aggregate)
        let app = AppModel(store: h.store), model = h.makeModel(app: app)
        XCTAssertEqual(model.batch(app.selected!)?.chat, saved.chat)
        XCTAssertEqual(model.cached(app.selected!)?.messages, [])
        XCTAssertNil(h.makeModel(app: app, backend: "https://other.convex.site").batch(app.selected!))
        h.identity = .init(owner: "bob", session: "b"); XCTAssertNil(model.batch(app.selected!))
    }
    @MainActor func testLostResponseUnknownBlocksReplacementAndLateCompletionGateOffReads() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.loseAfter = true; h.postState = "unknown"
        h.model.sendBatchQuestion("Decision?"); try await h.wait(); XCTAssertNotNil(h.model.error)
        let request = try XCTUnwrap(h.saved().chat?.request)
        let app = AppModel(store: h.store), model = h.makeModel(app: app)
        model.refreshBatchChat(); try await h.wait(model)
        XCTAssertEqual(try h.saved().chat?.operation?.state, "unknown")
        model.sendBatchQuestion("Replacement"); try await h.wait(model)
        model.resendAbsentBatchQuestion(); try await h.wait(model)
        XCTAssertEqual(h.payloads.count, 1)
        h.complete(request); h.gateOff = true; h.setAvailability("disabled")
        model.refreshBatchChat(); try await h.wait(model)
        XCTAssertNil(model.error); XCTAssertNil(try h.saved().chat?.request)
        XCTAssertEqual(try h.saved().chat?.status?.exchanges.count, 1)
        model.refreshBatchChat(); try await h.wait(model); XCTAssertEqual(h.payloads.count, 1)
    }
    @MainActor func testConfirmedAbsentExplicitSamePayloadOnlyAndTerminalReplay() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.loseBefore = true
        h.model.sendBatchQuestion("Exact payload\n"); try await h.wait()
        let payload = try XCTUnwrap(h.saved().chat?.request)
        let app = AppModel(store: h.store), model = h.makeModel(app: app)
        model.refreshBatchChat(); try await h.wait(model)
        XCTAssertTrue(try h.saved().chat!.confirmedAbsent); XCTAssertEqual(h.payloads.count, 1)
        model.sendBatchQuestion("Must not replace"); try await h.wait(model); XCTAssertEqual(h.payloads.count, 1)
        h.postHTTP = 200 // same identity terminal replay is a permitted response
        model.resendAbsentBatchQuestion(); try await h.wait(model)
        XCTAssertNil(model.error); XCTAssertEqual(h.payloads, [payload, payload])
        XCTAssertNil(try h.saved().chat?.request)
        XCTAssertEqual(try h.saved().chat?.status?.exchanges.count, 1)
    }
    @MainActor func testDisabledAndAllUnavailableStatesNeverPost() async throws {
        let h = try ChatHarness(); defer { h.close() }
        for state in ["disabled", "incomplete", "context_too_large", "history_full", "busy", "attention"] {
            h.setAvailability(state); h.model.sendBatchQuestion("Question"); try await h.wait()
            XCTAssertNotNil(h.model.error); XCTAssertEqual(try h.saved().chat?.status?.availability, state)
            XCTAssertFalse(BatchChatView.availabilityText(state).isEmpty)
        }
        XCTAssertTrue(h.payloads.isEmpty)
    }
    @MainActor func testGateOffPostPreservesIdentityThenGetAbsence() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.gateOff = true
        h.model.sendBatchQuestion("Question"); try await h.wait()
        let request = try XCTUnwrap(h.saved().chat?.request); XCTAssertNotNil(h.model.error)
        h.setAvailability("disabled"); h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNil(h.model.error); XCTAssertEqual(try h.saved().chat?.request, request)
        h.model.resendAbsentBatchQuestion(); try await h.wait(); XCTAssertEqual(h.payloads.count, 1)
    }
    @MainActor func testDiskFailureBeforePostAndBeforeHistoryPublish() async throws {
        for point in ["request", "operation", "history"] {
            let h = try ChatHarness(); defer { h.close() }
            h.failSave = { recording in
                let chat = recording.batches?.values.first?.chat
                if point == "request" { return chat?.request != nil }
                if point == "operation" { return chat?.operation != nil }
                return chat?.status?.exchanges.isEmpty == false
            }
            h.model.sendBatchQuestion("Question"); try await h.wait(); XCTAssertNotNil(h.model.error)
            XCTAssertTrue(h.model.batch(h.app.selected!)?.chat?.status?.exchanges.isEmpty != false)
            if point == "request" { XCTAssertTrue(h.payloads.isEmpty) }
            else {
                XCTAssertNotNil(try h.saved().chat?.request)
                h.failSave = { _ in false }
                let app = AppModel(store: h.store), model = h.makeModel(app: app)
                model.refreshBatchChat(); try await h.wait(model)
                XCTAssertNil(model.error); XCTAssertEqual(try h.saved().chat?.status?.exchanges.count, 1)
                XCTAssertEqual(h.payloads.count, 1)
            }
        }
    }
    @MainActor func testAccountSwitchAndCancellationFenceLateReply() async throws {
        for cancel in [false, true] {
            let h = try ChatHarness(); defer { h.close() }
            h.beforeReply = {
                if h.calls.last?.hasPrefix("POST") == true {
                    if cancel { h.model.cancel() } else { h.identity = .init(owner: "bob", session: "b") }
                }
            }
            h.model.sendBatchQuestion("Question"); try await h.wait()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNotNil(try h.saved().chat?.request)
            XCTAssertNil(try h.saved().chat?.operation)
            XCTAssertTrue(try h.saved().chat?.status?.exchanges.isEmpty == true)
            h.beforeReply = nil; h.identity = .init(owner: "alice", session: "a")
            h.model.refreshBatchChat(); try await h.wait()
            XCTAssertNil(h.model.error); XCTAssertEqual(h.payloads.count, 1)
        }
    }
    @MainActor func testOperationIdentityContextRevisionMismatchRejectsBeforeSave() async throws {
        for field in ["id", "context", "revision", "batch", "state", "quota", "reply"] {
            let h = try ChatHarness(); defer { h.close() }
            h.operationTransform = { op in
                .init(version: 1, batchId: field == "batch" ? "other-batch" : op.batchId, clientMessageId: field == "id" ? UUID().uuidString.lowercased() : op.clientMessageId, revision: field == "revision" ? 0 : op.revision, contextDigest: field == "context" ? String(repeating: "0", count: 64) : op.contextDigest, state: field == "state" ? "invented" : op.state, quota: field == "quota" ? "reserved" : op.quota, text: field == "reply" ? String(repeating: "x", count: 32767) : op.text, error: op.error)
            }
            h.model.sendBatchQuestion("Question"); try await h.wait()
            XCTAssertNotNil(h.model.error); XCTAssertNil(try h.saved().chat?.operation)
            XCTAssertNotNil(try h.saved().chat?.request)
            h.operationTransform = nil; h.model.refreshBatchChat(); try await h.wait()
            XCTAssertNil(h.model.error); XCTAssertEqual(h.payloads.count, 1)
        }
    }
    @MainActor func testContextMismatchAndHistoryRollbackPreserveSavedMessages() async throws {
        let h = try ChatHarness(); defer { h.close() }
        let original = h.status
        h.status = .init(version: 1, batchId: original.batchId, revision: 0, contextDigest: String(repeating: "0", count: 64), availability: "ready", exchanges: [], pending: nil)
        h.model.sendBatchQuestion("Question"); try await h.wait(); XCTAssertNotNil(h.model.error); XCTAssertTrue(h.payloads.isEmpty)
        h.status = original; h.model.sendBatchQuestion("Question"); try await h.wait()
        let saved = try h.saved().chat
        h.status = original; h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNotNil(h.model.error); XCTAssertEqual(try h.saved().chat, saved)
    }
    @MainActor func testKnownFailureAllowsOnlyNewExplicitQuestionAndObserved404NeverResends() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.postState = "failed"
        h.model.sendBatchQuestion("First"); try await h.wait(); XCTAssertNil(h.model.error)
        XCTAssertNil(try h.saved().chat?.request); XCTAssertEqual(try h.saved().chat?.operation?.state, "failed")
        h.postState = "unknown"; h.model.sendBatchQuestion("Second"); try await h.wait()
        XCTAssertEqual(h.payloads.count, 2); XCTAssertNotEqual(h.payloads[0].clientMessageId, h.payloads[1].clientMessageId)
        h.receipts = [:]; h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNotNil(h.model.error); XCTAssertFalse(try h.saved().chat!.confirmedAbsent)
        h.model.resendAbsentBatchQuestion(); try await h.wait(); XCTAssertEqual(h.payloads.count, 2)
    }
    func testMessageReplyHistoryBounds() throws {
        XCTAssertTrue(BatchChatValidation.message(String(repeating: "é", count: 4096)))
        XCTAssertFalse(BatchChatValidation.message(String(repeating: "é", count: 4096) + "x"))
        XCTAssertTrue(try BatchChatValidation.reply(String(repeating: "x", count: 32766)))
        XCTAssertFalse(try BatchChatValidation.reply(String(repeating: "x", count: 32767)))
        XCTAssertFalse(try BatchChatValidation.reply(String(repeating: "\n", count: 16384)))
        let payload = BatchChatRequest(batchId: "batch-chat", clientMessageId: UUID().uuidString.lowercased(), expectedContextDigest: String(repeating: "a", count: 64), expectedHistoryRevision: 0, message: "x" + String(repeating: "\u{1}", count: 8191))
        XCTAssertNoThrow(try payload.validate()); XCTAssertGreaterThan(try BatchChatValidation.jsonBytes(payload), 16384)
        let exchanges = (0..<21).map { _ in BatchChatStatus.Exchange(clientMessageId: UUID().uuidString.lowercased(), contextDigest: String(repeating: "a", count: 64), message: "x", reply: "y") }
        let status = BatchChatStatus(version: 1, batchId: "b", revision: 21, contextDigest: nil, availability: "history_full", exchanges: exchanges, pending: nil)
        XCTAssertThrowsError(try status.validate(batchID: "b"))
        let large = exchanges.prefix(5).map { BatchChatStatus.Exchange(clientMessageId: $0.clientMessageId, contextDigest: $0.contextDigest, message: "x", reply: String(repeating: "a", count: 32766)) }
        XCTAssertThrowsError(try BatchChatStatus(version: 1, batchId: "b", revision: 5, contextDigest: nil, availability: "history_full", exchanges: large, pending: nil).validate(batchID: "b"))
        XCTAssertFalse(BatchChatValidation.exact("é", "e\u{301}"))
    }
    @MainActor func testAllChatStatesRenderInMemoryWithoutFixtureWrites() async throws {
        let h = try ChatHarness(); defer { h.close() }
        h.model.sendBatchQuestion("What was decided?"); try await h.wait()
        for state in ["ready", "disabled", "incomplete", "context_too_large", "history_full", "busy", "attention"] {
            var batch = try h.saved()
            let status = try XCTUnwrap(batch.chat?.status)
            batch.chat?.status = .init(version: 1, batchId: status.batchId, revision: status.revision, contextDigest: status.contextDigest, availability: state, exchanges: status.exchanges, pending: nil)
            let view = NSHostingView(rootView: BatchChatView(batch: batch, cloud: h.model, enabled: true).environment(\.colorScheme, .light))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 700); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).count, 1000)
        }
    }
    @MainActor func testSameRevisionHistoryRewriteRejectsBeforeReplacement() async throws {
        let h = try ChatHarness(); defer { h.close() }
        h.model.sendBatchQuestion("é"); try await h.wait()
        let saved = try h.saved().chat, status = h.status, first = try XCTUnwrap(status.exchanges.first)
        h.status = .init(version: 1, batchId: status.batchId, revision: status.revision, contextDigest: status.contextDigest, availability: "ready", exchanges: [.init(clientMessageId: first.clientMessageId, contextDigest: first.contextDigest, message: "e\u{301}", reply: first.reply)], pending: nil)
        h.model.refreshBatchChat(); try await h.wait(); XCTAssertNotNil(h.model.error)
        XCTAssertEqual(try h.saved().chat, saved)
    }
    @MainActor func testMissingSuccessInHistoryRetainsRequestUntilConsistentRead() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.loseAfter = true
        let empty = h.status
        h.model.sendBatchQuestion("Question"); try await h.wait()
        let completed = h.status
        h.status = empty
        h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNotNil(try h.saved().chat?.request)
        h.model.sendBatchQuestion("Replacement"); try await h.wait(); XCTAssertEqual(h.payloads.count, 1)
        h.status = completed; h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNil(h.model.error); XCTAssertNil(try h.saved().chat?.request)
    }
    @MainActor func testHistoryConflictAfterAbsenceDoesNotRewriteOrResendPayload() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.loseBefore = true
        h.model.sendBatchQuestion("Question"); try await h.wait()
        let request = try XCTUnwrap(h.saved().chat?.request), s = h.status
        h.status = .init(version: 1, batchId: s.batchId, revision: 1, contextDigest: s.contextDigest, availability: "ready", exchanges: [.init(clientMessageId: UUID().uuidString.lowercased(), contextDigest: s.contextDigest!, message: "Other client question", reply: "Other reply")], pending: nil)
        h.model.resendAbsentBatchQuestion(); try await h.wait()
        XCTAssertNotNil(h.model.error); XCTAssertEqual(h.payloads.count, 1)
        XCTAssertEqual(try h.saved().chat?.request, request)
    }
    @MainActor func testActualEscapedMessageBodyExceedsTranscriptionLimitWithinChatLimit() async throws {
        let h = try ChatHarness(); defer { h.close() }
        let text = "x" + String(repeating: "\u{1}", count: 8191)
        h.model.sendBatchQuestion(text); try await h.wait()
        XCTAssertNil(h.model.error); XCTAssertEqual(h.payloads.first?.message, text)
        XCTAssertEqual(try h.saved().chat?.status?.exchanges.first?.message, text)
    }
    @MainActor func testHTTPConflictKeepsExactPayloadAndDoesNotAutomaticallyPostAgain() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.postFailure = 409
        h.model.sendBatchQuestion("Question"); try await h.wait()
        let payload = try XCTUnwrap(h.saved().chat?.request)
        XCTAssertNotNil(h.model.error); XCTAssertNil(try h.saved().chat?.operation)
        h.model.refreshBatchChat(); try await h.wait()
        XCTAssertEqual(try h.saved().chat?.request, payload); XCTAssertEqual(h.payloads.count, 1)
        XCTAssertTrue(try h.saved().chat!.confirmedAbsent)
    }
    @MainActor func testBoundedWireResponsesRejectBeforeSaveAndRecover() async throws {
        for route in ["status", "operation"] {
            let h = try ChatHarness(); defer { h.close() }; h.oversizeRoute = route
            h.model.sendBatchQuestion("Question"); try await h.wait()
            XCTAssertNotNil(h.model.error)
            if route == "status" { XCTAssertNil(try h.saved().chat); XCTAssertTrue(h.payloads.isEmpty) }
            else {
                XCTAssertNotNil(try h.saved().chat?.request); XCTAssertNil(try h.saved().chat?.operation)
                h.oversizeRoute = nil; h.model.refreshBatchChat(); try await h.wait()
                XCTAssertNil(h.model.error); XCTAssertEqual(h.payloads.count, 1)
            }
        }
    }
    @MainActor func testStatusPendingEvidenceCannotBecomeResendableAfter404() async throws {
        let h = try ChatHarness(); defer { h.close() }; h.loseBefore = true
        h.model.sendBatchQuestion("Question"); try await h.wait()
        let request = try XCTUnwrap(h.saved().chat?.request)
        h.complete(request, state: "unknown"); h.receipts = [:]
        h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNil(h.model.error); XCTAssertEqual(try h.saved().chat?.operation?.state, "unknown")
        XCTAssertFalse(try h.saved().chat!.confirmedAbsent)
        h.setAvailability("ready")
        h.model.resendAbsentBatchQuestion(); try await h.wait()
        XCTAssertNotNil(h.model.error); XCTAssertEqual(h.payloads.count, 1)
    }
    @MainActor func testOperationVersionsIndependentOfHistoryAndEqualVersionConflictRejected() async throws {
        let h = try ChatHarness(); defer { h.close() }
        for text in ["First", "Second", "Third"] { h.model.sendBatchQuestion(text); try await h.wait(); XCTAssertNil(h.model.error) }
        XCTAssertEqual(h.payloads.last?.expectedHistoryRevision, 2)
        XCTAssertEqual(try h.saved().chat?.operation?.revision, 1) // never compare with history 3
        XCTAssertEqual(try h.saved().chat?.status?.revision, 3)
        h.postState = "queued"; h.model.sendBatchQuestion("Fourth"); try await h.wait()
        let previous = try XCTUnwrap(h.saved().chat?.operation)
        XCTAssertEqual(previous.revision, 1)
        h.operationTransform = { op in .init(version: 1, batchId: op.batchId, clientMessageId: op.clientMessageId, revision: op.revision, contextDigest: op.contextDigest, state: "unknown", quota: op.quota, text: nil, error: nil) }
        h.model.refreshBatchChat(); try await h.wait(); XCTAssertNotNil(h.model.error)
        XCTAssertEqual(try h.saved().chat?.operation, previous)
        h.operationTransform = nil
        let request = try XCTUnwrap(h.saved().chat?.request)
        h.complete(request, state: "unknown"); h.model.refreshBatchChat(); try await h.wait()
        XCTAssertNil(h.model.error); XCTAssertEqual(try h.saved().chat?.operation?.revision, 2)
        XCTAssertEqual(try h.saved().chat?.status?.revision, 3)
    }
    @MainActor func testStatusOnlyDisappearanceResolvesLateSuccessAndKnownFailureWithoutPayload() async throws {
        for terminalState in ["succeeded", "failed"] {
            let h = try ChatHarness(); defer { h.close() }
            let digest = try XCTUnwrap(h.status.contextDigest)
            let old = discoveredOperation(context: digest)
            h.status = discoveredStatus(old)
            h.model.refreshBatchChat(); try await h.wait()
            let prior = try h.saved().chat
            let terminal = BatchChatOperation(version: 1, batchId: old.batchId, clientMessageId: old.clientMessageId, revision: 4, contextDigest: digest, state: terminalState, quota: terminalState == "succeeded" ? "consumed" : "released", text: terminalState == "succeeded" ? "Late reply" : nil, error: nil)
            let exchanges: [BatchChatStatus.Exchange] = terminalState == "succeeded" ? [.init(clientMessageId: old.clientMessageId, contextDigest: digest, message: "Question sent by another client", reply: "Late reply")] : []
            h.status = .init(version: 1, batchId: old.batchId, revision: Int64(exchanges.count), contextDigest: digest, availability: "ready", exchanges: exchanges, pending: nil)
            // A disappearing pending field does not override a still-unknown exact receipt.
            h.receipts[old.clientMessageId] = old
            h.model.refreshBatchChat(); try await h.wait(); XCTAssertNotNil(h.model.error)
            XCTAssertEqual(try h.saved().chat, prior)
            h.receipts[old.clientMessageId] = terminal
            let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
            model.refreshBatchChat(); try await h.wait(model); XCTAssertNil(model.error)
            XCTAssertNil(try h.saved().chat?.request)
            XCTAssertNil(try h.saved().chat?.status?.pending)
            XCTAssertEqual(try h.saved().chat?.observedOperation, terminal)
            XCTAssertEqual(try h.saved().chat?.status?.exchanges, exchanges)
            XCTAssertTrue(h.payloads.isEmpty)
            model.sendBatchQuestion("Fresh explicit question"); try await h.wait(model)
            XCTAssertNil(model.error); XCTAssertEqual(h.payloads.count, 1)
            XCTAssertNotEqual(h.payloads[0].clientMessageId, old.clientMessageId)
        }
    }
    @MainActor func testStatusOnlyIdentityReplacementRequiresOldTerminalAndSurvivesDiskFailure() async throws {
        let h = try ChatHarness(); defer { h.close() }
        let old = discoveredOperation(), next = discoveredOperation(revision: 1, state: "queued", id: "00000000-0000-4000-8000-000000000008")
        h.status = discoveredStatus(old); h.model.refreshBatchChat(); try await h.wait()
        let prior = try h.saved().chat
        h.status = discoveredStatus(next)
        h.model.refreshBatchChat(); try await h.wait(); XCTAssertNotNil(h.model.error) // exact old ID404
        XCTAssertEqual(try h.saved().chat, prior)
        let terminal = BatchChatOperation(version: 1, batchId: old.batchId, clientMessageId: old.clientMessageId, revision: 4, contextDigest: old.contextDigest, state: "failed", quota: "released", text: nil, error: nil)
        h.receipts[old.clientMessageId] = terminal
        h.failSave = { $0.batches?.values.first?.chat?.status?.pending?.clientMessageId == next.clientMessageId }
        h.model.refreshBatchChat(); try await h.wait(); XCTAssertNotNil(h.model.error)
        XCTAssertEqual(try h.saved().chat, prior); XCTAssertEqual(h.model.batch(h.app.selected!)?.chat, prior)
        h.failSave = { _ in false }
        let reopened = AppModel(store: h.store), model = h.makeModel(app: reopened)
        model.refreshBatchChat(); try await h.wait(model); XCTAssertNil(model.error)
        XCTAssertEqual(try h.saved().chat?.status?.pending, next)
        XCTAssertNil(try h.saved().chat?.request); XCTAssertTrue(h.payloads.isEmpty)
    }
    func testStatusOnlyTerminalResolutionRequiresMatchingContextAndHistory() throws {
        let old = discoveredOperation(), prior = discoveredStatus(old)
        let success = BatchChatOperation(version: 1, batchId: old.batchId, clientMessageId: old.clientMessageId, revision: 4, contextDigest: old.contextDigest, state: "succeeded", quota: "consumed", text: "é", error: nil)
        XCTAssertThrowsError(try discoveredStatus(nil).validate(batchID: old.batchId, previous: prior, resolvedPrevious: success))
        let wrongText = BatchChatStatus(version: 1, batchId: old.batchId, revision: 1, contextDigest: old.contextDigest, availability: "disabled", exchanges: [.init(clientMessageId: old.clientMessageId, contextDigest: old.contextDigest, message: "Other client question", reply: "e\u{301}")], pending: nil)
        XCTAssertThrowsError(try wrongText.validate(batchID: old.batchId, previous: prior, resolvedPrevious: success))
        XCTAssertThrowsError(try discoveredStatus(nil).validate(batchID: old.batchId, previous: prior, resolvedPrevious: discoveredOperation(revision: 4, context: String(repeating: "b", count: 64))))
    }
}

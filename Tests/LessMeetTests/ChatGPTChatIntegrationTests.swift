import XCTest
@testable import LessMeet

@MainActor
final class ChatGPTChatIntegrationTests: XCTestCase {
    func testRestoredSessionRefreshesThenSavesAndReopensChat() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanup() }
        let session = fixture.session()
        let originalSession = session.sessionIdentifier
        let chat = fixture.chat(session)
        chat.select(recordingID: fixture.recording.id)
        await chat.loadModels()
        XCTAssertEqual(fixture.refreshes, 1)
        XCTAssertEqual(session.sessionIdentifier, originalSession)
        chat.selectedModelSlug = "fixture-model"
        let saved = await chat.send("What was decided?")
        XCTAssertTrue(saved, chat.error ?? "Expected completed local save")
        XCTAssertEqual(fixture.wire.authorizations, ["Bearer fixture-access-new", "Bearer fixture-access-new"])
        XCTAssertEqual(fixture.refreshes, 1)
        XCTAssertEqual(try fixture.credentials.record().registrations.first?.tokens?.refresh, "fixture-refresh-new")
        let restored = fixture.session()
        let reopened = fixture.chat(restored)
        reopened.select(recordingID: fixture.recording.id)
        XCTAssertEqual(reopened.messages.map(\.text), ["What was decided?", "Use a local transcript."])
        XCTAssertEqual(restored.sessionIdentifier, originalSession)
    }

    func testRevokedRefreshEndsSessionWithoutSendingOrChangingHistory() async throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanup() }
        fixture.revokeRefresh = true
        let history = [ChatMessage(role: .user, text: "Earlier"), ChatMessage(role: .assistant, text: "Saved")]
        try ConversationStore(recordingStore: fixture.store).save(
            LocalConversation(recordingID: fixture.recording.id, messages: history))
        let session = fixture.session()
        let chat = fixture.chat(session)
        chat.select(recordingID: fixture.recording.id)
        await chat.loadModels()
        XCTAssertNil(session.sessionIdentifier)
        XCTAssertFalse(session.canUseChatGPTPlan)
        XCTAssertTrue(chat.models.isEmpty)
        XCTAssertFalse(chat.canSend)
        XCTAssertTrue(fixture.wire.authorizations.isEmpty)
        XCTAssertEqual(chat.messages, history)
        XCTAssertEqual(try ConversationStore(recordingStore: fixture.store).load(for: fixture.recording.id).messages, history)
    }

    func testIdentityOnlySessionCannotReachResponsesTransport() async throws {
        let fixture = try IntegrationFixture(planEnabled: false)
        defer { fixture.cleanup() }
        let session = fixture.session()
        XCTAssertNotNil(session.sessionIdentifier)
        XCTAssertFalse(session.canUseChatGPTPlan)
        let chat = fixture.chat(session)
        chat.select(recordingID: fixture.recording.id)
        await chat.loadModels()
        XCTAssertNotNil(chat.error)
        XCTAssertTrue(chat.models.isEmpty)
        XCTAssertTrue(fixture.wire.authorizations.isEmpty)
        XCTAssertEqual(fixture.refreshes, 0)
    }
}

@MainActor
private final class IntegrationFixture {
    let root: URL
    let store: RecordingStore
    let recording = Recording(title: "Synthetic integration", status: .ready)
    let credentials: IntegrationCredentials
    let wire = IntegrationResponsesWire()
    var refreshes = 0
    var revokeRefresh = false
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    init(planEnabled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatGPTIntegration-\(UUID())")
        store = try RecordingStore(root: root)
        try store.save(recording)
        let profile = ChatGPTProfile(id: "fixture-profile", displayName: "Fixture", clientID: "oaiapp_fixture")
        let token = ChatGPTTokenSet(access: "fixture-access-old", refresh: "fixture-refresh-old",
            identity: "fixture-previously-validated-identity",
            scopes: planEnabled ? Set(ChatGPTAuthConstants.planScopes.split(separator: " ").map(String.init)) : ["openid"],
            expiresAt: now.addingTimeInterval(-1), earliestRefreshAt: nil)
        var record = ChatGPTAuthRecord()
        record.registrations = [ChatGPTRegistration(clientID: profile.clientID, subject: "fixture-subject", profile: profile, tokens: token)]
        record.activeProfileID = profile.id
        record.sessionID = "fixture-session"
        credentials = try IntegrationCredentials(record)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func session() -> ChatGPTSession {
        ChatGPTSession(store: credentials, credentialLock: IntegrationLock(), send: { [unowned self] request in
            let object: [String: Any]
            var status = 200
            if request.url?.path == "/.well-known/openid-configuration" {
                object = ["issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/authorize",
                    "token_endpoint": "https://auth.openai.com/token", "jwks_uri": "https://auth.openai.com/jwks"]
            } else if request.url?.path == "/token" {
                self.refreshes += 1
                if self.revokeRefresh { status = 400; object = ["error": "invalid_grant"] }
                else {
                    object = ["access_token": "fixture-access-new", "refresh_token": "fixture-refresh-new",
                        "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTAuthConstants.planScopes]
                }
            } else { throw ChatGPTAuthError.response }
            return ChatGPTAuthHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: object))
        }, makeListener: { IntegrationListener() }, openBrowser: { _ in throw ChatGPTAuthError.browser }, now: { [now] in now })
    }

    func chat(_ session: ChatGPTSession) -> LocalChatModel {
        LocalChatModel(store: store, client: ResponsesClient(transport: { [wire] in wire.open($0) }),
            sessionID: { session.sessionIdentifier }, accessToken: { try await session.accessToken() },
            transcriptText: { _ in "Synthetic transcript: the team decided to use a local transcript." })
    }
}

@MainActor
private final class IntegrationCredentials: ChatGPTCredentialStore {
    private var data: Data
    init(_ record: ChatGPTAuthRecord) throws { data = try JSONEncoder().encode(record) }
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func record() throws -> ChatGPTAuthRecord { try JSONDecoder().decode(ChatGPTAuthRecord.self, from: data) }
}

@MainActor
private final class IntegrationLock: ChatGPTCredentialLock {
    func acquire() async throws {}
    func release() {}
}

@MainActor
private final class IntegrationListener: ChatGPTCallbackListener {
    func start() async throws -> URL { throw ChatGPTAuthError.callback }
    func callback() async throws -> URL { throw ChatGPTAuthError.callback }
    func cancel() {}
}

private final class IntegrationResponsesWire: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []
    var authorizations: [String] { lock.withLock { headers } }
    func open(_ request: URLRequest) -> ResponsesStream {
        lock.withLock { headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
        let isPost = request.httpMethod == "POST"
        let pair = AsyncThrowingStream<ResponsesTransportEvent, Error>.makeStream()
        pair.continuation.yield(.response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isPost ? "text/event-stream" : "application/json"])!))
        let text = isPost
            ? "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture\",\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Use a local transcript.\"}]}]}}\n\n"
            : "{\"models\":[{\"slug\":\"fixture-model\",\"display_name\":\"Fixture model\",\"visibility\":\"list\"}]}"
        pair.continuation.yield(.data(Data(text.utf8)))
        pair.continuation.finish()
        return ResponsesStream(events: pair.stream, cancel: {})
    }
}

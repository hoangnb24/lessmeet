#if LESSMEET_CHAT_UI_CHECK
import Foundation
import SwiftUI

// This entry uses product views and models. All external boundaries are local fixtures.
@MainActor
struct ChatGPTUICheckView: View {
    @StateObject private var fixture = ChatUICheckFixture()
    @State private var dark = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OFFLINE · Synthetic data only").font(.headline)
                Spacer()
                Toggle("Dark", isOn: $dark).toggleStyle(.switch)
            }.padding()
            if let context = fixture.context {
                ChatUICheckContent(context: context)
                    .id(context.id)
                    .defaultAppStorage(fixture.defaults)
            } else {
                Text("Could not create the isolated fixture. No product storage was opened.")
                    .padding()
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }
}

@MainActor
private final class ChatUICheckFixture: ObservableObject {
    let defaults = UserDefaults(suiteName: "com.lessmeet.chat-ui-check." + UUID().uuidString)!
    @Published var context: ChatUICheckContext?

    init() {
        do { context = try ChatUICheckContext() }
        catch { context = nil }
    }
}

@MainActor
private struct ChatUICheckContent: View {
    @ObservedObject var context: ChatUICheckContext
    @State private var account = false
    @State private var transcript = false
    @State private var scenario: ChatUICheckContext.Scenario = .signedOut
    @State private var mode: ChatUICheckWire.Mode = .complete

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Account fixture", selection: $scenario) {
                    ForEach(ChatUICheckContext.Scenario.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Picker("Response fixture", selection: $mode) {
                    ForEach(ChatUICheckWire.Mode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Button("Account") { account = true }
                Button("Reopen saved chat") { context.chat.select(recordingID: context.recordingID) }
            }.padding(.horizontal).padding(.bottom, 12)
            Text("Use product controls to sign in, cancel, load models, select a model and send. Links are blocked. Account fixtures reset authorization, not saved chat.")
                .font(.caption).padding(.horizontal).padding(.bottom, 12)
            Divider()
            ChatUICheckProductChat(session: context.session, chat: context.chat,
                                   recordingID: context.recordingID,
                                   openAccount: { account = true },
                                   openTranscript: { transcript = true })
            Text("Synthetic persistence: " + context.store.root.path)
                .font(.caption2).textSelection(.enabled).padding(8)
        }
        .onChange(of: scenario) { _, value in context.switchAccount(value) }
        .onChange(of: mode) { _, value in context.wire.setMode(value) }
        .sheet(isPresented: $account) {
            ChatGPTAccountSheet(session: context.session,
                                beforeAccountChange: { context.chat.accountChanged() })
        }
        .sheet(isPresented: $transcript) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Synthetic local transcript").font(.headline)
                Text(ChatUICheckContext.transcript)
                Button("Done") { transcript = false }
            }.padding(28).frame(width: 490)
        }
    }
}

@MainActor
private struct ChatUICheckProductChat: View {
    @ObservedObject var session: ChatGPTSession
    @ObservedObject var chat: LocalChatModel
    let recordingID: UUID
    let openAccount: () -> Void
    let openTranscript: () -> Void

    var body: some View {
        LocalChatView(model: chat, recordingID: recordingID,
                      canUsePlan: session.canUseChatGPTPlan,
                      openAccount: openAccount, openTranscript: openTranscript)
            .onChange(of: session.sessionIdentifier) { _, _ in chat.accountChanged() }
    }
}

@MainActor
private final class ChatUICheckContext: ObservableObject {
    enum Scenario: String, CaseIterable { case signedOut = "Signed out", consent = "Consent needed", connected = "Connected" }
    static let transcript = "Maya: We will ship the local chat layout on Friday.\nAlex: I will review keyboard navigation before Thursday."
    let id = UUID()
    let recordingID = UUID()
    let store: RecordingStore
    let wire = ChatUICheckWire()
    @Published private(set) var session: ChatGPTSession
    @Published private(set) var chat: LocalChatModel

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LessMeet-Chat-UICheck-" + UUID().uuidString, isDirectory: true)
        store = try RecordingStore(root: root)
        try store.save(Recording(id: recordingID, title: "Synthetic planning meeting", duration: 30, status: .ready))
        try store.saveLocalTranscript(LocalTranscript(segments: [
            LocalTranscriptSegment(startMs: 0, endMs: 30_000, speaker: "Maya", text: Self.transcript)
        ]), for: recordingID)
        let session = try Self.makeSession(.signedOut)
        self.session = session
        chat = Self.makeChat(store: store, session: session, wire: wire)
        chat.select(recordingID: recordingID)
    }

    func switchAccount(_ scenario: Scenario) {
        // Cancel the old context before replacing its injected models.
        session.cancelSignIn()
        chat.accountChanged()
        do {
            let replacement = try Self.makeSession(scenario)
            session = replacement
            chat = Self.makeChat(store: store, session: replacement, wire: wire)
            chat.select(recordingID: recordingID)
        } catch {
            // Encoding synthetic values should not fail. Keep the old safe context if it does.
        }
    }

    private static func makeChat(store: RecordingStore, session: ChatGPTSession,
                                 wire: ChatUICheckWire) -> LocalChatModel {
        LocalChatModel(store: store, client: ResponsesClient(transport: { wire.open($0) }),
                       sessionID: { session.sessionIdentifier }, accessToken: { try await session.accessToken() })
    }

    private static func makeSession(_ scenario: Scenario) throws -> ChatGPTSession {
        var record = ChatGPTAuthRecord()
        if scenario != .signedOut {
            let profile = ChatGPTProfile(id: "fixture-profile", displayName: "Maya · Synthetic", clientID: "fixture-client")
            record.registrations = [ChatGPTRegistration(clientID: profile.clientID, subject: "fixture-subject", profile: profile,
                tokens: ChatGPTTokenSet(access: "synthetic-access-only", refresh: nil, identity: "synthetic-identity-only",
                    scopes: scenario == .connected ? [ChatGPTAuthConstants.planScope] : ["openid"],
                    expiresAt: Date().addingTimeInterval(86_400), earliestRefreshAt: nil))]
            record.activeProfileID = profile.id
            record.sessionID = UUID().uuidString
        }
        let memory = ChatUICheckCredentials(data: try JSONEncoder().encode(record))
        return ChatGPTSession(store: memory, credentialLock: ChatUICheckLock(), send: { request in
            guard request.url?.path == "/.well-known/openid-configuration" else { throw ChatGPTAuthError.temporary }
            let metadata = ["issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/authorize",
                            "token_endpoint": "https://auth.openai.com/token", "jwks_uri": "https://auth.openai.com/jwks"]
            return ChatGPTAuthHTTPResponse(status: 200, data: try JSONEncoder().encode(metadata))
        }, makeListener: { ChatUICheckListener() }, openBrowser: { _ in })
    }
}

@MainActor
private final class ChatUICheckCredentials: ChatGPTCredentialStore {
    private var data: Data
    init(data: Data) { self.data = data }
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

@MainActor
private final class ChatUICheckLock: ChatGPTCredentialLock {
    private var held = false
    func acquire() async throws {
        try Task.checkCancellation()
        guard !held else { throw ChatGPTAuthError.locked }
        held = true
    }
    func release() { held = false }
}

@MainActor
private final class ChatUICheckListener: ChatGPTCallbackListener {
    private var canceled = false
    func start() async throws -> URL { URL(string: "http://127.0.0.1:49152/auth/callback")! }
    func callback() async throws -> URL {
        // No socket is opened. The product Cancel action ends this waiting fixture.
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            if canceled { throw CancellationError() }
        }
        throw ChatGPTAuthError.timeout
    }
    func cancel() { canceled = true }
}

private final class ChatUICheckWire: @unchecked Sendable {
    enum Mode: String, CaseIterable, Sendable { case complete = "Complete", slow = "Slow stream", error = "Error" }
    private let lock = NSLock()
    private var mode: Mode = .complete
    func setMode(_ value: Mode) { lock.lock(); defer { lock.unlock() }; mode = value }
    private func currentMode() -> Mode { lock.lock(); defer { lock.unlock() }; return mode }

    func open(_ request: URLRequest) -> ResponsesStream {
        let mode = currentMode()
        let pair = AsyncThrowingStream<ResponsesTransportEvent, Error>.makeStream()
        let task = Task {
            do {
                guard let url = request.url, ["/v1/models", "/v1/responses"].contains(url.path) else {
                    throw ResponsesClientError(.transport)
                }
                let catalog = url.path == "/v1/models"
                pair.continuation.yield(.response(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": catalog ? "application/json" : "text/event-stream"])!))
                try await Task.sleep(for: .milliseconds(400))
                if mode == .error { throw ResponsesClientError(.temporary, statusCode: 503) }
                if catalog {
                    pair.continuation.yield(.data(Data(#"{"models":[{"slug":"fixture-chat","display_name":"Synthetic Chat Model","visibility":"list"}]}"#.utf8)))
                } else {
                    let chunks = ["## Next steps\n\n", "- Ship the local chat layout on Friday.\n", "- Alex reviews keyboard navigation before Thursday."]
                    for (index, chunk) in chunks.enumerated() {
                        // Keep partial output visible while an observer locates Cancel.
                        let delay = mode == .slow ? (index == 0 ? 1000 : 20_000) : 250
                        try await Task.sleep(for: .milliseconds(delay))
                        try Task.checkCancellation()
                        try Self.event(["type": "response.output_text.delta", "delta": chunk], into: pair.continuation)
                    }
                    try Self.event(["type": "response.completed", "response": [
                        "id": "resp_fixture", "object": "response", "status": "completed", "output": [[
                            "id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
                            "content": [["type": "output_text", "text": chunks.joined()]]
                        ]]
                    ]], into: pair.continuation)
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return ResponsesStream(events: pair.stream, cancel: { task.cancel(); pair.continuation.finish(throwing: CancellationError()) })
    }

    private static func event(_ object: [String: Any],
                              into continuation: AsyncThrowingStream<ResponsesTransportEvent, Error>.Continuation) throws {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var bytes = Data("data: ".utf8)
        bytes.append(json)
        bytes.append(Data("\n\n".utf8))
        continuation.yield(.data(bytes))
    }
}
#endif

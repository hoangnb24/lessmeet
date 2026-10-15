import Foundation
import SwiftUI

@MainActor
struct LibraryUICheckView: View {
    @State private var context: LibraryUICheckContext?
    @State private var failed = false

    var body: some View {
        Group {
            if let context {
                VStack(spacing: 0) {
                    if let capture = context.manualCapture {
                        ManualUICheckControls(model: context.model, transcription: context.transcription,
                                              capture: capture) {
                            do { self.context = try LibraryUICheckContext(root: context.root) }
                            catch { failed = true; self.context = nil }
                        }
                    }
                    LibraryView(model: context.model, session: context.session, chat: context.chat,
                                modelManager: context.manager, transcription: context.transcription)
                        .defaultAppStorage(context.defaults)
                        .id(ObjectIdentifier(context.model))
                }
                .task(id: ObjectIdentifier(context.manager)) { await context.manager.prepare() }
            } else if failed {
                Text("Could not create the isolated Library fixture. No product storage was opened.")
            } else {
                ProgressView("Preparing synthetic Library")
            }
        }
        .environment(\.openURL, OpenURLAction { _ in .handled })
        .task {
            guard context == nil, !failed else { return }
            do {
                let fixture = try LibraryUICheckContext()
                context = fixture
                DemoWindowRecorder.shared.startIfRequested()
            } catch { failed = true }
        }
    }
}

@MainActor
final class LibraryUICheckContext {
    static let longID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    static let shortID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    static let shortText = "Maya: The synthetic planning check is complete. Alex will review the next draft on Friday."
    static let answer = "Synthetic answer: Alex will review the next draft on Friday."
    let root: URL
    let defaults: UserDefaults
    let store: RecordingStore
    let model: AppModel
    let session: ChatGPTSession
    let chat: LocalChatModel
    let manager: LocalModelManager
    let transcription: LocalTranscriptionModel
    let manualCapture: ManualUICheckCapture?

    init(root suppliedRoot: URL? = nil, manualCheck suppliedManual: Bool? = nil) throws {
        let manualCheck = suppliedManual ?? ManualTranscriptionUICheck.isActive
        root = suppliedRoot ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LessMeet-Library-UICheck-" + UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: "com.lessmeet.library-ui-check." + UUID().uuidString)!
        store = try RecordingStore(root: root.appendingPathComponent("Recordings", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        if manualCheck {
            if suppliedRoot == nil { try ManualTranscriptionUICheck.seed(store) }
        } else if DemoCapture.isActive {
            _ = try DemoCapture.seed(store: store)
        } else {
        try store.save(Recording(id: Self.longID, title: "Synthetic planning — long transcript",
                                 createdAt: date, duration: 2400, status: .ready))
        try store.save(Recording(id: Self.shortID, title: "Synthetic planning — short transcript",
                                 createdAt: date.addingTimeInterval(-3600), duration: 30, status: .ready))
        try store.saveLocalTranscript(LocalTranscript(segments: (0..<80).map { index in
            LocalTranscriptSegment(startMs: Int64(index * 30_000), endMs: Int64((index + 1) * 30_000),
                speaker: index.isMultiple(of: 2) ? "Maya" : "Alex",
                text: "Planning item \(index + 1). This is synthetic meeting text for the Library layout check. "
                    + "We will review the draft, compare the proposed schedule, and record the next action. "
                    + "Alex will review the next draft on Friday. Maya will prepare the checklist.")
        }), for: Self.longID)
        try store.saveLocalTranscript(LocalTranscript(segments: [
            LocalTranscriptSegment(startMs: 0, endMs: 30_000, speaker: "Maya", text: Self.shortText)
        ]), for: Self.shortID)
        }
        manualCapture = manualCheck ? ManualUICheckCapture() : nil
        let capture: any RecordingCapture
        if let manualCapture { capture = manualCapture }
        else if DemoCapture.isActive { capture = DemoCaptureRecorder() }
        else { capture = LibraryUICheckCapture() }
        model = AppModel(store: store, capture: capture)
        // An empty catalog fails validation before filesystem or network work, including Retry.
        manager = try manualCheck
            ? ManualTranscriptionUICheck.manager(root: root.appendingPathComponent("Models"))
            : LocalModelManager(root: root.appendingPathComponent("Models", isDirectory: true),
                                catalog: [], configuration: .ephemeral)
        let engine: any LocalTranscriptionProcessing = manualCheck
            ? ManualUICheckEngine() : LibraryUICheckEngine()
        transcription = LocalTranscriptionModel(app: model, manager: manager, engine: engine)
        let profile = ChatGPTProfile(id: "library-fixture", displayName: DemoCapture.isActive ? "Demo account" : "Synthetic account", clientID: "fixture-client")
        var record = ChatGPTAuthRecord()
        record.registrations = [ChatGPTRegistration(clientID: profile.clientID, subject: "fixture-subject", profile: profile,
            tokens: ChatGPTTokenSet(access: "synthetic-access-only", refresh: nil, identity: "synthetic-identity-only",
                scopes: [ChatGPTAuthConstants.planScope], expiresAt: Date().addingTimeInterval(86_400), earliestRefreshAt: nil))]
        record.activeProfileID = profile.id
        record.sessionID = "synthetic-library-session"
        let session = ChatGPTSession(store: LibraryUICheckCredentials(data: try JSONEncoder().encode(record)),
            credentialLock: LibraryUICheckLock(), send: { _ in throw LibraryUICheckError.disabled },
            makeListener: { LibraryUICheckListener() }, openBrowser: { _ in throw LibraryUICheckError.disabled })
        self.session = session
        chat = LocalChatModel(store: store, client: ResponsesClient(transport: { LibraryUICheckWire.open($0) }),
                              sessionID: { session.sessionIdentifier }, accessToken: { try await session.accessToken() })
    }
}

enum LibraryUICheckError: LocalizedError {
    case disabled
    var errorDescription: String? { "This action is disabled in the offline Library fixture." }
}

@MainActor
private final class LibraryUICheckCapture: RecordingCapture {
    var onFailure: ((String) -> Void)?
    func start(directory: URL) async throws { throw LibraryUICheckError.disabled }
    func stop() async throws -> CaptureResult { throw LibraryUICheckError.disabled }
}

private struct LibraryUICheckEngine: LocalTranscriptionProcessing {
    func transcribe(audioURL: URL, models: InstalledLocalModels,
                    progress: @escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> LocalTranscript {
        throw LibraryUICheckError.disabled
    }
}

@MainActor
private final class LibraryUICheckCredentials: ChatGPTCredentialStore {
    private var data: Data
    init(data: Data) { self.data = data }
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

@MainActor
private final class LibraryUICheckLock: ChatGPTCredentialLock {
    private var held = false
    func acquire() async throws {
        try Task.checkCancellation()
        guard !held else { throw ChatGPTAuthError.locked }
        held = true
    }
    func release() { held = false }
}

@MainActor
private final class LibraryUICheckListener: ChatGPTCallbackListener {
    func start() async throws -> URL { throw LibraryUICheckError.disabled }
    func callback() async throws -> URL { throw LibraryUICheckError.disabled }
    func cancel() {}
}

private enum LibraryUICheckWire {
    static func open(_ request: URLRequest) -> ResponsesStream {
        let pair = AsyncThrowingStream<ResponsesTransportEvent, Error>.makeStream()
        do {
            guard let url = request.url, ["/v1/models", "/v1/responses"].contains(url.path) else {
                throw LibraryUICheckError.disabled
            }
            let catalog = url.path == "/v1/models"
            pair.continuation.yield(.response(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": catalog ? "application/json" : "text/event-stream"])!))
            if catalog {
                pair.continuation.yield(.data(Data(#"{"models":[{"slug":"fixture-chat","display_name":"Synthetic Chat Model","visibility":"list"}]}"#.utf8)))
            } else {
                let answer = DemoCapture.isActive ? DemoCapture.answer
                    : "Synthetic answer: Alex will review the next draft on Friday."
                if DemoCapture.isActive {
                    streamDemo(answer, url: url, continuation: pair.continuation)
                    return ResponsesStream(events: pair.stream, cancel: { pair.continuation.finish(throwing: CancellationError()) })
                }
                let events: [[String: Any]] = [
                    ["type": "response.output_text.delta", "delta": answer],
                    ["type": "response.completed", "response": ["id": "resp_fixture", "object": "response",
                        "status": "completed", "output": [["id": "msg_fixture", "type": "message", "role": "assistant",
                            "status": "completed", "content": [["type": "output_text", "text": answer]]]]]]
                ]
                for event in events {
                    var bytes = Data("data: ".utf8)
                    bytes.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                    bytes.append(Data("\n\n".utf8))
                    pair.continuation.yield(.data(bytes))
                }
            }
            pair.continuation.finish()
        } catch { pair.continuation.finish(throwing: error) }
        return ResponsesStream(events: pair.stream, cancel: { pair.continuation.finish(throwing: CancellationError()) })
    }

    private static func streamDemo(_ answer: String, url: URL,
                                   continuation: AsyncThrowingStream<ResponsesTransportEvent, Error>.Continuation) {
        func line(_ event: [String: Any]) -> Data {
            var bytes = Data("data: ".utf8)
            bytes.append((try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data())
            bytes.append(Data("\n\n".utf8))
            return bytes
        }
        let words = answer.split(separator: " ", omittingEmptySubsequences: false)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            for (index, word) in words.enumerated() {
                let delta = (index == 0 ? "" : " ") + word
                continuation.yield(.data(line(["type": "response.output_text.delta", "delta": delta])))
                try? await Task.sleep(for: .milliseconds(45))
            }
            continuation.yield(.data(line(["type": "response.completed", "response": ["id": "resp_demo", "object": "response",
                "status": "completed", "output": [["id": "msg_demo", "type": "message", "role": "assistant",
                    "status": "completed", "content": [["type": "output_text", "text": answer]]]]]])))
            continuation.finish()
        }
    }
}

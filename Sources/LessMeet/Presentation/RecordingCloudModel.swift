import Foundation
import Combine

struct CloudIdentity: Equatable {
    let owner: String
    let session: String
}

@MainActor
final class RecordingCloudModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var activity: String?
    @Published private(set) var error: String?
    let configurationIssue: String?
    private let app: AppModel
    private let client: CloudClient?
    private let identity: () -> CloudIdentity?
    private let token: () async throws -> String
    private let pollDelay: Duration
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(app: AppModel, client: CloudClient?, configurationIssue: String? = nil,
         identity: @escaping () -> CloudIdentity?, token: @escaping () async throws -> String,
         pollDelay: Duration = .seconds(2)) {
        self.app = app
        self.client = client
        self.configurationIssue = configurationIssue
        self.identity = identity
        self.token = token
        self.pollDelay = pollDelay
    }

    convenience init(app: AppModel, account: AccountSession) {
        let configuration = try? AppConfiguration.load()
        let site = configuration?.convexSiteURL
        let namespace = "\(site?.absoluteString ?? "")|\(configuration?.clerkPublishableKey ?? "")"
        self.init(app: app, client: site.map { CloudClient(baseURL: $0) },
                  configurationIssue: site == nil ? "Configure CONVEX_SITE_URL and rebuild to use cloud features." : nil,
                  identity: {
            guard let user = account.userID, let session = account.sessionIdentifier else { return nil }
            return CloudIdentity(owner: "\(namespace)|\(user)", session: session)
        }, token: { try await account.token() })
    }

    func cached(_ recording: Recording) -> CloudRecording? {
        guard let identity = identity() else { return nil }
        return recording.cloud?[identity.owner]
    }

    func cancel() {
        let wasBusy = busy
        generation = UUID()
        task?.cancel()
        task = nil
        busy = false
        activity = nil
        error = wasBusy ? "Stopped waiting. A submitted cloud request may still finish and incur a charge. Refresh before submitting again." : nil
    }

    func contextChanged() {
        cancel()
        error = nil
    }

    private struct Context {
        let id: UUID
        let identity: CloudIdentity
        let generation: UUID
    }

    private func check(_ context: Context) throws {
        try Task.checkCancellation()
        guard generation == context.generation, app.selection == context.id,
              app.phase == .idle, identity() == context.identity else { throw CancellationError() }
    }

    private func bearer(_ context: Context) async throws -> String {
        try check(context)
        let value = try await token()
        try check(context)
        return value
    }

    private func save(_ result: CloudRecording, context: Context) throws {
        try check(context)
        guard var recording = app.recordings.first(where: { $0.id == context.id }), let store = app.store else {
            throw AccountError("The local recording is no longer available.")
        }
        recording.cloud = recording.cloud ?? [:]
        recording.cloud?[context.identity.owner] = result
        // Save before publishing so a failed disk write cannot pretend the remote ID is durable.
        try store.save(recording)
        if let index = app.recordings.firstIndex(where: { $0.id == context.id }) { app.recordings[index] = recording }
    }

    private func start(_ action: @escaping (CloudClient, Context) async throws -> Void) {
        guard !busy, app.phase == .idle else { return }
        error = nil
        guard let client else { error = configurationIssue ?? "Cloud is not configured."; return }
        guard let id = app.selection, let identity = identity() else { error = "Sign in before using cloud features."; return }
        generation = UUID()
        let context = Context(id: id, identity: identity, generation: generation)
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == context.generation { self.busy = false; self.activity = nil; self.task = nil }
            }
            do { try await action(client, context) }
            catch is CancellationError { }
            catch {
                if self.generation == context.generation, self.identity() == context.identity, self.app.selection == id {
                    self.error = "\(error.localizedDescription) No automatic retry was made. Refresh an existing cloud recording before submitting again."
                }
            }
        }
    }

    private func poll(_ id: String, client: CloudClient, context: Context) async throws {
        for _ in 0..<150 {
            let result = try await client.recording(id: id, token: bearer(context))
            guard result.recordingId == id else { throw AccountError("The server returned a different recording.") }
            try save(result, context: context)
            switch result.status {
            case "ready", "failed": return
            case "queued", "processing": activity = "Creating transcript…"
            default: throw AccountError("The server returned an unknown transcription status.")
            }
            try await Task.sleep(for: pollDelay)
        }
        throw AccountError("Still waiting for the transcript. Use Refresh later; the audio will not be uploaded again.")
    }

    func transcribe() {
        start { [self] client, context in
            guard let store = app.store else { throw AccountError("Recording storage is unavailable.") }
            activity = "Uploading audio…"
            let id = try await client.upload(fileURL: store.audioURL(for: context.id), token: bearer(context))
            try save(CloudRecording(recordingId: id, status: "queued", transcript: nil, messages: [], error: nil), context: context)
            try await poll(id, client: client, context: context)
        }
    }

    func refresh() {
        start { [self] client, context in
            guard let recording = app.selected, let remote = cached(recording) else { throw AccountError("No cloud recording to refresh.") }
            activity = "Refreshing…"
            try await poll(remote.recordingId, client: client, context: context)
        }
    }

    func send(_ message: String) {
        start { [self] client, context in
            guard let recording = app.selected, let remote = cached(recording), remote.status == "ready" else {
                throw AccountError("Create a transcript before chatting.")
            }
            activity = "Replying…"
            let text = try await client.chat(id: remote.recordingId, message: message, token: bearer(context))
            try save(CloudRecording(recordingId: remote.recordingId, status: remote.status,
                                    transcript: remote.transcript,
                                    messages: remote.messages + [CloudMessage(role: "user", text: message), CloudMessage(role: "assistant", text: text)],
                                    error: remote.error), context: context)
        }
    }
}

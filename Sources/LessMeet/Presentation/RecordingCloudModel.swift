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
        }, token: {
            guard !account.cloudAccessLocked else { throw AccountError("Account deletion requested. Check deletion status in Account settings.") }
            return try await account.token()
        })
    }

    func cached(_ recording: Recording) -> CloudRecording? {
        guard let identity = identity() else { return nil }
        return recording.cloud?[identity.owner]
    }

    private func batchKey(_ owner: String) -> String { "batch-v1|\(client?.batchNamespace ?? "")|\(owner)" }
    func batch(_ recording: Recording) -> LocalBatch? {
        guard let who = identity() else { return nil }
        return recording.batches?[batchKey(who.owner)]
    }

    private func saveBatch(_ batch: LocalBatch, context: Context) throws {
        try check(context)
        guard var recording = app.selected, let store = app.store else { throw AccountError("Local recording unavailable.") }
        recording.batches = recording.batches ?? [:]
        recording.batches?[batchKey(context.identity.owner)] = batch
        try store.save(recording)
        if let index = app.recordings.firstIndex(where: { $0.id == context.id }) { app.recordings[index] = recording }
    }

    private func currentBatch(_ context: Context) throws -> LocalBatch {
        try check(context)
        guard let recording = app.selected, let saved = batch(recording) else { throw AccountError("No saved batch to recover.") }
        try saved.manifest.validate()
        try BatchValidation.require(BatchValidation.uuid(saved.clientBatchId) && saved.chunkPaths.count == saved.manifest.chunks.count)
        for (index, path) in saved.chunkPaths.enumerated() {
            try BatchValidation.require(path == "batch-\(saved.clientBatchId)/" + String(format: "chunk-%02d.m4a", index))
        }
        if let status = saved.status { try status.validate(manifest: saved.manifest, clientID: saved.clientBatchId) }
        if let pending = saved.pending {
            try BatchValidation.require(["create", "upload", "seal", "retry"].contains(pending.kind))
            if pending.kind == "upload" || pending.kind == "retry" { try BatchValidation.require(pending.index.map { saved.manifest.chunks.indices.contains($0) } == true) }
        }
        return saved
    }

    private func accept(_ status: BatchStatus, local: inout LocalBatch, context: Context) throws {
        try status.validate(manifest: local.manifest, clientID: local.clientBatchId)
        if let old = local.status { try BatchValidation.require(old.batchId == status.batchId && status.revision >= old.revision) }
        local.status = status
        if let pending = local.pending {
            switch pending.kind {
            case "create": local.pending = nil
            case "upload":
                if let i = pending.index, status.chunks.indices.contains(i), !["missing", "admitting"].contains(status.chunks[i].state) { local.pending = nil }
            case "seal": if status.state != "uploading" { local.pending = nil }
            case "retry":
                if let i = pending.index, let attempt = pending.expectedAttempt, status.chunks.indices.contains(i), status.chunks[i].attempt > attempt { local.pending = nil }
            default: break
            }
        }
        try saveBatch(local, context: context)
    }

    private func reconcile(client: CloudClient, context: Context) async throws -> LocalBatch {
        var local = try currentBatch(context)
        activity = "Checking saved batch…"
        do {
            let status = try await client.lookupBatch(local, token: bearer(context))
            try accept(status, local: &local, context: context)
        } catch let failure as CloudClientError where failure.statusCode == 404 && local.status == nil {
            local.pending = nil
            local.notice = "No remote batch found. Choose Continue to submit the same saved batch identity."
            try saveBatch(local, context: context)
            return local
        }
        return local
    }

    func continueBatch() {
        start { [self] client, context in
            var local = try await reconcile(client: client, context: context)
            // This entire path is an explicit user action after reconciliation, never a retry loop.
            if let pending = local.pending {
                if pending.kind == "upload", let i = pending.index, local.status?.chunks[i].state == "missing" {
                    local.pending = nil
                } else if pending.kind == "seal", local.status?.state == "uploading", local.status?.chunks.allSatisfy({ $0.state == "uploaded" }) == true {
                    local.pending = nil
                } else { throw AccountError("A prior operation is unresolved. Refresh; do not repeat unknown work.") }
            }
            try await submitBatch(&local, client: client, context: context)
        }
    }

    private func submitBatch(_ local: inout LocalBatch, client: CloudClient, context: Context) async throws {
        if local.status == nil {
            local.pending = .init(kind: "create"); local.notice = nil
            try saveBatch(local, context: context)
            let status = try await client.createBatch(local, token: bearer(context))
            try accept(status, local: &local, context: context)
        }
        guard local.pending == nil else { throw AccountError("Refresh the unresolved operation before continuing.") }
        if local.status?.state == "uploading" {
            for index in local.manifest.chunks.indices {
                guard let state = local.status?.chunks[index].state else { throw AccountError("Missing batch slot.") }
                if state == "uploaded" { continue }
                guard state == "missing" else { throw AccountError("Chunk admission is unresolved. Refresh before continuing.") }
                guard let store = app.store else { throw AccountError("Local recording unavailable.") }
                let url = try store.batchFile(for: context.id, path: local.chunkPaths[index])
                local.pending = .init(kind: "upload", index: index)
                try saveBatch(local, context: context)
                activity = "Uploading chunk \(index + 1) of \(local.manifest.chunks.count)…"
                let status = try await client.uploadBatch(local, index: index, fileURL: url, token: bearer(context))
                try accept(status, local: &local, context: context)
                guard local.pending == nil else { throw AccountError("Chunk admission is unresolved. Refresh; no automatic repeat.") }
            }
            local.pending = .init(kind: "seal")
            try saveBatch(local, context: context)
            activity = "Queuing transcription…"
            let status = try await client.sealBatch(local, token: bearer(context))
            try accept(status, local: &local, context: context)
        }
        try await fetchBatchResults(client: client, context: context)
    }

    func retryBatch(index: Int) {
        start { [self] client, context in
            var local = try await reconcile(client: client, context: context)
            guard let slot = local.status?.chunks.first(where: { $0.index == index }), slot.state == "failed", slot.attempt == 1, slot.retryAllowed else {
                throw AccountError("Only an eligible known failed chunk can be retried. Unknown and successful work cannot be retried.")
            }
            if let pending = local.pending {
                guard pending.kind == "retry", pending.index == index, pending.expectedAttempt == slot.attempt, pending.expectedFence == slot.fence else {
                    throw AccountError("A different operation is unresolved. Refresh first.")
                }
            } else {
                local.pending = .init(kind: "retry", index: index, expectedAttempt: slot.attempt, expectedFence: slot.fence, requestId: UUID().uuidString.lowercased())
            }
            try saveBatch(local, context: context)
            let status = try await client.retryBatch(local, token: bearer(context))
            try accept(status, local: &local, context: context)
            try await fetchBatchResults(client: client, context: context)
        }
    }

    private func fetchBatchResults(client: CloudClient, context: Context) async throws {
        var local = try await reconcile(client: client, context: context)
        guard let status = local.status else { return }
        let aggregate = try await client.batchAggregate(batchID: status.batchId, token: bearer(context))
        try aggregate.validate(manifest: local.manifest)
        if let old = local.aggregate { try BatchValidation.require(aggregate.revision >= old.revision) }
        local.aggregate = aggregate
        if aggregate.aggregate != nil { local.lastReadableAggregate = aggregate }
        local.notice = nil
        try saveBatch(local, context: context)
        for slot in status.chunks where slot.resultAvailable {
            let key = "\(slot.index):\(slot.attempt)"
            if local.results[key] != nil { continue }
            do {
                let raw = try await client.batchResult(batchID: status.batchId, index: slot.index, attempt: slot.attempt, token: bearer(context))
                try raw.validate(manifest: local.manifest)
                local.results[key] = raw
                try saveBatch(local, context: context)
            } catch let failure as CloudClientError where failure.statusCode == 404 {
                local.notice = "Some original chunk results are not available yet. Saved partial results remain readable; refresh later."
                try saveBatch(local, context: context)
            }
        }
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

    func refreshBatchChat() {
        start { [self] client, context in _ = try await reconcileChat(client: client, context: context) }
    }

    private func acceptChatOperation(_ operation: BatchChatOperation, local: inout LocalBatch, context: Context) throws {
        guard var chat = local.chat, let request = chat.request else { throw AccountError("No saved question to reconcile.") }
        try operation.validate(batchID: request.batchId, request: request, previous: chat.operation)
        chat.operation = operation; chat.confirmedAbsent = false
        // A failed terminal receipt proves this question cannot still generate.
        if operation.state == "failed" { chat.lastRequest = request; chat.request = nil }
        local.chat = chat
        try saveBatch(local, context: context)
    }

    private func reconcileChat(client: CloudClient, context: Context) async throws -> LocalBatch {
        var local = try currentBatch(context)
        guard let batchID = local.status?.batchId else { throw AccountError("Submit and complete the batch before chatting.") }
        activity = "Checking saved batch chat…"
        if let request = local.chat?.request {
            try BatchValidation.require(request.batchId == batchID)
            do {
                let operation = try await client.batchChatOperation(request, token: bearer(context))
                try acceptChatOperation(operation, local: &local, context: context)
            } catch let failure as CloudClientError where failure.statusCode == 404 {
                // Absence cannot undo previously observed execution evidence.
                guard local.chat?.operation == nil,
                      local.chat?.status?.pending?.clientMessageId != request.clientMessageId,
                      local.chat?.status?.exchanges.contains(where: { $0.clientMessageId == request.clientMessageId }) != true else {
                    throw AccountError("A previously observed question is now unavailable. Keep its identity; contact the app owner. Do not resend.")
                }
                local.chat?.confirmedAbsent = true
                try saveBatch(local, context: context)
            }
        }
        let status = try await client.batchChatStatus(batchID: batchID, token: bearer(context))
        var chat = local.chat ?? LocalBatchChat()
        var resolvedPrevious: BatchChatOperation?
        if let old = chat.status?.pending, status.pending?.clientMessageId != old.clientMessageId {
            if let receipt = chat.operation, receipt.clientMessageId == old.clientMessageId, !receipt.unresolved {
                resolvedPrevious = receipt
            } else {
                // Read by exact observed identity; no message/history precondition is fabricated.
                resolvedPrevious = try await client.batchChatOperation(batchID: batchID, clientMessageID: old.clientMessageId, token: bearer(context))
            }
        }
        try status.validate(batchID: batchID, previous: chat.status, resolvedPrevious: resolvedPrevious)
        if let incoming = status.pending ?? resolvedPrevious {
            let previous = chat.observedOperation.flatMap { $0.clientMessageId == incoming.clientMessageId ? $0 : nil }
            try incoming.validate(batchID: batchID, previous: previous)
            if let submitted = chat.operation, submitted.clientMessageId == incoming.clientMessageId {
                try incoming.validate(batchID: batchID, previous: submitted)
            }
            chat.observedOperation = incoming
        }
        if status.availability == "ready" {
            try BatchValidation.require(status.contextDigest == BatchChatValidation.digest(local))
        }
        if let request = chat.request {
            if let exchange = status.exchanges.first(where: { $0.clientMessageId == request.clientMessageId }) {
                try BatchValidation.require(BatchChatValidation.exact(exchange.message, request.message) && exchange.contextDigest == request.expectedContextDigest)
                chat.confirmedAbsent = false
                if chat.operation?.state == "succeeded" {
                    try BatchValidation.require(BatchChatValidation.exact(exchange.reply, chat.operation?.text ?? ""))
                    chat.lastRequest = request; chat.request = nil; chat.confirmedAbsent = false
                }
            }
            if let pending = status.pending, pending.clientMessageId == request.clientMessageId {
                try acceptChatOperation(pending, local: &local, context: context)
                chat.operation = pending
                chat.confirmedAbsent = false
            }
        }
        chat.status = status; local.chat = chat
        try saveBatch(local, context: context)
        return local
    }

    func sendBatchQuestion(_ message: String) {
        start { [self] client, context in
            guard BatchChatValidation.message(message) else { throw AccountError("Send a nonempty question of at most 8 KiB.") }
            var local = try await reconcileChat(client: client, context: context)
            guard local.chat?.request == nil, let status = local.chat?.status, status.availability == "ready", status.pending == nil, let digest = status.contextDigest else {
                throw AccountError("Batch chat is unavailable or a question is unresolved. Refresh; do not replace unknown work.")
            }
            let payload = BatchChatRequest(batchId: status.batchId, clientMessageId: UUID().uuidString.lowercased(), expectedContextDigest: digest, expectedHistoryRevision: status.revision, message: message)
            try payload.validate()
            local.chat?.request = payload; local.chat?.operation = nil; local.chat?.confirmedAbsent = false
            try saveBatch(local, context: context) // Exact payload + UUID durable BEFORE POST/token acquisition.
            activity = "Submitting saved question…"
            let operation = try await client.batchChatOperation(payload, token: bearer(context), send: true)
            try acceptChatOperation(operation, local: &local, context: context)
            _ = try await reconcileChat(client: client, context: context)
        }
    }

    func resendAbsentBatchQuestion() {
        start { [self] client, context in
            // Explicit action, but always reconfirm exact-owner absence immediately first.
            var local = try await reconcileChat(client: client, context: context)
            guard let chat = local.chat, chat.confirmedAbsent, chat.operation == nil, let request = chat.request,
                  let status = chat.status, status.availability == "ready", status.pending == nil,
                  status.contextDigest == request.expectedContextDigest, status.revision == request.expectedHistoryRevision else {
                throw AccountError("The saved question is not confirmed absent with unchanged context/history. No resend was made.")
            }
            local.chat?.confirmedAbsent = false
            try saveBatch(local, context: context)
            let operation = try await client.batchChatOperation(request, token: bearer(context), send: true)
            try acceptChatOperation(operation, local: &local, context: context)
            _ = try await reconcileChat(client: client, context: context)
        }
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

    func transcribeLegacy() {
        start { [self] client, context in
            guard let store = app.store else { throw AccountError("Recording storage is unavailable.") }
            activity = "Uploading audio…"
            let id = try await client.upload(fileURL: store.audioURL(for: context.id), token: bearer(context))
            try save(CloudRecording(recordingId: id, status: "queued", transcript: nil, messages: [], error: nil), context: context)
            try await poll(id, client: client, context: context)
        }
    }

    func transcribe() {
        start { [self] client, context in
            guard let store = app.store, let recording = app.selected else { throw AccountError("Recording storage unavailable.") }
            guard batch(recording) == nil else { throw AccountError("A prepared batch already exists. Refresh, then explicitly continue; do not create another batch.") }
            let id = UUID().uuidString.lowercased()
            let folder = "batch-\(id)"
            activity = "Preparing and validating local audio chunks…"
            let prepared: TranscriptionChunks.Manifest
            do {
                prepared = try await TranscriptionChunks.prepare(source: store.audioURL(for: context.id), destination: store.directory(for: context.id).appendingPathComponent(folder))
            } catch let failure as TranscriptionChunks.Failure {
                switch failure {
                case .invalidDuration: throw AccountError("Local audio must be nonempty and no longer than 120 minutes. Original files are unchanged.")
                case .oversized: throw AccountError("A prepared chunk exceeds 18 MiB. No audio was uploaded or recompressed to a lower bitrate; originals are unchanged.")
                default: throw AccountError("Could not validate exact local audio chunks. Original files are unchanged; no audio was uploaded. Check the recording format or contact the app owner.")
                }
            }
            try check(context)
            var local = LocalBatch(clientBatchId: id, manifest: try BatchManifest(prepared: prepared), chunkPaths: prepared.chunks.map { "\(folder)/\($0.file.name)" })
            try saveBatch(local, context: context)
            try await submitBatch(&local, client: client, context: context)
        }
    }

    func refresh() {
        start { [self] client, context in
            if let recording = app.selected, batch(recording) != nil {
                try await fetchBatchResults(client: client, context: context)
                return
            }
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

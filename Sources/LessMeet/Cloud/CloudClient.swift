import Foundation

struct CloudClient {
    private let baseURL: URL
    private let session: URLSession
    private static let maximumAudioBytes = 18 * 1024 * 1024

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    var batchNamespace: String { baseURL.absoluteString }

    func batchChatStatus(batchID: String, token: String) async throws -> BatchChatStatus {
        let req = try batchRequest(path: "/chat", method: "GET", query: [.init(name: "batchId", value: batchID)], token: token)
        let status: BatchChatStatus = try await batchSend(req, statuses: [200], limit: 256 * 1024)
        try status.validate(batchID: batchID)
        return status
    }
    func batchChatOperation(_ payload: BatchChatRequest, token: String, send: Bool = false) async throws -> BatchChatOperation {
        try payload.validate()
        var req = try batchRequest(path: "/chat/message", method: send ? "POST" : "GET", query: send ? [] : [.init(name: "batchId", value: payload.batchId), .init(name: "clientMessageId", value: payload.clientMessageId)], token: token)
        if send { req.httpBody = try JSONEncoder().encode(payload); try BatchValidation.require(req.httpBody!.count <= 50176) }
        let operation: BatchChatOperation = try await batchSend(req, statuses: send ? [200, 202] : [200], limit: 64 * 1024)
        try operation.validate(batchID: payload.batchId, request: payload)
        return operation
    }
    func batchChatOperation(batchID: String, clientMessageID: String, token: String) async throws -> BatchChatOperation {
        try BatchValidation.require(!batchID.isEmpty && batchID.utf8.count <= 256 && BatchValidation.uuid(clientMessageID))
        let req = try batchRequest(path: "/chat/message", method: "GET", query: [.init(name: "batchId", value: batchID), .init(name: "clientMessageId", value: clientMessageID)], token: token)
        let operation: BatchChatOperation = try await batchSend(req, statuses: [200], limit: 64 * 1024)
        try operation.validate(batchID: batchID)
        try BatchValidation.require(operation.clientMessageId == clientMessageID)
        return operation
    }

    func createBatch(_ local: LocalBatch, token: String) async throws -> BatchStatus {
        struct Body: Encodable { let clientBatchId: String; let manifest: BatchManifest }
        return try await batchStatus(local, path: "", method: "POST", body: JSONEncoder().encode(Body(clientBatchId: local.clientBatchId, manifest: local.manifest)), token: token, statuses: [200, 201])
    }
    func lookupBatch(_ local: LocalBatch, token: String) async throws -> BatchStatus {
        try await batchStatus(local, path: "", method: "GET", query: [URLQueryItem(name: "clientBatchId", value: local.clientBatchId)], token: token, statuses: [200])
    }
    func uploadBatch(_ local: LocalBatch, index: Int, fileURL: URL, token: String) async throws -> BatchStatus {
        try BatchValidation.require(local.manifest.chunks.indices.contains(index))
        let file = try TranscriptionChunks.identity(fileURL)
        let declared = local.manifest.chunks[index]
        try BatchValidation.require(file.sha256 == declared.sha256 && file.bytes == declared.bytes)
        return try await batchStatus(local, path: "/chunk", method: "PUT", query: [URLQueryItem(name: "batchId", value: local.status?.batchId), URLQueryItem(name: "index", value: String(index))], file: fileURL, token: token, statuses: [200, 202])
    }
    func sealBatch(_ local: LocalBatch, token: String) async throws -> BatchStatus {
        struct Body: Encodable { let batchId: String; let manifestDigest: String }
        guard let id = local.status?.batchId else { throw malformed(mutating: false) }
        return try await batchStatus(local, path: "/seal", method: "POST", body: JSONEncoder().encode(Body(batchId: id, manifestDigest: try local.manifest.digest)), token: token, statuses: [202])
    }
    func retryBatch(_ local: LocalBatch, token: String) async throws -> BatchStatus {
        struct Body: Encodable { let batchId: String; let index: Int; let expectedAttempt: Int; let expectedFence: Int64; let requestId: String; let confirm = "retry-failed-chunk" }
        guard let id = local.status?.batchId, let pending = local.pending, pending.kind == "retry",
              let index = pending.index, let attempt = pending.expectedAttempt,
              let fence = pending.expectedFence, let nonce = pending.requestId, BatchValidation.uuid(nonce) else { throw malformed(mutating: false) }
        return try await batchStatus(local, path: "/retry", method: "POST", body: JSONEncoder().encode(Body(batchId: id, index: index, expectedAttempt: attempt, expectedFence: fence, requestId: nonce)), token: token, statuses: [202])
    }
    func batchResult(batchID: String, index: Int, attempt: Int, token: String) async throws -> BatchRawResult {
        let req = try batchRequest(path: "/result", method: "GET", query: [URLQueryItem(name: "batchId", value: batchID), URLQueryItem(name: "index", value: String(index)), URLQueryItem(name: "attempt", value: String(attempt))], token: token)
        let result: BatchRawResult = try await batchSend(req, statuses: [200], limit: 6 * 384 * 1024 + 4096)
        try BatchValidation.require(result.version == 1 && result.batchId == batchID && result.index == index && result.attempt == attempt && result.rawText.utf8.count <= 384 * 1024)
        return result
    }
    func batchAggregate(batchID: String, token: String) async throws -> BatchAggregateResponse {
        let req = try batchRequest(path: "/aggregate", method: "GET", query: [URLQueryItem(name: "batchId", value: batchID)], token: token)
        let result: BatchAggregateResponse = try await batchSend(req, statuses: [200], limit: 384 * 1024 + 16 * 1024)
        try BatchValidation.require(result.version == 1 && result.batchId == batchID && result.revision >= 0 && result.revision <= BatchValidation.safeInteger && ["pending", "complete", "partial", "too_large"].contains(result.status))
        try BatchValidation.require((result.status == "complete" || result.status == "partial") == (result.aggregate != nil))
        if let aggregate = result.aggregate {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            try BatchValidation.require(encoder.encode(aggregate).count <= 384 * 1024)
        }
        return result
    }
    private func batchStatus(_ local: LocalBatch, path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, file: URL? = nil, token: String, statuses: Set<Int>) async throws -> BatchStatus {
        try local.manifest.validate()
        try BatchValidation.require(BatchValidation.uuid(local.clientBatchId) && (body?.count ?? 0) <= 16 * 1024)
        var req = try batchRequest(path: path, method: method, query: query, token: token)
        req.httpBody = body
        if file != nil { req.setValue("audio/m4a", forHTTPHeaderField: "Content-Type") }
        var result: BatchStatus = try await batchSend(req, file: file, statuses: statuses, limit: 128 * 1024)
        result.chunks.sort { $0.index < $1.index }
        try result.validate(manifest: local.manifest, clientID: local.clientBatchId)
        if let id = local.status?.batchId { try BatchValidation.require(result.batchId == id) }
        return result
    }
    private func batchRequest(path: String, method: String, query: [URLQueryItem], token: String) throws -> URLRequest {
        var req = try request(path: "v1/transcription-batches" + path, method: method, token: token, contentType: method == "GET" ? nil : "application/json")
        var url = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        req.url = url.url
        return req
    }
    private func batchSend<T: Decodable>(_ request: URLRequest, file: URL? = nil, statuses: Set<Int>, limit: Int) async throws -> T {
        let data: Data; let response: URLResponse
        do {
                try Task.checkCancellation()
                var outbound = request
                if let file {
                    outbound.httpBodyStream = InputStream(url: file)
                    guard outbound.httpBodyStream != nil else { throw malformed(mutating: false) }
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    if let size { outbound.setValue(String(size), forHTTPHeaderField: "Content-Length") }
                }
                let (bytes, reply) = try await session.bytes(for: outbound, delegate: RejectRedirects())
                response = reply
                var bounded = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard bounded.count < limit else { throw malformed(mutating: request.httpMethod != "GET") }
                    bounded.append(byte)
                }
                data = bounded
        } catch { throw CloudClientError(message: "Batch request did not complete. Local preparation is saved. Refresh to reconcile; no automatic retry." ) }
        guard let http = response as? HTTPURLResponse else { throw malformed(mutating: request.httpMethod != "GET") }
        guard statuses.contains(http.statusCode) else {
            let unavailable = request.url?.path.contains("/chat") == true
                ? "Batch chat is disabled or unavailable. The saved question is retained. Refresh batch chat to reconcile; no automatic resend."
                : "Batch transcription is disabled or unavailable. Local preparation is saved. Refresh, then explicitly continue when available."
            let message = http.statusCode == 503 ? unavailable : "Batch request failed (HTTP \(http.statusCode)). Local data is saved. Refresh before continuing."
            throw CloudClientError(message: message, statusCode: http.statusCode)
        }
        guard data.count <= limit else { throw malformed(mutating: request.httpMethod != "GET") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw malformed(mutating: request.httpMethod != "GET") }
    }

    func subscription(token: String, synchronize: Bool = false) async throws -> SubscriptionStatus {
        let request = try request(path: synchronize ? "billing/sync" : "billing",
                                  method: synchronize ? "POST" : "GET", token: token)
        let result: SubscriptionStatus = try await send(request, expectedStatus: 200)
        guard result.isValid else { throw malformed(mutating: false) }
        return result
    }

    func deletion(token: String, requestDeletion: Bool = false) async throws -> AccountDeletionStatus {
        var request = try request(path: "account/deletion", method: requestDeletion ? "POST" : "GET",
                                  token: token, contentType: requestDeletion ? "application/json" : nil)
        if requestDeletion { request.httpBody = Data(#"{"confirm":"delete-account"}"#.utf8) }
        let trace = requestDeletion ? nil : RefreshDiagnostics.current
        let result: AccountDeletionStatus = try await send(request, expectedStatus: requestDeletion ? 202 : 200, trace: trace)
        guard result.isValid else { trace?.event(.invalidStatus); throw malformed(mutating: requestDeletion) }
        return result
    }

    func upload(fileURL: URL, token: String) async throws -> String {
        let request = try request(path: "recordings", method: "POST", token: token, contentType: "audio/m4a")
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "m4a" else {
            throw CloudClientError(message: "Choose a local combined.m4a recording to upload.")
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch { throw CloudClientError(message: "The recording cannot be read. Check that the local audio file still exists.") }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            throw CloudClientError(message: "The recording must be a nonempty regular audio file.")
        }
        guard size.int64Value <= Self.maximumAudioBytes else {
            throw CloudClientError(message: "This recording exceeds the 18 MiB upload limit. Use a shorter recording; the local file has not been changed.")
        }
        struct UploadResponse: Decodable { let recordingId: String }
        let result: UploadResponse = try await send(request, fileURL: fileURL, expectedStatus: 202)
        guard !result.recordingId.isEmpty else { throw malformed(mutating: true) }
        return result.recordingId
    }

    func recording(id: String, token: String) async throws -> CloudRecording {
        var request = try request(path: "recordings", method: "GET", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        request.url = components.url
        let result: CloudRecording = try await send(request, expectedStatus: 200)
        guard result.recordingId == id, ["queued", "processing", "ready", "failed"].contains(result.status) else {
            throw malformed(mutating: false)
        }
        return result
    }

    func chat(id: String, message: String, token: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 8 * 1024 else {
            throw CloudClientError(message: "Send a nonempty question of at most 8 KiB.")
        }
        var request = try request(path: "chat", method: "POST", token: token, contentType: "application/json")
        struct ChatRequest: Encodable { let recordingId: String; let message: String }
        struct ChatResponse: Decodable { let text: String }
        request.httpBody = try JSONEncoder().encode(ChatRequest(recordingId: id, message: message))
        let result: ChatResponse = try await send(request, expectedStatus: 200)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw malformed(mutating: true) }
        return result.text
    }

    private func request(path: String, method: String, token: String, contentType: String? = nil) throws -> URLRequest {
        // Reuse the accepted configuration allowlist even when constructed directly.
        guard (try? AppConfiguration(clerkPublishableKey: nil, convexSiteURL: baseURL.absoluteString).convexSiteURL) != nil else {
            throw CloudClientError(message: "Configure an HTTPS .convex.site endpoint without credentials, port, path, query or fragment.")
        }
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw CloudClientError(message: "Sign in again to obtain a valid session token.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest, fileURL: URL? = nil, expectedStatus: Int,
                                      trace: RefreshTrace? = nil) async throws -> Value {
        let mutating = request.httpMethod != "GET"
        let data: Data
        let response: URLResponse
        do {
            if let fileURL {
                (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: RejectRedirects())
            } else {
                (data, response) = try await session.data(for: request, delegate: RejectRedirects())
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            trace?.event(cancelled ? .transportCancelled : .transportError)
            throw CloudClientError(message: (cancelled ? "Cloud request was cancelled." : "Could not reach the cloud service. Check your connection.") + ambiguity(mutating))
        }
        guard let http = response as? HTTPURLResponse else {
            trace?.event(.invalidHTTP); throw malformed(mutating: mutating)
        }
        guard http.statusCode == expectedStatus else {
            trace?.event(.httpRejected)
            if (200..<300).contains(http.statusCode) { throw malformed(mutating: mutating) }
            if (300..<400).contains(http.statusCode) {
                throw CloudClientError(message: "Cloud redirect rejected to protect your sign-in token. Check the configured endpoint." + ambiguity(mutating), statusCode: http.statusCode)
            }
            let backend = try? JSONDecoder().decode(BackendError.self, from: data)
            let safeText = backend?.error.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
            let detail = safeText.flatMap {
                !$0.isEmpty && $0.utf8.count <= 4096 && $0.rangeOfCharacter(from: .controlCharacters) == nil && !$0.contains(token) ? $0 : nil
            }
            throw CloudClientError(message: "Cloud service (HTTP \(http.statusCode)): \(detail ?? "Request failed. Sign in again or contact the app owner.")" + ambiguity(mutating && http.statusCode >= 500), statusCode: http.statusCode)
        }
        trace?.event(.httpSucceeded)
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            trace?.event(.decoded)
            return value
        }
        catch { trace?.event(.decodeFailed); throw malformed(mutating: mutating) }
    }

    private func malformed(mutating: Bool) -> CloudClientError {
        CloudClientError(message: "The cloud service returned an unexpected response. Refresh or contact the app owner." + ambiguity(mutating))
    }

    private func ambiguity(_ mutating: Bool) -> String {
        mutating ? " The request may already have been processed. Refresh before retrying; no automatic retry was made." : ""
    }
}

private struct BackendError: Decodable { let error: String }

struct CloudClientError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

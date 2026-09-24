import Foundation

struct CloudClient {
    private let baseURL: URL
    private let session: URLSession
    private static let maximumAudioBytes = 18 * 1024 * 1024

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
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
        let result: AccountDeletionStatus = try await send(request, expectedStatus: requestDeletion ? 202 : 200)
        guard result.isValid else { throw malformed(mutating: requestDeletion) }
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

    private func send<Value: Decodable>(_ request: URLRequest, fileURL: URL? = nil, expectedStatus: Int) async throws -> Value {
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
            throw CloudClientError(message: (cancelled ? "Cloud request was cancelled." : "Could not reach the cloud service. Check your connection.") + ambiguity(mutating))
        }
        guard let http = response as? HTTPURLResponse else { throw malformed(mutating: mutating) }
        guard http.statusCode == expectedStatus else {
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
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw malformed(mutating: mutating) }
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

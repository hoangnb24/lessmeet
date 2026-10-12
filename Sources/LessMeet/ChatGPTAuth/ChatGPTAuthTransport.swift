import Foundation

struct ChatGPTAuthHTTPResponse {
    let status: Int
    let data: Data
}

typealias ChatGPTAuthSend = @MainActor (URLRequest) async throws -> ChatGPTAuthHTTPResponse

final class ChatGPTAuthURLSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> ChatGPTAuthHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ChatGPTAuthError.response }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw ChatGPTAuthError.response }
                data.append(byte)
            }
            return ChatGPTAuthHTTPResponse(status: response.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ChatGPTAuthError.temporary }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ChatGPTDiscovery: Decodable {
    let issuer: String
    let authorization_endpoint: URL
    let token_endpoint: URL
    let jwks_uri: URL
    let revocation_endpoint: URL?

    func validate() throws {
        guard issuer == ChatGPTAuthConstants.issuer else { throw ChatGPTAuthError.response }
        for url in [authorization_endpoint, token_endpoint, jwks_uri] + [revocation_endpoint].compactMap({ $0 }) {
            guard url.scheme == "https", url.host == "auth.openai.com", url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw ChatGPTAuthError.response
            }
        }
    }
}

struct ChatGPTTokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let id_token: String?
    let token_type: String?
    let expires_in: Double?
    let scope: String?
    let earliest_refresh_at: Double?

    func tokens(now: Date, previousIdentity: String? = nil, refresh: Bool = false) throws -> ChatGPTTokenSet {
        guard let identity = id_token ?? previousIdentity, !identity.isEmpty,
              !refresh || scope != nil else { throw ChatGPTAuthError.response }
        let scope = scope ?? ""
        guard scope.count <= 8192 else { throw ChatGPTAuthError.response }
        let scopes = Set(scope.split(separator: " ").map(String.init))
        if access_token != nil || scopes.contains(ChatGPTAuthConstants.planScope) || refresh {
            guard let access_token, !access_token.isEmpty, token_type?.lowercased() == "bearer",
                  let expires_in, expires_in.isFinite, expires_in > 0, expires_in <= 86_400 else {
                throw ChatGPTAuthError.response
            }
        }
        if refresh || scopes.contains("offline_access") {
            guard let refresh_token, !refresh_token.isEmpty else { throw ChatGPTAuthError.response }
        }
        if let earliest_refresh_at {
            guard earliest_refresh_at.isFinite, earliest_refresh_at >= 0 else { throw ChatGPTAuthError.response }
        }
        return ChatGPTTokenSet(access: access_token, refresh: refresh_token, identity: identity, scopes: scopes,
                               expiresAt: now.addingTimeInterval(expires_in ?? 0),
                               earliestRefreshAt: earliest_refresh_at.map(Date.init(timeIntervalSince1970:)))
    }
}

@MainActor
struct ChatGPTAuthTransport {
    let send: ChatGPTAuthSend

    func discovery() async throws -> ChatGPTDiscovery {
        let result = try await send(URLRequest(url: URL(string: ChatGPTAuthConstants.issuer + "/.well-known/openid-configuration")!))
        try check(result)
        let metadata: ChatGPTDiscovery
        do { metadata = try JSONDecoder().decode(ChatGPTDiscovery.self, from: result.data) }
        catch { throw ChatGPTAuthError.response }
        try metadata.validate()
        return metadata
    }

    func identity(_ token: String, metadata: ChatGPTDiscovery, clientID: String, nonce: String?,
                  subject: String?, now: Date) async throws -> ChatGPTVerifiedIdentity {
        let result = try await send(URLRequest(url: metadata.jwks_uri))
        try check(result)
        return try ChatGPTIdentityVerifier.verify(token, jwks: result.data, clientID: clientID,
                                                  nonce: nonce, subject: subject, now: now)
    }

    func exchange(endpoint: URL, fields: [String: String]) async throws -> ChatGPTTokenResponse {
        let result = try await send(Self.request(endpoint, fields: fields))
        try check(result)
        do { return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: result.data) }
        catch { throw ChatGPTAuthError.response }
    }

    func revoke(endpoint: URL, clientID: String, token: String) async -> Bool {
        for attempt in 0..<2 {
            if Task.isCancelled { return false }
            do {
                let result = try await send(Self.request(endpoint, fields: ["token": token,
                    "token_type_hint": "refresh_token", "client_id": clientID]))
                if result.status == 200 { return true }
                if result.status < 500 { return false }
            } catch { }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        return false
    }

    static func request(_ endpoint: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = ChatGPTAuthConstants.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    private func check(_ result: ChatGPTAuthHTTPResponse) throws {
        guard result.data.count <= 1_048_576 else { throw ChatGPTAuthError.response }
        if result.status == 200 { return }
        if result.status == 429 || result.status >= 500 { throw ChatGPTAuthError.temporary }
        let object = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
        let rawCode = (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["code"] as? String)
        let known = ["access_denied", "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                     "refresh_token_invalidated", "refresh_token_reused", "invalid_client"]
        throw ChatGPTAuthError.oauth(rawCode.flatMap { known.contains($0) ? $0 : nil } ?? "request_failed")
    }
}

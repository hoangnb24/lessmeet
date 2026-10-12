import Foundation
import CryptoKit
import Security

struct ChatGPTProfile: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let clientID: String
}

enum ChatGPTAuthError: Error, LocalizedError, Equatable {
    case canceled, timeout, callback, identity, storage, locked, browser, response
    case signedOut, consent, temporary, oauth(String)

    var errorDescription: String? {
        switch self {
        case .canceled: return "Sign-in was canceled."
        case .timeout: return "Sign-in timed out. Try again."
        case .callback: return "The sign-in callback could not be verified."
        case .identity: return "The ChatGPT identity could not be verified."
        case .storage: return "Secure storage failed. Credentials were not updated."
        case .locked: return "Another session operation is active. Try again shortly."
        case .browser: return "The system browser could not be opened."
        case .response: return "The authentication response was invalid."
        case .signedOut: return "Sign in to ChatGPT again."
        case .consent: return "Enable ChatGPT plan usage before sending a request."
        case .temporary: return "ChatGPT authentication is temporarily unavailable. Try again later."
        case .oauth(let code):
            if code == "invalid_client" { return "ChatGPT rejected the client registration. Check the client configuration." }
            return code == "access_denied" ? "Sign-in permission was declined." : "ChatGPT authorization failed. Sign in again."
        }
    }

    var terminalRefresh: Bool {
        guard case .oauth(let code) = self else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }
}

enum ChatGPTAuthConstants {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let identityScopes = "openid profile email"
    static let planScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), text.count % 4 != 1 else { throw ChatGPTAuthError.identity }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), base64URL(bytes) == text else { throw ChatGPTAuthError.identity }
        return bytes
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError.response
        }
        return base64URL(Data(bytes))
    }

    static func form(_ values: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" +
                $0.value.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&").utf8)
    }
}

struct ChatGPTAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let clientID: String?

    init(redirectURI: URL, clientID: String?) throws {
        self.redirectURI = redirectURI
        self.clientID = clientID
        state = try ChatGPTAuthConstants.random()
        nonce = try ChatGPTAuthConstants.random()
        verifier = try ChatGPTAuthConstants.random()
    }

    var challenge: String { ChatGPTAuthConstants.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    func authorizationURL(endpoint: URL, hostID: String, idToken: String?, requestPlanConsent: Bool) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirectURI.absoluteString,
                      "scope": ChatGPTAuthConstants.planScopes,
                      "resource": ChatGPTAuthConstants.resource, "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": challenge]
        if clientID == nil { values["agent_name_hint"] = "LessMeet" }
        if let idToken { values["id_token_hint"] = idToken }
        if requestPlanConsent { values["prompt"] = "consent" }
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              components.port == redirectURI.port, components.percentEncodedPath == "/auth/callback",
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw ChatGPTAuthError.callback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else { throw ChatGPTAuthError.callback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw ChatGPTAuthError.callback }
        if let code = values["error"] {
            guard values["code"] == nil else { throw ChatGPTAuthError.callback }
            throw ChatGPTAuthError.oauth(code == "access_denied" ? code : "authorization_failed")
        }
        guard let code = values["code"], let issued = values["client_id"] ?? clientID,
              issued != "dynamic_agent_client", !issued.isEmpty, issued.count <= 256,
              issued.utf8.allSatisfy({ (33...126).contains($0) }),
              clientID == nil || issued == clientID else { throw ChatGPTAuthError.callback }
        return (code, issued)
    }
}

struct ChatGPTTokenSet: Codable {
    let access: String?
    let refresh: String?
    let identity: String
    let scopes: Set<String>
    let expiresAt: Date
    let earliestRefreshAt: Date?
}

struct ChatGPTRegistration: Codable {
    let clientID: String
    var subject: String?
    var profile: ChatGPTProfile?
    var tokens: ChatGPTTokenSet?
}

struct ChatGPTAuthRecord: Codable {
    var version = 1
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var registrations: [ChatGPTRegistration] = []
    var activeProfileID: String?
    var sessionID: String?
}

@MainActor
protocol ChatGPTCredentialStore: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

@MainActor
protocol ChatGPTCredentialLock: AnyObject {
    func acquire() async throws
    func release()
}

@MainActor
protocol ChatGPTCallbackListener: AnyObject {
    func start() async throws -> URL
    func callback() async throws -> URL
    func cancel()
}

import Foundation

struct AppConfiguration {
    let clerkPublishableKey: String?
    let convexSiteURL: URL?

    init(clerkPublishableKey: String?, convexSiteURL: String?) throws {
        let key = clerkPublishableKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            guard key.hasPrefix("pk_test_") || key.hasPrefix("pk_live_") else {
                throw ConfigurationError("CLERK_PUBLISHABLE_KEY must be a public pk_test_ or pk_live_ key, never a secret key.")
            }
            var encoded = String(key.dropFirst(8))
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
                  decoded.hasSuffix("$"), Self.isHost(String(decoded.dropLast())) else {
                throw ConfigurationError("CLERK_PUBLISHABLE_KEY is malformed. Copy the complete Publishable Key from Clerk.")
            }
            self.clerkPublishableKey = key
        } else { self.clerkPublishableKey = nil }

        if let value = convexSiteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard let url = URL(string: value), url.scheme == "https",
                  let host = url.host, host.hasSuffix(".convex.site"), Self.isHost(host),
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                throw ConfigurationError("CONVEX_SITE_URL must be the HTTPS .convex.site URL for this app, not its .convex.cloud URL.")
            }
            self.convexSiteURL = url
        } else { self.convexSiteURL = nil }
    }

    static func load() throws -> AppConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return try AppConfiguration(
            clerkPublishableKey: environment["CLERK_PUBLISHABLE_KEY"] ?? Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String,
            convexSiteURL: environment["CONVEX_SITE_URL"] ?? Bundle.main.object(forInfoDictionaryKey: "ConvexSiteURL") as? String
        )
    }

    private static func isHost(_ value: String) -> Bool {
        value.contains(".") && !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

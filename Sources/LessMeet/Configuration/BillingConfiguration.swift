import Foundation

/// Kept separate so a billing configuration error never disables local capture or sign-in.
struct BillingConfiguration {
    let publicAppleAPIKey: String?
    let privacyURL: URL?
    let termsURL: URL?

    init(publicAppleAPIKey: String?, privacyURL: String? = nil, termsURL: String? = nil) throws {
        let key = publicAppleAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard key.isEmpty || (key.hasPrefix("appl_") && key.count > 5 &&
                             key.dropFirst(5).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ConfigurationError("RevenueCat requires a public Apple SDK key (appl_), never a secret key.")
        }
        self.publicAppleAPIKey = key.isEmpty ? nil : key
        self.privacyURL = try Self.legalURL(privacyURL)
        self.termsURL = try Self.legalURL(termsURL)
    }

    static func load() throws -> BillingConfiguration {
        let env = ProcessInfo.processInfo.environment
        return try BillingConfiguration(
            publicAppleAPIKey: env["REVENUECAT_PUBLIC_APPLE_KEY"] ?? Bundle.main.object(forInfoDictionaryKey: "RevenueCatPublicAppleKey") as? String,
            privacyURL: env["LESSMEET_PRIVACY_URL"] ?? Bundle.main.object(forInfoDictionaryKey: "LessMeetPrivacyURL") as? String,
            termsURL: env["LESSMEET_TERMS_URL"] ?? Bundle.main.object(forInfoDictionaryKey: "LessMeetTermsURL") as? String)
    }

    private static func legalURL(_ raw: String?) throws -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ConfigurationError("Subscription terms and privacy links must be public HTTPS URLs without credentials.")
        }
        return url
    }
}

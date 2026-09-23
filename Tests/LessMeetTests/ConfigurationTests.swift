import XCTest
@testable import LessMeet

final class ConfigurationTests: XCTestCase {
    func testOptionalBillingConfigurationRejectsSecretsAndUnsafeLegalURLs() throws {
        XCTAssertNil(try BillingConfiguration(publicAppleAPIKey: nil).publicAppleAPIKey)
        XCTAssertEqual(try BillingConfiguration(publicAppleAPIKey: " appl_publicFixture123 ").publicAppleAPIKey, "appl_publicFixture123")
        for key in ["sk_secret", "test_sandbox", "goog_key", "appl_", "appl_key\nsecret"] {
            XCTAssertThrowsError(try BillingConfiguration(publicAppleAPIKey: key))
        }
        for url in ["http://example.com/privacy", "https://user:secret@example.com/privacy", "file:///tmp/privacy"] {
            XCTAssertThrowsError(try BillingConfiguration(publicAppleAPIKey: nil, privacyURL: url))
        }
        XCTAssertEqual(try BillingConfiguration(publicAppleAPIKey: nil, privacyURL: "https://example.com/privacy").privacyURL?.path, "/privacy")
    }

    func testPublicConfigurationAndLocalOnlyMode() throws {
        let local = try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil)
        XCTAssertNil(local.clerkPublishableKey)
        let key = "pk_test_" + Data("sample.clerk.accounts.dev$".utf8).base64EncodedString()
        let cloud = try AppConfiguration(clerkPublishableKey: key, convexSiteURL: "https://sample.convex.site")
        XCTAssertEqual(cloud.clerkPublishableKey, key)
        XCTAssertEqual(cloud.convexSiteURL?.host, "sample.convex.site")
    }

    func testSecretsMalformedKeysAndNonConvexDestinationsAreRejected() {
        for key in ["sk_test_notpublic", "pk_test_invalid", "AIza_not_a_clerk_key"] {
            XCTAssertThrowsError(try AppConfiguration(clerkPublishableKey: key, convexSiteURL: nil))
        }
        for url in ["http://sample.convex.site", "https://sample.convex.cloud", "https://evil.example", "https://user:password@sample.convex.site"] {
            XCTAssertThrowsError(try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: url))
        }
    }
}

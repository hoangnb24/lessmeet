import XCTest
@testable import LessMeet

final class ConfigurationTests: XCTestCase {
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

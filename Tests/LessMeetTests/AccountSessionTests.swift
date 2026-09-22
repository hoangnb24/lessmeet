import XCTest
@testable import LessMeet

final class AccountSessionTests: XCTestCase {
    @MainActor
    func testMissingConfigurationKeepsAccountOptional() throws {
        let configuration = try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil)
        let session = AccountSession(configuration: configuration)
        XCTAssertNil(session.clerk)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.configurationIssue?.contains("CLERK_PUBLISHABLE_KEY") == true)
    }

    @MainActor
    func testUnconfiguredActionsFailWithoutStartingClerkOrNetworking() async throws {
        let session = AccountSession(configuration: try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil))
        await session.signIn()
        XCTAssertEqual(session.error, session.configurationIssue)
        XCTAssertFalse(session.busy)
        await session.signOut()
        XCTAssertEqual(session.error, session.configurationIssue)
        do {
            _ = try await session.token()
            XCTFail("Unconfigured account must not authorize cloud calls")
        } catch {
            XCTAssertEqual(error.localizedDescription, session.configurationIssue)
        }
        XCTAssertNil(session.clerk)
    }
}

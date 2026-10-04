import XCTest
@testable import LessMeet

final class AccountSessionTests: XCTestCase {
    @MainActor
    func testConfiguredStartupDoesNotTouchClerk() async throws {
        var configureCalls = 0
        let key = "pk_test_" + Data("offline.example$".utf8).base64EncodedString()
        let configuration = try AppConfiguration(clerkPublishableKey: key, convexSiteURL: nil)
        let session = AccountSession(configuration: configuration, configure: { _ in
            configureCalls += 1
            return nil
        })
        XCTAssertTrue(session.needsConnection)
        XCTAssertNil(session.clerk)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.userID)
        XCTAssertNil(session.sessionIdentifier)
        XCTAssertFalse(session.isLoaded)
        _ = session.displayName
        await session.deletion.refresh()
        await session.signIn()
        await session.signOut()
        do { _ = try await session.token(); XCTFail("Disconnected account must not authorize requests") }
        catch {}
        XCTAssertEqual(configureCalls, 0)
        session.connect()
        XCTAssertEqual(configureCalls, 1)
        XCTAssertNotNil(session.error)
    }

    @MainActor
    func testMissingConfigurationCannotConnect() throws {
        var configureCalls = 0
        let session = AccountSession(configuration: try AppConfiguration(clerkPublishableKey: nil, convexSiteURL: nil),
                                     configure: { _ in configureCalls += 1; return nil })
        session.connect()
        XCTAssertFalse(session.needsConnection)
        XCTAssertEqual(configureCalls, 0)
        XCTAssertEqual(session.error, session.configurationIssue)
    }

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

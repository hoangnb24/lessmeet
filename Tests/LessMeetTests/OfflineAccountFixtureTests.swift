import XCTest
@testable import LessMeet

final class OfflineAccountFixtureTests: XCTestCase {
    @MainActor
    func testReadyRequestedAndFailure() async {
        let fixture = OfflineAccountFixture()
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.requested, false)
        XCTAssertNil(fixture.model.status?.googleStatus)
        fixture.scenario = .requested
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.requested, true)
        XCTAssertEqual(fixture.model.status?.userId, "offline-alice")
        let previous = fixture.model.status
        fixture.scenario = .failure
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.error, "Synthetic connection failure. No request was sent.")
        XCTAssertFalse(fixture.model.busy)
        XCTAssertEqual(fixture.model.status, previous)
    }

    @MainActor
    func testGoogleScenariosApplyOnlyThroughRefreshAndKeepProvidersPending() async throws {
        let fixture = OfflineAccountFixture()
        await fixture.model.refresh()
        let cases: [(OfflineAccountFixture.Scenario, AccountDeletionStatus.GoogleStatus)] = [
            (.googlePending, .pending), (.googleException, .exception), (.googleAcknowledged, .acknowledged)
        ]
        for (scenario, google) in cases {
            let previous = fixture.model.status
            fixture.scenario = scenario
            XCTAssertEqual(fixture.model.status, previous)
            await fixture.model.refresh()
            let status = try XCTUnwrap(fixture.model.status)
            XCTAssertTrue(status.requested)
            XCTAssertEqual(status.googleStatus, google)
            XCTAssertEqual(status.userId, fixture.identity.owner)
            XCTAssertEqual(status.localComplete, google == .acknowledged)
            XCTAssertFalse(status.providersComplete)
            XCTAssertTrue(status.isValid)
            XCTAssertNotNil(AccountDeletionCopy.googleStatus(status))
            XCTAssertNil(fixture.model.error)
            XCTAssertFalse(fixture.model.busy)
        }
        fixture.scenario = .ready
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.requested, false)
        XCTAssertNil(fixture.model.status?.googleStatus)
    }

    @MainActor
    func testAccountSwitchClearsGoogleResultAndNewRefreshUsesCurrentOwner() async {
        let fixture = OfflineAccountFixture()
        fixture.scenario = .googleAcknowledged
        await fixture.model.refresh()
        fixture.switchAccount()
        XCTAssertNil(fixture.model.status)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.userId, "offline-bob")
        XCTAssertEqual(fixture.model.status?.googleStatus, .acknowledged)
        XCTAssertEqual(fixture.model.status?.providersComplete, false)
    }

    @MainActor
    func testWaitingResponseCanBeCompleted() async {
        let fixture = OfflineAccountFixture()
        fixture.scenario = .waiting
        let ready = expectation(description: "Response suspended")
        let finished = expectation(description: "Refresh finished")
        fixture.onPendingResponse = { ready.fulfill() }
        let task = Task { await fixture.model.refresh(); finished.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        guard fixture.hasPendingResponse else { task.cancel(); return }
        XCTAssertTrue(fixture.hasPendingResponse)
        XCTAssertTrue(fixture.model.busy)
        fixture.completePendingResponse()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(fixture.model.busy)
        XCTAssertEqual(fixture.model.status?.requested, false)
        XCTAssertFalse(fixture.hasPendingResponse)
    }

    @MainActor
    func testAccountSwitchDiscardsPendingResponse() async {
        let fixture = OfflineAccountFixture()
        fixture.scenario = .waiting
        let ready = expectation(description: "Response suspended")
        let finished = expectation(description: "Refresh finished")
        fixture.onPendingResponse = { ready.fulfill() }
        let task = Task { await fixture.model.refresh(); finished.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        guard fixture.hasPendingResponse else { task.cancel(); return }
        XCTAssertTrue(fixture.hasPendingResponse)
        fixture.switchAccount()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(fixture.identity.owner, "offline-bob")
        XCTAssertNil(fixture.model.status)
        XCTAssertNil(fixture.model.error)
        XCTAssertFalse(fixture.model.busy)
    }

    @MainActor
    func testDeletionFailsLocally() async {
        let fixture = OfflineAccountFixture()
        fixture.model.prepareConfirmation()
        await fixture.model.confirm()?.value
        XCTAssertEqual(fixture.model.error, "Offline checks cannot delete accounts.")
        XCTAssertNil(fixture.model.status)
    }
}

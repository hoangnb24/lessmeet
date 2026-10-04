import XCTest
@testable import LessMeet

final class OfflineAccountFixtureTests: XCTestCase {
    @MainActor
    func testReadyRequestedAndFailure() async {
        let fixture = OfflineAccountFixture()
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.requested, false)
        fixture.scenario = .requested
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.status?.requested, true)
        XCTAssertEqual(fixture.model.status?.userId, "offline-alice")
        fixture.scenario = .failure
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.error, "Synthetic connection failure. No request was sent.")
        XCTAssertFalse(fixture.model.busy)
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

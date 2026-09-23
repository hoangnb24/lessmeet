import XCTest
@testable import LessMeet

final class SubscriptionModelTests: XCTestCase {
    @MainActor
    func testRequiredSyncWaitsForSuspendedGetAndPublishesNewPlan() async {
        var releaseGet: CheckedContinuation<Void, Never>?
        var methods: [Bool] = []
        let model = SubscriptionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, fetch: { _, sync in
            methods.append(sync)
            if !sync { await withCheckedContinuation { releaseGet = $0 } }
            return SubscriptionStatus(userId: "alice", enforcement: true, plan: sync ? "pro" : "free",
                                      periodEndsAt: nil, transcriptionSeconds: .init(limit: 7200, used: 0, reserved: 0),
                                      questions: .init(limit: 20, used: 0, reserved: 0))
        })
        let get = Task { await model.refresh() }
        while releaseGet == nil { await Task.yield() }
        let sync = Task { await model.refresh(synchronize: true) }
        while model.pendingSynchronizationCount == 0 { await Task.yield() }
        XCTAssertEqual(methods, [false])
        releaseGet?.resume()
        await get.value
        await sync.value
        XCTAssertEqual(methods, [false, true])
        XCTAssertEqual(model.status?.plan, "pro")
        XCTAssertFalse(model.busy)
    }

    private func fixture(user: String = "alice") -> SubscriptionStatus {
        SubscriptionStatus(userId: user, enforcement: true, plan: "free", periodEndsAt: nil,
                           transcriptionSeconds: .init(limit: 7200, used: 0, reserved: 0),
                           questions: .init(limit: 20, used: 0, reserved: 0))
    }

    @MainActor
    func testQueuedSyncCannotCrossAccountChange() async {
        var account: CloudIdentity? = .init(owner: "alice", session: "a")
        var releaseGet: CheckedContinuation<Void, Never>?
        var methods: [Bool] = []
        let model = SubscriptionModel(identity: { account }, token: { "fresh" }, fetch: { _, sync in
            methods.append(sync)
            await withCheckedContinuation { releaseGet = $0 }
            return self.fixture()
        })
        let get = Task { await model.refresh() }
        while releaseGet == nil { await Task.yield() }
        let sync = Task { await model.refresh(synchronize: true) }
        while model.pendingSynchronizationCount == 0 { await Task.yield() }
        account = .init(owner: "bob", session: "b")
        model.contextChanged()
        releaseGet?.resume()
        await get.value
        await sync.value
        XCTAssertEqual(methods, [false])
        XCTAssertNil(model.status)
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testChangedAccountDuringTokenFetchCannotSend() async {
        var identity = CloudIdentity(owner: "alice", session: "a")
        let model = SubscriptionModel(identity: { identity }, token: {
            identity = CloudIdentity(owner: "bob", session: "b")
            return "old-token"
        }, fetch: { _, _ in XCTFail("Stale token must not be sent"); return self.fixture() })
        await model.refresh()
        XCTAssertNil(model.status)
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testChangedAccountDuringResponseCannotPublish() async {
        var identity = CloudIdentity(owner: "alice", session: "a")
        let model = SubscriptionModel(identity: { identity }, token: { "fixture-token" }, fetch: { _, _ in
            identity = CloudIdentity(owner: "bob", session: "b")
            return self.fixture()
        })
        await model.refresh()
        XCTAssertNil(model.status)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testSyncAndSignOutClearPrivateSnapshot() async {
        var account: CloudIdentity? = CloudIdentity(owner: "alice", session: "a")
        let model = SubscriptionModel(identity: { account }, token: { "fresh" }, fetch: { token, sync in
            XCTAssertEqual(token, "fresh"); XCTAssertTrue(sync)
            return self.fixture()
        })
        await model.refresh(synchronize: true)
        XCTAssertEqual(model.status?.userId, "alice")
        account = nil
        model.contextChanged()
        XCTAssertNil(model.status)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testMismatchedUserAndFailedRefreshDoNotRetainPlan() async {
        var wrongUser = false
        let model = SubscriptionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, fetch: { _, _ in
            self.fixture(user: wrongUser ? "bob" : "alice")
        })
        await model.refresh()
        XCTAssertNotNil(model.status)
        wrongUser = true
        await model.refresh()
        XCTAssertNil(model.status)
        XCTAssertNotNil(model.error)
    }
}

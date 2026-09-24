import XCTest
@testable import LessMeet

final class AccountDeletionTests: XCTestCase {
    private func fixture(user: String = "alice", requested: Bool = true) -> AccountDeletionStatus {
        .init(userId: user, requested: requested, localComplete: false, providersComplete: false,
              requestedAt: requested ? 1234 : nil)
    }

    @MainActor
    func testConfirmationRequiredAndCancelledConfirmationDoesNotSend() async {
        var sends = 0
        let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, send: { _, _ in
            sends += 1; return self.fixture()
        })
        XCTAssertNil(model.confirm())
        model.prepareConfirmation(); XCTAssertTrue(model.confirming)
        model.cancelConfirmation(); XCTAssertNil(model.confirm())
        model.prepareConfirmation()
        let task = model.confirm()
        XCTAssertNil(model.confirm())
        await task?.value
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(model.status, fixture())
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testConfirmationCannotFollowUserOrSessionSwitch() async {
        for changed in [CloudIdentity(owner: "bob", session: "b"), CloudIdentity(owner: "alice", session: "new-session")] {
            var identity = CloudIdentity(owner: "alice", session: "a")
            let model = AccountDeletionModel(identity: { identity }, token: { XCTFail("Stale confirmation"); return "token" }, send: { _, _ in
                XCTFail("Stale confirmation must not send"); return self.fixture()
            })
            model.prepareConfirmation(); identity = changed
            XCTAssertNil(model.confirm())
            XCTAssertFalse(model.confirming)
        }
    }

    @MainActor
    func testAccountSwitchDuringFreshTokenPreventsMutation() async {
        var identity = CloudIdentity(owner: "alice", session: "a")
        let model = AccountDeletionModel(identity: { identity }, token: {
            identity = .init(owner: "bob", session: "b"); return "old-token"
        }, send: { _, _ in XCTFail("Old token must not be sent"); return self.fixture() })
        model.prepareConfirmation(); await model.confirm()?.value
        XCTAssertNil(model.status)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testLateResponseCannotPublishAfterAccountChange() async {
        var identity = CloudIdentity(owner: "alice", session: "a")
        var resume: CheckedContinuation<Void, Never>?
        var locks: [CloudIdentity] = []
        let model = AccountDeletionModel(identity: { identity }, token: { "fresh" }, send: { _, _ in
            await withCheckedContinuation { resume = $0 }
            return self.fixture()
        }, lock: { who, _ in locks.append(who) })
        model.prepareConfirmation(); let pending = model.confirm()
        while resume == nil { await Task.yield() }
        XCTAssertTrue(model.busy)
        identity = .init(owner: "bob", session: "b"); model.contextChanged()
        resume?.resume(); await pending?.value
        XCTAssertNil(model.status); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(locks, [.init(owner: "alice", session: "a")])
    }

    @MainActor
    func testAmbiguousFailureLocksUntilExplicitRefreshWithoutAutomaticRetry() async {
        var calls: [Bool] = [], locks: [Bool] = []
        let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, send: { _, request in
            calls.append(request)
            if request { throw URLError(.networkConnectionLost) }
            return self.fixture(requested: false)
        }, lock: { _, value in locks.append(value) })
        model.prepareConfirmation(); await model.confirm()?.value
        XCTAssertEqual(calls, [true]); XCTAssertEqual(locks, [true]); XCTAssertNotNil(model.error)
        await model.refresh()
        XCTAssertEqual(calls, [true, false]); XCTAssertEqual(locks, [true, false])
        XCTAssertEqual(model.status?.requested, false); XCTAssertNil(model.error)
    }

    @MainActor
    func testWrongOwnerOrFalseSuccessCannotBePresentedAsAccepted() async {
        for response in [fixture(user: "bob"), fixture(requested: false)] {
            let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, send: { _, _ in response })
            model.prepareConfirmation(); await model.confirm()?.value
            XCTAssertNil(model.status); XCTAssertNotNil(model.error)
        }
        XCTAssertFalse(AccountDeletionStatus(userId: "alice", requested: false, localComplete: true, providersComplete: true, requestedAt: nil).isValid)
        XCTAssertFalse(AccountDeletionStatus(userId: "alice", requested: true, localComplete: false, providersComplete: true, requestedAt: 123).isValid)
    }

    @MainActor
    func testBusyRequestDoesNotSendTwiceAndSignedOutStatusDoesNotFetch() async {
        var identity: CloudIdentity? = .init(owner: "alice", session: "a")
        var resume: CheckedContinuation<Void, Never>?
        var sends = 0
        let model = AccountDeletionModel(identity: { identity }, token: { "fresh" }, send: { _, _ in
            sends += 1; await withCheckedContinuation { resume = $0 }; return self.fixture()
        })
        model.prepareConfirmation(); let pending = model.confirm()
        while resume == nil { await Task.yield() }
        model.prepareConfirmation(); XCTAssertNil(model.confirm())
        await model.refresh(); XCTAssertEqual(sends, 1)
        resume?.resume(); await pending?.value
        identity = nil; model.contextChanged(); await model.refresh()
        XCTAssertEqual(sends, 1); XCTAssertNil(model.status)
    }

    @MainActor
    func testDeletionDoesNotModifyLocalAudioOrSavedResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var recording = Recording(title: "Synthetic recording")
        recording.status = .ready; recording.transcript = "Saved result"
        recording.messages = [.init(role: .user, text: "Saved question")]
        try store.save(recording)
        let audio = store.audioURL(for: recording.id)
        try Data([1, 2, 3]).write(to: audio)
        let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" }, send: { _, _ in self.fixture() })
        model.prepareConfirmation(); await model.confirm()?.value
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        XCTAssertEqual(try RecordingStore(root: root).load(), [recording])
    }
}

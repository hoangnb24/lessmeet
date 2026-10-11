import XCTest
@testable import LessMeet

final class AccountDeletionTests: XCTestCase {
    func testDeletionDisclosureUsesApprovedCalendarDaysAndEmailWithoutUniversalErasureClaim() {
        XCTAssertTrue(AccountDeletionCopy.timing.contains("7 calendar days of receipt"))
        XCTAssertTrue(AccountDeletionCopy.timing.contains("verified account contact"))
        XCTAssertTrue(AccountDeletionCopy.timing.contains("status, reason and next update date"))
        XCTAssertTrue(AccountDeletionCopy.confirmation.contains(AccountDeletionCopy.timing))
        XCTAssertTrue(AccountDeletionCopy.confirmation.contains(AccountDeletionCopy.scope))
        XCTAssertTrue(AccountDeletionCopy.scope.contains("does not confirm that all internal provider copies are erased"))
        XCTAssertTrue(AccountDeletionCopy.confirmation.contains("Local recordings and saved results remain"))
        XCTAssertTrue(AccountDeletionCopy.confirmation.contains("cancellation is not required"))
        XCTAssertFalse(AccountDeletionCopy.confirmation.contains("business days"))
        XCTAssertFalse(AccountDeletionCopy.confirmation.contains("no completion date is promised"))
        XCTAssertTrue(AccountDeletionCopy.confirmation.contains(AccountDeletionCopy.googleConsequence))
        XCTAssertTrue(AccountDeletionCopy.googleConsequence.contains("can affect sign-in across clients in the LessMeet Google project"))
        XCTAssertFalse(AccountDeletionCopy.confirmation.contains("all Google apps"))
    }

    private func fixture(user: String = "alice", requested: Bool = true,
                         google: AccountDeletionStatus.GoogleStatus? = nil) -> AccountDeletionStatus {
        .init(userId: user, requested: requested, localComplete: false, providersComplete: false,
              requestedAt: requested ? 1234 : nil, googleStatus: google)
    }

    private func decode(google: Any? = nil, requested: Bool = true,
                        complete: Bool = false) throws -> AccountDeletionStatus {
        var json: [String: Any] = ["userId": "alice", "requested": requested,
                                  "localComplete": complete, "providersComplete": complete,
                                  "requestedAt": requested ? 1234 : NSNull()]
        if let google { json["googleStatus"] = google }
        return try JSONDecoder().decode(AccountDeletionStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testGoogleStatusDecodesLegacyNullAndFutureValues() throws {
        for google in [nil, NSNull()] as [Any?] {
            let legacy = try decode(google: google, complete: true)
            XCTAssertNil(legacy.googleStatus)
            XCTAssertTrue(legacy.isValid)
            let ready = try decode(google: google, requested: false)
            XCTAssertTrue(ready.isValid)
            XCTAssertNil(AccountDeletionCopy.googleStatus(ready))
        }
        let future = try decode(google: "future_provider_state")
        XCTAssertEqual(future.googleStatus, .unknown)
        XCTAssertTrue(future.isValid)
        XCTAssertEqual(AccountDeletionCopy.googleStatus(future), AccountDeletionCopy.googleStatus(fixture(google: .unknown)))
        XCTAssertFalse(try decode(google: "future_provider_state", complete: true).isValid)
        XCTAssertFalse(try decode(google: "future_provider_state", requested: false).isValid)
        XCTAssertThrowsError(try decode(google: 42))
    }

    func testKnownGoogleStatusWireValuesAndCompletionValidation() throws {
        for google in AccountDeletionStatus.GoogleStatus.allCases {
            let status = try decode(google: google.rawValue)
            XCTAssertEqual(status.googleStatus, google)
            XCTAssertTrue(status.isValid)
            let encoded = try JSONEncoder().encode(status)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["googleStatus"] as? String, google.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(AccountDeletionStatus.self, from: encoded), status)
            XCTAssertFalse(try decode(google: google.rawValue, requested: false).isValid)
            XCTAssertEqual(try decode(google: google.rawValue, complete: true).isValid,
                           google == .acknowledged || google == .notApplicable)
        }
        XCTAssertEqual(AccountDeletionStatus.GoogleStatus.notApplicable.rawValue, "not_applicable")
    }

    func testGoogleCopySeparatesServiceOperatorAndScopedAcknowledgement() throws {
        for google in AccountDeletionStatus.GoogleStatus.allCases {
            let copy = try XCTUnwrap(AccountDeletionCopy.googleStatus(fixture(google: google)))
            XCTAssertTrue(copy.hasPrefix("Google permission revocation") || copy.hasPrefix("Google accepted"))
            XCTAssertFalse(copy.lowercased().contains("disconnect"))
            XCTAssertNil(AccountDeletionCopy.googleStatus(fixture(requested: false, google: google)))
            switch google {
            case .pending, .revoking: XCTAssertTrue(copy.contains("LessMeet handles this through its service"))
            case .exception, .unknown: XCTAssertTrue(copy.contains("operator"))
            case .acknowledged:
                XCTAssertTrue(copy.contains("Google accepted permission revocation"))
                XCTAssertTrue(copy.contains("does not confirm that all copies are erased or all provider handling is complete"))
            case .notApplicable:
                XCTAssertTrue(copy.contains("verified as not applicable to this request's scope"))
                XCTAssertTrue(copy.contains("does not confirm that all copies are erased"))
            }
        }
        XCTAssertTrue(try XCTUnwrap(AccountDeletionCopy.googleStatus(fixture())).contains("was not reported"))
    }

    @MainActor
    func testUnresolvedGoogleCompletionRejectsResponseAndPreservesStatusAndLock() async {
        for google in [AccountDeletionStatus.GoogleStatus.pending, .revoking, .exception, .unknown] {
            var response = fixture(google: .pending)
            var locks: [Bool] = []
            let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" },
                send: { _, _ in response }, lock: { _, locked in locks.append(locked) }, diagnostics: nil)
            await model.refresh()
            let previous = model.status
            response = .init(userId: "alice", requested: true, localComplete: true, providersComplete: true,
                             requestedAt: 1234, googleStatus: google)
            await model.refresh()
            XCTAssertEqual(model.status, previous)
            XCTAssertEqual(model.status?.googleStatus, .pending)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(locks, [true])
            XCTAssertFalse(model.busy)
        }
    }

    @MainActor
    func testGoogleAcknowledgementDoesNotCompleteProviderHandlingOrUnlockCloud() async {
        let response = AccountDeletionStatus(userId: "alice", requested: true, localComplete: true,
                                             providersComplete: false, requestedAt: 1234, googleStatus: .acknowledged)
        var locks: [Bool] = []
        let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" },
            send: { _, _ in response }, lock: { _, locked in locks.append(locked) }, diagnostics: nil)
        await model.refresh()
        XCTAssertEqual(model.status, response)
        XCTAssertEqual(model.status?.providersComplete, false)
        XCTAssertEqual(locks, [true])
        XCTAssertNil(model.error)
    }

    @MainActor
    func testWrongOwnerGoogleResultCannotReplaceCurrentStatusOrLock() async {
        var response = fixture(google: .pending)
        var locks: [Bool] = []
        let model = AccountDeletionModel(identity: { .init(owner: "alice", session: "a") }, token: { "fresh" },
            send: { _, _ in response }, lock: { _, locked in locks.append(locked) }, diagnostics: nil)
        await model.refresh()
        response = fixture(user: "bob", google: .acknowledged)
        await model.refresh()
        XCTAssertEqual(model.status, fixture(google: .pending))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(locks, [true])
    }

    @MainActor
    func testLateGoogleResultIsDiscardedForChangedUserSessionOrGeneration() async {
        for changed in [CloudIdentity(owner: "bob", session: "b"),
                        CloudIdentity(owner: "alice", session: "new-session"),
                        CloudIdentity(owner: "alice", session: "a")] {
            var identity = CloudIdentity(owner: "alice", session: "a")
            var resume: CheckedContinuation<Void, Never>?
            var locks: [Bool] = []
            let model = AccountDeletionModel(identity: { identity }, token: { "fresh" }, send: { _, _ in
                await withCheckedContinuation { resume = $0 }
                return self.fixture(google: .acknowledged)
            }, lock: { _, locked in locks.append(locked) }, diagnostics: nil)
            let pending = Task { await model.refresh() }
            while resume == nil { await Task.yield() }
            identity = changed
            // A same-identity context change must still reject the old generation.
            if changed.session == "a" { model.contextChanged() }
            resume?.resume(); await pending.value
            XCTAssertNil(model.status); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
            XCTAssertTrue(locks.isEmpty)
        }
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

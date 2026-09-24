import XCTest
import RevenueCat
@testable import LessMeet

@MainActor
final class BillingStoreTests: XCTestCase {
    func testDefaultAdmissionIsClosed() async {
        let driver = BillingFixtureDriver()
        let model = BillingStore(publicAppleAPIKey: "appl_fixture", driver: driver, gate: BillingOperationGate())
        await model.prepare(userID: "user_a")
        let restored = await model.restore()
        XCTAssertFalse(restored)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testRelaunchRequiresFreshExplicitNonDeletionStatus() async {
        let driver = BillingFixtureDriver()
        for mode in 0..<4 {
            driver.statusHook = { who in
                if mode == 0 { throw BillingFixtureError.failed }
                return AccountDeletionStatus(userId: mode == 1 ? "other" : who.owner,
                    requested: mode == 2, localComplete: mode == 3,
                    providersComplete: false, requestedAt: mode == 2 ? 1 : nil)
            }
            // A new store represents a fresh process admission state, not a live SDK restart.
            let model = store(driver)
            await model.prepare(userID: "user_a")
            let restored = await model.restore()
            XCTAssertFalse(restored)
            XCTAssertTrue(driver.events.isEmpty)
        }
        driver.statusHook = nil
        await store(driver).prepare(userID: "user_a")
        XCTAssertEqual(driver.events, ["identify:user_a", "packages:user_a"])
    }

    func testDelayedStatusCannotAuthorizeReplacementSessionOfSameOwner() async {
        let driver = BillingFixtureDriver()
        let entered = BillingLatch(), release = BillingLatch()
        driver.statusHook = { who in
            entered.open(); await release.wait()
            return AccountDeletionStatus(userId: who.owner, requested: false,
                localComplete: false, providersComplete: false, requestedAt: nil)
        }
        let model = store(driver)
        let preparing = Task { await model.prepare(userID: "user_a") }
        await entered.wait()
        driver.identity = CloudIdentity(owner: "user_a", session: "replacement")
        release.open()
        await preparing.value
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertTrue(model.packages.isEmpty)
    }

    func testDeletionAndSignoutSuspendDelayedAdmission() async {
        for deleting in [true, false] {
            let driver = BillingFixtureDriver()
            let entered = BillingLatch(), release = BillingLatch()
            driver.statusHook = { who in
                entered.open(); await release.wait()
                return AccountDeletionStatus(userId: who.owner, requested: false,
                    localComplete: false, providersComplete: false, requestedAt: nil)
            }
            let model = store(driver)
            let preparing = Task { await model.prepare(userID: "user_a") }
            await entered.wait()
            model.suspend()
            if !deleting { driver.identity = nil }
            release.open()
            await preparing.value
            XCTAssertTrue(driver.events.isEmpty)
            XCTAssertNil(model.activeUserID)
            XCTAssertFalse(model.busy)
        }
    }

    func testPurchaseAndRestoreRecheckStatusWithoutSDKCallsOnUnknown() async {
        let driver = BillingFixtureDriver()
        let admitted = store(driver)
        await admitted.prepare(userID: "user_a")
        driver.events = []
        driver.statusHook = { _ in throw BillingFixtureError.failed }
        let purchased = await admitted.purchase(packageID: "monthly")
        let restored = await admitted.restore()
        XCTAssertFalse(purchased)
        XCTAssertFalse(restored)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testDeletionObservedBeforeRestoreNeverIdentifiesAgain() async {
        let driver = BillingFixtureDriver()
        let model = store(driver)
        await model.prepare(userID: "user_a")
        driver.events = []
        driver.statusHook = { who in
            AccountDeletionStatus(userId: who.owner, requested: true,
                localComplete: true, providersComplete: true, requestedAt: 1)
        }
        let restored = await model.restore()
        let purchased = await model.purchase(packageID: "monthly")
        XCTAssertFalse(restored)
        XCTAssertFalse(purchased)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testAmbiguousDeletionRevokesBillingBeforeRequestCompletes() async {
        let driver = BillingFixtureDriver(), entered = BillingLatch(), release = BillingLatch()
        let model = store(driver)
        await model.prepare(userID: "user_a")
        driver.events = []
        let deletion = AccountDeletionModel(identity: { driver.identity }, token: { "fixture" },
            send: { _, _ in
                entered.open(); await release.wait(); throw BillingFixtureError.failed
            }, lock: { _, locked in if locked { model.suspend() } })
        deletion.prepareConfirmation()
        let request = deletion.confirm()
        await entered.wait()
        XCTAssertNil(model.activeUserID)
        let restored = await model.restore()
        XCTAssertFalse(restored)
        XCTAssertTrue(driver.events.isEmpty)
        release.open()
        await request?.value
        XCTAssertNotNil(deletion.error)
        XCTAssertNil(model.activeUserID)
    }

    func testPinnedSDKCancellationClassificationWithoutConfiguringSDK() {
        XCTAssertTrue(RevenueCatBillingDriver.isPurchaseCancellation(
            NSError(domain: ErrorCode.errorDomain, code: ErrorCode.purchaseCancelledError.rawValue)))
        XCTAssertFalse(RevenueCatBillingDriver.isPurchaseCancellation(
            NSError(domain: NSURLErrorDomain, code: ErrorCode.purchaseCancelledError.rawValue)))
        XCTAssertFalse(RevenueCatBillingDriver.isPurchaseCancellation(
            NSError(domain: ErrorCode.errorDomain, code: ErrorCode.networkError.rawValue)))
    }

    private func store(_ driver: BillingFixtureDriver, gate: BillingOperationGate? = nil,
                       key: String? = "appl_fixture") -> BillingStore {
        BillingStore(publicAppleAPIKey: key, driver: driver, gate: gate ?? BillingOperationGate(),
                     identity: { driver.identity }, deletionStatus: { who in
            try await driver.statusHook?(who) ?? AccountDeletionStatus(userId: who.owner, requested: false,
                localComplete: false, providersComplete: false, requestedAt: nil)
        })
    }

    func testInvalidKeysAndAnonymousUsersNeverReachDriver() async {
        for key in [nil, "", "appl_", "sk_secret", "test_fixture", "goog_fixture", "appl_a b"] as [String?] {
            let driver = BillingFixtureDriver()
            let model = store(driver, key: key)
            await model.prepare(userID: "user_a")
            XCTAssertFalse(model.isConfigured)
            let purchased = await model.purchase(packageID: "monthly")
            let restored = await model.restore()
            XCTAssertFalse(purchased)
            XCTAssertFalse(restored)
            XCTAssertTrue(driver.events.isEmpty)
        }
        let driver = BillingFixtureDriver()
        let model = store(driver)
        for user in [nil, "", "  ", " user_a", "$RCAnonymousID:fixture"] {
            await model.prepare(userID: user)
        }
        XCTAssertNil(model.activeUserID)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testPackagesAreFilteredWithoutPriceFallbackAndNoAutomaticRestore() async {
        let driver = BillingFixtureDriver()
        driver.offered += [driver.offered[0], BillingPackage(id: "bad", productID: "lifetime",
            title: "Lifetime", localizedPrice: "$1", period: .yearly),
            BillingPackage(id: "empty", productID: "com.lessmeet.app.pro.monthly",
                           title: "Pro", localizedPrice: "", period: .monthly)]
        let model = store(driver)
        await model.prepare(userID: "user_a")
        XCTAssertEqual(model.packages.count, 1)
        XCTAssertEqual(model.packages[0].localizedPrice, "12,99 €")
        XCTAssertEqual(driver.events, ["identify:user_a", "packages:user_a"])
        let purchased = await model.purchase(packageID: "invented")
        XCTAssertFalse(purchased)
        XCTAssertFalse(model.busy)
    }

    func testIdentityChangesClearBeforeSuspensionAndSerializeLogin() async {
        let driver = BillingFixtureDriver()
        let entered = BillingLatch(), release = BillingLatch()
        driver.identifyHook = { user in
            if user == "user_a" { entered.open(); await release.wait() }
        }
        let model = store(driver)
        let a = Task { await model.prepare(userID: "user_a") }
        await entered.wait()
        let switched = BillingLatch()
        let observer = model.$activeUserID.sink { if $0 == "user_b" { switched.open() } }
        driver.identity = CloudIdentity(owner: "user_b", session: "session_b")
        let b = Task { await model.prepare(userID: "user_b") }
        await switched.wait()
        XCTAssertEqual(model.activeUserID, "user_b")
        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertEqual(driver.events, ["identify:user_a"])
        release.open()
        await a.value
        await b.value
        withExtendedLifetime(observer) {}
        XCTAssertEqual(driver.events, ["identify:user_a", "identify:user_b", "packages:user_b"])
        XCTAssertEqual(driver.maxConcurrent, 1)
        XCTAssertFalse(model.busy)
    }

    func testSignoutDiscardsStaleOfferingFailure() async {
        let driver = BillingFixtureDriver()
        let entered = BillingLatch(), release = BillingLatch()
        driver.packageHook = { entered.open(); await release.wait(); throw BillingFixtureError.failed }
        let model = store(driver)
        let preparing = Task { await model.prepare(userID: "user_a") }
        await entered.wait()
        await model.prepare(userID: nil)
        XCTAssertNil(model.activeUserID)
        XCTAssertTrue(model.packages.isEmpty)
        release.open()
        await preparing.value
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
    }

    func testPurchaseCancellationIsNotAnErrorAndErrorsAreSafe() async {
        let driver = BillingFixtureDriver()
        let model = store(driver)
        await model.prepare(userID: "user_a")
        driver.purchaseResult = BillingPurchaseResult(cancelled: true, hasProEntitlement: false)
        let cancelled = await model.purchase(packageID: "monthly")
        XCTAssertFalse(cancelled)
        XCTAssertNil(model.error)
        driver.purchaseHook = { throw BillingFixtureError.failed }
        let failed = await model.purchase(packageID: "monthly")
        XCTAssertFalse(failed)
        XCTAssertEqual(model.error, "Purchase could not be completed. Please try again.")
        XCTAssertFalse(model.purchaseInProgress)
        XCTAssertFalse(model.busy)
    }

    func testPurchaseBlocksDoubleClickAndIdentityMutationUntilCompletion() async {
        let driver = BillingFixtureDriver()
        let entered = BillingLatch(), release = BillingLatch()
        driver.purchaseHook = { entered.open(); await release.wait() }
        let model = store(driver)
        await model.prepare(userID: "user_a")
        let purchase = Task { await model.purchase(packageID: "monthly") }
        await entered.wait()
        XCTAssertTrue(model.purchaseInProgress)
        let duplicate = await model.purchase(packageID: "monthly")
        XCTAssertFalse(duplicate)
        await model.prepare(userID: nil)
        XCTAssertNil(model.activeUserID)
        XCTAssertFalse(model.hasProEntitlement)
        XCTAssertTrue(model.packages.isEmpty)
        let switched = BillingLatch()
        let observer = model.$activeUserID.sink { if $0 == "user_b" { switched.open() } }
        driver.identity = CloudIdentity(owner: "user_b", session: "session_b")
        let b = Task { await model.prepare(userID: "user_b") }
        await switched.wait()
        XCTAssertFalse(driver.events.contains("identify:user_b"))
        release.open()
        let result = await purchase.value
        await b.value
        withExtendedLifetime(observer) {}
        XCTAssertFalse(result)
        XCTAssertFalse(model.hasProEntitlement)
        XCTAssertEqual(driver.events.filter { $0.hasPrefix("purchase:") }, ["purchase:user_a"])
        XCTAssertEqual(driver.maxConcurrent, 1)
        XCTAssertFalse(model.busy)
    }

    func testSharedGateSerializesDifferentStoresAndCancelledQueuedWorkDoesNothing() async {
        let driver = BillingFixtureDriver(), gate = BillingOperationGate()
        let entered = BillingLatch(), release = BillingLatch()
        driver.identifyHook = { _ in entered.open(); await release.wait() }
        let first = store(driver, gate: gate), second = store(driver, gate: gate)
        let a = Task { await first.prepare(userID: "user_a") }
        await entered.wait()
        let switched = BillingLatch()
        let observer = second.$activeUserID.sink { if $0 == "user_b" { switched.open() } }
        driver.identity = CloudIdentity(owner: "user_b", session: "session_b")
        let b = Task { await second.prepare(userID: "user_b") }
        await switched.wait()
        b.cancel()
        release.open()
        await a.value
        await b.value
        withExtendedLifetime(observer) {}
        XCTAssertEqual(driver.events, ["identify:user_a"])
        XCTAssertTrue(second.packages.isEmpty)
        XCTAssertFalse(second.busy)
        XCTAssertEqual(driver.maxConcurrent, 1)
    }

    func testRestoreExplicitSuccessWithoutEntitlementAndFailure() async {
        let driver = BillingFixtureDriver()
        let model = store(driver)
        await model.prepare(userID: "user_a")
        let restored = await model.restore()
        XCTAssertTrue(restored)
        XCTAssertFalse(model.hasProEntitlement)
        driver.restoreHook = { throw BillingFixtureError.failed }
        let failed = await model.restore()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.error, "Purchases could not be restored. Please try again.")
    }

    func testStaleRestoreCannotPublishEntitlement() async {
        let driver = BillingFixtureDriver()
        driver.restoredPro = true
        let entered = BillingLatch(), release = BillingLatch()
        driver.restoreHook = { entered.open(); await release.wait() }
        let model = store(driver)
        await model.prepare(userID: "user_a")
        let restoring = Task { await model.restore() }
        await entered.wait()
        await model.prepare(userID: nil)
        release.open()
        let result = await restoring.value
        XCTAssertFalse(result)
        XCTAssertFalse(model.hasProEntitlement)
        XCTAssertNil(model.error)
    }

    func testCurrentOfferingFailureAndEmptyOfferingDisableSales() async {
        let driver = BillingFixtureDriver()
        let model = store(driver)
        driver.packageHook = { throw BillingFixtureError.failed }
        await model.prepare(userID: "user_a")
        XCTAssertEqual(model.error, "Unable to load subscriptions. Please try again.")
        driver.packageHook = nil
        driver.offered = []
        await model.prepare(userID: "user_a")
        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertNotNil(model.error)
        let result = await model.purchase(packageID: "monthly")
        XCTAssertFalse(result)
    }

    func testSuccessfulPurchaseAndRestoreLeavePackagePurchasable() async {
        let driver = BillingFixtureDriver()
        let model = store(driver)
        await model.prepare(userID: "user_a")
        let purchased = await model.purchase(packageID: "monthly")
        XCTAssertTrue(purchased)
        XCTAssertTrue(model.hasProEntitlement)
        let restored = await model.restore()
        XCTAssertTrue(restored)
        XCTAssertFalse(model.hasProEntitlement)
        let purchasedAgain = await model.purchase(packageID: "monthly")
        XCTAssertTrue(purchasedAgain)
        await model.prepare(userID: nil)
        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertFalse(model.hasProEntitlement)
        XCTAssertNil(model.error)
    }

    func testQueuedPurchaseInvalidatedBeforeDriverCannotCharge() async {
        let driver = BillingFixtureDriver(), gate = BillingOperationGate()
        let model = store(driver, gate: gate)
        await model.prepare(userID: "user_a")
        await gate.acquire()
        let entered = BillingLatch()
        let observer = model.$purchaseInProgress.sink { if $0 { entered.open() } }
        let purchase = Task { await model.purchase(packageID: "monthly") }
        await entered.wait()
        await model.prepare(userID: nil)
        gate.release()
        let result = await purchase.value
        withExtendedLifetime(observer) {}
        XCTAssertFalse(result)
        XCTAssertFalse(driver.events.contains("purchase:user_a"))
        XCTAssertFalse(model.busy)
    }

    func testSignoutDiscardsSuccessfulStaleOfferings() async {
        let driver = BillingFixtureDriver()
        let entered = BillingLatch(), release = BillingLatch()
        driver.packageHook = { entered.open(); await release.wait() }
        let model = store(driver)
        let preparing = Task { await model.prepare(userID: "user_a") }
        await entered.wait()
        await model.prepare(userID: nil)
        release.open()
        await preparing.value
        XCTAssertTrue(model.packages.isEmpty)
        XCTAssertNil(model.activeUserID)
        XCTAssertNil(model.error)
    }
}

@MainActor
private final class BillingLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private enum BillingFixtureError: Error { case failed }

@MainActor
private final class BillingFixtureDriver: BillingDriver {
    var identity: CloudIdentity? = CloudIdentity(owner: "user_a", session: "session_a")
    var statusHook: ((CloudIdentity) async throws -> AccountDeletionStatus)?
    var offered = [BillingPackage(id: "monthly", productID: "com.lessmeet.app.pro.monthly",
                                title: "Pro", localizedPrice: "12,99 €", period: .monthly)]
    var events: [String] = []
    var maxConcurrent = 0
    private var concurrent = 0
    var identifyHook: ((String) async throws -> Void)?
    var packageHook: (() async throws -> Void)?
    var purchaseHook: (() async throws -> Void)?
    var restoreHook: (() async throws -> Void)?
    var purchaseResult = BillingPurchaseResult(cancelled: false, hasProEntitlement: true)
    var restoredPro = false
    private func begin(_ event: String) {
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        events.append(event)
    }
    func identify(publicAppleAPIKey: String, userID: String) async throws {
        begin("identify:\(userID)"); defer { concurrent -= 1 }
        try await identifyHook?(userID)
    }
    func packages(userID: String) async throws -> [BillingPackage] {
        begin("packages:\(userID)"); defer { concurrent -= 1 }
        try await packageHook?()
        return offered
    }
    func purchase(packageID: String, userID: String) async throws -> BillingPurchaseResult {
        begin("purchase:\(userID)"); defer { concurrent -= 1 }
        try await purchaseHook?()
        return purchaseResult
    }
    func restore(userID: String) async throws -> Bool {
        begin("restore:\(userID)"); defer { concurrent -= 1 }
        try await restoreHook?()
        return restoredPro
    }
}

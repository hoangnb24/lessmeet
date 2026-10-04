import XCTest
@testable import LessMeet

final class RefreshDiagnosticsTests: XCTestCase {
    func testOptInRequiresDevAndFutureFiniteDeadline() {
        let now = Date()
        let future = now.timeIntervalSince1970 + 60
        for info: [String: Any] in [[:], ["LessMeetPackagingMode": "dev"],
            ["LessMeetPackagingMode": "store", "LessMeetRefreshDiagnosticsUntil": future],
            ["LessMeetPackagingMode": "dev", "LessMeetRefreshDiagnosticsUntil": now.timeIntervalSince1970],
            ["LessMeetPackagingMode": "dev", "LessMeetRefreshDiagnosticsUntil": Double.infinity]] {
            XCTAssertNil(RefreshDiagnostics.configured(info: info, now: now, sink: { _ in XCTFail() }))
        }
        XCTAssertNotNil(RefreshDiagnostics.configured(info: ["LessMeetPackagingMode": "dev",
            "LessMeetRefreshDiagnosticsUntil": future], now: now, sink: { _ in }))
    }

    func testBudgetExpiryAndAllowlistedFields() {
        var now = Date(timeIntervalSince1970: 100)
        var lines: [String] = []
        let log = RefreshDiagnostics(expires: now.addingTimeInterval(10), limit: 2, now: { now }, sink: { lines.append($0) })
        let trace = log.trace(origin: .manual)
        trace.event(.started); trace.event(.applied, requested: false)
        trace.event(.started)
        XCTAssertEqual(lines.count, 2)
        let fields = Set(lines.joined(separator: " ").split(separator: " ").map { String($0.split(separator: "=")[0]) })
        XCTAssertEqual(fields, ["refresh", "utc", "local", "origin", "phase", "requested"])
        XCTAssertTrue(lines.allSatisfy { $0.contains("local=\(trace.id.uuidString)") })
        let expiring = RefreshDiagnostics(expires: now.addingTimeInterval(1), now: { now }, sink: { _ in XCTFail("Expired") })
        now = now.addingTimeInterval(1)
        expiring.trace(origin: .automatic).event(.started)
    }

    @MainActor
    func testApplyAndEarlyReturnsDoNotExposeIdentityOrToken() async {
        var lines: [String] = []
        var identity: CloudIdentity? = .init(owner: "private-owner", session: "private-session")
        let log = RefreshDiagnostics(expires: Date().addingTimeInterval(60), sink: { lines.append($0) })
        let model = AccountDeletionModel(identity: { identity }, token: { "private-token" }, send: { _, _ in
            .init(userId: "private-owner", requested: false, localComplete: false, providersComplete: false, requestedAt: nil)
        }, diagnostics: log)
        await model.refresh(origin: .manual)
        XCTAssertEqual(model.status?.requested, false)
        XCTAssertTrue(lines.last!.contains("phase=applied requested=false"))
        XCTAssertFalse(lines.joined().contains("private-"))
        identity = nil
        await model.refresh()
        XCTAssertTrue(lines.last!.contains("phase=skippedNoIdentity"))
    }

    @MainActor
    func testBusyAndLateResponseHaveDistinctPhases() async {
        var lines: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        let log = RefreshDiagnostics(expires: Date().addingTimeInterval(60), sink: { lines.append($0) })
        let model = AccountDeletionModel(identity: { .init(owner: "a", session: "s") }, token: { "t" }, send: { _, _ in
            await withCheckedContinuation { continuation = $0 }
            return .init(userId: "a", requested: false, localComplete: false, providersComplete: false, requestedAt: nil)
        }, diagnostics: log)
        let task = Task { await model.refresh() }
        while continuation == nil { await Task.yield() }
        await model.refresh()
        XCTAssertTrue(lines.last!.contains("phase=skippedBusy"))
        model.contextChanged(); continuation?.resume(); await task.value
        XCTAssertTrue(lines.last!.contains("phase=discardedAfterResponse"))
        XCTAssertFalse(lines.contains { $0.contains("phase=applied") })
        XCTAssertNil(model.status)
    }

    @MainActor
    func testDiscardAfterTokenAndSafeErrors() async {
        for scenario in ["switch", "token", "response", "wrongOwner", "lateError"] {
            var lines: [String] = []
            var identity = CloudIdentity(owner: "a", session: "s")
            let log = RefreshDiagnostics(expires: Date().addingTimeInterval(60), sink: { lines.append($0) })
            let model = AccountDeletionModel(identity: { identity }, token: {
                if scenario == "switch" { identity = .init(owner: "b", session: "s") }
                if scenario == "token" { throw AccountError("private-token-error") }
                return "private-token"
            }, send: { _, _ in
                if scenario == "lateError" { identity = .init(owner: "b", session: "s") }
                if scenario == "response" || scenario == "lateError" { throw AccountError("private-response-error") }
                return .init(userId: "wrong-private-owner", requested: false, localComplete: false, providersComplete: false, requestedAt: nil)
            }, diagnostics: log)
            await model.refresh()
            let expected = ["switch": "discardedAfterToken", "token": "tokenError", "response": "responseError",
                            "wrongOwner": "invalidAccountResponse", "lateError": "discardedError"][scenario]!
            XCTAssertTrue(lines.contains { $0.contains("phase=\(expected)") })
            XCTAssertFalse(lines.joined().contains("private-"))
            XCTAssertFalse(lines.contains { $0.contains("phase=applied") })
            XCTAssertNil(model.status)
        }
    }

    @MainActor
    func testDisabledLoggingAndMutationRemainSilent() async {
        var lines: [String] = []
        let log = RefreshDiagnostics(expires: Date().addingTimeInterval(60), sink: { lines.append($0) })
        let model = AccountDeletionModel(identity: { .init(owner: "a", session: "s") }, token: { "t" }, send: { _, request in
            .init(userId: "a", requested: request, localComplete: false, providersComplete: false, requestedAt: request ? 1 : nil)
        }, diagnostics: log)
        model.prepareConfirmation(); await model.confirm()?.value
        XCTAssertTrue(lines.isEmpty)
        let disabled = AccountDeletionModel(identity: { nil }, token: { "t" }, send: { _, _ in XCTFail(); return model.status! }, diagnostics: nil)
        await disabled.refresh()
        XCTAssertTrue(lines.isEmpty)
    }
}

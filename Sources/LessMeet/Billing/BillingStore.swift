import Combine
import Foundation

struct BillingPackage: Identifiable, Equatable, Sendable {
    enum Period: String, Sendable { case monthly, yearly }
    let id: String
    let productID: String
    let title: String
    let localizedPrice: String
    let period: Period

    var isSupported: Bool {
        !id.isEmpty && !title.isEmpty && !localizedPrice.isEmpty &&
        ((productID == "com.lessmeet.app.pro.monthly" && period == .monthly) ||
         (productID == "com.lessmeet.app.pro.yearly" && period == .yearly))
    }
}

struct BillingPurchaseResult {
    let cancelled: Bool
    let hasProEntitlement: Bool
}

/// Driver calls are made only while holding the process-wide billing gate.
/// Implementations must never configure anonymously or change identity during purchase/restore.
@MainActor
protocol BillingDriver: AnyObject {
    func identify(publicAppleAPIKey: String, userID: String) async throws
    func packages(userID: String) async throws -> [BillingPackage]
    func purchase(packageID: String, userID: String) async throws -> BillingPurchaseResult
    func restore(userID: String) async throws -> Bool
}

/// MainActor alone is reentrant across awaits. Hold this gate across entire SDK operations,
/// including identity setup, so logIn cannot overtake an in-flight purchase or restore.
@MainActor
final class BillingOperationGate {
    static let shared = BillingOperationGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

@MainActor
final class BillingStore: ObservableObject {
    @Published private(set) var packages: [BillingPackage] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var isConfigured: Bool
    @Published private(set) var activeUserID: String?
    @Published private(set) var purchaseInProgress = false
    /// Presentation only. Never use this for cloud authorization.
    @Published private(set) var hasProEntitlement = false

    private let key: String?
    private let driver: BillingDriver
    private let gate: BillingOperationGate
    private var generation = UUID()
    private var operations = 0
    private var ready = false

    convenience init(publicAppleAPIKey: String?) {
        self.init(publicAppleAPIKey: publicAppleAPIKey, driver: RevenueCatBillingDriver.shared,
                  gate: .shared)
    }

    init(publicAppleAPIKey: String?, driver: BillingDriver, gate: BillingOperationGate) {
        let value = publicAppleAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = value.map {
            $0.hasPrefix("appl_") && $0.count > 5 &&
            $0.dropFirst(5).unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        } ?? false
        key = valid ? value : nil
        isConfigured = valid
        self.driver = driver
        self.gate = gate
    }

    /// Identity and visible state change before the first await. Call for every Clerk change.
    /// An already-submitted StoreKit purchase cannot be undone; keep account controls disabled
    /// while busy. A stale completion is discarded, never applied to the replacement account.
    func prepare(userID: String?) async {
        generation = UUID()
        let ticket = generation
        activeUserID = userID.flatMap {
            $0.isEmpty || $0.hasPrefix("$RCAnonymousID:") ||
            $0.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ? nil : $0
        }
        packages = []
        hasProEntitlement = false
        error = nil
        ready = false
        guard let user = activeUserID, let key else { return }
        begin()
        defer { end() }
        await gate.acquire()
        defer { gate.release() }
        guard current(ticket) else { return }
        do {
            try await driver.identify(publicAppleAPIKey: key, userID: user)
            guard current(ticket) else { return }
            let offered = try await driver.packages(userID: user)
            guard current(ticket) else { return }
            var seen = Set<String>()
            packages = offered.filter { $0.isSupported && seen.insert($0.id).inserted }
            ready = true
            if packages.isEmpty { error = "No subscription packages are available. Please try again later." }
        } catch {
            guard current(ticket) else { return }
            self.error = "Unable to load subscriptions. Please try again."
        }
    }

    /// False means cancelled, failed, blocked, or stale; inspect error for current-user failures.
    func purchase(packageID: String) async -> Bool {
        guard !busy, ready, key != nil, let user = activeUserID,
              packages.contains(where: { $0.id == packageID && $0.isSupported }) else { return false }
        let ticket = generation
        error = nil
        purchaseInProgress = true
        begin()
        defer { purchaseInProgress = false; end() }
        await gate.acquire()
        defer { gate.release() }
        guard current(ticket) else { return false }
        do {
            let result = try await driver.purchase(packageID: packageID, userID: user)
            guard current(ticket), !result.cancelled else { return false }
            hasProEntitlement = result.hasProEntitlement
            return true
        } catch {
            guard current(ticket) else { return false }
            self.error = "Purchase could not be completed. Please try again."
            return false
        }
    }

    /// Explicit user action only. True means restore completed, not that a subscription exists.
    func restore() async -> Bool {
        guard !busy, key != nil, let user = activeUserID else { return false }
        let ticket = generation
        error = nil
        begin()
        defer { end() }
        await gate.acquire()
        defer { gate.release() }
        guard current(ticket), let key else { return false }
        do {
            try await driver.identify(publicAppleAPIKey: key, userID: user)
            guard current(ticket) else { return false }
            let pro = try await driver.restore(userID: user)
            guard current(ticket) else { return false }
            hasProEntitlement = pro
            return true
        } catch {
            guard current(ticket) else { return false }
            self.error = "Purchases could not be restored. Please try again."
            return false
        }
    }

    private func current(_ ticket: UUID) -> Bool { generation == ticket && !Task.isCancelled }
    private func begin() { operations += 1; busy = true }
    private func end() { operations -= 1; busy = operations > 0 }
}

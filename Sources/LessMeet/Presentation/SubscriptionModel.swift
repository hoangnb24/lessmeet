import Combine
import Foundation

@MainActor
final class SubscriptionModel: ObservableObject {
    @Published private(set) var status: SubscriptionStatus?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let identity: () -> CloudIdentity?
    private let token: () async throws -> String
    private let fetch: (String, Bool) async throws -> SubscriptionStatus
    private var generation = UUID()
    private var waitingSynchronizations: [CheckedContinuation<Void, Never>] = []
    // Internal observability for deterministic concurrency fixtures, not authorization.
    var pendingSynchronizationCount: Int { waitingSynchronizations.count }

    init(identity: @escaping () -> CloudIdentity?, token: @escaping () async throws -> String,
         fetch: @escaping (String, Bool) async throws -> SubscriptionStatus) {
        self.identity = identity
        self.token = token
        self.fetch = fetch
    }

    convenience init(account: AccountSession) {
        let site = (try? AppConfiguration.load())?.convexSiteURL
        self.init(identity: {
            guard let user = account.userID, let session = account.sessionIdentifier else { return nil }
            return CloudIdentity(owner: user, session: session)
        }, token: {
            guard !account.cloudAccessLocked else { throw AccountError("Account deletion requested. Billing access is locked.") }
            return try await account.token()
        }, fetch: { token, sync in
            guard let site else { throw AccountError("Configure the cloud endpoint to view your plan.") }
            return try await CloudClient(baseURL: site).subscription(token: token, synchronize: sync)
        })
    }

    /// Clear private state immediately, including while an old network request is suspended.
    func contextChanged() {
        generation = UUID()
        status = nil
        error = nil
        finishRefresh()
    }

    func refresh(synchronize: Bool = false) async {
        guard let account = identity() else { contextChanged(); return }
        let request = generation
        if busy {
            guard synchronize else { return }
            // A post-purchase verification must outlive an overlapping ordinary GET.
            // Its caller stays suspended (and purchase controls locked) until verified.
            await withCheckedContinuation { waitingSynchronizations.append($0) }
            guard request == generation, identity() == account, !Task.isCancelled else { return }
            await refresh(synchronize: true)
            return
        }
        busy = true
        error = nil
        defer { if request == generation { finishRefresh() } }
        do {
            let bearer = try await token()
            guard request == generation, identity() == account, !Task.isCancelled else { return }
            let result = try await fetch(bearer, synchronize)
            guard request == generation, identity() == account, !Task.isCancelled else { return }
            guard result.isValid, result.userId == account.owner else {
                throw AccountError("The plan response did not match the signed-in account. Refresh before purchasing.")
            }
            status = result
        } catch {
            guard request == generation, identity() == account, !Task.isCancelled else { return }
            status = nil
            self.error = error.localizedDescription
        }
    }

    private func finishRefresh() {
        busy = false
        let waiting = waitingSynchronizations
        waitingSynchronizations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

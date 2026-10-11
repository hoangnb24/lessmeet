import Combine
import Foundation

/// In-memory inputs for tests and the separate offline-check executable.
/// This fixture never creates AccountSession, Clerk, CloudClient or a recording store.
@MainActor
final class OfflineAccountFixture: ObservableObject {
    enum Scenario: String, CaseIterable, Identifiable {
        case ready = "No deletion requested"
        case requested = "Deletion pending"
        case failure = "Request fails"
        case waiting = "Wait for response"
        case googlePending = "Google revocation pending"
        case googleException = "Google revocation exception"
        case googleAcknowledged = "Google revocation acknowledged"
        var id: String { rawValue }
    }

    @Published var scenario: Scenario = .ready
    @Published private(set) var identity = CloudIdentity(owner: "offline-alice", session: "offline-a")
    @Published private(set) var hasPendingResponse = false
    private var pending: CheckedContinuation<AccountDeletionStatus, Error>?
    private var pendingStatus: AccountDeletionStatus?
    var onPendingResponse: (() -> Void)?

    lazy var model = AccountDeletionModel(identity: { [weak self] in self?.identity },
        token: { "offline-fixture-not-a-token" }, send: { [weak self] _, deletion in
            guard let self, !deletion else { throw AccountError("Offline checks cannot delete accounts.") }
            let status = self.status()
            switch self.scenario {
            case .failure: throw AccountError("Synthetic connection failure. No request was sent.")
            case .waiting:
                return try await withCheckedThrowingContinuation { continuation in
                    self.pendingStatus = status
                    self.pending = continuation
                    self.hasPendingResponse = true
                    self.onPendingResponse?()
                }
            case .ready, .requested, .googlePending, .googleException, .googleAcknowledged: return status
            }
        }, diagnostics: nil)

    private func status() -> AccountDeletionStatus {
        let google: AccountDeletionStatus.GoogleStatus?
        switch scenario {
        case .googlePending: google = .pending
        case .googleException: google = .exception
        case .googleAcknowledged: google = .acknowledged
        case .ready, .requested, .failure, .waiting: google = nil
        }
        let requested = scenario == .requested || google != nil
        return .init(userId: identity.owner, requested: requested,
                     localComplete: google == .acknowledged, providersComplete: false,
                     requestedAt: requested ? 1 : nil, googleStatus: google)
    }

    func completePendingResponse() {
        guard let pending, let status = pendingStatus else { return }
        self.pending = nil; pendingStatus = nil; hasPendingResponse = false
        pending.resume(returning: status)
    }

    func switchAccount() {
        identity = identity.owner == "offline-alice"
            ? .init(owner: "offline-bob", session: "offline-b")
            : .init(owner: "offline-alice", session: "offline-a")
        model.contextChanged()
        // Finish the old response after the generation changed. The model must discard it.
        completePendingResponse()
    }
}

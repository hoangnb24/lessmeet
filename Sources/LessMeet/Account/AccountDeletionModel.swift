import Combine
import Foundation

struct AccountDeletionStatus: Codable, Equatable {
    let userId: String
    let requested: Bool
    let localComplete: Bool
    let providersComplete: Bool
    let requestedAt: Double?

    var isValid: Bool {
        !userId.isEmpty && (requested ? requestedAt != nil : (!localComplete && !providersComplete && requestedAt == nil)) &&
        (!providersComplete || localComplete)
    }
}

@MainActor
final class AccountDeletionModel: ObservableObject {
    @Published private(set) var status: AccountDeletionStatus?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var confirming = false
    private let identity: () -> CloudIdentity?
    private let token: () async throws -> String
    private let send: (String, Bool) async throws -> AccountDeletionStatus
    private let lock: (CloudIdentity, Bool) -> Void
    private var confirmationIdentity: CloudIdentity?
    private var generation = UUID()
    private let diagnostics: RefreshDiagnostics?

    init(identity: @escaping () -> CloudIdentity?, token: @escaping () async throws -> String,
         send: @escaping (String, Bool) async throws -> AccountDeletionStatus,
         lock: @escaping (CloudIdentity, Bool) -> Void = { _, _ in },
         diagnostics: RefreshDiagnostics? = RefreshDiagnostics.runtime) {
        self.identity = identity; self.token = token; self.send = send; self.lock = lock
        self.diagnostics = diagnostics
    }

    convenience init(account: AccountSession) {
        let site = (try? AppConfiguration.load())?.convexSiteURL
        self.init(identity: { [weak account] in
            guard let user = account?.userID, let session = account?.sessionIdentifier else { return nil }
            return CloudIdentity(owner: user, session: session)
        }, token: { [weak account] in
            guard let account else { throw AccountError("Sign in again.") }
            return try await account.token()
        }, send: { bearer, request in
            guard let site else { throw AccountError("Configure the cloud endpoint before requesting deletion.") }
            return try await CloudClient(baseURL: site).deletion(token: bearer, requestDeletion: request)
        }, lock: { [weak account] who, locked in
            account?.setDeletionLock(who, locked: locked)
        })
    }

    func contextChanged() {
        generation = UUID(); status = nil; error = nil; busy = false; cancelConfirmation()
    }
    func prepareConfirmation() {
        guard !busy, let who = identity() else { return }
        confirmationIdentity = who; confirming = true
    }
    func cancelConfirmation() { confirming = false; confirmationIdentity = nil }
    func confirm() -> Task<Void, Never>? {
        guard let who = confirmationIdentity, who == identity(), !busy else { cancelConfirmation(); return nil }
        cancelConfirmation()
        let current = generation
        return Task {
            guard current == generation, who == identity(), !Task.isCancelled else { return }
            await perform(request: true)
        }
    }
    func refresh(origin: RefreshOrigin = .unspecified) async {
        await RefreshDiagnostics.$current.withValue(diagnostics?.trace(origin: origin)) {
            await perform(request: false)
        }
    }

    private func perform(request: Bool) async {
        let trace = request ? nil : RefreshDiagnostics.current
        trace?.event(.started)
        guard !busy else { trace?.event(.skippedBusy); return }
        guard let who = identity() else { trace?.event(.skippedNoIdentity); return }
        let current = generation
        busy = true; error = nil
        // An ambiguous request must not leave cached purchase/upload controls enabled.
        if request { lock(who, true) }
        defer { if current == generation { busy = false } }
        var sending = false
        do {
            trace?.event(.tokenStarted)
            let bearer = try await token()
            guard current == generation, identity() == who, !Task.isCancelled else {
                trace?.event(.discardedAfterToken); return
            }
            sending = true
            trace?.event(.sendStarted)
            let result = try await send(bearer, request)
            trace?.event(.received, requested: result.requested, localComplete: result.localComplete,
                         providersComplete: result.providersComplete)
            guard current == generation, identity() == who, !Task.isCancelled else {
                trace?.event(.discardedAfterResponse); return
            }
            guard result.isValid, result.userId == who.owner, !request || result.requested else {
                trace?.event(.invalidAccountResponse)
                throw AccountError("Deletion response did not match this account. Refresh status before retrying.")
            }
            status = result; lock(who, result.requested)
            trace?.event(.applied, requested: status?.requested, localComplete: status?.localComplete,
                         providersComplete: status?.providersComplete)
        } catch {
            guard current == generation, identity() == who, !Task.isCancelled else {
                trace?.event(.discardedError); return
            }
            trace?.event(sending ? .responseError : .tokenError)
            self.error = error.localizedDescription
        }
    }
}

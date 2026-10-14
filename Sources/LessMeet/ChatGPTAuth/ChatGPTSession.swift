import Foundation
import AppKit

@MainActor
final class ChatGPTSession: ObservableObject {
    @Published private(set) var profiles: [ChatGPTProfile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var needsSignOutRetry = false
    @Published private var sessionRevision: String?
    @Published private var planEnabled = false

    var sessionIdentifier: String? { sessionRevision }
    var canUseChatGPTPlan: Bool { planEnabled && activeProfileID != nil && !loggingOut && pendingLogoutProfileID == nil }

    private let store: ChatGPTCredentialStore
    private let credentialLock: ChatGPTCredentialLock
    private let transport: ChatGPTAuthTransport
    private let makeListener: () -> ChatGPTCallbackListener
    private let openBrowser: (URL) throws -> Void
    private let now: () -> Date
    private var generation = UUID()
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var refreshID: UUID?
    private var listener: ChatGPTCallbackListener?
    private var loggingOut = false
    private var pendingLogoutProfileID: String?

    convenience init() {
        let network = ChatGPTAuthURLSession()
        self.init(store: ChatGPTKeychainStore(), credentialLock: ChatGPTFileLock(),
                  send: { try await network.send($0) }, makeListener: { ChatGPTLoopbackListener() },
                  openBrowser: { guard NSWorkspace.shared.open($0) else { throw ChatGPTAuthError.browser } })
    }

    init(store: ChatGPTCredentialStore, credentialLock: ChatGPTCredentialLock,
         send: @escaping ChatGPTAuthSend, makeListener: @escaping () -> ChatGPTCallbackListener,
         openBrowser: @escaping (URL) throws -> Void, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.credentialLock = credentialLock
        transport = ChatGPTAuthTransport(send: send)
        self.makeListener = makeListener
        self.openBrowser = openBrowser
        self.now = now
        do { publish(try read()) }
        catch { self.error = ChatGPTAuthError.storage.localizedDescription }
    }

    func signIn(profileID: String? = nil, requestPlanConsent: Bool = false) async {
        guard !loggingOut, pendingLogoutProfileID == nil else { return }
        let maintenance = refreshTask
        cancelSignIn()
        generation = UUID()
        let epoch = generation
        busy = true
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if let maintenance { _ = await maintenance.result }
                try self.check(epoch)
                try await self.authorize(profileID: profileID, requestPlanConsent: requestPlanConsent, epoch: epoch)
            }
            catch {
                if self.generation == epoch {
                    self.error = self.message(error)
                }
            }
            if self.generation == epoch {
                self.busy = false
                self.signInTask = nil
                self.listener = nil
            }
        }
        signInTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelSignIn() {
        generation = UUID()
        signInTask?.cancel()
        signInTask = nil
        listener?.cancel()
        listener = nil
        if !loggingOut { busy = false }
    }

    func signOut() async {
        guard !loggingOut else { return }
        pendingLogoutProfileID = pendingLogoutProfileID ?? activeProfileID
        let selectedID = pendingLogoutProfileID
        let maintenance = refreshTask
        loggingOut = true
        cancelSignIn()
        sessionRevision = nil
        planEnabled = false
        activeProfileID = nil
        busy = true
        error = nil
        defer { loggingOut = false; busy = false }
        do {
            if let maintenance { _ = await maintenance.result }
            try await credentialLock.acquire()
            defer { credentialLock.release() }
            var record = try read()
            guard let index = record.registrations.firstIndex(where: { $0.profile?.id == selectedID && selectedID != nil }) else {
                pendingLogoutProfileID = nil
                needsSignOutRetry = false
                publish(record, allowActive: false)
                return
            }
            var confirmed = true
            if let token = record.registrations[index].tokens?.refresh {
                confirmed = false
                if let metadata = try? await transport.discovery(), let endpoint = metadata.revocation_endpoint {
                    confirmed = await transport.revoke(endpoint: endpoint, clientID: record.registrations[index].clientID, token: token)
                }
            }
            record.registrations[index].tokens = nil
            if record.activeProfileID == selectedID {
                record.activeProfileID = nil
                record.sessionID = nil
            }
            try save(record)
            pendingLogoutProfileID = nil
            needsSignOutRetry = false
            publish(record, allowActive: false)
            if !confirmed {
                error = "Signed out locally. Remote revocation was not confirmed. Disconnect LessMeet in ChatGPT Settings."
            }
        } catch {
            needsSignOutRetry = true
            self.error = "Local sign-out could not be saved. Access is disabled in this app session. Retry sign-out before quitting; stored credentials may remain after restart."
        }
    }

    func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard !loggingOut, pendingLogoutProfileID == nil, !busy, let selectedID = activeProfileID else { throw ChatGPTAuthError.signedOut }
        let epoch = generation
        if let refreshTask {
            let result = try await refreshTask.value
            try Task.checkCancellation()
            try check(epoch)
            return result
        }
        let id = UUID()
        let task = Task { try await self.currentToken(profileID: selectedID, epoch: epoch) }
        refreshTask = task
        refreshID = id
        defer {
            if refreshID == id { refreshTask = nil; refreshID = nil }
        }
        do {
            let token = try await task.value
            try Task.checkCancellation()
            try check(epoch)
            return token
        } catch {
            if generation == epoch { self.error = message(error) }
            throw error
        }
    }

    private func authorize(profileID: String?, requestPlanConsent: Bool, epoch: UUID) async throws {
        try await credentialLock.acquire()
        defer { credentialLock.release() }
        try check(epoch)
        var record = try read()
        let selected: ChatGPTRegistration?
        if let profileID {
            guard let found = record.registrations.first(where: { $0.profile?.id == profileID }) else {
                throw ChatGPTAuthError.signedOut
            }
            selected = found
        } else {
            selected = record.registrations.last(where: { $0.subject == nil })
        }
        // Persist the host before any registration request can leave the process.
        try save(record)
        let metadata = try await transport.discovery()
        try check(epoch)
        let callbackListener = makeListener()
        listener = callbackListener
        defer { callbackListener.cancel() }
        let uri = try await callbackListener.start()
        try check(epoch)
        let attempt = try ChatGPTAuthAttempt(redirectURI: uri, clientID: selected?.clientID)
        try openBrowser(attempt.authorizationURL(endpoint: metadata.authorization_endpoint, hostID: record.hostID,
                                                 idToken: selected?.tokens?.identity, requestPlanConsent: requestPlanConsent))
        let url = try await callbackListener.callback()
        try check(epoch)
        let callback = try attempt.callback(url)
        var index = record.registrations.firstIndex(where: { $0.clientID == callback.clientID })
        if selected == nil {
            guard index == nil else { throw ChatGPTAuthError.identity }
            record.registrations.append(ChatGPTRegistration(clientID: callback.clientID))
            index = record.registrations.count - 1
            // Keep the issued client even if the code is expired or the exchange fails.
            try save(record)
        }
        guard let index else { throw ChatGPTAuthError.storage }
        let response = try await transport.exchange(endpoint: metadata.token_endpoint, fields: [
            "grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code,
            "code_verifier": attempt.verifier, "redirect_uri": uri.absoluteString, "resource": ChatGPTAuthConstants.resource
        ])
        try check(epoch)
        let tokens = try response.tokens(now: now())
        let identity = try await transport.identity(tokens.identity, metadata: metadata, clientID: callback.clientID,
                                                    nonce: attempt.nonce, subject: selected?.subject, now: now())
        try check(epoch)
        let profile = identity.profile(clientID: callback.clientID)
        record.registrations[index].profile = profile
        record.registrations[index].subject = identity.subject
        record.registrations[index].tokens = tokens
        record.activeProfileID = profile.id
        record.sessionID = UUID().uuidString
        try save(record)
        publish(record)
    }

    private func currentToken(profileID: String, epoch: UUID) async throws -> String {
        try await credentialLock.acquire()
        defer { credentialLock.release() }
        try check(epoch)
        var record = try read()
        guard record.activeProfileID == profileID,
              let index = record.registrations.firstIndex(where: { $0.profile?.id == profileID }),
              let tokens = record.registrations[index].tokens else {
            publish(record)
            throw ChatGPTAuthError.signedOut
        }
        publish(record)
        guard tokens.scopes.contains(ChatGPTAuthConstants.planScope) else { throw ChatGPTAuthError.consent }
        if tokens.expiresAt > now().addingTimeInterval(60), let access = tokens.access { return access }
        if let earliest = tokens.earliestRefreshAt, earliest > now() {
            if tokens.expiresAt > now(), let access = tokens.access { return access }
            throw ChatGPTAuthError.temporary
        }
        guard let refresh = tokens.refresh else { throw ChatGPTAuthError.signedOut }
        // Only the refresh endpoint can classify these credentials as unusable.
        let metadata = try await transport.discovery()
        try check(epoch)
        let response: ChatGPTTokenResponse
        do {
            response = try await transport.exchange(endpoint: metadata.token_endpoint, fields: [
                "grant_type": "refresh_token", "client_id": record.registrations[index].clientID,
                "refresh_token": refresh, "resource": ChatGPTAuthConstants.resource
            ])
        } catch {
            if let failure = error as? ChatGPTAuthError, failure.terminalRefresh {
                record.registrations[index].tokens = nil
                record.activeProfileID = nil
                record.sessionID = nil
                try save(record)
                if generation == epoch { publish(record) }
            }
            throw error
        }
        // A dispatched rotation must finish credential maintenance even after a session switch.
        let replacement = try response.tokens(now: now(), previousIdentity: tokens.identity, refresh: true)
        if let identityToken = response.id_token {
            _ = try await transport.identity(identityToken, metadata: metadata, clientID: record.registrations[index].clientID,
                                             nonce: nil, subject: record.registrations[index].subject, now: now())
        }
        record.registrations[index].tokens = replacement
        try save(record)
        try check(epoch)
        publish(record)
        guard replacement.scopes.contains(ChatGPTAuthConstants.planScope), let access = replacement.access else {
            throw ChatGPTAuthError.consent
        }
        return access
    }

    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch, !loggingOut, pendingLogoutProfileID == nil else { throw ChatGPTAuthError.canceled }
    }

    private func read() throws -> ChatGPTAuthRecord {
        do {
            guard let data = try store.read() else { return ChatGPTAuthRecord() }
            let record = try JSONDecoder().decode(ChatGPTAuthRecord.self, from: data)
            guard record.version == 1, record.hostID.hasPrefix("urn:uuid:"),
                  UUID(uuidString: String(record.hostID.dropFirst(9))) != nil,
                  Set(record.registrations.map(\.clientID)).count == record.registrations.count else {
                throw ChatGPTAuthError.storage
            }
            return record
        } catch { throw ChatGPTAuthError.storage }
    }

    private func save(_ record: ChatGPTAuthRecord) throws {
        do { try store.write(JSONEncoder().encode(record)) }
        catch { throw ChatGPTAuthError.storage }
    }

    private func publish(_ record: ChatGPTAuthRecord, allowActive: Bool = true) {
        profiles = record.registrations.compactMap(\.profile)
        guard allowActive, !loggingOut, pendingLogoutProfileID == nil, let selected = record.registrations.first(where: {
            $0.profile?.id == record.activeProfileID && $0.profile != nil
        }), let tokens = selected.tokens else {
            activeProfileID = nil
            sessionRevision = nil
            planEnabled = false
            return
        }
        activeProfileID = record.activeProfileID
        sessionRevision = record.sessionID
        planEnabled = tokens.scopes.contains(ChatGPTAuthConstants.planScope)
    }

    private func message(_ error: Error) -> String {
        if error is CancellationError { return ChatGPTAuthError.canceled.localizedDescription }
        return (error as? ChatGPTAuthError ?? .temporary).localizedDescription
    }
}

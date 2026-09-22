import ClerkKit
import Combine
import Foundation

@MainActor
final class AccountSession: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    // Clerk is itself @Observable. Reading these values in a SwiftUI body tracks
    // restored sessions, expiration and profile changes without a polling task.
    let clerk: Clerk?
    let configurationIssue: String?

    init(configuration: AppConfiguration? = nil) {
        do {
            let configuration = try configuration ?? AppConfiguration.load()
            if let key = configuration.clerkPublishableKey {
                clerk = Clerk.configure(publishableKey: key)
                configurationIssue = nil
            } else {
                clerk = nil
                configurationIssue = "Sign-in is not configured. Set CLERK_PUBLISHABLE_KEY or rebuild with ClerkPublishableKey. Local recording is still available."
            }
        } catch {
            clerk = nil
            configurationIssue = "Account configuration could not load: \(error.localizedDescription) Local recording is still available."
        }
    }

    var isSignedIn: Bool { clerk?.session?.status == .active }
    var isLoaded: Bool { clerk?.isLoaded == true }
    var email: String? { clerk?.user?.primaryEmailAddress?.emailAddress }
    var displayName: String {
        let name = [clerk?.user?.firstName, clerk?.user?.lastName]
            .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (email ?? "Signed in") : name
    }

    func signIn() async {
        guard !busy else { return }
        error = nil
        guard let clerk else { error = configurationIssue; return }
        busy = true
        defer { busy = false }
        do {
            let session = try await clerk.auth.startHostedAuth(redirectUrl: "com.lessmeet.app://callback")
            guard session.status == .active, clerk.session?.id == session.id else {
                throw AccountError("Sign-in did not activate an account. Complete the account requirements in the sign-in window and try again.")
            }
        } catch {
            self.error = "Sign-in did not finish: \(error.localizedDescription) Try signing in again; local recording remains available."
        }
    }

    func signOut() async {
        guard !busy else { return }
        error = nil
        guard let clerk else { error = configurationIssue; return }
        busy = true
        defer { busy = false }
        do {
            try await clerk.auth.signOut()
        } catch {
            self.error = "Could not sign out: \(error.localizedDescription) Check your connection and try again."
        }
    }

    func token() async throws -> String {
        guard let clerk else {
            throw AccountError(configurationIssue ?? "Configure Clerk before using cloud features.")
        }
        guard !busy, let session = clerk.session, session.status == .active else {
            throw AccountError("Sign in and finish account verification before using cloud features.")
        }
        let token: String?
        do {
            token = try await session.getToken(.init(skipCache: true))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError("Could not authorize the cloud request: \(error.localizedDescription) Check your connection, then try again or sign in again.")
        }
        guard !busy, clerk.session?.id == session.id, clerk.session?.status == .active else {
            throw AccountError("Your account changed while authorizing this request. Try again with the current account.")
        }
        guard let token, !token.isEmpty else {
            throw AccountError("No account token was returned. Sign out and sign in again.")
        }
        return token
    }
}

struct AccountError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

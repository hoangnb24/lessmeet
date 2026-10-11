import SwiftUI

struct AccountPanel: View {
    @ObservedObject var session: AccountSession
    var billingBusy = false
    @State private var showingAccount = false

    var body: some View {
        Button { showingAccount.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(.system(size: 21)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.isSignedIn ? session.displayName : "Your account")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(accountSubtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAccount, arrowEdge: .top) { accountDetails.padding(20).frame(width: 290) }
    }

    private var accountSubtitle: String {
        if session.error != nil { return "Account needs attention" }
        if session.configurationIssue != nil { return "Account unavailable" }
        if session.needsConnection { return "Local mode · Connect account" }
        return session.isSignedIn ? "Account settings" : "Sign in for transcripts & chat"
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Account", systemImage: "person.crop.circle").font(.headline)
            if let issue = session.configurationIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            } else if session.needsConnection {
                Text("Recording works without connecting your account. Connect to restore your saved session or sign in.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("macOS may ask permission to read LessMeet's saved sign-in data in Keychain. Account connection may wait until you handle that prompt.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Connect Account") { session.connect() }.disabled(session.busy)
            } else if session.isSignedIn {
                Text(session.displayName).font(.subheadline)
                if let email = session.email, email != session.displayName {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign Out") { Task { await session.signOut() } }.disabled(session.busy || billingBusy)
                AccountDeletionView(model: session.deletion, sessionID: session.sessionIdentifier, billingBusy: billingBusy)
            } else {
                Text("Sign in for transcripts and chat. Recording works without an account.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sign In with Google or Apple") { Task { await session.signIn() } }.disabled(session.busy)
                if !session.isLoaded {
                    Text("Account connection is loading. Sign in to connect or try again if offline.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if session.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Updating account…").font(.caption) }
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

struct AccountDeletionView: View {
    @ObservedObject var model: AccountDeletionModel
    let sessionID: String?
    let billingBusy: Bool
    var allowsExternalActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let status = model.status, status.requested {
                Text("Account deletion requested").font(.caption.bold())
                Text(status.localComplete ? "Cloud storage cleanup verified." : "Cloud cleanup is pending, including any in-flight work.")
                Text(status.providersComplete ? "Provider handling verified. Contact the operator for the completion record and remaining retention limits." : "Provider handling is pending. This is not confirmation that all copies have been erased.")
                if let google = AccountDeletionCopy.googleStatus(status) {
                    Text(google)
                }
            } else {
                Button("Delete Account…", role: .destructive) { model.prepareConfirmation() }
                    .disabled(model.busy || billingBusy || !allowsExternalActions)
            }
            Button("Refresh deletion status") { Task { await model.refresh(origin: .manual) } }.disabled(model.busy)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(AccountDeletionCopy.timing)
            Text(AccountDeletionCopy.scope).foregroundStyle(.secondary)
            Text("Local recordings and saved results stay on this Mac. Account deletion does not cancel Apple subscriptions.")
            if allowsExternalActions {
                Link("Manage or cancel subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: sessionID) { model.contextChanged(); await model.refresh(origin: .automatic) }
        .confirmationDialog("Delete this LessMeet account?", isPresented: Binding(get: { model.confirming }, set: { if !$0 { model.cancelConfirmation() } }), titleVisibility: .visible) {
            Button("Delete Account and Cloud Data", role: .destructive) {
                guard allowsExternalActions else { model.cancelConfirmation(); return }
                _ = model.confirm()
            }
                .disabled(billingBusy || !allowsExternalActions)
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
        } message: {
            Text(AccountDeletionCopy.confirmation)
        }
    }
}

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
        return session.isSignedIn ? "Account settings" : "Sign in for transcripts & chat"
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Account", systemImage: "person.crop.circle").font(.headline)
            if let issue = session.configurationIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
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

private struct AccountDeletionView: View {
    @ObservedObject var model: AccountDeletionModel
    let sessionID: String?
    let billingBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let status = model.status, status.requested {
                Text("Account deletion requested").font(.caption.bold())
                Text(status.localComplete ? "Cloud storage cleanup verified." : "Cloud cleanup is pending, including any in-flight work.")
                Text(status.providersComplete ? "Provider handling verified. Contact the operator for the completion record and remaining retention limits." : "Provider handling is pending. This is not confirmation that all copies have been erased.")
            } else {
                Button("Delete Account…", role: .destructive) { model.prepareConfirmation() }
                    .disabled(model.busy || billingBusy)
            }
            Button("Refresh deletion status") { Task { await model.refresh() } }.disabled(model.busy)
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Local recordings and saved results stay on this Mac. Account deletion does not cancel Apple subscriptions.")
            Link("Manage or cancel subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        }
        .font(.caption)
        .task(id: sessionID) { model.contextChanged(); await model.refresh() }
        .confirmationDialog("Delete this LessMeet account?", isPresented: Binding(get: { model.confirming }, set: { if !$0 { model.cancelConfirmation() } }), titleVisibility: .visible) {
            Button("Delete Account and Cloud Data", role: .destructive) { _ = model.confirm() }
                .disabled(billingBusy)
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
        } message: {
            Text("Cloud access will be locked and deletion of your account, uploaded audio, transcripts and chat will begin. This cannot be undone here. Provider fulfillment takes additional time and remains pending until verified; no completion date is promised. Local recordings and saved results remain. Apple billing continues unless you cancel separately; cancellation is not required to request deletion. Deleting this account does not transfer purchases to another account.")
        }
    }
}

import SwiftUI

struct AccountPanel: View {
    @ObservedObject var session: AccountSession
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
                Button("Sign Out") { Task { await session.signOut() } }.disabled(session.busy)
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

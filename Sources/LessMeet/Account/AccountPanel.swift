import SwiftUI

struct AccountPanel: View {
    @ObservedObject var session: AccountSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Account", systemImage: "person.crop.circle").font(.headline)
            if let issue = session.configurationIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            } else if session.isSignedIn {
                Text(session.displayName).font(.subheadline).lineLimit(2)
                if let email = session.email, email != session.displayName {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Sign Out") { Task { await session.signOut() } }
                    .disabled(session.busy)
            } else {
                Text("Sign in for transcripts and chat. Recording works without an account.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sign In with Google or Apple") { Task { await session.signIn() } }
                    .disabled(session.busy)
                if !session.isLoaded {
                    Text("Account connection is loading. Sign in to connect or try again if offline.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if session.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating account…").font(.caption)
                }
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

import SwiftUI

@MainActor
struct ChatGPTAccountView: View {
    @ObservedObject var session: ChatGPTSession
    var beforeAccountChange: () -> Void = {}

    @AppStorage("com.lessmeet.app.chatgpt.planWelcomeAcknowledged.v1")
    private var acknowledgedPlanWelcome = false
    @State private var selectedProfileID: String?
    @State private var showingPlanWelcome = false
    @State private var signingOut = false

    private let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ChatGPT account").font(.title2.bold())
            Text("Use your ChatGPT plan for eligible transcript chat requests in LessMeet.")
                .foregroundStyle(.secondary)

            if let profile = session.profiles.first(where: { $0.id == session.activeProfileID }) {
                Label(profile.displayName, systemImage: "person.crop.circle")
                    .textSelection(.enabled)
            }

            if session.canUseChatGPTPlan {
                HStack {
                    Label("Using ChatGPT plan", systemImage: "checkmark.circle")
                    Link("Manage usage", destination: usageURL)
                }
            } else if let activeID = session.activeProfileID {
                Text("This account has not enabled ChatGPT plan usage.")
                    .foregroundStyle(.secondary)
                Button("Enable ChatGPT plan usage") {
                    signIn(profileID: activeID, requestPlanConsent: true)
                }
                .disabled(session.busy)
            } else {
                Text("Sign in to send questions. Your saved chats remain available locally.")
                    .foregroundStyle(.secondary)
            }

            if !session.profiles.isEmpty {
                Picker("Account", selection: $selectedProfileID) {
                    Text("New account or workspace").tag(String?.none)
                    ForEach(session.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }
                .disabled(session.busy)
            }

            HStack(spacing: 12) {
                ChatGPTSignInButton {
                    signIn(profileID: selectedProfileID)
                }
                Button("Add account") {
                    selectedProfileID = nil
                    signIn(profileID: nil)
                }
            }
            .disabled(session.busy)

            if session.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(signingOut ? "Signing out…" : "Complete sign-in in your browser…")
                        .foregroundStyle(.secondary)
                    if !signingOut {
                        Button("Cancel sign-in") {
                            beforeAccountChange()
                            session.cancelSignIn()
                        }
                    }
                }
            }

            if let error = session.error {
                // The session exposes safe messages, never raw OAuth responses.
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Account error: \(error)")
            }

            HStack {
                // Failed cleanup clears activeProfileID but still needs an explicit retry.
                Button(session.activeProfileID == nil && session.error != nil ? "Retry sign-out" : "Sign out") {
                    beforeAccountChange()
                    signingOut = true
                    Task {
                        await session.signOut()
                        signingOut = false
                    }
                }
                .disabled(session.busy)
                if !session.canUseChatGPTPlan {
                    Link("Manage usage", destination: usageURL)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 520, alignment: .leading)
        .onChange(of: session.activeProfileID, initial: true) { _, id in
            selectedProfileID = id
        }
        .onChange(of: session.canUseChatGPTPlan, initial: true) { _, enabled in
            showingPlanWelcome = enabled && !acknowledgedPlanWelcome
        }
        .sheet(isPresented: $showingPlanWelcome) {
            VStack(alignment: .leading, spacing: 16) {
                Text("You’re using your ChatGPT plan").font(.title2.bold())
                Text("Eligible LessMeet chat requests count toward your ChatGPT plan usage. Review usage and limits in ChatGPT settings.")
                Link("Manage usage", destination: usageURL)
                HStack {
                    Spacer()
                    Button("Got it") {
                        acknowledgedPlanWelcome = true
                        showingPlanWelcome = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 400)
            .interactiveDismissDisabled()
        }
    }

    private func signIn(profileID: String?, requestPlanConsent: Bool = false) {
        beforeAccountChange()
        Task { await session.signIn(profileID: profileID, requestPlanConsent: requestPlanConsent) }
    }
}

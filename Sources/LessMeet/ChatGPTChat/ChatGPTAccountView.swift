import SwiftUI

@MainActor
struct ChatGPTAccountView: View {
    @ObservedObject var session: ChatGPTSession
    var beforeAccountChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage("com.lessmeet.app.chatgpt.planWelcomeAcknowledged.v1")
    private var acknowledgedPlanWelcome = false
    @State private var selectedProfileID: String?
    @State private var showingPlanWelcome = false
    @State private var showingAccountSelection = false
    @State private var signingOut = false

    private let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    private var activeProfile: ChatGPTProfile? {
        session.profiles.first { $0.id == session.activeProfileID }
    }

    private var needsSignOutRetry: Bool {
        session.needsSignOutRetry
    }

    private var signOutNeedsAttention: Bool {
        needsSignOutRetry
    }

    var body: some View {
        // LibraryView owns the fixed header and the sheet's 490 × 608 limit.
        ScrollView {
            VStack(spacing: 20) {
                if session.busy || signingOut {
                    waitingBody
                } else if signOutNeedsAttention || showingAccountSelection ||
                            !session.profiles.isEmpty || session.activeProfileID != nil {
                    accountBody.disabled(session.busy)
                } else {
                    signedOutBody.disabled(session.busy)
                }
                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatGPTStyle.surface)
        .foregroundStyle(ChatGPTStyle.ink)
        .tint(ChatGPTStyle.accent)
        .onChange(of: session.activeProfileID, initial: true) { _, id in
            selectedProfileID = id
            showingAccountSelection = id == nil && !session.profiles.isEmpty
        }
        .onChange(of: session.canUseChatGPTPlan, initial: true) { _, enabled in
            showingPlanWelcome = enabled && !acknowledgedPlanWelcome
        }
        .sheet(isPresented: $showingPlanWelcome) {
            welcomeBody.interactiveDismissDisabled()
        }
    }

    private var signedOutBody: some View {
        VStack(spacing: 20) {
            connectionArt
            heading("Your meetings.\nA clearer next step.",
                    detail: "Connect ChatGPT to ask questions about\nyour meeting transcripts in LessMeet.")
            VStack(spacing: 0) {
                benefit("Use your ChatGPT plan", symbol: "text.bubble",
                        detail: "Eligible requests count toward your plan’s usage.")
                Divider().overlay(ChatGPTStyle.separator)
                benefit("Know what you share", symbol: "checkmark.shield",
                        detail: "When you send a question, the full transcript and conversation go to OpenAI. Audio stays local.")
            }
            .padding(.horizontal, 15)
            .background(ChatGPTStyle.inset, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ChatGPTStyle.separator))
            errorMessage
            VStack(spacing: 8) {
                ChatGPTSignInButton { signIn(profileID: nil) }
                caption("Continues securely in your browser")
            }
            if needsSignOutRetry {
                // A reopened sheet must not hide pending cleanup after a failure.
                HStack {
                    Link("Manage usage ↗", destination: usageURL)
                    Spacer()
                    Button("Retry sign-out", action: signOut).foregroundStyle(.red)
                }
                .font(.system(size: 12))
            }
        }
    }

    private var accountBody: some View {
        VStack(spacing: 20) {
            connectionArt
            if signOutNeedsAttention {
                heading("Sign-out needs attention.",
                        detail: "Review the sign-out message below. Retry if cleanup is incomplete.")
            } else if showingAccountSelection || session.activeProfileID == nil {
                heading("Choose your account.", detail: "Select an account, then continue in your browser.")
            } else if session.canUseChatGPTPlan {
                heading("You’re connected.", detail: "Ask questions using your ChatGPT plan.")
            } else {
                heading("One more step to chat.", detail: "This account has not enabled ChatGPT plan usage.")
            }

            if let profile = activeProfile {
                HStack(spacing: 11) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 36)).foregroundStyle(ChatGPTStyle.secondary)
                        .accessibilityHidden(true)
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if session.canUseChatGPTPlan {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(ChatGPTStyle.accent)
                    }
                }
                .padding(13)
                .background(ChatGPTStyle.inset, in: RoundedRectangle(cornerRadius: 10))
            }

            errorMessage
            if signOutNeedsAttention {
                wideButton("Retry sign-out", action: signOut)
            } else if showingAccountSelection || session.activeProfileID == nil {
                Picker("Account", selection: $selectedProfileID) {
                    Text("New account or workspace").tag(String?.none)
                    ForEach(session.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: .infinity)
                // Selection alone never activates an account.
                ChatGPTSignInButton { signIn(profileID: selectedProfileID) }
            } else if session.canUseChatGPTPlan {
                wideButton("Back to chat", primary: true) { dismiss() }
            } else if let activeID = session.activeProfileID {
                wideButton("Enable ChatGPT plan usage") {
                    signIn(profileID: activeID, requestPlanConsent: true)
                }
            }

            HStack(spacing: 8) {
                Button("Switch account") {
                    selectedProfileID = session.activeProfileID
                    showingAccountSelection = true
                }
                .frame(maxWidth: .infinity)
                Button("Add account") {
                    selectedProfileID = nil
                    showingAccountSelection = true
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            HStack {
                Link("Manage usage ↗", destination: usageURL)
                Spacer()
                if !signOutNeedsAttention {
                    Button(needsSignOutRetry ? "Retry sign-out" : "Sign out", action: signOut)
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
            }
            .font(.system(size: 13))
        }
    }

    private var waitingBody: some View {
        VStack(spacing: 20) {
            statusIcon(signingOut ? "person.crop.circle.badge.minus" : "macwindow")
            heading(signingOut ? "Signing out…" : "Continue in your browser.",
                    detail: signingOut ? "Chat access is disabled while sign-out completes." :
                        "Finish the ChatGPT sign-in step there.\nLessMeet will update when you return.")
            if signingOut {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Signing out…").font(.system(size: 12))
                }
            } else {
                VStack(alignment: .leading, spacing: 17) {
                    Label("Browser sign-in started", systemImage: "circle")
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for your authorization").fontWeight(.medium)
                    }
                    .foregroundStyle(ChatGPTStyle.accent)
                    Label("Return to LessMeet", systemImage: "circle")
                }
                .font(.system(size: 12)).foregroundStyle(ChatGPTStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("If the browser does not open, cancel and try again.\nClosing this sheet does not cancel sign-in.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatGPTStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChatGPTStyle.separator))
                wideButton("Cancel sign-in") {
                    beforeAccountChange()
                    session.cancelSignIn()
                }
                caption("No chat request has been sent.")
            }
            errorMessage
        }
    }

    private var welcomeBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusIcon("checkmark")
                heading("You’re using\nyour ChatGPT plan.",
                        detail: "Eligible LessMeet chat requests count toward your ChatGPT plan usage. Review usage and limits in ChatGPT settings.")
                Link("Manage usage ↗", destination: usageURL)
                wideButton("Got it", primary: true) {
                    acknowledgedPlanWelcome = true
                    showingPlanWelcome = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(36).frame(maxWidth: .infinity)
        }
        .frame(width: 490, height: 340)
        .foregroundStyle(ChatGPTStyle.ink).tint(ChatGPTStyle.accent)
        .background(ChatGPTStyle.surface)
    }

    private var connectionArt: some View {
        HStack(spacing: 13) {
            Image(systemName: "waveform")
                .font(.system(size: 29)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(ChatGPTStyle.action, in: RoundedRectangle(cornerRadius: 14))
            Text("···").font(.system(size: 17)).foregroundStyle(ChatGPTStyle.secondary)
            ChatGPTMark(size: 29)
                .frame(width: 52, height: 52)
                .background(ChatGPTStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ChatGPTStyle.separator))
        }
        .padding(.top, 3).accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: 17) {
            Divider().overlay(ChatGPTStyle.separator)
            caption("Recording and local transcription do not require sign-in.\nYour saved chats remain available on this Mac.")
        }
    }

    @ViewBuilder private var errorMessage: some View {
        if let error = session.error {
            // The session provides safe messages, not raw OAuth responses.
            Text(error).font(.system(size: 12)).foregroundStyle(.red)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(ChatGPTStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.3)))
                .accessibilityLabel("Account error: \(error)")
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 13)).foregroundStyle(ChatGPTStyle.secondary)
                .lineSpacing(4)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private func benefit(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(ChatGPTStyle.accent)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(ChatGPTStyle.secondary).lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(ChatGPTStyle.secondary)
            .lineSpacing(3).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 26))
            .foregroundStyle(ChatGPTStyle.accent).frame(width: 58, height: 58)
            .background(ChatGPTStyle.question, in: Circle()).accessibilityHidden(true)
    }

    private func wideButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(primary ? Color.white : ChatGPTStyle.ink)
                .background(primary ? ChatGPTStyle.action : ChatGPTStyle.surface,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChatGPTStyle.separator))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func signIn(profileID: String?, requestPlanConsent: Bool = false) {
        beforeAccountChange()
        Task { await session.signIn(profileID: profileID, requestPlanConsent: requestPlanConsent) }
    }

    private func signOut() {
        beforeAccountChange()
        signingOut = true
        Task {
            await session.signOut()
            signingOut = false
        }
    }
}

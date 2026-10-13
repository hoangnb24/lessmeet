import SwiftUI

@MainActor
struct LocalChatView: View {
    @ObservedObject var model: LocalChatModel
    let recordingID: UUID
    let canUsePlan: Bool
    var openAccount: () -> Void = {}
    var openTranscript: () -> Void = {}
    var isRecording: Bool = false

    @State private var drafts: [UUID: String] = [:]
    @State private var draftRevisions: [UUID: UUID] = [:]
    @State private var editorFocused = false

    private let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private var hasCurrentRecording: Bool { model.recordingID == recordingID }
    private var draft: String { drafts[recordingID] ?? "" }
    private var canSend: Bool {
        canUsePlan && !isRecording && hasCurrentRecording && model.canSend
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            history
            VStack(alignment: .leading, spacing: 9) {
                statusNotice
                HStack {
                    Text(canUsePlan ? "Using ChatGPT plan" : "Saved chats remain local")
                    Link("Manage usage", destination: usageURL)
                    Spacer()
                }
                .font(.caption)
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        ChatTextEditor(text: draftBinding, isFocused: $editorFocused, isEditable: true)
                            .accessibilityLabel("Question about this transcript")
                        if draft.isEmpty {
                            Text("Ask about this transcript…")
                                .foregroundStyle(ChatGPTStyle.secondary)
                                .padding(.top, 3)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 58)
                    modelControls
                }
                .padding(12)
                .background(ChatGPTStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(editorFocused ? ChatGPTStyle.accent : ChatGPTStyle.separator))
                Text("Return for a new line · ⌘Return to send")
                    .font(.caption).foregroundStyle(ChatGPTStyle.secondary)
                Text("When you send, LessMeet sends the full local transcript and this conversation to OpenAI. Audio stays local.")
                    .font(.caption).foregroundStyle(ChatGPTStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(ChatGPTStyle.ink)
        .background(ChatGPTStyle.surface)
        .tint(ChatGPTStyle.accent)
        // The shell owns selection and context cancellation. Tab visibility does neither.
    }

    private var modelControls: some View {
            HStack {
                Picker("Model", selection: $model.selectedModelSlug) {
                    Text("Choose a model").tag(String?.none)
                    ForEach(model.models) { choice in
                        Text(choice.displayName).tag(Optional(choice.slug))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("ChatGPT model")
                .frame(maxWidth: 200)
                .disabled(!canUsePlan || isRecording || !hasCurrentRecording || model.busy || model.models.isEmpty)
                Button(model.models.isEmpty ? "Load models" : "Refresh") {
                    guard canUsePlan, !isRecording, hasCurrentRecording, !model.busy else { return }
                    Task {
                        guard model.recordingID == recordingID else { return }
                        await model.loadModels()
                    }
                }
                .disabled(!canUsePlan || isRecording || !hasCurrentRecording || model.busy)
                Spacer(minLength: 8)
                if model.busy && hasCurrentRecording {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(ChatGPTStyle.action)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
            .controlSize(.small)
    }

    private var statusNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = model.error, hasCurrentRecording {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("ChatGPT error: \(error)")
                // Safe strings do not identify a typed quota or transcript state.
                Link("Manage usage", destination: usageURL)
                    .buttonStyle(.borderedProminent)
                Button("Go to Transcript", action: openTranscript).buttonStyle(.link)
            } else if isRecording {
                Text("Finish recording to send a question.").fontWeight(.semibold)
                Text("Chat is paused while a recording is active. Completed chats remain available.")
            } else if !canUsePlan {
                Text("Chat is currently unavailable.").fontWeight(.semibold)
                Text("Check your ChatGPT account and plan permission. Finish any active account action. You can still read saved chats.")
                Button("Open ChatGPT account", action: openAccount).buttonStyle(.link)
            } else if hasCurrentRecording && model.busy && model.pendingQuestion == nil {
                Text("Loading available models…").fontWeight(.semibold)
                Text("No question has been sent. You can cancel this request.")
            } else if hasCurrentRecording && !model.busy && model.models.isEmpty {
                Text("Choose how ChatGPT answers.").fontWeight(.semibold)
                Text("Load the models available to your account, then select one.")
            } else if hasCurrentRecording && !model.busy && model.selectedModelSlug == nil {
                Text("Select a model to continue.")
                Text("Nothing is selected automatically.")
            }
        }
        .font(.caption)
        .foregroundStyle(ChatGPTStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(hasNotice ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hasNotice ? ChatGPTStyle.inset : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var hasNotice: Bool {
        isRecording || !canUsePlan || (hasCurrentRecording &&
            (model.error != nil || (model.busy && model.pendingQuestion == nil)
             || (!model.busy && (model.models.isEmpty || model.selectedModelSlug == nil))))
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !hasCurrentRecording {
                    Text("Loading local chat…").foregroundStyle(ChatGPTStyle.secondary)
                } else if model.messages.isEmpty && model.pendingQuestion == nil {
                    if model.error == nil {
                        emptyState
                    } else {
                        Text("Chat needs attention. Review the message below before sending.")
                            .foregroundStyle(ChatGPTStyle.secondary)
                    }
                }
                if hasCurrentRecording {
                    ForEach(model.messages) { message in
                        if message.role == .user {
                            questionView(message.text)
                        } else {
                            answerView(message.text, saved: true)
                        }
                    }
                    if let pending = model.pendingQuestion {
                        questionView(pending)
                        answerView(model.partialAnswer, saved: false)
                    }
                }
            }
            .frame(maxWidth: 666, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24)).foregroundStyle(ChatGPTStyle.accent)
                .frame(width: 48, height: 48)
                .background(ChatGPTStyle.inset, in: RoundedRectangle(cornerRadius: 14))
            Text("What would you like to know?").font(.title2.weight(.semibold))
            Text("Turn this transcript into a clear summary, next steps, or answers to your questions.")
                .foregroundStyle(ChatGPTStyle.secondary)
                .frame(maxWidth: 370)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { promptButtons }
                VStack(spacing: 8) { promptButtons }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var promptButtons: some View {
        Group {
            promptButton("Summarize decisions", draft: "Summarize the key decisions.")
            promptButton("Find next steps", draft: "What are the next steps?")
            promptButton("Find open questions", draft: "What questions remain open?")
        }
        .controlSize(.small)
    }

    private func promptButton(_ title: String, draft text: String) -> some View {
        Button(title) {
            draftBinding.wrappedValue = text
            editorFocused = true
        }
        .buttonStyle(.bordered)
    }

    private func questionView(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text).textSelection(.enabled)
                .padding(.horizontal, 17).padding(.vertical, 12)
                .background(ChatGPTStyle.question, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("You: \(text)")
        }
    }

    private func answerView(_ text: String, saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                ChatGPTMark(size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT").font(.caption.weight(.semibold))
                    Text(saved ? "From this recording’s transcript" : "Incomplete answer · not saved")
                        .font(.caption).foregroundStyle(ChatGPTStyle.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !saved && text.isEmpty {
                    Text("Waiting for an answer…").foregroundStyle(ChatGPTStyle.secondary)
                } else {
                    MarkdownView(text: text)
                }
                if saved {
                    Label("Completed chat saved on this Mac", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(ChatGPTStyle.secondary)
                } else if !text.isEmpty {
                    Text("Answering…").font(.caption).foregroundStyle(ChatGPTStyle.secondary)
                }
            }
            .padding(.leading, 29)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var draftBinding: Binding<String> {
        let id = recordingID
        return Binding(get: { drafts[id] ?? "" }, set: { value in
            drafts[id] = value
            draftRevisions[id] = UUID()
        })
    }

    private func send() {
        guard canSend else { return }
        let id = recordingID
        let question = draft
        let revision = draftRevisions[id]
        Task {
            guard model.recordingID == id else { return }
            let completed = await model.send(question)
            guard completed, model.recordingID == id,
                  draftRevisions[id] == revision, drafts[id] == question else { return }
            drafts[id] = ""
            draftRevisions[id] = UUID()
        }
    }
}

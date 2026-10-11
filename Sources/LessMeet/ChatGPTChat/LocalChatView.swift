import SwiftUI

@MainActor
struct LocalChatView: View {
    @ObservedObject var model: LocalChatModel
    let recordingID: UUID
    let canUsePlan: Bool

    @State private var drafts: [UUID: String] = [:]
    @State private var draftRevisions: [UUID: UUID] = [:]
    @State private var editorFocused = false

    private let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private var hasCurrentRecording: Bool { model.recordingID == recordingID }
    private var draft: String { drafts[recordingID] ?? "" }
    private var canSend: Bool {
        canUsePlan && hasCurrentRecording && model.canSend
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            history
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                modelControls

                if let error = model.error, hasCurrentRecording {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityLabel("ChatGPT error: \(error)")
                        // The controller exposes safe text, not a typed quota state.
                        // Keep usage recovery primary for all request errors.
                        Link("Manage usage", destination: usageURL)
                            .buttonStyle(.borderedProminent)
                    }
                }

                Text("When you send, LessMeet sends the full local transcript and this conversation to OpenAI. Audio stays local.")
                    .font(.caption).foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask about this transcript…")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    ChatTextEditor(text: draftBinding, isFocused: $editorFocused, isEditable: true)
                }
                .padding(10)
                .frame(height: 88)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                HStack {
                    Text("Return for a new line · ⌘Return to send")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.busy && hasCurrentRecording {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancel() }
                    }
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                }
            }
            .padding(14)
        }
        // The shell owns selection and context cancellation. Tab visibility does neither.
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if canUsePlan {
                    Text("Using ChatGPT plan").font(.caption)
                } else {
                    Text("Chat is unavailable. Enable your ChatGPT plan in Account and finish any active recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("Manage usage", destination: usageURL).font(.caption)
            }
            HStack {
                Picker("Model", selection: $model.selectedModelSlug) {
                    Text("Choose a model").tag(String?.none)
                    ForEach(model.models) { choice in
                        Text(choice.displayName).tag(Optional(choice.slug))
                    }
                }
                .disabled(!canUsePlan || !hasCurrentRecording || model.busy || model.models.isEmpty)
                Button(model.models.isEmpty ? "Load models" : "Refresh models") {
                    guard canUsePlan, hasCurrentRecording, !model.busy else { return }
                    Task {
                        guard model.recordingID == recordingID else { return }
                        await model.loadModels()
                    }
                }
                .disabled(!canUsePlan || !hasCurrentRecording || model.busy)
            }
        }
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !hasCurrentRecording {
                    Text("Loading local chat…").foregroundStyle(.secondary)
                } else if model.messages.isEmpty && model.pendingQuestion == nil {
                    Text("Ask a question about this recording’s local transcript. Completed chats are saved on this Mac.")
                        .foregroundStyle(.secondary)
                }
                if hasCurrentRecording {
                    ForEach(model.messages) { message in
                        messageView(title: message.role == .user ? "You" : "ChatGPT", text: message.text)
                    }
                    if let pending = model.pendingQuestion {
                        messageView(title: "You · sending", text: pending)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("ChatGPT · incomplete answer · not saved", systemImage: "clock")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            if model.partialAnswer.isEmpty {
                                Text("Waiting for an answer…").foregroundStyle(.secondary)
                            } else {
                                MarkdownView(text: model.partialAnswer)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func messageView(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            MarkdownView(text: text)
        }
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

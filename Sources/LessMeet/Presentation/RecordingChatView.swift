import SwiftUI

/// Chat is a stable workspace; the transcript is an optional reference pane.
struct RecordingChatView: View {
    let recording: Recording
    let remote: CloudRecording?
    @ObservedObject var cloud: RecordingCloudModel
    @Binding var draft: String
    let pendingQuestion: String?
    let canUseCloud: Bool
    let canSend: Bool
    let send: () -> Void
    @State private var showingSource = false
    @State private var composerFocused = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat").font(.system(size: 16, weight: .semibold))
                    Text(recording.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { showingSource.toggle() } label: {
                    Label(showingSource ? "Hide transcript" : "Show transcript", systemImage: "sidebar.right")
                }.buttonStyle(.bordered).help("Read the source alongside this conversation")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            HSplitView {
                conversation.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                if showingSource {
                    source.frame(minWidth: 280, idealWidth: 340, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if remote?.messages.isEmpty != false && pendingQuestion == nil {
                            starters.padding(.top, 36)
                        }
                        ForEach(Array((remote?.messages ?? []).enumerated()), id: \.offset) { _, message in
                            messageView(message)
                        }
                        if let pendingQuestion {
                            messageView(CloudMessage(role: "user", text: pendingQuestion))
                        }
                        if cloud.busy {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(cloud.activity == "Replying…" ? "Reading the transcript…" : (cloud.activity ?? "Working…"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let error = cloud.error {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("The response wasn’t completed", systemImage: "exclamationmark.circle")
                                    .font(.callout.weight(.medium))
                                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("Refresh the conversation before sending another question; the submitted request may still finish.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Refresh conversation", systemImage: "arrow.clockwise") { cloud.refresh() }
                                    .disabled(!canUseCloud)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("chatEnd")
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
                .onAppear { proxy.scrollTo("chatEnd", anchor: .bottom) }
                .onChange(of: pendingQuestion) { _, value in
                    if value != nil { proxy.scrollTo("chatEnd", anchor: .bottom) }
                }
                .onChange(of: remote?.messages.count) { _, _ in proxy.scrollTo("chatEnd", anchor: .bottom) }
            }
            composer.frame(maxWidth: 700).padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What would you like to know?").font(.system(size: 24, weight: .semibold))
            Text("Find a decision, catch up on the conversation, or turn it into next steps.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            ForEach(["Summarize this conversation", "What decisions were made?", "List the action items"], id: \.self) { suggestion in
                Button {
                    draft = suggestion
                    composerFocused = true
                } label: {
                    HStack {
                        Text(suggestion).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!canUseCloud)
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: CloudMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 32)
                Text(message.text).font(.system(size: 14)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("You: \(message.text)")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("LessMeet").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                MarkdownView(text: message.text)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatTextEditor(text: $draft, isFocused: $composerFocused, isEditable: canUseCloud)
                .frame(height: 64)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask about this recording…").font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Question about this recording")
            HStack(spacing: 10) {
                Label("Transcript attached", systemImage: "doc.text")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if cloud.busy {
                    Button { cloud.cancel() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            .frame(width: 32, height: 32)
                            .background(.primary, in: Circle())
                            .contentShape(Circle())
                    }
                        .buttonStyle(.plain).help("Stop waiting; the submitted request may still finish")
                        .accessibilityLabel("Stop waiting for answer")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : .secondary)
                            .frame(width: 32, height: 32)
                            .background(canSend ? Color.primary : Color.primary.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                        .buttonStyle(.plain).disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("Send question").help("Send question (⌘Return)")
                }
            }
            if draft.utf8.count > 8 * 1024 {
                Text("This question is too long. Shorten it before sending.").font(.caption).foregroundStyle(.orange)
            } else if !cloud.busy {
                Text("⌘Return to send · Return for a new line").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(composerFocused ? 0.3 : 0.14), lineWidth: 1))
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Transcript", systemImage: "doc.text").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { showingSource = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close transcript pane")
            }.padding(20)
            Divider().opacity(0.5)
            ScrollView {
                MarkdownView(text: remote?.transcript ?? "")
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(.primary.opacity(0.018))
    }
}

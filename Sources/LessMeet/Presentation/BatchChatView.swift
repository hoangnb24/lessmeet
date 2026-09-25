import SwiftUI

struct BatchChatView: View {
    let batch: LocalBatch
    @ObservedObject var cloud: RecordingCloudModel
    let enabled: Bool
    @State private var draft = ""
    @State private var focused = false
    @State private var confirmResend = false

    private var chat: LocalBatchChat? { batch.chat }
    private var canSend: Bool { enabled && chat?.status?.availability == "ready" && chat?.status?.pending == nil && chat?.request == nil && BatchChatValidation.message(draft) }
    static func availabilityText(_ state: String?) -> String {
        switch state {
        case "ready": return "Ready — questions use all selected original chunk results."
        case "disabled": return "Batch chat is disabled. Saved messages and recovery remain available."
        case "incomplete": return "Chat needs a complete batch and all original results. Your partial transcript remains readable."
        case "context_too_large": return "The full transcript context exceeds the chat limit. Nothing was truncated; chat is unavailable."
        case "history_full": return "This conversation is full. Saved history is retained; no messages were dropped."
        case "busy": return "A question is queued or running. Refresh to check it; do not submit a replacement."
        case "attention": return "A question needs attention. Unknown execution blocks new questions; stopping a wait does not stop generation."
        default: return "Refresh batch chat to check availability and recover saved questions."
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Batch chat").font(.title2.weight(.semibold))
                Text(Self.availabilityText(chat?.status?.availability)).foregroundStyle(.secondary)
                Text("Overlap may repeat speech. Speaker labels are chunk-local; model references are not verified citations.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh batch chat") { cloud.refreshBatchChat() }.disabled(!enabled)
                    if cloud.busy { Button("Stop waiting") { cloud.cancel() } }
                }
                ForEach(chat?.status?.exchanges ?? [], id: \.clientMessageId) { exchange in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("You").font(.caption.weight(.semibold))
                        Text(exchange.message).textSelection(.enabled)
                        Text("LessMeet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        MarkdownView(text: exchange.reply)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                if let request = chat?.request {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved question — \(chat?.operation?.state ?? (chat?.confirmedAbsent == true ? "confirmed absent" : "unresolved"))").font(.callout.weight(.medium))
                        Text(request.message).textSelection(.enabled)
                        Text("This exact question and its identity are saved. Refresh after a lost response or relaunch; no automatic resend occurs.").font(.caption)
                        if chat?.confirmedAbsent == true {
                            Button("Resend this saved question…") { confirmResend = true }.disabled(!enabled)
                        }
                    }.padding(16).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                if let operation = chat?.operation, operation.state == "failed" {
                    if let question = chat?.lastRequest?.message { Text(question).textSelection(.enabled) }
                    Text("The saved question failed (\(operation.error?.code ?? "failed")). Refresh availability before sending a new question.").foregroundStyle(.orange)
                }
                if let pending = chat?.status?.pending, chat?.request == nil {
                    Text("Saved remote question: \(pending.state). Refresh to reconcile. A replacement question is blocked.").foregroundStyle(.orange)
                }
                if let error = cloud.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if cloud.busy { ProgressView(cloud.activity ?? "Checking batch chat…") }
                VStack(alignment: .leading, spacing: 10) {
                    ChatTextEditor(text: $draft, isFocused: $focused, isEditable: enabled && chat?.request == nil)
                        .frame(height: 80).accessibilityLabel("Question about this batch transcript")
                    HStack {
                        Text("8 KiB maximum · one AI question when quotas are enabled").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Send question") { cloud.sendBatchQuestion(draft) }.disabled(!canSend)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: chat?.request?.clientMessageId) { _, value in if value != nil { draft = "" } }
        .confirmationDialog("Resend the exact saved question?", isPresented: $confirmResend, titleVisibility: .visible) {
            Button("Confirm same-question resend") { cloud.resendAbsentBatchQuestion() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The app will check absence again, then send only this saved UUID and payload. It will not replace unknown or completed work.") }
    }
}

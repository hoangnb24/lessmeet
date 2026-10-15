import SwiftUI

struct ChatGPTAccountSheet: View {
    @ObservedObject var session: ChatGPTSession
    var beforeAccountChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ChatGPT account").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            Divider()
            ChatGPTAccountView(session: session, beforeAccountChange: beforeAccountChange)
        }
        .frame(width: 490, height: 608)
        .foregroundStyle(ChatGPTStyle.ink)
        .background(ChatGPTStyle.surface)
        .tint(ChatGPTStyle.accent)
    }
}

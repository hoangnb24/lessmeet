import SwiftUI

/// Uses the original bundled ChatGPT logo through the shared presentation mark.
struct ChatGPTSignInButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ChatGPTMark(size: 21)
                Text("Continue with ChatGPT").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(ChatGPTStyle.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(ChatGPTStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ChatGPTStyle.separator))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue with ChatGPT")
    }
}

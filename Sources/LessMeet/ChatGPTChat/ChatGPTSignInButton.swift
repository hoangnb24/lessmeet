import AppKit
import SwiftUI

/// Uses the original asset from developers.openai.com/assets/siwc/sign-in-buttons/.
struct ChatGPTSignInButton: View {
    let action: () -> Void

    private static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "ChatGPTLogo", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let logo = Self.logo {
                    Image(nsImage: logo).resizable().frame(width: 21, height: 21)
                        .accessibilityHidden(true)
                }
                Text("Continue with ChatGPT").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.4)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue with ChatGPT")
    }
}

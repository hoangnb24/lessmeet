import AppKit
import SwiftUI

/// Presentation tokens for the approved LM-SC-01 account and chat surfaces.
enum ChatGPTStyle {
    static let surface = adaptive(0xFCFCF9, 0x222832)
    static let inset = adaptive(0xF5F7EF, 0x2A3341)
    static let question = adaptive(0xEDF0E5, 0x313D50)
    static let ink = adaptive(0x28362A, 0xE8EBF1)
    static let secondary = adaptive(0x626A5D, 0xB4BFD0)
    static let separator = adaptive(0xDFE3D8, 0x414B5A)
    static let accent = adaptive(0x354B33, 0x9EBEFF)
    static let action = adaptive(0x354B33, 0x245CC7)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct ChatGPTMark: View {
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme
    private static let logo: NSImage? = Bundle.module.url(forResource: "ChatGPTLogo", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.logo {
                if colorScheme == .dark {
                    Image(nsImage: image).resizable().colorInvert()
                } else {
                    Image(nsImage: image).resizable()
                }
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

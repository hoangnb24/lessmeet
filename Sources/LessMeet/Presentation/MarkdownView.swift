import SwiftUI

/// Small native renderer for the headings, paragraphs, lists and code used by transcripts.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    Text(block.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    let content = heading > 0 ? String(block.dropFirst(heading)).trimmingCharacters(in: .whitespaces) : block
                    Text(inline(content))
                        .font(heading == 1 ? .title2.bold() : heading > 1 ? .headline : .body)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, heading > 0 ? 10 : 0)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
    }

    private var blocks: [String] {
        var result: [String] = []
        var code: [String]? = nil
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if var existing = code {
                    existing.append(line)
                    result.append(existing.joined(separator: "\n"))
                    code = nil
                } else { code = [line] }
            } else if code != nil { code?.append(line) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { result.append(line) }
        }
        if let code { result.append((code + ["```"]).joined(separator: "\n")) }
        return result
    }
}

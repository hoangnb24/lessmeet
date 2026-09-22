import AppKit
import SwiftUI
import XCTest
@testable import LessMeet

final class ChatTextEditorTests: XCTestCase {
    @MainActor
    func testEditorHasNoScrollbarGutterAndPreservesMultilineTyping() throws {
        _ = NSApplication.shared
        var draft = ""
        let host = NSHostingView(rootView: ChatTextEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(false), isEditable: true))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(findScrollView(host))
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(editor.textContainer?.widthTracksTextView == true)
        XCTAssertTrue(editor.isEditable)
        editor.insertText("First line", replacementRange: NSRange(location: 0, length: 0))
        editor.insertNewline(nil)
        editor.insertText("Second line", replacementRange: editor.selectedRange())
        XCTAssertEqual(draft, "First line\nSecond line")
    }

    @MainActor
    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView($0) }.first
    }
}

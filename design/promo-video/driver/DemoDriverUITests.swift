import AppKit
import XCTest

// Drives the offline Library fixture through real controls for the promo
// recording. Logs each action (wall clock, kind, window-relative point, label)
// so the composer can draw the cursor and place sound effects.
@MainActor
final class DemoDriverUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: URL!
    private var origin = CGPoint.zero

    func testExplore() throws { try run(explore: true) }
    func testRecordDemo() throws { try run(explore: false) }

    private func run(explore: Bool) throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        let appPath = try XCTUnwrap(env["DEMO_APP_PATH"])
        dir = URL(fileURLWithPath: try XCTUnwrap(env["DEMO_DIR"]), isDirectory: true)
        app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        app.launchEnvironment["LESSMEET_DEMO_CAPTURE_DIR"] = dir.path
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        pause(2.0)
        origin = window.frame.origin
        mark("start", nil, "")
        if explore {
            dump("library")
            app.terminate()
            return
        }
        pause(1.6)
        // 1. Record
        click(app.buttons["New recording"].firstMatch, "New recording")
        pause(4.5)
        dump("recording")
        click(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Stop'")).firstMatch, "Stop")
        pause(2.2)
        dump("stopped")
        // 2. Transcript of an earlier meeting
        click(app.buttons["Product weekly"].firstMatch, "Product weekly")
        pause(2.5)
        dump("transcript")
        let transcript = app.scrollViews.allElementsBoundByIndex.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let transcript {
            mark("scroll", center(transcript), "transcript")
            for _ in 0..<6 { transcript.scroll(byDeltaX: 0, deltaY: -40); pause(0.12) }
        }
        pause(1.8)
        // 3. Ask about it
        click(tab("Chat"), "Chat")
        pause(1.5)
        dump("chat")
        let load = window.buttons["Load models"].firstMatch
        if load.exists { click(load, "Load models"); pause(1.0) }
        dump("models")
        let picker = window.popUpButtons.firstMatch
        if picker.waitForExistence(timeout: 3), picker.isEnabled {
            click(picker, "Model")
            pause(0.7)
            let item = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Synthetic'")).firstMatch
            if item.waitForExistence(timeout: 3) { click(item, "Synthetic Chat Model") } else { dump("menu") }
            pause(0.8)
        }
        let editor = window.textViews.firstMatch
        click(editor, "Editor")
        pause(0.4)
        let question = "What did we decide, and what happens next?"
        mark("typing-start", center(editor), question)
        for character in question {
            editor.typeText(String(character))
            mark("key", nil, String(character))
        }
        mark("typing-end", nil, "")
        pause(0.6)
        let send = window.buttons["Send"].firstMatch
        if send.exists && send.isEnabled { click(send, "Send") } else { editor.typeKey(.return, modifierFlags: .command); mark("send-key", nil, "") }
        pause(9.0)
        dump("answer")
        mark("end", nil, "")
        pause(1.0)
        app.terminate()
    }

    private func tab(_ label: String) -> XCUIElement {
        let radio = app.windows.firstMatch.radioButtons[label]
        return radio.exists ? radio : app.windows.firstMatch.buttons[label]
    }

    private func center(_ element: XCUIElement) -> CGPoint {
        CGPoint(x: element.frame.midX - origin.x, y: element.frame.midY - origin.y)
    }

    private func click(_ element: XCUIElement, _ label: String) {
        guard element.waitForExistence(timeout: 5) else { XCTFail("Missing \(label)"); return }
        mark("move", center(element), label)
        pause(0.55)
        mark("click", center(element), label)
        element.click()
    }

    private func mark(_ kind: String, _ point: CGPoint?, _ label: String) {
        let p = point ?? CGPoint(x: -1, y: -1)
        // The runner cannot write outside its container; run.sh extracts these lines.
        print(String(format: "DEMOEVT\t%.6f\t%@\t%.1f\t%.1f\t%@", Date().timeIntervalSince1970, kind, p.x, p.y,
                     label.replacingOccurrences(of: "\t", with: " ")))
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func dump(_ name: String) {
        print("DEMOAX-BEGIN \(name)\n\(app.windows.firstMatch.debugDescription)\nDEMOAX-END")
    }
}

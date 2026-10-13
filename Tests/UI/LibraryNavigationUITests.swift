import AppKit
import CryptoKit
import XCTest

@MainActor
final class LibraryNavigationUITests: XCTestCase {
    private let fixtureID = "com.lessmeet.app.library-ui-check"
    private let longTitle = "Synthetic planning — long transcript"
    private let shortTitle = "Synthetic planning — short transcript"
    private var app: XCUIApplication!
    private var ownedProcess: NSRunningApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(env["LIBRARY_UI_APP_PATH"], "Use scripts/test-library-ui.sh with an explicit bundle path")
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(url.path, path, "Require a canonical absolute bundle path")
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, fixtureID)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LessMeetPackagingMode") as? String, "library-ui-check")
        for key in ["ClerkPublishableKey", "ConvexSiteURL", "CFBundleURLTypes"] {
            XCTAssertNil(bundle.object(forInfoDictionaryKey: key), "Unexpected service configuration: \(key)")
        }
        let binary = try XCTUnwrap(bundle.executableURL)
        let hash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, env["LIBRARY_UI_EXECUTABLE_SHA256"], "Bundle changed after validation")
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).isEmpty,
                      "Another driver owns a fixture process; refusing to launch")
        app = XCUIApplication(url: url)
        XCTAssertEqual(app.state, .notRunning, "Refusing an existing fixture")
        app.launch()
        let processes = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID)
        let process = try XCTUnwrap(processes.first)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(process.bundleURL?.resolvingSymlinksInPath().path, path)
        ownedProcess = process
        attach("Launch identity", "path=\(path)\nsha256=\(hash)\npid=\(process.processIdentifier)\nstart=\(String(describing: process.launchDate))")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(libraryHeading.waitForExistence(timeout: 15))
        capture("Initial Library")
        assertShell()
    }

    override func tearDownWithError() throws {
        guard let process = ownedProcess else { return }
        capture("Final state")
        // Do not terminate a replacement process or an app owned by another run.
        if !process.isTerminated,
           let current = NSRunningApplication(processIdentifier: process.processIdentifier),
           current.launchDate == process.launchDate, current.bundleURL == process.bundleURL {
            current.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Owned fixture did not exit; inspect retained identity")
        }
        ownedProcess = nil
    }

    func testLongMeetingNavigation() throws {
        try exercise(first: longTitle, recent: shortTitle)
    }

    func testShortMeetingNavigation() throws {
        try exercise(first: shortTitle, recent: longTitle)
    }

    private func exercise(first: String, recent: String) throws {
        // The row has a status label; the Recent button has only the title.
        let row = app.windows.firstMatch.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", first, "Saved locally")).firstMatch
        click(row, "Open Library row: \(first)")
        assertShell()
        try assertTabs()
        assertTranscript(first)
        click(try tab("Chat"), "Open Chat")
        assertShell()
        try assertTabs()
        let editor = app.windows.firstMatch.textViews.firstMatch
        assertVisible(editor, "Chat draft editor")
        editor.click()
        editor.typeText("Synthetic draft retained across tabs.")
        expectValue(editor, "Synthetic draft retained across tabs.")
        click(try tab("Transcript"), "Return to Transcript")
        assertShell()
        try assertTabs()
        assertTranscript(first)
        click(try tab("Chat"), "Return to Chat")
        assertVisible(editor, "Chat draft editor after roundtrip")
        expectValue(editor, "Synthetic draft retained across tabs.")
        capture("Draft retained")

        click(app.windows.firstMatch.buttons[recent], "Switch through Recent: \(recent)")
        assertShell()
        try assertTabs()
        click(try tab("Transcript"), "Show switched transcript")
        assertTranscript(recent)
        click(try sidebarLibrary(), "Return through sidebar Library")
        XCTAssertTrue(libraryHeading.waitForExistence(timeout: 5))
        assertShell()
        let search = app.textFields["Search recordings"]
        click(search, "Search synthetic short meeting")
        search.typeText("short transcript")
        expectValue(search, "short transcript")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Search results")).firstMatch.waitForExistence(timeout: 5))
        let shortRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", shortTitle, "Saved locally")).firstMatch
        assertVisible(shortRow, "Filtered short row")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", longTitle, "Saved locally")).firstMatch.exists)
        click(try sidebarLibrary(), "Clear search through Library")
        expectValue(search, "")
        XCTAssertTrue(libraryHeading.waitForExistence(timeout: 5))
        capture("Library restored")
    }

    private var libraryHeading: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your conversations, all in one place.")).firstMatch
    }

    private func assertTranscript(_ title: String) {
        let titleField = app.textFields["Recording title"]
        assertVisible(titleField, "Recording title")
        expectValue(titleField, title)
        let expected = title == longTitle ? "Planning item 1." : "Maya: The synthetic planning check is complete."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected)).firstMatch.waitForExistence(timeout: 5))
        capture("Transcript: \(title)")
    }

    private func assertShell() {
        assertVisible(app.textFields["Search recordings"], "Sidebar search")
        assertVisible(app.buttons["Library, 2"], "Sidebar Library")
        assertVisible(app.buttons[longTitle], "Recent long meeting")
        assertVisible(app.buttons[shortTitle], "Recent short meeting")
    }

    private func sidebarLibrary() throws -> XCUIElement {
        let search = app.textFields["Search recordings"]
        return try XCTUnwrap(app.windows.firstMatch.buttons.allElementsBoundByIndex.first {
            $0.label.hasPrefix("Library") && $0.frame.minX < search.frame.maxX
        }, "Sidebar Library button must remain present")
    }

    private func tab(_ label: String) throws -> XCUIElement {
        let radios = app.windows.firstMatch.radioButtons[label]
        if radios.exists { return radios }
        let button = app.windows.firstMatch.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing tab: \(label)")
        return button
    }

    private func assertTabs() throws {
        assertVisible(try tab("Transcript"), "Transcript tab")
        assertVisible(try tab("Chat"), "Chat tab")
    }

    private func assertVisible(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), name, file: file, line: line)
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        attach("Geometry: \(name)", "control=\(frame)\nwindow=\(window)\nhittable=\(element.isHittable)")
        XCTAssertFalse(frame.isEmpty, name, file: file, line: line)
        XCTAssertTrue(window.contains(frame), "\(name) lies outside visible window: \(frame), window: \(window)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(name) is not usable", file: file, line: line)
        XCTAssertTrue(element.isEnabled, "\(name) is disabled", file: file, line: line)
    }

    private func click(_ element: XCUIElement, _ name: String) {
        XCTContext.runActivity(named: name) { _ in
            assertVisible(element, name)
            element.click()
            capture(name)
        }
    }

    private func expectValue(_ element: XCUIElement, _ value: String) {
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed, "Expected value: \(value)")
    }

    private func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String) {
        guard let app, app.windows.firstMatch.exists else { return }
        let window = app.windows.firstMatch
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        attach("\(name) accessibility", window.debugDescription)
    }
}

import XCTest

/// Exercises the shared account view through the isolated app's public controls.
@MainActor
final class OfflineAccountUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ownsApp = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundleURL = root.appendingPathComponent("dist/offline-check/LessMeet.app")
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(bundle.bundleIdentifier, "com.lessmeet.app.offline-check")
        for key in ["ClerkPublishableKey", "ConvexSiteURL", "CFBundleURLTypes"] {
            XCTAssertNil(bundle.object(forInfoDictionaryKey: key), "Unexpected service configuration: \(key)")
        }
        app = XCUIApplication(url: bundleURL)
        XCTAssertEqual(app.state, .notRunning, "Another driver owns the offline app. Stop before testing.")
        ownsApp = true
        app.launch()
        XCTAssertTrue(app.popUpButtons["offline-response"].waitForExistence(timeout: 10))
        expectResult("Applied response: requested=false")
        capture("Baseline")
    }

    override func tearDownWithError() throws {
        guard ownsApp, let app else { return }
        defer {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Owned fixture did not exit")
            ownsApp = false
        }
        capture("Final state")
    }

    func testReadyAndPendingRefresh() {
        click("Refresh deletion status")
        expectResult("Applied response: requested=false")
        selectResponse("Deletion pending")
        expectResult("Applied response: requested=false")
        click("Refresh deletion status")
        expectResult("Applied response: requested=true")
        XCTAssertTrue(text(containing: "Cloud cleanup is pending").exists)
        XCTAssertTrue(text(containing: "Provider handling is pending").exists)
        capture("Pending response applied")
    }

    func testFailurePreservesLastAppliedStatus() {
        selectResponse("Deletion pending")
        click("Refresh deletion status")
        expectResult("Applied response: requested=true")
        selectResponse("Request fails")
        click("Refresh deletion status")
        XCTAssertTrue(text(containing: "Synthetic connection failure. No request was sent.")
            .waitForExistence(timeout: 5))
        expectResult("Applied response: requested=true")
        XCTAssertTrue(app.windows.firstMatch.buttons["Refresh deletion status"].isEnabled)
        capture("Failure with previous status retained")
    }

    func testGoogleStatesStaySeparateFromProviderCompletion() {
        for (response, message) in [
            ("Google revocation pending", "Google permission revocation is pending"),
            ("Google revocation exception", "Google permission revocation needs operator handling"),
            ("Google revocation acknowledged", "Google accepted permission revocation")
        ] {
            selectResponse(response)
            click("Refresh deletion status")
            expectResult("Applied response: requested=true")
            XCTAssertTrue(text(containing: message).waitForExistence(timeout: 5))
            XCTAssertTrue(text(containing: "Provider handling is pending").exists)
            XCTAssertFalse(text(containing: "Provider handling verified").exists)
            capture(response)
        }
        selectResponse("Request fails")
        click("Refresh deletion status")
        XCTAssertTrue(text(containing: "Synthetic connection failure").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Google accepted permission revocation").exists)
        XCTAssertTrue(text(containing: "Provider handling is pending").exists)
    }

    func testDelayedResponseCompletes() {
        selectResponse("Wait for response")
        click("Refresh deletion status")
        expectResult("Refresh is waiting")
        XCTAssertFalse(app.windows.firstMatch.buttons["Refresh deletion status"].isEnabled)
        XCTAssertFalse(app.popUpButtons["offline-response"].isEnabled)
        XCTAssertTrue(app.windows.firstMatch.buttons["Complete pending response"].isEnabled)
        capture("Waiting controls")
        click("Complete pending response")
        expectResult("Applied response: requested=false")
        XCTAssertTrue(app.windows.firstMatch.buttons["Refresh deletion status"].isEnabled)
    }

    func testSwitchAccountDiscardsDelayedResponse() {
        selectResponse("Wait for response")
        click("Refresh deletion status")
        expectResult("Refresh is waiting")
        click("Switch synthetic account")
        XCTAssertTrue(text(containing: "Account: offline-bob").waitForExistence(timeout: 5))
        expectResult("No response applied")
        XCTAssertFalse(app.windows.firstMatch.buttons["Complete pending response"].isEnabled)
        XCTAssertTrue(app.windows.firstMatch.buttons["Refresh deletion status"].isEnabled)
        capture("Old account response discarded")
    }

    func testConfirmationCanBeCancelledAndCannotDelete() {
        click("Preview deletion confirmation (no deletion)")
        let delete = app.windows.firstMatch.buttons["Delete Account and Cloud Data"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(text(containing: "7 calendar days").exists)
        XCTAssertTrue(text(containing: "LessMeet Google project").exists)
        capture("Disabled deletion confirmation")
        click("Cancel")
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5))
        expectResult("Applied response: requested=false")
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    private func expectResult(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = app.staticTexts["offline-refresh-result"]
        let matches = NSPredicate(format: "label == %@ OR value == %@", expected, expected)
        let wait = XCTNSPredicateExpectation(predicate: matches, object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed, expected, file: file, line: line)
    }

    private func click(_ label: String) {
        XCTContext.runActivity(named: "Click \(label)") { _ in
            let button = app.windows.firstMatch.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isEnabled)
            button.click()
            capture("After \(label)")
        }
    }

    private func selectResponse(_ value: String) {
        XCTContext.runActivity(named: "Select response: \(value)") { _ in
            app.popUpButtons["offline-response"].click()
            let item = app.menuItems[value]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            capture("Selected \(value)")
        }
    }

    private func capture(_ name: String) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: window.debugDescription)
        tree.name = "\(name) accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

import XCTest

/// Shared helpers for all ZiroEdge UI tests.
/// Subclass this instead of XCTestCase for UI tests.
class UITestBase: XCTestCase {

    var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    // MARK: - Screenshot Capture

    private static var stepCounters: [String: Int] = [:]

    /// Capture a screenshot with auto-numbered filename.
    /// Output: test-output/screenshots/{ClassName}_{NN}_{name}.png
    func capture(_ name: String) {
        let className = String(describing: type(of: self))
        let step = (UITestBase.stepCounters[className] ?? 0) + 1
        UITestBase.stepCounters[className] = step

        let padded = String(format: "%02d", step)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(className)_\(padded)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Navigation

    /// Tap a tab bar item by label. Returns true if found and tapped.
    @discardableResult
    func navigateTo(tab label: String) -> Bool {
        let tab = app.tabBars.buttons[label]
        guard tab.waitForExistence(timeout: 3) else { return false }
        tab.tap()
        return true
    }

    /// Tap the first match for a button/accessibility label. Returns true if tapped.
    @discardableResult
    func tapButton(_ label: String, timeout: TimeInterval = 3) -> Bool {
        let btn = app.buttons[label]
        guard btn.waitForExistence(timeout: timeout) else { return false }
        btn.tap()
        return true
    }

    /// Wait for an element to appear. Returns true if it did.
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - Chat Helpers

    /// Type and send a message in the chat input field.
    func sendChatMessage(_ text: String) {
        let field = app.textViews.firstMatch
        guard field.waitForExistence(timeout: 5) else { return }
        field.tap()
        field.typeText(text)
        tapButton("Send")
    }

    /// Wait for a response to appear (message count increases).
    func waitForResponse(timeout: TimeInterval = 30) -> Bool {
        // The app renders messages in scrollable content.
        // A response means more cells/views than just our sent message.
        // Poll for new content.
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let cells = app.scrollViews.otherElements.staticTexts
            if cells.count > 1 { return true }
            sleep(2)
        }
        return false
    }

    // MARK: - Model Helpers

    /// Returns true if at least one model appears installed in the models list.
    func hasInstalledModel() -> Bool {
        // Navigate to models tab and check for any model row
        navigateTo(tab: "Models")
        // Look for any cell/row that isn't a download button
        let cells = app.tables.cells.count + app.collectionViews.cells.count
        // Fallback: check for common model file indicators
        let detailButton = app.buttons["chevron"].firstMatch
        if detailButton.waitForExistence(timeout: 3) { return true }
        return cells > 0
    }

    // MARK: - Assertions

    /// Assert a screen is visible by checking for a key element.
    func assertScreenVisible(_ element: XCUIElement, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Expected screen element not found", file: file, line: line)
    }
}

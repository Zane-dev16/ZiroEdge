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

    // MARK: - Sidebar / NavigationSplitView helpers

    /// Tap a tab bar item by label (legacy). Returns true if found and tapped.
    @discardableResult
    func navigateTo(tab label: String) -> Bool {
        let tab = app.tabBars.buttons[label]
        guard tab.waitForExistence(timeout: 3) else { return false }
        tab.tap()
        return true
    }

    /// Open the Settings sheet via the gear toolbar button. Returns true only
    /// after the Settings navigation title and a screen-specific row appear.
    @discardableResult
    func openSettings(timeout: TimeInterval = 5) -> Bool {
        let settingsButtons = app.buttons.matching(identifier: "Settings")
        guard settingsButtons.firstMatch.waitForExistence(timeout: timeout),
              let settingsButton = settingsButtons.allElementsBoundByIndex
                .filter(\.isHittable)
                .max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return false
        }
        settingsButton.tap()

        let manageModelsButton = app.buttons["Manage Models"].firstMatch
        let manageModelsText = app.staticTexts["Manage Models"].firstMatch
        let activeModelSection = app.staticTexts["Active Model"].firstMatch
        let manageModelsVisible = manageModelsButton.waitForExistence(timeout: 2)
            || manageModelsText.waitForExistence(timeout: timeout)
        return manageModelsVisible
            && activeModelSection.waitForExistence(timeout: timeout)
    }

    /// Open the Models screen: Settings sheet -> "Manage Models" NavigationLink.
    /// Returns true only after the Models navigation title and model list appear.
    @discardableResult
    func openModels(timeout: TimeInterval = 10) -> Bool {
        guard openSettings(timeout: timeout) else { return false }

        let manageModels = app.buttons["Manage Models"].firstMatch
        let manageModelsText = app.staticTexts["Manage Models"].firstMatch
        let manageModelsCell = app.cells["Manage Models"].firstMatch
        if manageModels.waitForExistence(timeout: timeout) {
            manageModels.tap()
        } else if manageModelsCell.waitForExistence(timeout: 2) {
            manageModelsCell.tap()
        } else if manageModelsText.waitForExistence(timeout: 2) {
            manageModelsText.tap()
        } else {
            return false
        }

        let modelsTitle = app.staticTexts["Models"].firstMatch
        let modelCatalogContent = app.staticTexts["Llama 3.2 3B"].firstMatch
        return modelsTitle.waitForExistence(timeout: timeout)
            && modelCatalogContent.waitForExistence(timeout: timeout)
    }

    /// Select an existing conversation or create a new one. Returns true only
    /// when ChatView's input exists; tapping a control alone is not navigation
    /// evidence (for example, a model redirect may appear instead).
    @discardableResult
    func selectOrCreateConversation(timeout: TimeInterval = 8) -> Bool {
        let chatInput = app.textFields["chatInput"].firstMatch
        if chatInput.waitForExistence(timeout: 2) { return true }

        let newConversation = app.buttons["New Conversation"].firstMatch
        if newConversation.waitForExistence(timeout: timeout) {
            newConversation.tap()
            if chatInput.waitForExistence(timeout: timeout) { return true }
        }

        for label in ["new-conversation", "plus"] {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 2) {
                button.tap()
                if chatInput.waitForExistence(timeout: timeout) { return true }
            }
        }

        if let cell = firstCellInSidebar(app: app, timeout: timeout),
           cell.waitForExistence(timeout: timeout) {
            cell.tap()
            if chatInput.waitForExistence(timeout: timeout) { return true }
        }

        let startButton = app.buttons["Start a Conversation"].firstMatch
        if startButton.waitForExistence(timeout: 2) {
            startButton.tap()
            if chatInput.waitForExistence(timeout: timeout) { return true }
        }

        return false
    }

    /// Select a model from the model picker menu in the chat input bar.
    /// Assumes we're already in a ChatView. Taps the picker, selects the
    /// first available model, waits for it to load.
    @discardableResult
    func selectModelFromPicker(timeout: TimeInterval = 30) -> Bool {
        // `firstMatch` is never nil. Test each candidate's existence instead
        // of using a dead nil-coalescing chain.
        let candidates = [
            app.buttons["No Model"].firstMatch,
            app.buttons.containing(NSPredicate(format: "label CONTAINS 'Gemma'")).firstMatch,
            app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'model'")).firstMatch,
        ]
        guard let picker = candidates.first(where: { $0.waitForExistence(timeout: 2) }) else {
            return false
        }
        picker.tap()
        sleep(1) // Wait for menu popup

        // The menu shows available models as buttons. Tap the first one.
        // Model names include "Gemma 4 E2B", "Gemma 4 E4B", etc.
        let firstModel = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Gemma'")).firstMatch
        if firstModel.waitForExistence(timeout: 3) {
            firstModel.tap()
            // Wait for model to load — picker label should change from "No Model"
            // to the model name, and the ProgressView should disappear.
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                let noModel = app.buttons["No Model"].firstMatch
                if !noModel.exists { return true }
                sleep(2)
            }
        }
        return false
    }

    /// Find the first cell in the sidebar, trying both CollectionView and TableView.
    private func firstCellInSidebar(app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        // SwiftUI List(.sidebar) renders as CollectionView on iOS 16+
        let cvCell = app.collectionViews.cells.firstMatch
        if cvCell.waitForExistence(timeout: 2) { return cvCell }
        // Fallback: traditional UITableView-based List
        let tvCell = app.tables.cells.firstMatch
        if tvCell.waitForExistence(timeout: 2) { return tvCell }
        return nil
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
        // `firstMatch` is never nil, so choose the first element that exists.
        let candidates = [
            app.textFields["chatInput"].firstMatch,
            app.textFields["Message ZiroEdge"].firstMatch,
            app.textFields.firstMatch,
        ]
        guard let field = candidates.first(where: { $0.waitForExistence(timeout: 2) }) else {
            return
        }

        // Tap to focus
        field.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else { return }

        // Type into the app (keyboard-focused element) — more reliable
        // than field.typeText() for SwiftUI @FocusState-bound TextFields
        app.typeText(text)
        Thread.sleep(forTimeInterval: 1) // Wait for binding

        // Send via the localized keyboard return key.
        let returnButtons = ["Return", "enter", "return"].map {
            app.keyboards.buttons[$0].firstMatch
        }
        if let returnButton = returnButtons.first(where: { $0.waitForExistence(timeout: 1) }) {
            returnButton.tap()
        }
    }

    /// Wait for a response to appear (message count increases).
    /// Snapshots the baseline text count first, then waits for it to increase
    /// by at least 2 (user message bubble + assistant response bubble).
    func waitForResponse(timeout: TimeInterval = 30) -> Bool {
        let baseline = app.scrollViews.otherElements.staticTexts.count
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let current = app.scrollViews.otherElements.staticTexts.count
            if current >= baseline + 2 { return true }
            sleep(2)
        }
        return false
    }

    // MARK: - Model Helpers

    /// Wait for a production model to be loaded and ready in the picker.
    /// The model picker label must show a model name (not "No Model") and
    /// any loading ProgressView must have disappeared.
    func waitForModelLoaded(timeout: TimeInterval = 30) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            // Once "No Model" is gone, a model is loaded
            let noModel = app.buttons["No Model"].firstMatch
            if !noModel.exists {
                // Double-check: the picker should show an actual model name
                let pickerLabel = readModelPickerLabel()
                if let label = pickerLabel, label != "No Model", !label.isEmpty {
                    return true
                }
            }
            sleep(2)
        }
        return false
    }

    /// Verify that a specific screen is visible by checking for a
    /// distinguishing accessibility element. Fails the test if the
    /// element does not appear within the timeout.
    func requireScreenVisible(_ element: XCUIElement, named description: String,
                              timeout: TimeInterval = 5,
                              file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Screen '\(description)' not visible — expected element did not appear",
            file: file, line: line
        )
    }

    /// Returns true if at least one model appears installed in the models list.
    func hasInstalledModel() -> Bool {
        // Navigate to models tab and check for any model row
        openModels()
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

    // MARK: - UI Test Send Helper

    /// Wait for a UITest-sendtest message response. Used with the
    /// --uitesting-sendtest launch arg where the app creates a conversation
    /// and sends a message internally. Polls until messages appear or error.
    func waitForUITestMessage(timeout: TimeInterval = 90) -> Bool {
        return waitForResponse(timeout: timeout)
    }

    /// Wait for the "UITest Send Test" conversation to appear in the sidebar.
    /// The --uitesting-sendtest handler creates a conversation with this
    /// specific title after the model loads, which can take 30-60s.
    func waitForSidebarCell(timeout: TimeInterval = 120) -> XCUIElement? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            // Look for the "UITest Send Test" cell in collectionViews or tables.
            let cvCell = app.collectionViews.cells["UITest Send Test"].firstMatch
            if cvCell.waitForExistence(timeout: 2) {
                return cvCell
            }
            let tvCell = app.tables.cells["UITest Send Test"].firstMatch
            if tvCell.waitForExistence(timeout: 2) {
                return tvCell
            }
            // Also try staticTexts (sometimes cells are identified by text)
            let text = app.staticTexts["UITest Send Test"].firstMatch
            if text.waitForExistence(timeout: 2) {
                return text
            }
            sleep(3)
        }
        return nil
    }

    // MARK: - Diagnostics (accessibility-tree based, no screenshots)

    /// Read the current error banner text, if visible. Returns nil if no error.
    func readErrorBanner() -> String? {
        // Error banner has: exclamation image + Text(message) + "Dismiss" button
        let dismiss = app.buttons["Dismiss"].firstMatch
        guard dismiss.waitForExistence(timeout: 2) else { return nil }
        // Read all static texts — the error message is the red text near Dismiss
        let texts = app.staticTexts.allElementsBoundByIndex.compactMap { elem -> String? in
            let label = elem.label
            guard !label.isEmpty else { return nil }
            if label == "ZiroEdge" || label.contains("Gemma") || label == "Dismiss"
               || label.contains("Message Ziro") || label.contains("messages")
               || label == "Conversations" || label.contains("min ago")
               || label == "\u{00B7}" || label == "New Conversation" { return nil }
            return label
        }
        return texts.last
    }

    /// Read the model picker label to see what model is selected.
    func readModelPickerLabel() -> String? {
        if app.buttons["No Model"].firstMatch.exists { return "No Model" }
        for label in ["Gemma", "Llama", "Mistral", "Phi", "Qwen"] {
            let btn = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if btn.exists { return btn.label }
        }
        return nil
    }

    /// Read visible messages from the chat. Returns the last meaningful text.
    func readLastAssistantMessage() -> String? {
        let texts = app.scrollViews.otherElements.staticTexts.allElementsBoundByIndex.compactMap { elem -> String? in
            let label = elem.label
            guard !label.isEmpty else { return nil }
            if label == "ZiroEdge" || label.contains("Gemma") || label.contains("No Model")
               || label.contains("Message Ziro") || label.contains("messages")
               || label == "Conversations" || label.contains("min ago")
               || label == "\u{00B7}" || label == "New Conversation" { return nil }
            return label
        }
        return texts.last
    }
}
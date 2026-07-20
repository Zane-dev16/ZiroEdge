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

    /// Open the Settings sheet via the gear toolbar button.
    /// On iPhone with NavigationSplitView collapsed, the gear button is in the
    /// navigation bar of whichever view is currently front-most.
    @discardableResult
    func openSettings(timeout: TimeInterval = 5) -> Bool {
        // Try common accessibility labels for the gear button
        for label in ["gear", "Settings", "settings", "Gear"] {
            let btn = app.buttons[label]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                sleep(1)
                return true
            }
        }
        // Try navigation bar buttons
        let navBtn = app.navigationBars.buttons.firstMatch
        if navBtn.waitForExistence(timeout: 2) {
            navBtn.tap()
            sleep(1)
            return true
        }
        // Fallback: broader predicate match
        let gearButton = app.buttons.containing(
            NSPredicate(format: "identifier CONTAINS 'gear' OR label CONTAINS[c] 'gear' OR label CONTAINS[c] 'setting'")
        ).firstMatch
        if gearButton.waitForExistence(timeout: timeout) {
            gearButton.tap()
            sleep(1)
            return true
        }
        return false
    }

    /// Open the Models screen: Settings sheet -> "Manage Models" NavigationLink.
    @discardableResult
    func openModels(timeout: TimeInterval = 10) -> Bool {
        guard openSettings(timeout: timeout) else { return false }
        // Wait for the Settings sheet to fully appear — look for "Manage Models"
        // as either a button or a static text (NavigationLink renders as a cell)
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
        sleep(1) // Wait for push animation
        return true
    }

    /// Select an existing conversation or create a new one so ChatView (with
    /// its textView input) is shown instead of WelcomeView.
    @discardableResult
    func selectOrCreateConversation(timeout: TimeInterval = 8) -> Bool {
        // On iPhone, the sidebar IS the root NavigationStack.
        // SwiftUI List(.sidebar) renders as CollectionView, not TableView.
        // Try collectionViews first (iOS 16+ SwiftUI), then fall back to tables.
        let cell = firstCellInSidebar(app: app, timeout: timeout)
        if let cell, cell.waitForExistence(timeout: timeout) {
            cell.tap()
            return true
        }

        // No conversations yet — try "New Conversation" button in SidebarView
        for label in ["New Conversation", "new-conversation", "plus"] {
            let btn = app.buttons[label]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                return true
            }
        }

        // If we're on WelcomeView, try "Start a Conversation"
        let startBtn = app.buttons["Start a Conversation"]
        if startBtn.waitForExistence(timeout: 2) {
            startBtn.tap()
            return true
        }

        return false
    }

    /// Select a model from the model picker menu in the chat input bar.
    /// Assumes we're already in a ChatView. Taps the picker, selects the
    /// first available model, waits for it to load.
    @discardableResult
    func selectModelFromPicker(timeout: TimeInterval = 30) -> Bool {
        // The model picker is a Menu whose label shows "No Model" or the
        // model name. In XCUITest, SwiftUI Menu renders as a button.
        // Try tapping by common labels.
        let picker = app.buttons["No Model"].firstMatch
            ?? app.buttons.containing(NSPredicate(format: "label CONTAINS 'Gemma'")).firstMatch
            ?? app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'model'")).firstMatch

        guard picker.waitForExistence(timeout: 5) else { return false }
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
        // ChatView uses TextField with accessibilityIdentifier "chatInput"
        let field = app.textFields["chatInput"].firstMatch
            ?? app.textFields["Message ZiroEdge..."].firstMatch
            ?? app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return }

        // Tap to focus
        field.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else { return }

        // Type into the app (keyboard-focused element) — more reliable
        // than field.typeText() for SwiftUI @FocusState-bound TextFields
        app.typeText(text)
        Thread.sleep(forTimeInterval: 1) // Wait for binding

        // Send via keyboard return
        let returnBtn = app.keyboards.buttons["Return"].firstMatch
            ?? app.keyboards.buttons["enter"].firstMatch
            ?? app.keyboards.buttons["return"].firstMatch
        if returnBtn.waitForExistence(timeout: 2) {
            returnBtn.tap()
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
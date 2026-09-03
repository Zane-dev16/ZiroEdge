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

    /// Reveal the conversation sidebar (drawer toggle on compact widths;
    /// verifies the persistent column on regular widths).
    @discardableResult
    func openSidebar(timeout: TimeInterval = 8) -> Bool {
        // iPad persistent column, or a drawer that is already open: the
        // Conversations title is present without tapping.
        let conversationsTitle = app.staticTexts["Conversations"].firstMatch
        if conversationsTitle.waitForExistence(timeout: 1) { return true }

        let sidebarButton = app.buttons["sidebar-button"].firstMatch
        guard sidebarButton.waitForExistence(timeout: 2) else {
            return conversationsTitle.waitForExistence(timeout: timeout)
        }

        // The drawer presentation can lag several seconds behind a cold
        // launch (history-restore work), and the first tap is occasionally
        // swallowed before the sheet transaction runs — the r2 finding that
        // resurfaced in r4 as three consecutive sim-dark Settings capture
        // failures. Verify the drawer actually appeared and re-tap if it
        // did not, instead of returning true from a fire-and-forget tap.
        let drawerContent = app.buttons["New Conversation"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            sidebarButton.tap()
            if drawerContent.waitForExistence(timeout: 2)
                || conversationsTitle.waitForExistence(timeout: 1) {
                return true
            }
        } while Date() < deadline
        return conversationsTitle.exists || drawerContent.exists
    }

    /// Open Settings as an in-app page: reveal the sidebar (drawer on iPhone,
    /// persistent column on iPad), then tap the "Settings" Library row.
    /// Returns true only after the "Manage Models" link and the
    /// "Active Model" section header appear.
    @discardableResult
    func openSettings(timeout: TimeInterval = 10) -> Bool {
        guard openSidebar(timeout: timeout) else { return false }

        let settingsRow = app.buttons["Settings"].firstMatch
        // The drawer's Library section sits below the conversation list;
        // with several conversations it renders below the fold (lazy
        // List), so scroll toward it before concluding the row is absent.
        if !settingsRow.waitForExistence(timeout: 3) {
            app.swipeUp()
            if !settingsRow.waitForExistence(timeout: 2) {
                app.swipeUp()
            }
        }
        guard settingsRow.waitForExistence(timeout: timeout) else { return false }
        settingsRow.tap()

        let manageModelsButton = app.buttons["Manage Models"].firstMatch
        let manageModelsText = app.staticTexts["Manage Models"].firstMatch
        let activeModelSection = app.staticTexts["Active Model"].firstMatch
        let manageModelsVisible = manageModelsButton.waitForExistence(timeout: 2)
            || manageModelsText.waitForExistence(timeout: timeout)
        return manageModelsVisible
            && activeModelSection.waitForExistence(timeout: timeout)
    }

    /// Open the Models screen: sidebar -> Settings page -> "Manage Models" link.
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
        guard modelsTitle.waitForExistence(timeout: timeout) else { return false }

        // The catalog defaults to the Installed scope when a model is already
        // on the device; curated downloads (including Llama 3.2 3B) live
        // under the Available segment.
        let modelCatalogContent = app.staticTexts["Llama 3.2 3B"].firstMatch
        if modelCatalogContent.waitForExistence(timeout: 3) { return true }

        let availableSegment = app.buttons["Available"].firstMatch
        if availableSegment.waitForExistence(timeout: 2) {
            availableSegment.tap()
        }
        return modelCatalogContent.waitForExistence(timeout: timeout)
    }

    /// Select an existing conversation or create a new one. Returns true only
    /// when ChatView's input exists; tapping a control alone is not navigation
    /// evidence (for example, a model redirect may appear instead).
    ///
    /// Since the shell overhaul the app launches directly into a chat surface
    /// (unsaved draft when nothing is selected), so the input check usually
    /// succeeds immediately. "New Conversation" lives inside the sidebar — a
    /// drawer sheet on compact widths — so it is only reachable after revealing
    /// the sidebar.
    @discardableResult
    func selectOrCreateConversation(timeout: TimeInterval = 8) -> Bool {
        let chatInput = app.textFields["chatInput"].firstMatch
        if chatInput.waitForExistence(timeout: min(timeout, 5)) { return true }

        // Reveal the sidebar first: on the compact shell the drawer sheet is
        // closed at launch, so its "New Conversation" button is not in the
        // accessibility hierarchy until the drawer is presented.
        _ = openSidebar(timeout: timeout)
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

    /// Select a model from the header pill menu (taps picker, picks the first
    /// available model, waits for it to load).
    @discardableResult
    func selectModelFromPicker(timeout: TimeInterval = 30) -> Bool {
        // `firstMatch` is never nil. Test each candidate's existence instead
        // of using a dead nil-coalescing chain.
        let candidates = [
            app.buttons["No Model"].firstMatch,
            app.buttons["No model yet"].firstMatch,
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
            // Wait for model to load — picker label should change from a
            // placeholder to the model name, and the loading indicator go away.
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if !hasNoModelIndicator() { return true }
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
        // The on-screen keyboard does not reliably appear on headless/CI
        // simulators (hardware-keyboard bridging varies by host state) — do
        // not abort when it is missing. XCUIApplication.typeText synthesizes
        // key events with or without the software keyboard, which is exactly
        // how the diagnostic chat flows type, so proceed unconditionally.
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) == false {
            // Keyboard still down — the first tap may not have taken focus on
            // a cold launch. Tap once more, then type regardless: typeText is
            // how the passing diagnostic flows input text on this host.
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
        }

        // Type into the app (keyboard-focused element) — more reliable
        // than field.typeText() for SwiftUI @FocusState-bound TextFields
        app.typeText(text)
        Thread.sleep(forTimeInterval: 1) // Wait for binding

        // Prefer the app's own send affordance: the overhauled composer's
        // Return handling proved unreliable under XCUITest on iOS 26 (the
        // keyboard key tap does not always fire onSubmit), so the labeled
        // send button is the primary path with Return as fallback.
        let sendButton = app.buttons["Send message"].firstMatch
        if sendButton.waitForExistence(timeout: 2), sendButton.isEnabled {
            sendButton.tap()
            return
        }

        // Send via the localized keyboard return key.
        let returnButtons = ["Return", "enter", "return"].map {
            app.keyboards.buttons[$0].firstMatch
        }
        if let returnButton = returnButtons.first(where: { $0.waitForExistence(timeout: 1) }) {
            returnButton.tap()
        }
    }

    /// Wait for a response: baseline text count must grow by at least 2
    /// (user bubble + assistant bubble).
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

    /// Wait for the chat header pill to show a loaded model (no placeholder).
    func waitForModelLoaded(timeout: TimeInterval = 30) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !hasNoModelIndicator() {
                // Double-check: the pill should show an actual model name
                let pickerLabel = readModelPickerLabel()
                if let label = pickerLabel, !isPlaceholderLabel(label) {
                    return true
                }
            }
            sleep(2)
        }
        return false
    }

    /// Placeholder pill states: legacy "No Model" and S2's "No model yet".
    private func hasNoModelIndicator() -> Bool {
        app.buttons["No Model"].firstMatch.exists || app.buttons["No model yet"].firstMatch.exists
    }

    func isPlaceholderLabel(_ label: String) -> Bool {
        label == "No Model" || label == "No model yet" || label.isEmpty
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
    /// Banners carry the `errorBanner` accessibility identifier; reading the
    /// identified element resolves in a single snapshot (no index enumeration
    /// to race against a re-rendering transcript).
    func readErrorBanner() -> String? {
        let banner = app.descendants(matching: .any)["errorBanner"].firstMatch
        guard banner.waitForExistence(timeout: 2) else { return nil }
        if !banner.label.isEmpty { return banner.label }
        let message = banner.staticTexts.firstMatch
        return message.exists ? message.label : nil
    }

    /// Read the chat header pill title to see what model is selected.
    /// Strategy: parse the "Chat model, <name>" accessibility label first
    /// (authoritative for every pill state), then fall back to family-name scans.
    func readModelPickerLabel() -> String? {
        if hasNoModelIndicator() { return "No Model" }
        let pill = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Chat model,'")
        ).firstMatch
        if pill.exists {
            let tail = pill.label
                .replacingOccurrences(of: "Chat model,", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { return tail }
        }
        for label in ["Gemma", "Llama", "Mistral", "Phi", "Qwen"] {
            let btn = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if btn.exists { return btn.label }
        }
        return nil
    }

    /// Read the assistant's reply text from the chat, if present. Assistant
    /// bubbles carry a stable "Assistant said: …" accessibility label, so this
    /// resolves via a single-snapshot label predicate instead of enumerating
    /// `allElementsBoundByIndex` (which aborts with "Failed to get matching
    /// snapshot" when the transcript re-renders mid-read). In a multi-turn
    /// conversation this returns the first assistant bubble — sufficient for
    /// the diagnostic callers, which use it on fresh conversations.
    func readLastAssistantMessage() -> String? {
        let reply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Assistant said: '")
        ).firstMatch
        guard reply.exists, !reply.label.isEmpty else { return nil }
        return String(reply.label.dropFirst("Assistant said: ".count))
    }
}

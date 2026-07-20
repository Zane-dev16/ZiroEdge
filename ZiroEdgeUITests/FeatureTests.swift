import XCTest

/// L1 Feature Tests — deep interaction tests for recently-built features.
/// Run after building a new feature. Add tests here as features land.
///
/// Template: copy a test method, change navigation + interaction + capture.
final class FeatureTests: UITestBase {

    // MARK: - Chat Interaction

    /// Test that a model auto-loads, a test message is sent (bypassing the
    /// TextField via --uitesting-sendtest launch arg), and the assistant
    /// responds. The app creates a conversation with title "UITest Send Test"
    /// and sends a message internally. The test waits for ChatView to appear
    /// (selectedConversationID is set by the handler), then waits for response.
    func testModelAutoLoads() {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--uitesting-sendtest"]
        chatApp.launch()
        app = chatApp

        print("[TEST] Waiting for ChatView to appear (model loading + conversation creation)...")

        // The --uitesting-sendtest handler:
        // 1. Auto-loads first model (30-60s for Gemma 4 E2B)
        // 2. Creates a conversation titled "UITest Send Test"
        // 3. Sets selectedConversationID -> MainView shows ChatView
        // 4. Sets inputText and calls sendMessage()
        // We just need to wait for ChatView's chatInput TextField to appear.
        let input = app.textFields["chatInput"].firstMatch
        guard input.waitForExistence(timeout: 120) else {
            // Diagnose: check if we're stuck on WelcomeView or sidebar
            let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
            print("[TEST] Visible texts: \(texts)")
            if let error = readErrorBanner() {
                XCTFail("No ChatView, error: \(error)")
            } else {
                XCTFail("ChatView did not appear within 120s (model may not have loaded)")
            }
            return
        }
        print("[TEST] Chat view appeared")

        // Check model picker
        let modelLabel = readModelPickerLabel() ?? "unknown"
        print("[TEST] Model picker shows: \(modelLabel)")

        // The app has already sent (or is sending) the test message.
        // Wait for the assistant response.
        // waitForResponse snapshots baseline and waits for +2 texts.
        // But if messages are already there (sendMessage completed), baseline
        // already includes them. So check if we already have responses.
        let initialTexts = app.scrollViews.otherElements.staticTexts.count
        print("[TEST] Initial message texts: \(initialTexts)")

        if initialTexts >= 2 {
            // Messages already present — sendMessage completed before we got here
            if let reply = readLastAssistantMessage() {
                print("[TEST] Assistant replied: \(reply)")
            }
            return  // PASS
        }

        // Wait for streaming to complete and response to appear
        print("[TEST] Waiting for assistant response...")
        let responded = waitForResponse(timeout: 120)
        if responded {
            if let reply = readLastAssistantMessage() {
                print("[TEST] Assistant replied: \(reply)")
            }
            return  // PASS
        }

        // Diagnose failure
        if let error = readErrorBanner() {
            print("[TEST] Error banner: \(error)")
            XCTFail("App error: \(error)")
            return
        }
        if let label = readModelPickerLabel(), label == "No Model" {
            XCTFail("Model never loaded — picker still shows 'No Model'")
            return
        }
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        print("[TEST] Visible texts: \(texts)")
        XCTAssertTrue(responded, "No AI response within 120s")
    }

    func testChatStreamingStop() throws {
        let navigated = selectOrCreateConversation()
        guard navigated else {
            throw XCTSkip("Could not open or create a conversation")
        }

        let input = app.textFields["Message ZiroEdge..."].firstMatch
            ?? app.textFields.firstMatch
        guard input.waitForExistence(timeout: 5) else {
            throw XCTSkip("No chat input found — model may not be loaded")
        }

        sendChatMessage("Write a very long essay about the color blue")
        capture("chat_streaming_started")

        // Try to stop generation
        if tapButton("stop.circle.fill", timeout: 5) || tapButton("Stop", timeout: 2) {
            capture("chat_streaming_stopped")
        }
    }

    // MARK: - Diagnostic: Full chat flow

    /// Tests the full chat flow: auto-loads model via --uitesting, taps
    /// New Conversation, sends a message via TextField, waits for response.
    func testDiagnosticChatFlow() {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting"]
        chatApp.launch()
        app = chatApp

        print("[TEST-DIAG] Waiting 15s for model auto-load...")
        sleep(15)

        let newConvBtn = app.buttons["New Conversation"].firstMatch
        guard newConvBtn.waitForExistence(timeout: 10) else {
            print("[TEST-DIAG] No 'New Conversation' button")
            return
        }
        newConvBtn.tap()
        print("[TEST-DIAG] Tapped New Conversation")
        sleep(3)

        let modelLabel = readModelPickerLabel() ?? "unknown"
        print("[TEST-DIAG] Model picker: \(modelLabel)")

        let input = app.textFields["chatInput"].firstMatch
        guard input.waitForExistence(timeout: 10) else {
            print("[TEST-DIAG] No chatInput found")
            let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            print("[TEST-DIAG] Texts: \(texts.joined(separator: " | "))")
            return
        }
        print("[TEST-DIAG] Chat input found")

        input.tap()
        sleep(1)
        app.typeText("Hello, say hi in one word")
        sleep(1)

        // Multi-line TextField (axis: .vertical) doesn't trigger .onSubmit
        // on Return key — it inserts a newline. Must use the send button instead.
        // First dismiss keyboard, then tap the send button.
        tapButton("Arrow Up Circle", timeout: 5)
        print("[TEST-DIAG] Sent via send button")

        let responded = waitForResponse(timeout: 120)
            if responded {
            if let reply = readLastAssistantMessage() {
                print("[TEST-DIAG] AI replied: \(reply)")
            }
            print("[TEST-DIAG] SUCCESS")
        } else {
            print("[TEST-DIAG] FAILURE — no response within 120s")
            if let error = readErrorBanner() {
                print("[TEST-DIAG] Error: \(error)")
            }
        }
        XCTAssertTrue(responded, "Model did not respond within 120s")
    }

    // MARK: - Diagnostic: New Conversation flow

    /// Diagnostic test that taps "New Conversation" and checks if we
    /// enter ChatView (model exists) or get "Download a Model" (no model).
    func testDiagnosticNewConv() {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting"]
        chatApp.launch()
        app = chatApp
        sleep(3)

        // Tap "New Conversation" button
        let newConvBtn = app.buttons["New Conversation"].firstMatch
        guard newConvBtn.waitForExistence(timeout: 5) else {
            print("[TEST-DIAG] No 'New Conversation' button found")
            return
        }
        newConvBtn.tap()
        sleep(5) // Wait for navigation/animation

        // Check what happened
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let buttons = app.buttons.allElementsBoundByIndex.map { $0.label }
        let textFields = app.textFields.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] After New Conv — texts: \(texts.joined(separator: " | "))")
        print("[TEST-DIAG] After New Conv — buttons: \(buttons.joined(separator: " | "))")
        print("[TEST-DIAG] After New Conv — textFields: \(textFields.joined(separator: " | "))")

        let hasDownloadModel = texts.contains("Download a Model") || texts.contains("No Models Installed")
        let hasChatInput = !textFields.isEmpty
        let hasNoModel = buttons.contains("No Model")
        print("[TEST-DIAG] Has Download Model sheet: \(hasDownloadModel)")
        print("[TEST-DIAG] Has chat input: \(hasChatInput)")
        print("[TEST-DIAG] Has 'No Model' button: \(hasNoModel)")

        capture("diagnostic_new_conv")
    }

    // MARK: - Diagnostic: Dump root view

    /// Diagnostic test that dumps ALL accessibility elements from the
    /// root view.
    func testDiagnosticDump() {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting"]
        chatApp.launch()
        app = chatApp
        sleep(5) // Wait for UI to settle

        // Dump all static texts
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] Static texts: \(texts.joined(separator: " | "))")

        // Dump all buttons
        let buttons = app.buttons.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] Buttons: \(buttons.joined(separator: " | "))")

        // Dump all cells
        let cvCells = app.collectionViews.cells.allElementsBoundByIndex.map { $0.label }
        let tvCells = app.tables.cells.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] CollectionView cells: \(cvCells.joined(separator: " | "))")
        print("[TEST-DIAG] TableView cells: \(tvCells.joined(separator: " | "))")

        // Dump all navigation bars
        let navBars = app.navigationBars.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] Nav bars: \(navBars.joined(separator: " | "))")

        // Dump all text fields
        let textFields = app.textFields.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] Text fields: \(textFields.joined(separator: " | "))")

        // Dump all other elements
        let otherElements = app.otherElements.allElementsBoundByIndex.map { $0.label }
        print("[TEST-DIAG] Other elements: \(otherElements.joined(separator: " | "))")

        // Print element count summary
        print("[TEST-DIAG] Summary: \(texts.count) texts, \(buttons.count) buttons, \(cvCells.count) cvCells, \(tvCells.count) tvCells, \(navBars.count) navBars, \(textFields.count) textFields")

        capture("diagnostic_dump")
    }

    // MARK: - Model Picker

    func testModelPicker() {
        // Navigate into a conversation
        selectOrCreateConversation()

        // Look for model picker button in chat view
        if tapButton("model") || tapButton("picker") || tapButton("Model") {
            capture("model_picker_open")
            // Close it
            app.swipeDown()
            capture("model_picker_closed")
        }
    }
}
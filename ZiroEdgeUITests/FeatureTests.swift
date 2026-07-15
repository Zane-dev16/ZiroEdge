import XCTest

/// L1 Feature Tests — deep interaction tests for recently-built features.
/// Run after building a new feature. Add tests here as features land.
///
/// Template: copy a test method, change navigation + interaction + capture.
final class FeatureTests: UITestBase {

    // MARK: - Chat Interaction

    func testModelAutoLoads() {
        // Launch with --uitesting to trigger model auto-load.
        // Then send a test message and verify response or diagnose errors.
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting"]
        chatApp.launch()
        app = chatApp

        // Navigate into a conversation
        let cvCell = app.collectionViews.cells.firstMatch
        let tvCell = app.tables.cells.firstMatch
        let sidebarCell = cvCell.exists ? cvCell : tvCell
        guard (cvCell.exists || tvCell.exists) && sidebarCell.waitForExistence(timeout: 10) else {
            XCTFail("No conversation list visible")
            return
        }
        sidebarCell.tap()

        // Wait for ChatView
        let input = app.textFields["chatInput"].firstMatch
            ?? app.textFields["Message ZiroEdge..."].firstMatch
            ?? app.textFields.firstMatch
        guard input.waitForExistence(timeout: 10) else {
            XCTFail("Chat view did not appear")
            return
        }

        // Wait for model to load — poll the picker label
        let loadStart = Date()
        while Date().timeIntervalSince(loadStart) < 60 {
            if let label = readModelPickerLabel(), label != "No Model" {
                print("[TEST] Model loaded: \(label)")
                break
            }
            sleep(2)
        }
        let modelLabel = readModelPickerLabel() ?? "unknown"
        print("[TEST] Model picker shows: \(modelLabel)")

        // Send message
        sendChatMessage("Hello, say hi in one word")
        print("[TEST] Message sent, waiting for response...")

        // Wait for response
        let responded = waitForResponse(timeout: 60)
        if responded {
            if let reply = readLastAssistantMessage() {
                print("[TEST] Assistant replied: \(reply)")
            }
        } else {
            // Diagnose what went wrong
            if let error = readErrorBanner() {
                print("[TEST] Error banner: \(error)")
                XCTFail("App error: \(error)")
                return
            }
            if let label = readModelPickerLabel(), label == "No Model" {
                XCTFail("Model never loaded — picker still shows 'No Model'")
                return
            }
            // Dump visible static texts for debugging
            let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
            print("[TEST] Visible texts: \(texts)")
        }
        XCTAssertTrue(responded, "No AI response within 60s")
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

    // MARK: - New Feature Template
    //
    // To add a test for a new feature:
    //
    // func testMyNewFeature() {
    //     // 1. Navigate to where the feature lives
    //     navigateTo(tab: "Chat")
    //
    //     // 2. Screenshot the before state
    //     capture("feature_before")
    //
    //     // 3. Interact
    //     tapButton("my_button")
    //     // or: app.swipeUp(), etc.
    //
    //     // 4. Screenshot the after state
    //     capture("feature_after")
    //
    //     // 5. Assert
    //     XCTAssertTrue(someElement.exists, "Expected thing didn't happen")
    // }
}

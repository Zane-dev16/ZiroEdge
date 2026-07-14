import XCTest

/// L1 Feature Tests — deep interaction tests for recently-built features.
/// Run after building a new feature. Add tests here as features land.
///
/// Template: copy a test method, change navigation + interaction + capture.
final class FeatureTests: UITestBase {

    // MARK: - Chat Interaction

    func testSendChatMessage() throws {
        navigateTo(tab: "Chat")

        guard hasInstalledModel() else {
            throw XCTSkip("No model installed — skipping chat test")
        }

        sendChatMessage("Hello, say hi in one word")
        capture("chat_message_sent")

        let responded = waitForResponse(timeout: 30)
        XCTAssertTrue(responded, "No response appeared within 30s")
        capture("chat_response_received")
    }

    func testChatStreamingStop() throws {
        navigateTo(tab: "Chat")

        guard hasInstalledModel() else {
            throw XCTSkip("No model installed — skipping streaming test")
        }

        sendChatMessage("Write a very long essay about the color blue")
        capture("chat_streaming_started")

        // Try to stop generation
        if tapButton("Stop", timeout: 5) {
            capture("chat_streaming_stopped")
        }
    }

    // MARK: - Model Picker

    func testModelPicker() {
        navigateTo(tab: "Chat")

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

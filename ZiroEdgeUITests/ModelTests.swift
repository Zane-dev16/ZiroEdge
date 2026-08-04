import XCTest

/// L2 Model Tests — verify a specific model loads and produces output.
/// Only run when testing a new model or verifying model changes.
/// Uses whatever model is already on the device unless a specific one is named.
final class ModelTests: UITestBase {

    /// Test that the first available model can be loaded and responds.
    func testInstalledModelResponds() throws {
        navigateTo(tab: "Models")

        // Find a model that's already downloaded
        let firstCell = app.tables.cells.firstMatch
        guard firstCell.waitForExistence(timeout: 5) else {
            throw XCTSkip("No models on device")
        }

        // Go to model detail and load it
        firstCell.tap()
        capture("model_detail_for_test")

        // Look for a load/use button
        if tapButton("Use") || tapButton("Load") || tapButton("Chat") {
            capture("model_loading")
        }

        // Navigate to chat and send a test prompt
        navigateTo(tab: "Chat")
        sendChatMessage("Reply with only the word 'test'")
        capture("model_test_prompt_sent")

        let responded = waitForResponse(timeout: 60)
        XCTAssertTrue(responded, "Model did not respond within 60s")
        capture("model_test_responded")
    }

    // MARK: - Specific Model Template
    //
    // To test a specific model by name:
    //
    // func testSpecificModel() {
    //     navigateTo(tab: "Models")
    //
    //     // Find the model by name in the list
    //     let model = app.tables.cells.containing(.staticText, identifier: "ModelName").firstMatch
    //     guard model.waitForExistence(timeout: 5) else {
    //         throw XCTSkip("Model 'ModelName' not found on device")
    //     }
    //
    //     model.tap()
    //     tapButton("Use")
    //     navigateTo(tab: "Chat")
    //     sendChatMessage("test prompt")
    //     waitForResponse(timeout: 60)
    //     capture("specific_model_response")
    // }
}

/// Physical-device acceptance test for the real E4B Text chat path.
///
/// This deliberately does not inherit from `UITestBase`: that base launches with
/// `--uitesting`, while this test must exercise the ordinary production app.
final class PhysicalE4BTextUITests: XCTestCase {
    private let modelName = "Gemma 4 E4B Text"
    private let prompt = "In one short sentence, say hello from E4B."
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 480
        app = XCUIApplication()
        app.launch()
    }

    func testPhysicalDeviceE4BTextRespondsThroughPublicUI() throws {
        try openConversation()

        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Chat model, ")
        ).firstMatch
        require(
            picker.waitForExistence(timeout: 15),
            "Chat model picker did not appear within 15 seconds",
            screenshot: "picker_missing"
        )
        picker.tap()

        let modelRow = app.buttons[modelName].firstMatch
        let discovered = modelRow.waitForExistence(timeout: 15)
        capture("e4b_text_visible_in_picker")
        require(
            discovered,
            "Public chat model picker does not visibly list '\(modelName)'",
            includeHierarchy: true
        )

        modelRow.tap()
        capture("e4b_text_selected_or_loading")

        try waitUntilModelIsReady(timeout: 300)
        capture("e4b_text_ready")

        let input = app.textFields["chatInput"].firstMatch
        require(
            input.waitForExistence(timeout: 15) && input.isEnabled,
            "Chat input was not publicly enabled after '\(modelName)' became selected"
        )
        input.tap()
        require(
            app.keyboards.firstMatch.waitForExistence(timeout: 15),
            "Keyboard did not appear within 15 seconds"
        )
        input.typeText(prompt)
        require(
            (input.value as? String) == prompt,
            "Chat input did not contain the exact required prompt; value was '\(String(describing: input.value))'"
        )

        let completedAssistantCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Assistant said: ")
        ).count
        let sendButton = app.buttons["Send message"].firstMatch
        require(
            sendButton.waitForExistence(timeout: 15) && sendButton.isEnabled,
            "Public send path was not enabled for the exact prompt"
        )
        sendButton.tap()

        let userBubble = app.staticTexts["You said: \(prompt)"].firstMatch
        require(
            userBubble.waitForExistence(timeout: 15),
            "The exact prompt was not visibly submitted within 15 seconds"
        )
        capture("exact_prompt_sent")

        let assistant = try waitForFinalAssistantResponse(
            afterCount: completedAssistantCount,
            timeout: 180
        )
        let exactAccessibilityLabel = assistant.label
        let response = String(exactAccessibilityLabel.dropFirst("Assistant said: ".count))
        require(
            !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Final assistant response was visible but empty"
        )

        print("[E4B-PHYSICAL] assistant accessibility label: \(exactAccessibilityLabel)")
        print("[E4B-PHYSICAL] assistant response verbatim: \(response)")
        capture("final_assistant_response")
    }

    private func openConversation() throws {
        let newConversation = app.buttons["New Conversation"].firstMatch
        require(
            newConversation.waitForExistence(timeout: 30),
            "Ordinary app did not expose the public New Conversation button within 30 seconds",
            screenshot: "new_conversation_missing",
            includeHierarchy: true
        )
        newConversation.tap()

        let input = app.textFields["chatInput"].firstMatch
        let browseModels = app.buttons["Browse Models"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            require(
                !browseModels.exists,
                "Public New Conversation redirected to Browse Models instead of ordinary chat",
                screenshot: "new_conversation_redirected_to_browse_models",
                includeHierarchy: true
            )
            if input.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        require(
            false,
            "Public New Conversation did not expose chat input within 30 seconds",
            screenshot: "new_conversation_chat_timeout",
            includeHierarchy: true
        )
    }

    private func waitUntilModelIsReady(timeout: TimeInterval) throws {
        let expectedPickerLabel = "Chat model, \(modelName)"
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try failIfPublicLoadErrorIsVisible()

            let selectedPicker = app.buttons[expectedPickerLabel].firstMatch
            let switching = app.staticTexts["Switching…"].firstMatch.exists
                || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Switching…")).firstMatch.exists
            let input = app.textFields["chatInput"].firstMatch
            if selectedPicker.exists && !switching && input.exists && input.isEnabled { return }

            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        require(
            false,
            "'\(modelName)' did not satisfy the public readiness contract within 300 seconds",
            screenshot: "model_readiness_timeout"
        )
    }

    private func waitForFinalAssistantResponse(
        afterCount baseline: Int,
        timeout: TimeInterval
    ) throws -> XCUIElement {
        let finalResponses = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Assistant said: ")
        )
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try failIfPublicLoadErrorIsVisible()
            if finalResponses.count > baseline {
                return finalResponses.element(boundBy: finalResponses.count - 1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        require(
            false,
            "No new final visible assistant response appeared within 180 seconds",
            screenshot: "assistant_response_timeout"
        )
        return finalResponses.firstMatch
    }

    private func failIfPublicLoadErrorIsVisible() throws {
        for message in ["Model Load Failed", "Model Needs More Memory"] {
            if app.alerts[message].firstMatch.exists || app.staticTexts[message].firstMatch.exists {
                require(false, "Public model failure appeared: \(message)", screenshot: "public_model_failure")
            }
        }

        let errorBanner = app.otherElements["errorBanner"].firstMatch
        if errorBanner.exists {
            require(
                false,
                "Public error banner appeared: \(errorBanner.label)",
                screenshot: "public_error_banner"
            )
        }
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        screenshot: String? = nil,
        includeHierarchy: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            if let screenshot { capture(screenshot) }
            let details = includeHierarchy ? "\nUI hierarchy:\n\(app.debugDescription)" : ""
            XCTFail(message + details, file: file, line: line)
            return
        }
    }

    private func capture(_ name: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(timestamp)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

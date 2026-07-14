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

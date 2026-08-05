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

    // MARK: - E2B Offline Tests (Issue 07)
    //
    // These tests are enabled only by device-test.sh --layer offline. Other
    // model layers skip them so their normal coverage does not require both
    // production models to be installed.

    private func requireOfflineLayer() throws {
        guard ProcessInfo.processInfo.environment["ZIROEDGE_REQUIRE_OFFLINE_MODELS"] == "1" else {
            throw XCTSkip("E2B/E4B checks run only in the physical offline layer")
        }
    }

    @discardableResult
    private func selectChatModel(containing modelName: String) -> Bool {
        navigateTo(tab: "Chat")

        let selectedModel = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Chat model,' AND label CONTAINS[c] %@", modelName)
        ).firstMatch
        if selectedModel.waitForExistence(timeout: 2) { return true }

        let modelMenu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Chat model,'")
        ).firstMatch
        guard modelMenu.waitForExistence(timeout: 5) else { return false }
        modelMenu.tap()

        let option = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", modelName)
        ).firstMatch
        guard option.waitForExistence(timeout: 5) else { return false }
        option.tap()

        return selectedModel.waitForExistence(timeout: 30)
    }

    /// Verify E2B model is installed and can be loaded.
    /// Fails if E2B is not found — this layer requires it.
    func testE2BModelInstalledAndLoadable() throws {
        try requireOfflineLayer()
        guard openModels() else {
            XCTFail("Cannot navigate to Models view")
            return
        }

        // Look for E2B model in the list
        let e2bCell = app.tables.cells.containing(
            NSPredicate(format: "label CONTAINS[c] 'E2B'")
        ).firstMatch

        guard e2bCell.waitForExistence(timeout: 5) else {
            XCTFail("E2B model not found on device — required for offline layer")
            return
        }

        e2bCell.tap()
        capture("e2b_model_detail")

        // Verify model shows as installed
        let installed = app.staticTexts["Installed"].firstMatch
        XCTAssertTrue(
            installed.exists,
            "E2B model must show as Installed for offline layer"
        )
        capture("e2b_model_installed")
    }

    /// Verify E4B model is installed and can be loaded.
    /// Fails if E4B is not found — this layer requires it.
    func testE4BModelInstalledAndLoadable() throws {
        try requireOfflineLayer()
        guard openModels() else {
            XCTFail("Cannot navigate to Models view")
            return
        }

        let e4bCell = app.tables.cells.containing(
            NSPredicate(format: "label CONTAINS[c] 'E4B'")
        ).firstMatch

        guard e4bCell.waitForExistence(timeout: 5) else {
            XCTFail("E4B model not found on device — required for offline layer")
            return
        }

        e4bCell.tap()
        capture("e4b_model_detail")

        let installed = app.staticTexts["Installed"].firstMatch
        XCTAssertTrue(
            installed.exists,
            "E4B model must show as Installed for offline layer"
        )
        capture("e4b_model_installed")
    }

    /// Verify E2B model produces a text response.
    /// Fails if model does not respond — this layer requires functional inference.
    func testE2BTextResponse() throws {
        try requireOfflineLayer()
        guard selectChatModel(containing: "E2B") else {
            XCTFail("Could not select E2B for the offline response test")
            return
        }

        sendChatMessage("Reply with exactly: E2B_OK")
        capture("e2b_text_prompt_sent")

        let responded = waitForResponse(timeout: 120)
        XCTAssertTrue(responded, "E2B model must produce a text response for offline layer")
        capture("e2b_text_response")
    }

    /// Verify E4B model produces a text response.
    /// Fails if model does not respond — this layer requires functional inference.
    func testE4BTextResponse() throws {
        try requireOfflineLayer()
        guard selectChatModel(containing: "E4B") else {
            XCTFail("Could not select E4B for the offline response test")
            return
        }

        sendChatMessage("Reply with exactly: E4B_OK")
        capture("e4b_text_prompt_sent")

        let responded = waitForResponse(timeout: 120)
        XCTAssertTrue(responded, "E4B model must produce a text response for offline layer")
        capture("e4b_text_response")
    }
}

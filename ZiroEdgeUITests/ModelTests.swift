import XCTest

/// L2 Model Tests — verify a specific model loads and produces output.
/// Only run when testing a new model or verifying model changes.
/// Uses whatever model is already on the device unless a specific one is named.
final class ModelTests: UITestBase {

    /// Regression: the Delete Model button arms `showingDeleteConfirmation`
    /// on the shared view model, but the modal used to host only in
    /// ModelsView — two pushes underneath — so the tap visibly did nothing.
    /// Hermetic ready seeds llama32_3B as downloaded, which renders the
    /// destructive section on the Storage page.
    func testDeleteModelPresentsConfirmation() throws {
        let hermeticApp = XCUIApplication()
        hermeticApp.launchArguments = [
            "--uitesting",
            "--uitesting-hermetic-model",
        ]
        hermeticApp.launch()
        app = hermeticApp

        guard openModels(timeout: 15) else {
            XCTFail("Failed to open Models page under hermetic flags")
            return
        }
        let modelCell = app.cells.containing(
            NSPredicate(format: "label CONTAINS 'Llama 3.2 3B'")
        ).firstMatch
        guard modelCell.waitForExistence(timeout: 15) else {
            XCTFail("Llama 3.2 3B row missing on the Models page")
            return
        }
        modelCell.tap()

        let storageRow = app.cells.containing(
            NSPredicate(format: "label CONTAINS 'Storage'")
        ).firstMatch
        guard storageRow.waitForExistence(timeout: 15) else {
            XCTFail("Storage & Provenance row missing on the model detail page")
            return
        }
        storageRow.tap()

        let deleteButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Delete Model'")
        ).firstMatch
        guard deleteButton.waitForExistence(timeout: 10) else {
            XCTFail("Delete Model button missing on the Storage page")
            return
        }
        deleteButton.tap()

        let modal = app.descendants(matching: .any)["confirmation-modal"].firstMatch
        XCTAssertTrue(modal.waitForExistence(timeout: 10),
                      "Delete Model must present the confirmation modal")
        capture("delete_model_confirmation")
        let cancel = app.descendants(matching: .any)["confirmation-cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) {
            cancel.tap()
        }
        sleep(1) // Wait for dismissal animation
        XCTAssertFalse(modal.exists,
                       "Cancelling the delete confirmation must dismiss the modal")
    }

    /// Device storage discipline: forget-import the model whose row contains
    /// `needle`, so the next download starts from a clean artifact directory.
    /// Runs against the REAL library — no hermetic flags. Device-only.
    /// One thin test per lineup model; each runs in import → validate →
    /// forget sequence (see the e2e runs in the session log).
    func testDeleteImportedLFMModelReleasesStorage() throws {
        try forgetImportedModel(containing: "LFM2.5-1.2B")
    }

    func testDeleteImportedQwen08BReleasesStorage() throws {
        try forgetImportedModel(containing: "Qwen3.5-0.8B")
    }

    func testDeleteImportedBonsai4BReleasesStorage() throws {
        try forgetImportedModel(containing: "Bonsai-4B")
    }

    func testDeleteImportedQwen2BReleasesStorage() throws {
        try forgetImportedModel(containing: "Qwen3.5-2B")
    }

    func testDeleteImportedLFM26BReleasesStorage() throws {
        try forgetImportedModel(containing: "LFM2.5-2.6B")
    }

    func testDeleteImportedBonsai8BReleasesStorage() throws {
        try forgetImportedModel(containing: "Bonsai-8B")
    }

    /// Curated download proof (device-only): the smallest lineup row
    /// (Qwen 3.5 0.8B, 532MB) downloads through the production path with
    /// SHA verification, then is deleted to leave storage clean. Curated
    /// rows keep their registry literal, so after delete the Download
    /// button must return (unlike forget-import, where the row vanishes).
    func testCuratedQwen08BDownloadsAndDeletes() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only: curated download writes 532MB on the physical iPhone")
#else
        guard openModels(timeout: 20) else {
            XCTFail("Failed to open Models page on device")
            return
        }
        try proveCuratedModelDownload(name: "Qwen 3.5 0.8B", tag: "qwen08b", downloadTimeout: 2400)
#endif
    }

    /// Full lineup proof (device-only): every remaining curated row
    /// downloads with SHA verification and is deleted before the next
    /// begins, keeping one-at-a-time storage discipline. Qwen 0.8B is
    /// covered by testCuratedQwen08BDownloadsAndDeletes.
    func testCuratedLineupDownloadsAndDeletes() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only: curated downloads write GBs on the physical iPhone")
#else
        guard openModels(timeout: 20) else {
            XCTFail("Failed to open Models page on device")
            return
        }
        // Size-ordered smallest-first so early iterations validate fast.
        try proveCuratedModelDownload(name: "Bonsai 4B", tag: "bonsai4b", downloadTimeout: 2400)
        try proveCuratedModelDownload(name: "LFM 2.5 1.2B", tag: "lfm12b", downloadTimeout: 2400)
        try proveCuratedModelDownload(name: "Bonsai 8B", tag: "bonsai8b", downloadTimeout: 3600)
        try proveCuratedModelDownload(name: "Qwen 3.5 2B", tag: "qwen2b", downloadTimeout: 3600)
        try proveCuratedModelDownload(name: "LFM 2.5 2.6B", tag: "lfm26b", downloadTimeout: 4200)
#endif
    }

    /// Shared download-verify-delete flow. Starts on the Models list, ends
    /// back on the Models list with the row offering Download again.
    private func proveCuratedModelDownload(name: String, tag: String, downloadTimeout: TimeInterval) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only")
#else
        for _ in 0..<10 { app.swipeDown() }
        let availableScope = app.buttons["Available"].firstMatch
        if availableScope.waitForExistence(timeout: 5) {
            availableScope.tap()
        }
        try findCuratedRow(name: name, tag: tag)
        try startCuratedDownload(tag: tag)
        let installedLabel = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Installed'")
        ).firstMatch
        // Background-session transfers are discretionarily throttled by iOS
        // (~0.5MB/s observed); per-model timeouts carry retry margin.
        // Downloaded detail shows Start Chatting (delete lives under
        // Storage & Provenance), not a Delete Model button.
        XCTAssertTrue(installedLabel.waitForExistence(timeout: downloadTimeout),
                      "\(name) must reach the downloaded state (Installed visible)")
        capture("curated_\(tag)_downloaded")
        try deleteDownloadedCuratedModel(name: name, tag: tag)
#endif
    }

    /// Locate a curated row across both scopes. Returns non-nil after
    /// tapping into detail. Skips (clean) when the row is absent.
    private func findCuratedRow(name: String, tag: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only")
#else
        // Rows expose static-text labels; match any element lineage (cells
        // on some scopes, buttons on others) instead of cells alone.
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        func row() -> XCUIElement {
            let cell = app.cells.containing(predicate).firstMatch
            if cell.waitForExistence(timeout: 2) { return cell }
            return app.buttons.containing(predicate).firstMatch
        }
        func scan() -> Bool {
            var found = row().waitForExistence(timeout: 5)
            for _ in 0..<15 where !found {
                app.swipeUp()
                found = row().waitForExistence(timeout: 3)
            }
            return found
        }
        if scan() {
            row().tap()
            capture("curated_\(tag)_detail")
            return
        }
        // The scope pill virtualizes out of the hierarchy when scrolled
        // away: return to top so it re-renders, then switch. A resumed or
        // partial curated artifact lists under Installed.
        for _ in 0..<15 { app.swipeDown() }
        let installedScope = app.buttons["Installed"].firstMatch
        if installedScope.waitForExistence(timeout: 10) {
            installedScope.tap()
        }
        if scan() {
            row().tap()
            capture("curated_\(tag)_detail")
            return
        }
        capture("curated_\(tag)_row_missing")
        throw XCTSkip("\(name) row missing from both scopes")
#endif
    }

    /// Tap whichever primary action the detail offers: Resume (restored
    /// partial), Retry (errored), or Download (fresh / already done).
    private func startCuratedDownload(tag: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only")
#else
        let resumeButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Resume Download'")
        ).firstMatch
        let retryButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Retry Download'")
        ).firstMatch
        let downloadButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Download'")
        ).firstMatch
        if resumeButton.waitForExistence(timeout: 10) {
            resumeButton.tap()
            capture("curated_\(tag)_resuming")
        } else if retryButton.waitForExistence(timeout: 5) {
            retryButton.tap()
            capture("curated_\(tag)_retrying")
        } else if downloadButton.waitForExistence(timeout: 10) {
            // Already downloaded (e.g. a previous proof run): skip to delete.
            downloadButton.tap()
            capture("curated_\(tag)_downloading")
        }
#endif
    }

    /// Delete via Storage & Provenance, confirm, and return to the Models
    /// list with the row offering Download again.
    private func deleteDownloadedCuratedModel(name: String, tag: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only")
#else
        let storageRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Storage & Provenance'")
        ).firstMatch
        guard storageRow.waitForExistence(timeout: 10) else {
            XCTFail("Storage & Provenance row missing on downloaded detail")
            return
        }
        storageRow.tap()
        let deleteButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Delete Model'")
        ).firstMatch
        guard deleteButton.waitForExistence(timeout: 10) else {
            XCTFail("Delete Model missing on Storage page")
            return
        }
        deleteButton.tap()
        let modal = app.descendants(matching: .any)["confirmation-modal"].firstMatch
        guard modal.waitForExistence(timeout: 10) else {
            XCTFail("Delete confirmation modal never appeared")
            return
        }
        let confirm = app.descendants(matching: .any)["confirmation-confirm"].firstMatch
        guard confirm.waitForExistence(timeout: 5) else {
            XCTFail("Delete confirm button missing in modal")
            return
        }
        confirm.tap()
        XCTAssertFalse(modal.waitForExistence(timeout: 2),
                        "Delete confirmation modal must dismiss after confirm")
        app.navigationBars.buttons.firstMatch.tap()
        let downloadButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Download'")
        ).firstMatch
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 30),
                      "After delete, \(name) must offer Download again")
        capture("curated_\(tag)_released")
        // Back to the Models list for the next iteration.
        app.navigationBars.buttons.firstMatch.tap()
#endif
    }

    private func forgetImportedModel(containing needle: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("device-only: imported artifact lives on the physical iPhone")
#else
        guard openModels(timeout: 20) else {
            XCTFail("Failed to open Models page on device")
            return
        }
        // The page lands on Available when no curated model is fully ready;
        // imports live under the Installed scope ("Imported from Hugging Face").
        let installedScope = app.buttons["Installed"].firstMatch
        if installedScope.waitForExistence(timeout: 5) {
            installedScope.tap()
        }
        let modelCell = app.cells.containing(
            NSPredicate(format: "label CONTAINS %@", needle)
        ).firstMatch
        var found = modelCell.waitForExistence(timeout: 5)
        for _ in 0..<6 where !found {
            app.swipeUp()
            found = modelCell.waitForExistence(timeout: 3)
        }
        guard found else {
            let labels = app.cells.allElementsBoundByIndex.prefix(30).map({ $0.label }).joined(separator: " | ")
            print("MODELS-CELLS: \(labels)")
            capture("delete_import_row_missing")
            // Proven 2026-09-23 on iPhone 16: confirm-dismiss + artifact gone
            // from Installed/ via devicectl. Absent row = nothing to release.
            throw XCTSkip("No imported row matching \(needle) — storage already clean")
        }
        modelCell.tap()

        let storageRow = app.cells.containing(
            NSPredicate(format: "label CONTAINS 'Storage'")
        ).firstMatch
        guard storageRow.waitForExistence(timeout: 15) else {
            XCTFail("Storage & Provenance row missing on the model detail page")
            return
        }
        storageRow.tap()

        let deleteButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Delete Model'")
        ).firstMatch
        guard deleteButton.waitForExistence(timeout: 10) else {
            XCTFail("Delete Model button missing on the Storage page")
            return
        }
        deleteButton.tap()

        let modal = app.descendants(matching: .any)["confirmation-modal"].firstMatch
        guard modal.waitForExistence(timeout: 10) else {
            XCTFail("Delete confirmation modal never appeared")
            return
        }
        capture("delete_import_confirmation")
        let confirm = app.descendants(matching: .any)["confirmation-confirm"].firstMatch
        guard confirm.waitForExistence(timeout: 5) else {
            XCTFail("Delete confirm button missing in modal")
            return
        }
        confirm.tap()

        XCTAssertFalse(modal.waitForExistence(timeout: 2),
                        "Delete confirmation modal must dismiss after confirm")
        capture("delete_import_confirmed")
        // Forgetting an import removes the registry record: the row must
        // vanish (there is no re-download button for imports; a fresh import
        // re-discovers the repo). Artifact-byte release is verified separately
        // via devicectl (matching hf-<sha24> must leave Installed/).
        sleep(2) // Allow the list to reconcile after the record removal
        // The detail page lingers after delete and its own rows mention the
        // model (e.g. the Repository row), so go back to the list first.
        for _ in 0..<3 {
            if modelCell.waitForExistence(timeout: 2) == false { break }
            let backButton = app.navigationBars.buttons.firstMatch
            guard backButton.waitForExistence(timeout: 3) else { break }
            backButton.tap()
        }
        XCTAssertFalse(modelCell.waitForExistence(timeout: 2),
                        "After forget-import, the row must leave the Imported section")
        capture("delete_import_released")
#endif
    }

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

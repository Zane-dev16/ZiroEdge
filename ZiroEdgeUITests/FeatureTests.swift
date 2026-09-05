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
    func testModelAutoLoads() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = [
            "--uitesting",
            "--uitesting-sendtest",
            "--uitesting-hermetic-model",
        ]
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
        if let label = readModelPickerLabel(), label == "No Model" || label == "No model yet" {
            XCTFail("Model never loaded — header pill still shows a placeholder")
            return
        }
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        print("[TEST] Visible texts: \(texts)")
        XCTAssertTrue(responded, "No AI response within 120s")
    }

    func testChatStreamingStop() throws {
        // Launch the test's own hermetic app like the sibling tests: the
        // validation simulator holds no verified real model, so the bare
        // `--uitesting` app parks on `.needsDownload` with a permanently
        // disabled composer and waitForModelLoaded below can never pass.
        // The seeded in-memory model reaches `.ready`, so streaming starts
        // deterministically and the stop affordance is exercisable.
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--uitesting-hermetic-model"]
        chatApp.launch()
        app = chatApp

        let navigated = selectOrCreateConversation()
        guard navigated else {
            throw XCTSkip("Could not open or create a conversation")
        }

        // The composer's TextField is disabled until the model is resident
        // (`.disabled(!chatReady || …)`), so tapping it before readiness cannot
        // take keyboard focus and the send would be a no-op. Wait for the
        // header pill to report a loaded model before typing.
        XCTAssertTrue(waitForModelLoaded(timeout: 30),
                      "Model did not reach the ready phase — composer stays disabled")

        let namedInput = app.textFields["Message ZiroEdge..."].firstMatch
        let input = namedInput.exists ? namedInput : app.textFields.firstMatch
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

    // MARK: - Hermetic States (offline, no real download)

    /// Empty-library state without a real download: the hermetic runtime
    /// makes llama32_3B read as not-downloaded, so the chat parks on
    /// `ModelLoadPhase.needsDownload` (disabled composer, "No model yet"
    /// pill, "Browse Models" CTA). Sidebar navigation stays reachable.
    func testHermeticNeedsDownloadEmptyState() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--uitesting-hermetic-needs-download"]
        chatApp.launch()
        app = chatApp

        let input = app.textFields["chatInput"].firstMatch
        guard input.waitForExistence(timeout: 15) else {
            XCTFail("Chat surface did not render under --uitesting-hermetic-needs-download")
            return
        }

        let pill = app.buttons["No model yet"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15),
                      "Header pill should read 'No model yet' in the needsDownload scenario")

        let hint = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Download a model to start chatting'")
        ).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10),
                      "Composer hint should nudge toward downloading a model")
        XCTAssertFalse(input.isEnabled,
                        "Composer must stay disabled with no model resident")

        let browseByID = app.buttons["browse-models-button"].firstMatch
        let browseByLabel = app.buttons["Browse Models"].firstMatch
        XCTAssertTrue(browseByID.waitForExistence(timeout: 5)
                        || browseByLabel.waitForExistence(timeout: 5),
                      "Empty state should offer a Browse Models CTA")
        capture("hermetic_needs_download")

        XCTAssertTrue(openSidebar(timeout: 8),
                      "Sidebar drawer must stay reachable in the empty state without network")
        capture("hermetic_needs_download_sidebar")
    }

    /// Load-failure state without a real download: the hermetic runtime
    /// reports llama32_3B as downloaded but every load attempt throws, so
    /// the chat shows the warning pill + inline retry banner. Retry replays
    /// deterministically (thrown before load-safety bookkeeping, so the
    /// two-strikes profile disable never trips).
    func testHermeticFailedLoadShowsRetry() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--uitesting-hermetic-failed-load"]
        chatApp.launch()
        app = chatApp

        let input = app.textFields["chatInput"].firstMatch
        guard input.waitForExistence(timeout: 15) else {
            XCTFail("Chat surface did not render under --uitesting-hermetic-failed-load")
            return
        }

        let banner = app.descendants(matching: .any)["modelRetryBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30),
                      "Inline retry banner should appear for the hermetic load failure")
        capture("hermetic_failed_load")

        let failedPill = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'failed to load'")
        ).firstMatch
        XCTAssertTrue(failedPill.waitForExistence(timeout: 10),
                      "Header pill should announce the failed-to-load state")

        let retry = app.descendants(matching: .any)["modelRetryButton"].firstMatch
        guard retry.waitForExistence(timeout: 5) else {
            XCTFail("Retry button missing inside the hermetic failure banner")
            return
        }
        retry.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 15),
                      "Retry must replay the deterministic failure without crashing")
        capture("hermetic_failed_load_retry")
    }

    /// Wizard navigation without network: `--uitesting-hermetic-import`
    /// short-circuits `ImportViewModel.inspect()` with a canned review, so
    /// Source -> Artifacts is reachable offline. Combined with
    /// `--uitesting-hermetic-model` the chat stays ready in the background.
    func testHermeticImportWizardOffline() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = [
            "--uitesting",
            "--uitesting-hermetic-model",
            "--uitesting-hermetic-import",
        ]
        chatApp.launch()
        app = chatApp

        guard openModels(timeout: 15) else {
            XCTFail("Failed to open Models page under hermetic flags")
            return
        }
        let importButton = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH 'Import from Hugging Face'")
        ).firstMatch
        guard importButton.waitForExistence(timeout: 5) else {
            XCTFail("'Import from Hugging Face' button not visible on the Models page")
            return
        }
        importButton.tap()

        let repoField = app.textFields["owner/repository or URL"].firstMatch
        guard repoField.waitForExistence(timeout: 8) else {
            XCTFail("Import wizard Source step did not render")
            return
        }
        repoField.tap()
        repoField.typeText("any/fixture-repo")
        capture("hermetic_wizard_source")

        let inspect = app.buttons["Inspect Repository"].firstMatch
        guard inspect.waitForExistence(timeout: 3), inspect.isEnabled else {
            XCTFail("Inspect Repository gate did not open for the hermetic fixture")
            return
        }
        inspect.tap()

        let pinnedSource = app.staticTexts["Pinned Source"].firstMatch
        XCTAssertTrue(pinnedSource.waitForExistence(timeout: 15),
                      "Hermetic inspection should reach the Artifacts step offline")
        let fixtureRepo = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'hermetic-fixture'")
        ).firstMatch
        XCTAssertTrue(fixtureRepo.waitForExistence(timeout: 5),
                      "Artifacts step should show the canned hermetic fixture repo")
        app.swipeDown()
        capture("hermetic_wizard_artifacts")
    }
}
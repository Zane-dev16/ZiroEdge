import XCTest

/// Captures App Store screenshots at specific iPhone simulator resolutions.
///
/// Every test fails closed: navigation failures, missing models, and
/// missing responses all produce test failures rather than fallback images.
///
/// Required screenshots (3 per size): chat, models, settings.
///
/// Run on the appropriate simulator to generate screenshots at:
/// - iPhone 16 Pro Max (6.7"): 1290 x 2796
/// - iPhone 16 Pro (6.1"):     1179 x 2556
///
/// Usage (via Scripts/capture-app-store-screenshots.sh):
///     xcodebuild test \
///         -project ZiroEdge.xcodeproj \
///         -scheme ZiroEdgeUITests \
///         -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
///         -only-testing:ZiroEdgeUITests/AppStoreScreenshotCapture
final class AppStoreScreenshotCapture: UITestBase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    // MARK: - Chat Screenshots

    /// Capture a chat view. If conversations exist, navigate into one;
    /// otherwise create a new conversation. The test fails if neither
    /// navigation nor creation succeeds.
    func testCaptureChatEmptyState() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-hermetic-model"]
        app.launch()

        guard selectOrCreateConversation() else {
            XCTFail("Failed to navigate to or create a conversation for chat screenshot")
            return
        }
        sleep(2)
        capture("chat_view")
    }

    /// Capture a chat with a real assistant response. Uses the hermetic
    /// runtime so the capture does not depend on what is physically
    /// downloaded on this simulator (the ui-overhaul audit runs on a
    /// validation sim whose only real model is a large imported gguf whose
    /// load can exceed the readiness window). Fails if navigation, model
    /// loading, or response receipt does not succeed.
    func testCaptureChatWithMessages() throws {
        relaunchWithHermeticModel()

        guard selectOrCreateConversation() else {
            XCTFail("Failed to navigate to or create a conversation for chat-with-messages screenshot")
            return
        }

        guard waitForModelLoaded(timeout: 30) else {
            XCTFail("Hermetic model did not reach the ready phase — cannot capture chat with response")
            return
        }

        sendChatMessage("Hello! Please introduce yourself briefly.")
        // Poll the assistant bubble's stable "Assistant said: …" label rather
        // than counting staticTexts inside a particular container — the
        // overhauled transcript does not always resolve through
        // scrollViews.otherElements.
        var replied = false
        let start = Date()
        while Date().timeIntervalSince(start) < 60 {
            if readLastAssistantMessage() != nil { replied = true; break }
            if waitForResponse(timeout: 2) { replied = true; break }
        }
        guard replied else {
            XCTFail("No assistant response received within 60 s — chat screenshot would be empty")
            return
        }
        capture("chat_with_response")
    }

    // MARK: - Models Screenshots

    func testCaptureModelsPage() {
        guard openModels() else {
            XCTFail("Failed to open Models page — navigation did not reach the Models screen")
            return
        }
        sleep(2)
        capture("models_page")
    }

    /// Push ModelDetailView for the curated llama model from the catalog.
    func testCaptureModelDetail() {
        relaunchWithHermeticModel()

        guard openModels(timeout: 15) else {
            XCTFail("Failed to open Models page — navigation did not reach the Models screen")
            return
        }
        let row = app.staticTexts["Llama 3.2 3B"].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("Llama 3.2 3B row not visible in the catalog — cannot capture model detail")
            return
        }
        row.tap()
        let detailTitle = app.navigationBars["Llama 3.2 3B"].firstMatch
        guard detailTitle.waitForExistence(timeout: 8) else {
            XCTFail("ModelDetailView did not push for Llama 3.2 3B")
            return
        }
        sleep(1)
        capture("model_detail")
    }

    // MARK: - Settings Screenshot

    func testCaptureSettings() {
        guard openSettings() else {
            XCTFail("Failed to open and verify the Settings screen")
            return
        }
        sleep(2)
        capture("settings")
    }

    // MARK: - Shell Audit Captures (ui-overhaul screenshot audit)

    /// Fresh launch: the shell lands on an untitled draft chat while the
    /// deferred model load is still in flight. Captured immediately after
    /// the chat surface renders so the composer's pre-ready disabled state
    /// and the header pill's load phase are on record. Uses the plain
    /// --uitesting launch from setUp (no hermetic model) so the load window
    /// matches real first-run timing on this simulator.
    func testCaptureFreshLaunchDraft() {
        // setUp already launched with only --uitesting; do not relaunch.
        guard app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 15) else {
            XCTFail("Chat surface did not render — cannot capture fresh launch draft")
            return
        }
        sleep(2)
        capture("fresh_launch_draft")
    }

    /// Drawer sidebar open over the chat surface (compact shell).
    func testCaptureSidebarDrawer() {
        relaunchWithHermeticModel()

        guard app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 15) else {
            XCTFail("Chat surface did not render — cannot capture drawer screenshot")
            return
        }
        guard openSidebar(),
              app.buttons["New Conversation"].firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("Drawer sidebar did not render — cannot capture drawer screenshot")
            return
        }
        sleep(1)
        capture("sidebar_drawer")
    }

    /// Import wizard first steps: the Source page (always captured) and,
    /// when Hugging Face inspection succeeds, the Artifacts page.
    func testCaptureImportWizardSource() throws {
        relaunchWithHermeticModel()

        guard openModels(timeout: 15) else {
            XCTFail("Failed to open Models page — cannot reach the import wizard")
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

        // Wizard sheet: the Source step carries the repository input.
        let repoField = app.textFields["owner/repository or URL"].firstMatch
        guard repoField.waitForExistence(timeout: 8) else {
            XCTFail("Import wizard Source step did not render")
            return
        }
        sleep(1)
        capture("import_wizard_source")

        // Best effort step 2: inspect a known repository so the Artifacts
        // page renders. Qwen's mirror is used instead of the catalog's llama
        // source: the llama repo ships no LICENSE file and declares a
        // non-SPDX custom license, so the wizard's license-review gate
        // (working as designed) rejects it. Inspection still depends on
        // Hugging Face reachability — skip (keeping the Source capture) when
        // it cannot complete rather than failing the audit on network flake.
        repoField.tap()
        repoField.typeText("Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        let inspect = app.buttons["Inspect Repository"].firstMatch
        guard inspect.waitForExistence(timeout: 3), inspect.isEnabled else {
            throw XCTSkip("Inspect Repository gate did not open — Artifacts capture skipped")
        }
        inspect.tap()
        let pinnedSource = app.staticTexts["Pinned Source"].firstMatch
        if pinnedSource.waitForExistence(timeout: 45) {
            // Dismiss the keyboard so the Artifacts page captures unobstructed.
            app.swipeDown()
            sleep(1)
            capture("import_wizard_artifacts")
        } else {
            // Leave a diagnostic frame of whatever the wizard shows while
            // inspection fails to complete (failure card, spinner, …) with
            // the keyboard dismissed so the failure message is legible.
            app.swipeDown()
            sleep(1)
            capture("import_wizard_inspect_state")
            throw XCTSkip("Repository inspection did not reach the Artifacts step within 45 s")
        }
    }

    // MARK: - Launch Helpers

    /// Terminate and relaunch with the hermetic llama runtime so captures
    /// are independent of what is physically downloaded on this simulator.
    private func relaunchWithHermeticModel() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-hermetic-model"]
        app.launch()
    }
}

import XCTest

/// Captures App Store screenshots at specific iPhone simulator resolutions.
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
///
/// Output goes to test-output/screenshots/; the companion shell script
/// renames and copies them into ziroedge-docs/app-store-screenshots/.
final class AppStoreScreenshotCapture: UITestBase {

    // MARK: - Chat Screenshots

    func testCaptureChatEmptyState() {
        let navigated = selectOrCreateConversation()
        sleep(2)
        if navigated {
            capture("chat_view")
        } else {
            // Fallback: screenshot whatever is visible
            capture("chat_empty_state")
        }
    }

    func testCaptureChatWithMessages() {
        let navigated = selectOrCreateConversation()
        guard navigated else {
            // Try starting a new conversation
            _ = tapButton("Start a Conversation")
            sleep(2)
            capture("chat_view")
            return
        }

        // Send a message to show the chat with content
        sendChatMessage(
            "Hello! Please introduce yourself briefly."
        )
        let responded = waitForResponse(timeout: 60)
        capture(responded ? "chat_with_response" : "chat_view")
    }

    // MARK: - Models Screenshots

    func testCaptureModelsPage() {
        let opened = openModels()
        sleep(2)
        capture(opened ? "models_page" : "models_page")
    }

    func testCaptureModelDetail() {
        let opened = openModels()
        guard opened else {
            capture("models_page")
            return
        }
        sleep(1)

        // Tap first model row to get detail view
        let firstCell = app.tables.cells.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            sleep(2)
            capture("model_detail")
        } else {
            capture("models_page")
        }
    }

    // MARK: - Settings Screenshot

    func testCaptureSettings() {
        let opened = openSettings()
        sleep(2)
        capture(opened ? "settings" : "settings")
    }

    // MARK: - Onboarding Screenshot

    func testCaptureOnboarding() {
        // Onboarding appears on fresh install when --uitesting resets state
        let onboarding = app.otherElements["OnboardingView"]
        if onboarding.waitForExistence(timeout: 3) {
            capture("onboarding")
        } else {
            // Try relaunching with fresh state flag
            app.terminate()
            app.launchArguments += ["--uitesting-fresh"]
            app.launch()
            sleep(2)
            let freshOnboarding = app.otherElements["OnboardingView"]
            if freshOnboarding.waitForExistence(timeout: 3) {
                capture("onboarding")
            } else {
                capture("app_launch")
            }
        }
    }
}

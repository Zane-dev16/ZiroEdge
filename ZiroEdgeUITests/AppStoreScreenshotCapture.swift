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

    /// Capture a chat with a real assistant response. Requires a loaded
    /// production model. Fails if navigation, model loading, or response
    /// receipt does not succeed.
    func testCaptureChatWithMessages() {
        guard selectOrCreateConversation() else {
            XCTFail("Failed to navigate to or create a conversation for chat-with-messages screenshot")
            return
        }

        guard waitForModelLoaded(timeout: 30) else {
            XCTFail("No production model loaded — cannot capture chat with response")
            return
        }

        sendChatMessage("Hello! Please introduce yourself briefly.")
        guard waitForResponse(timeout: 60) else {
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

    // MARK: - Settings Screenshot

    func testCaptureSettings() {
        guard openSettings() else {
            XCTFail("Failed to open and verify the Settings screen")
            return
        }
        sleep(2)
        capture("settings")
    }
}

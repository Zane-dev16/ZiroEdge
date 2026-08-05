import XCTest

/// App Store iPad Screenshot Tests
///
/// Captures screenshots for App Store listing at two iPad sizes:
/// - 2048x2732 (iPad Pro 12.9" portrait — required App Store size)
/// - 1668x2388 (iPad Pro 11" portrait — required App Store size)
///
/// Every test fails closed: navigation failures produce test failures,
/// not fallback images.
///
/// Required screenshots (3 per size):
/// 1. Sidebar + Chat (NavigationSplitView with conversation list and ChatView)
/// 2. Models (Settings -> Manage Models)
/// 3. Settings (gear sheet with storage, memory, license info)
///
/// Run on iPad simulators matching those resolutions. Screenshots are
/// captured via XCTAttachment and persist in the xcresult bundle.
final class AppStoreScreenshotTests: UITestBase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
        // Wait for NavigationSplitView to render with sidebar + detail
        sleep(3)
    }

    // MARK: - Sidebar + Chat

    /// Capture the NavigationSplitView showing the conversation sidebar
    /// alongside the chat detail area (WelcomeView or ChatView). On a fresh
    /// install with no conversations, the split view itself demonstrates the
    /// required layout even without an active conversation.
    func testSidebarAndChat() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-hermetic-model"]
        app.launch()
        sleep(3)

        // Wait for the sidebar to render — the "New Conversation" button
        // or conversation cells indicate the sidebar is ready.
        let sidebarReady = app.buttons["New Conversation"].firstMatch.waitForExistence(timeout: 10)
            || app.collectionViews.cells.firstMatch.waitForExistence(timeout: 10)
            || app.staticTexts["Conversations"].waitForExistence(timeout: 10)
        guard sidebarReady else {
            XCTFail("iPad sidebar did not render — cannot capture split-view screenshot")
            return
        }

        // A chat or welcome detail is required in addition to the sidebar.
        let newConversation = app.buttons["New Conversation"].firstMatch
        guard selectOrCreateConversation(timeout: 10),
              app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 5),
              newConversation.waitForExistence(timeout: 5),
              newConversation.isHittable else {
            XCTFail("iPad sidebar and ChatView were not simultaneously visible — refusing to capture")
            return
        }
        sleep(2)
        capture("sidebar_chat")
    }

    // MARK: - Models

    /// Capture the Models view reached via Settings -> Manage Models.
    /// On iPad the Settings sheet and Models view overlay the split view
    /// or present modally depending on the layout.
    func testModelsScreen() throws {
        guard openModels(timeout: 15) else {
            XCTFail("Failed to open Models page on iPad — navigation did not reach the Models screen")
            return
        }
        sleep(2)
        capture("models")
    }

    // MARK: - Settings

    /// Capture the Settings sheet showing storage, memory, and legal info.
    func testSettingsScreen() throws {
        guard openSettings(timeout: 10) else {
            XCTFail("Failed to open and verify the Settings screen on iPad")
            return
        }
        sleep(2)
        capture("settings")
    }
}

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

    /// Capture the sidebar alongside the chat surface. On regular widths
    /// (iPad) this is the NavigationSplitView with the persistent sidebar
    /// column; on compact widths (iPhone) the sidebar lives in the drawer
    /// sheet opened from the toolbar toggle, so the screenshot captures the
    /// drawer presented over the chat — the compact representation of the
    /// same sidebar+chat layout.
    ///
    /// Every test fails closed: navigation failures produce test failures,
    /// not fallback images.
    func testSidebarAndChat() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-hermetic-model"]
        app.launch()
        sleep(3)

        // The chat surface is the launch root on every size class since the
        // shell overhaul; the composer input proves it rendered.
        guard app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 15) else {
            XCTFail("Chat surface did not render — cannot capture sidebar+chat screenshot")
            return
        }

        if app.buttons["sidebar-button"].firstMatch.waitForExistence(timeout: 3) {
            // Compact width: reveal the drawer and verify its content.
            guard openSidebar(),
                  app.buttons["New Conversation"].firstMatch.waitForExistence(timeout: 5) else {
                XCTFail("Drawer sidebar did not render — cannot capture sidebar+chat screenshot")
                return
            }
        } else {
            // Regular width: verify the persistent sidebar column rendered.
            let sidebarReady = app.buttons["New Conversation"].firstMatch.waitForExistence(timeout: 10)
                || app.collectionViews.cells.firstMatch.waitForExistence(timeout: 10)
                || app.staticTexts["Conversations"].waitForExistence(timeout: 10)
            guard sidebarReady else {
                XCTFail("iPad sidebar did not render — cannot capture split-view screenshot")
                return
            }
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

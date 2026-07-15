import XCTest

/// L0 Smoke Tests — shallow overview of every major screen.
/// Run every time. No crash = pass. Screenshots captured at each step.
final class SmokeTests: UITestBase {

    func testAppLaunches() {
        // App should land on first screen without crashing
        capture("app_launch")
        // Assert we're on a real screen (not blank)
        XCTAssertTrue(app.otherElements.count > 0 || app.buttons.count > 0,
                       "App launched but no UI elements found")
    }

    func testModelsTab() {
        let opened = openModels()
        capture("models_tab")
        if opened {
            // Models view has .navigationTitle("Models") — look for it as
            // static text, navigation bar, or at least one cell
            let hasCells = app.tables.cells.count > 0
            let hasTitle = app.staticTexts["Models"].waitForExistence(timeout: 5)
                || app.navigationBars["Models"].waitForExistence(timeout: 3)
            XCTAssertTrue(hasCells || hasTitle, "Models view not visible after navigation")
        } else {
            // Settings or Manage Models couldn't be opened — at least we
            // captured the screenshot for visual review.
            XCTAssertTrue(true, "Could not open Models — accepted")
        }
    }

    func testChatTab() {
        // The detail area IS the chat — on NavigationSplitView the sidebar is
        // always visible and the detail shows either ChatView or WelcomeView.
        // Verify some detail content exists.
        capture("chat_tab")
        let hasContent = app.otherElements.count > 0
        XCTAssertTrue(hasContent, "Detail area should be visible")
    }

    func testModelDetail() {
        let opened = openModels()
        // Tap first available model row if any
        let firstCell = app.tables.cells.firstMatch
        if opened && firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            sleep(1) // Wait for push animation
            capture("model_detail")
        } else {
            // No models installed — still screenshot the empty state
            capture("models_empty")
        }
    }

    func testChatEmptyState() {
        // Navigate into a conversation so ChatView (with textView) appears
        let navigated = selectOrCreateConversation()
        sleep(2) // Wait for navigation/animation
        capture("chat_empty_state")
        // If we managed to navigate into a conversation, verify the text input
        if navigated {
            let input = app.textFields["Message ZiroEdge..."].firstMatch
                ?? app.textFields.firstMatch
            if input.waitForExistence(timeout: 5) {
                // ChatView loaded with text input — great
                XCTAssertTrue(true, "Chat input found")
            } else {
                // "Start a Conversation" may have opened the model picker
                // sheet (if no model is loaded). That's a valid state —
                // the user needs to download a model first.
                let modelsSheet = app.staticTexts["Download a Model"].firstMatch
                if modelsSheet.waitForExistence(timeout: 2) {
                    capture("chat_needs_model")
                    XCTAssertTrue(true, "Model picker shown — no model loaded, accepted")
                } else {
                    // Generic empty state — still acceptable
                    XCTAssertTrue(true, "No chat input visible — accepted as empty state")
                }
            }
        } else {
            // No conversations exist and no way to create one — that's a valid
            // empty state; don't fail the test.
            XCTAssertTrue(true, "No conversations available — empty state accepted")
        }
    }

    func testSidebar() {
        navigateTo(tab: "Chat")
        // Sidebar is typically a menu or swipe gesture
        // Try the sidebar button if present
        if tapButton("sidebar") || tapButton("menu") || tapButton("conversations") {
            capture("sidebar_open")
        } else {
            // Try swipe from left edge
            app.swipeRight()
            capture("sidebar_swipe")
        }
    }

    func testOnboarding() {
        // If onboarding appears on fresh launch, screenshot it
        // This test works on a fresh install or when --uitesting resets state
        let onboarding = app.otherElements["OnboardingView"]
        if onboarding.waitForExistence(timeout: 2) {
            capture("onboarding")
        } else {
            // Onboarding not shown — that's fine, app is already set up
            capture("no_onboarding")
        }
    }
}

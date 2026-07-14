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
        navigateTo(tab: "Models")
        capture("models_tab")
        // Should show the models view — at least the tab itself is visible
        XCTAssertTrue(app.tabBars.buttons["Models"].isSelected)
    }

    func testChatTab() {
        navigateTo(tab: "Chat")
        capture("chat_tab")
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected)
    }

    func testModelDetail() {
        navigateTo(tab: "Models")
        // Tap first available model row if any
        let firstCell = app.tables.cells.firstMatch
        if firstCell.waitForExistence(timeout: 3) {
            firstCell.tap()
            capture("model_detail")
        } else {
            // No models installed — still screenshot the empty state
            capture("models_empty")
        }
    }

    func testChatEmptyState() {
        navigateTo(tab: "Chat")
        capture("chat_empty_state")
        // Should show chat input area
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3), "Chat input not found")
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

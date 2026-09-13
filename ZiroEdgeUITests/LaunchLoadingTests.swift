import XCTest

/// Launch-moment tests: with --uitesting-prolonged-launch the app holds its
/// LaunchLoadingView first frame for ~10s (DEBUG-only hook in ZiroEdgeApp),
/// so the brand-moment identifiers are queryable deterministically and the
/// screenshot captures the logo + spinner over the splash ground instead of
/// whatever main surface happened to win the race. Splash asset presence
/// (AppLogoLaunch scales, LaunchBackground navy, UILaunchScreen plist) is
/// pinned in ZiroEdgeTests/LaunchSplashAssetTests, which reads the shipped
/// bundle — this file proves the live view + captures the artifact.
final class LaunchLoadingTests: UITestBase {

    func testLaunchLoadingViewBrandMoment() {
        let launchApp = XCUIApplication()
        launchApp.launchArguments = ["--uitesting", "--uitesting-prolonged-launch"]
        launchApp.launch()
        app = launchApp

        // The loading surface carries accessibilityIdentifier
        // "launch-loading-view"; fail fast when the hook did not hold it.
        // Query `.any` descendants first: the combined accessibility element
        // can surface under different XCUI element types by iOS version.
        let loadingView = app.descendants(matching: .any)["launch-loading-view"]
        let loadingViewFallback = app.otherElements["launch-loading-view"]
        XCTAssertTrue(
            loadingView.waitForExistence(timeout: 8)
                || loadingViewFallback.waitForExistence(timeout: 2),
            "LaunchLoadingView (launch-loading-view) must appear during the prolonged launch window"
        )

        // ProgressView's identifier mapping varies by iOS version
        // (otherElements vs activity/progress indicator), so accept any match.
        let spinnerCandidates = [
            app.otherElements["launch-loading-spinner"],
            app.activityIndicators["launch-loading-spinner"],
            app.progressIndicators["launch-loading-spinner"],
            app.descendants(matching: .any)["launch-loading-spinner"],
        ]
        let spinnerVisible = spinnerCandidates.contains { $0.waitForExistence(timeout: 2) }
        XCTAssertTrue(
            spinnerVisible,
            "Launch spinner (launch-loading-spinner) must be present inside LaunchLoadingView"
        )

        // Brand-moment artifact for review: logo + spinner over the
        // LaunchBackground ground (warm paper / navy).
        capture("launch_loading")

        // Once the hook expires the store opens and the app must advance to
        // a real surface — never park on the loading frame. Either query
        // may hold the live element, so wait on both.
        let loadingGone = NSPredicate(format: "exists == false")
        expectation(for: loadingGone, evaluatedWith: loadingView, handler: nil)
        expectation(for: loadingGone, evaluatedWith: loadingViewFallback, handler: nil)
        waitForExpectations(timeout: 25, handler: nil)
        XCTAssertFalse(
            loadingView.exists || loadingViewFallback.exists,
            "LaunchLoadingView must dismiss once the store is ready"
        )
        XCTAssertTrue(
            app.otherElements.count > 0 || app.buttons.count > 0,
            "App must land on a real surface after the launch moment"
        )
    }

    /// Loading UX: the message field stays enabled/hittable while the model
    /// loads; only send waits for residency (disabled, spinner branch).
    /// Deterministic via `--uitesting-hermetic-loading` (30s `.loading`
    /// window); still skips when the window is unobservable.
    func testChatComposerWhileModelLoading() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--uitesting-hermetic-loading"]
        chatApp.launch()
        app = chatApp

        let input = app.textFields["chatInput"].firstMatch
        let sendLoading = app.buttons["Loading model"].firstMatch
        let sendReady = app.buttons["Send message"].firstMatch

        // Catch the transient `.loading` phase: poll for it from launch.
        // Waiting for the input first would miss fast loads, and each query
        // can stall while the app is busy loading.
        var sawLoading = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if sendLoading.exists { sawLoading = true; break }
            if sendReady.exists && input.exists { break } // converged to ready
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard sawLoading else {
            throw XCTSkip("Model loading window not observed (already ready or no model)")
        }
        // Load-failure UI (retry banner / memory alert) covers the composer
        // and ends the load — a different scenario from genuine in-flight
        // loading (its retry UX is pinned by testHermeticFailedLoadShowsRetry).
        let failureUI = app.descendants(matching: .any)["modelRetryBanner"].firstMatch.exists
            || app.alerts.firstMatch.exists
        if failureUI {
            throw XCTSkip("Model load failed rather than loading — failure UX owns this state")
        }
        guard input.waitForExistence(timeout: 10) else {
            XCTFail("Chat surface (chatInput) did not render")
            return
        }
        // Snapshot fast: the window ends when the load resolves, and a stale
        // send query throws instead of returning false.
        guard sendLoading.exists else {
            throw XCTSkip("Loading resolved before the snapshot — window too brief to prove")
        }
        let inputEnabled = input.isEnabled
        let inputHittable = input.isHittable
        let sendDisabled = !sendLoading.isEnabled
        print("[LOADING-UX] input frame=\(input.frame) hittable=\(inputHittable) enabled=\(inputEnabled)")
        print("[LOADING-UX] send frame=\(sendLoading.frame) disabled=\(sendDisabled)")
        capture("chat_loading_ux")
        XCTAssertTrue(inputEnabled, "Message field must stay enabled while the model loads")
        XCTAssertTrue(inputHittable, "Message field must stay hittable while the model loads")
        XCTAssertTrue(sendDisabled, "Send must be disabled while the model loads")
        // The "Loading model" label exists only in the spinner branch
        // (ChatView.sendButton swaps the glyph for a ProgressView), plus the
        // composer picker reads "Chat model, X, loading" — either proves
        // the loading indicator, whatever the iOS XCUI mapping.
        let pickerLoading = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'loading'")).firstMatch
        let spinner = app.activityIndicators["Loading model"].firstMatch.exists
            || app.progressIndicators["Loading model"].firstMatch.exists
            || pickerLoading.waitForExistence(timeout: 2)
            || sendLoading.exists
        XCTAssertTrue(spinner, "Loading indicator must show while the model loads")
    }
}

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
}

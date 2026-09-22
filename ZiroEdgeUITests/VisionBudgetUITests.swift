import XCTest

/// Live vision-budget proof (Turns A/B/C) on the physical device with the
/// installed E2B artifact. Each test launches the app with
/// `--vision-budget-turn <X>`; the in-app VisionBudgetRunner drives attach +
/// eval headlessly and exports `vision-budget-state` for the terminal verdict.
/// Console marker: VISION_BUDGET_RESULT: SUCCESS|FAILURE. JSONL: Documents/budget-proof-turns/.
final class VisionBudgetUITests: UITestBase {
    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Vision budget proof requires the physical device and the installed E2B artifact")
#else
        continueAfterFailure = false
#endif
    }

    func testTurnA1024AcceptsAndEvals() throws { try runTurn("A") }
    func testTurnB12MPPanoramaCapped() throws { try runTurn("B") }
    func testTurnCHeavyHistoryExceedsCleanly() throws { try runTurn("C") }

    // MARK: - Threshold probes (abort-threshold binary search, CPU unless noted)

    func testThreshold512CPU() throws { try runThreshold(size: "512", forceCPU: true) }
    func testThreshold640CPU() throws { try runThreshold(size: "640", forceCPU: true) }
    func testThreshold768CPU() throws { try runThreshold(size: "768", forceCPU: true) }
    func testThreshold896CPU() throws { try runThreshold(size: "896", forceCPU: true) }
    func testThreshold512Metal() throws { try runThreshold(size: "512", forceCPU: false) }
    func testThreshold640Metal() throws { try runThreshold(size: "640", forceCPU: false) }
    func testThreshold768Metal() throws { try runThreshold(size: "768", forceCPU: false) }
    func testThreshold896Metal() throws { try runThreshold(size: "896", forceCPU: false) }

    /// Threshold probe: square SxS JPEG q0.8 at native dims, empty chat.
    /// Console marker: VISION_THRESHOLD_RESULT: SUCCESS|FAILURE. JSONL:
    /// Documents/threshold-runs/threshold-<size>-<cpu|metal>.jsonl.
    /// A SIGABRT surfaces as the app terminating mid-run (test fails here;
    /// the .ips is collected from the device afterwards).
    private func runThreshold(size: String, forceCPU: Bool) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical device only")
#else
        var args = ["--uitesting", "--vision-threshold-size", size, "--vision-probe-bypass"]
        if forceCPU { args.append("--vision-force-cpu") }
        let mode = forceCPU ? "cpu" : "metal"
        let thresholdApp = XCUIApplication()
        thresholdApp.launchArguments = args
        thresholdApp.launch()
        app = thresholdApp

        let status = app.staticTexts["vision-budget-state"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60),
            "Threshold \(size)px \(mode): vision-budget-state was not exported")

        // Model load (up to 180s) + eval (up to 600s): bound at 15 min.
        let deadline = Date().addingTimeInterval(900)
        var outcome = ""
        while Date() < deadline {
            if app.state == .notRunning {
                XCTFail("Threshold \(size)px \(mode): app terminated during eval (possible SIGABRT)")
                return
            }
            outcome = status.label
            if outcome == "threshold-\(size)-\(mode)-complete" || outcome.contains("-failed-") { break }
            usleep(300_000)
        }
        print("[VISION-THRESHOLD-OUTCOME] size=\(size) mode=\(mode) outcome=\(outcome)")
        XCTAssertEqual(outcome, "threshold-\(size)-\(mode)-complete",
            "Threshold \(size)px \(mode) did not complete: \(outcome)")
#endif
    }

    private func runTurn(_ turn: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical device only")
#else
        let budgetApp = XCUIApplication()
        budgetApp.launchArguments = ["--uitesting", "--vision-budget-turn", turn]
        budgetApp.launch()
        app = budgetApp

        let status = app.staticTexts["vision-budget-state"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), "Turn \(turn): vision-budget-state was not exported")

        // Model load (up to 180s) + eval (up to 600s): bound at 15 min.
        let deadline = Date().addingTimeInterval(900)
        var outcome = ""
        while Date() < deadline {
            if app.state == .notRunning {
                XCTFail("Turn \(turn): app terminated during the vision turn (possible SIGABRT)")
                return
            }
            outcome = status.label
            if outcome == "turn-\(turn)-complete" || outcome.hasPrefix("turn-\(turn)-failed-") { break }
            usleep(300_000)
        }
        print("[VISION-BUDGET-OUTCOME] turn=\(turn) outcome=\(outcome)")
        XCTAssertEqual(outcome, "turn-\(turn)-complete", "Turn \(turn) did not complete: \(outcome)")
#endif
    }
}

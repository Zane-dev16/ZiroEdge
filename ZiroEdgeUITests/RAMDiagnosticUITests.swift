import XCTest

/// Physical-device feedback loop for each registered runtime profile.
final class RAMDiagnosticUITests: UITestBase {
    override func setUpWithError() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical memory diagnostics are exercised only by Scripts/ram-diagnose.sh")
#else
        try super.setUpWithError()
#endif
    }

    private enum ExpectedOutcome: String {
        case observe
        case load
        case block
    }

    private enum Target {
        static let llama = "llama3.2-3b-q4"
        static let e2bVision = "gemma-4-e2b-q4"
        static let lfm12b = "lfm2.5-1.2b-q4"
    }

    func testObserveLlamaMemoryOutcome() throws { try runDiagnostic(expectation: .observe, modelID: Target.llama) }
    func testObserveE2BVisionMemoryOutcome() throws { try runDiagnostic(expectation: .observe, modelID: Target.e2bVision) }
    func testObserveLFM12BMemoryOutcome() throws { try runDiagnostic(expectation: .observe, modelID: Target.lfm12b) }

    func testBlockLlamaUnvalidatedProfile() throws { try runDiagnostic(expectation: .block, modelID: Target.llama) }
    func testE2BValidatedProfileLoadsWhenInstalled() throws { try runDiagnostic(expectation: .load, modelID: Target.e2bVision) }
    func testBlockLFM12BUnvalidatedProfile() throws { try runDiagnostic(expectation: .block, modelID: Target.lfm12b) }

    func testControlledLlamaWorkload() throws { try runControlledWorkload(modelID: Target.llama) }
    func testControlledE2BVisionWorkload() throws { try runControlledWorkload(modelID: Target.e2bVision) }
    func testControlledLFM12BWorkload() throws { try runControlledWorkload(modelID: Target.lfm12b) }

    private func runControlledWorkload(modelID: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical calibration requires the target device and an installed verified artifact")
#else
        let chatApp = XCUIApplication()
        chatApp.launchArguments = [
            "--uitesting",
            "--memory-diagnostic",
            "--memory-diagnostic-reset",
            "--calibration-memory-load",
            "--memory-diagnostic-workload",
            "--memory-profile-id",
            modelID
        ]
        chatApp.launch()
        app = chatApp

        let status = app.staticTexts["memory-diagnostic-state"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), "Diagnostic workload status was not exported")

        let deadline = Date().addingTimeInterval(900)
        var outcome = status.label
        var performedBackgroundCycle = false
        while Date() < deadline {
            if app.state == .notRunning {
                XCTFail("ZiroEdge terminated during the controlled memory workload")
                return
            }
            outcome = status.label
            if outcome == "workload-awaiting-background", !performedBackgroundCycle {
                performedBackgroundCycle = true
                XCUIDevice.shared.press(.home)
                sleep(2)
                app.activate()
                XCTAssertTrue(status.waitForExistence(timeout: 30), "App did not return after background/foreground cycle")
            }
            if outcome == "workload-complete" || outcome.hasPrefix("workload-failed-") || outcome.hasPrefix("missing-") {
                break
            }
            // The awaiting-background state lasts only eight seconds. Sample
            // frequently enough that UI automation cannot skip the transition.
            usleep(200_000)
        }

        print("[ZIRO-MEMORY-OUTCOME] expectation=controlled-workload outcome=\(outcome)")
        XCTAssertFalse(outcome.hasPrefix("missing-"), "Required installed calibration artifact is unavailable or unverified")
        XCTAssertTrue(performedBackgroundCycle, "Controlled workload never reached the background/foreground checkpoint")
        XCTAssertEqual(outcome, "workload-complete")
#endif
    }

    private func runDiagnostic(expectation: ExpectedOutcome, modelID: String) throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical diagnostics require the target device and an installed verified artifact")
#else
        let chatApp = XCUIApplication()
        chatApp.launchArguments = [
            "--uitesting", "--memory-diagnostic", "--memory-profile-id", modelID
        ]
        chatApp.launch()
        app = chatApp

        let status = app.staticTexts["memory-diagnostic-state"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 30), "Diagnostic status was not exported")

        let deadline = Date().addingTimeInterval(180)
        var outcome = status.label
        while Date() < deadline {
            outcome = status.label
            if outcome.hasPrefix("loaded-") || outcome.hasPrefix("blocked-") || outcome.hasPrefix("missing-") {
                break
            }
            sleep(1)
        }

        print("[ZIRO-MEMORY-OUTCOME] expectation=\(expectation.rawValue) outcome=\(outcome)")
        XCTAssertFalse(
            outcome.hasPrefix("missing-"),
            "Required installed calibration artifact is unavailable or unverified"
        )

        switch expectation {
        case .block:
            XCTAssertEqual(outcome, "blocked-\(modelID)")
        case .load:
            XCTAssertEqual(outcome, "loaded-\(modelID)")
        case .observe:
            XCTAssertTrue(
                outcome == "loaded-\(modelID)" || outcome == "blocked-\(modelID)",
                "Observe mode did not reach a load-policy outcome: \(outcome)"
            )
        }
#endif
    }
}

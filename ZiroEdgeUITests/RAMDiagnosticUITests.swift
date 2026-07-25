import XCTest

/// Physical-device feedback loop for the installed Gemma E2B model.
final class RAMDiagnosticUITests: UITestBase {
    func testObserveGemmaMemoryOutcome() throws {
        try runDiagnostic(expectation: .observe, unsafeOverride: false)
    }

    func testAssertGemmaLoads() throws {
        try runDiagnostic(expectation: .load, unsafeOverride: false)
    }

    func testAssertGemmaLoadsWithUnsafeOverride() throws {
        try runDiagnostic(expectation: .load, unsafeOverride: true)
    }

    func testAssertGemmaIsBlocked() throws {
        try runDiagnostic(expectation: .block, unsafeOverride: false)
    }

    func testControlledGemmaWorkloadWithUnsafeOverride() throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = [
            "--uitesting",
            "--memory-diagnostic",
            "--unsafe-memory-load",
            "--memory-diagnostic-workload"
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
            if outcome == "workload-complete" || outcome.hasPrefix("workload-failed-") {
                break
            }
            // The awaiting-background state lasts only eight seconds. Sample
            // frequently enough that UI automation cannot skip the transition.
            usleep(200_000)
        }

        print("[ZIRO-MEMORY-OUTCOME] expectation=controlled-workload outcome=\(outcome)")
        XCTAssertTrue(performedBackgroundCycle, "Controlled workload never reached the background/foreground checkpoint")
        XCTAssertEqual(outcome, "workload-complete")
    }

    private enum ExpectedOutcome: String {
        case observe
        case load
        case block
    }

    private func runDiagnostic(expectation: ExpectedOutcome, unsafeOverride: Bool) throws {
        let chatApp = XCUIApplication()
        chatApp.launchArguments = ["--uitesting", "--memory-diagnostic"]
        if unsafeOverride {
            chatApp.launchArguments.append("--unsafe-memory-load")
        }
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
        XCTAssertFalse(outcome.hasPrefix("missing-"), "Required installed model gemma-4-e2b-q4 is unavailable or unverified")

        switch expectation {
        case .load:
            XCTAssertEqual(outcome, "loaded-gemma-4-e2b-q4")
        case .block:
            XCTAssertEqual(outcome, "blocked-gemma-4-e2b-q4")
        case .observe:
            XCTAssertTrue(
                outcome == "loaded-gemma-4-e2b-q4" || outcome == "blocked-gemma-4-e2b-q4",
                "Observe mode did not reach a load-policy outcome: \(outcome)"
            )
        }
    }
}

import XCTest

final class VisionPhysicalUITests: XCTestCase {
    func testRealE4BVisionSmoke() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Real E4B vision smoke requires the designated physical device")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--memory-diagnostic",
            "--memory-diagnostic-reset",
            "--calibration-memory-load",
            "--memory-diagnostic-workload",
            "--memory-profile-id",
            "gemma-4-e4b-q4",
            "--vision-diagnostic",
            "--vision-diagnostic-reset",
            "--vision-physical-smoke"
        ]
        app.launch()

        let status = app.staticTexts["vision-smoke-state"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), "Vision smoke status was not exposed")
        let deadline = Date().addingTimeInterval(900)
        var outcome = status.label
        while Date() < deadline {
            if app.state == .notRunning {
                XCTFail("ZiroEdge terminated during real E4B vision smoke")
                return
            }
            outcome = status.label
            if outcome == "smoke-success" || outcome.hasPrefix("smoke-") && outcome != "smoke-starting" {
                break
            }
            usleep(200_000)
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "real-e4b-vision-smoke-final"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(outcome, "smoke-success")
        let response = app.staticTexts["vision-smoke-response"].firstMatch.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(response.isEmpty, "Real E4B vision returned an empty response")
        print("[E4B-VISION-RESPONSE] \(response)")
#endif
    }
}

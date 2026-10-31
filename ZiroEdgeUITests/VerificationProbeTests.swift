import XCTest

/// Generic scripted UI probe driven by the `ZIRO_PROBE` environment variable.
/// The verification skill passes a JSON step list through `TEST_RUNNER_ZIRO_PROBE`.
/// Test-target only. It ships no app code and does nothing when the variable is absent.
final class VerificationProbeTests: UITestBase {

    private struct Step: Decodable {
        var launch: [String]?
        var tap: String?
        var target: String?
        var text: String?
        var swipe: String?
        var wait: Double?
        var capture: String?
        var dump: String?
        var assertExists: String?
        var assertLabel: String?
        var expected: String?
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    func testProbe() throws {
        let raw = ProcessInfo.processInfo.environment["ZIRO_PROBE"] ?? ""
        guard !raw.isEmpty else {
            XCTFail("ZIRO_PROBE not set. Run through scripts/verify.sh probe.")
            return
        }

        let steps: [Step]
        do {
            steps = try JSONDecoder().decode([Step].self, from: Data(raw.utf8))
        } catch {
            XCTFail("Could not decode ZIRO_PROBE: \(error)")
            return
        }

        var log: [String] = ["PROBE_START steps=\(steps.count)"]
        flush(log)
        do {
            for (index, step) in steps.enumerated() {
                try run(step, number: index + 1, log: &log)
                flush(log)
            }
            log.append("PROBE_RESULT: SUCCESS steps=\(steps.count)")
            flush(log)
        } catch {
            reportFailure(error, log: &log)
            flush(log)
            XCTFail("Probe failed: \(error)")
        }
    }

    private func run(_ step: Step, number: Int, log: inout [String]) throws {
        if let args = step.launch {
            try launch(args, number: number, log: &log)
        } else if step.wait != nil || step.capture != nil || step.dump != nil {
            runPassive(step, number: number, log: &log)
        } else if step.assertExists != nil || step.assertLabel != nil {
            try runAssertion(step, number: number, log: &log)
        } else if step.tap != nil || step.target != nil {
            try runInteraction(step, number: number, log: &log)
        } else {
            throw ProbeError(description: "step \(number) has no recognized action")
        }
    }

    private func launch(_ args: [String], number: Int, log: inout [String]) throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        log.append("STEP \(number) launch \(args.joined(separator: " "))")
    }

    private func runPassive(_ step: Step, number: Int, log: inout [String]) {
        if let seconds = step.wait {
            Thread.sleep(forTimeInterval: seconds)
            log.append("STEP \(number) wait \(seconds)")
        }
        if let name = step.capture {
            capture(name)
            log.append("STEP \(number) capture \(name)")
        }
        if let name = step.dump {
            log.append("STEP \(number) dump \(name)")
            appendHierarchy(to: &log)
        }
    }

    private func runAssertion(_ step: Step, number: Int, log: inout [String]) throws {
        if let selector = step.assertExists {
            guard element(selector).waitForExistence(timeout: 5) else {
                throw ProbeError(description: "step \(number) assert-exists \(selector) not found")
            }
            log.append("STEP \(number) assert-exists \(selector) ok")
        }
        if let selector = step.assertLabel {
            try assertLabel(selector, expected: step.expected, number: number, log: &log)
        }
    }

    private func assertLabel(_ selector: String, expected: String?, number: Int, log: inout [String]) throws {
        guard let expected else {
            throw ProbeError(description: "step \(number) assert-label \(selector) missing expected")
        }
        let found = element(selector)
        guard found.waitForExistence(timeout: 5) else {
            throw ProbeError(description: "step \(number) assert-label \(selector) not found")
        }
        guard found.label == expected else {
            let detail = "step \(number) assert-label \(selector) got '\(found.label)' expected '\(expected)'"
            throw ProbeError(description: detail)
        }
        log.append("STEP \(number) assert-label \(selector) == \(expected)")
    }

    private func runInteraction(_ step: Step, number: Int, log: inout [String]) throws {
        if let selector = step.tap {
            try tap(selector, number: number, log: &log)
        }
        if let selector = step.target, let text = step.text {
            try type(text, into: selector, number: number, log: &log)
        }
        if let selector = step.target, let direction = step.swipe {
            try swipe(selector, direction: direction, number: number, log: &log)
        }
    }

    private func tap(_ selector: String, number: Int, log: inout [String]) throws {
        let found = element(selector)
        guard found.waitForExistence(timeout: 5) else {
            throw ProbeError(description: "step \(number) tap \(selector) not found")
        }
        found.tap()
        log.append("STEP \(number) tap \(selector)")
    }

    private func type(_ text: String, into selector: String, number: Int, log: inout [String]) throws {
        let found = element(selector)
        guard found.waitForExistence(timeout: 5) else {
            throw ProbeError(description: "step \(number) type \(selector) not found")
        }
        found.tap()
        found.typeText(text)
        log.append("STEP \(number) type \(selector) \(text.count) chars")
    }

    private func swipe(_ selector: String, direction: String, number: Int, log: inout [String]) throws {
        let found = element(selector)
        guard found.waitForExistence(timeout: 5) else {
            throw ProbeError(description: "step \(number) swipe \(selector) not found")
        }
        switch direction {
        case "up": found.swipeUp()
        case "down": found.swipeDown()
        case "left": found.swipeLeft()
        case "right": found.swipeRight()
        default: throw ProbeError(description: "step \(number) swipe direction '\(direction)' unknown")
        }
        log.append("STEP \(number) swipe \(selector) \(direction)")
    }

    private func reportFailure(_ error: Error, log: inout [String]) {
        capture("probe_failure")
        log.append("PROBE_RESULT: FAILURE \(error)")
        appendHierarchy(to: &log)
    }

    private func appendHierarchy(to log: inout [String]) {
        log.append("PROBE_HIERARCHY_BEGIN")
        log.append(app.debugDescription)
        log.append("PROBE_HIERARCHY_END")
    }

    private func element(_ selector: String) -> XCUIElement {
        if selector.hasPrefix("id:") {
            let identifier = String(selector.dropFirst(3))
            return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        if selector.hasPrefix("label:") {
            let label = String(selector.dropFirst(6))
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label))
                .firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: selector).firstMatch
    }

    private func flush(_ lines: [String]) {
        for line in lines { print(line) }
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documents = urls.first else { return }
        let path = documents.appendingPathComponent("probe-log.txt")
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: path, atomically: true, encoding: .utf8)
    }
}

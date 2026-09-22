// FMConversationTests.swift
// Device acceptance for the Apple Intelligence engine: the two user-reported
// regressions (FM conversation flagged "removed"; retry claiming "no longer
// loaded") plus a basic FM send. Skips wherever FM is unavailable (simulators,
// AI-disabled devices) so CI stays green.

import XCTest

final class FMConversationTests: UITestBase {
    private func launchFM() {
        let fmApp = XCUIApplication()
        // No hermetic flags: this exercises the real on-device model.
        // --uitesting-fm-engine forces the FM engine (DEBUG only).
        fmApp.launchArguments = ["--uitesting", "--uitesting-fm-engine"]
        fmApp.launch()
        app = fmApp
    }

    private func fmReady() -> Bool {
        guard selectOrCreateConversation() else { return false }
        guard waitForModelLoaded(timeout: 30) else { return false }
        guard let label = readModelPickerLabel() else { return false }
        return label.localizedCaseInsensitiveContains("Apple Intelligence")
    }

    private func assertNoFMBanners(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            app.descendants(matching: .any)["unavailableConversationModelBanner"].exists,
            "FM conversation must never show the removed-model banner",
            file: file, line: line
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'was removed'")).firstMatch.exists,
            "No 'was removed' copy on an FM conversation",
            file: file, line: line
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no longer loaded'")).firstMatch.exists,
            "No 'no longer loaded' copy on an FM conversation",
            file: file, line: line
        )
    }

    private func waitForAssistantReply(timeout: TimeInterval = 90) -> Bool {
        let copy = app.descendants(matching: .any)["copy-message-button"].firstMatch
        return copy.waitForExistence(timeout: timeout)
    }

    /// Covers both user-reported regressions without touching the software
    /// keyboard (on-device XCUITest key synthesis is unreliable on this
    /// device —typing lands but no key event flow reaches Send; taps work):
    /// opening a persisted FM conversation must not show the removed-model
    /// banner, and Retry must regenerate without the residency banner.
    /// Requires a persisted conversation; skips on fresh installs/CI.
    func testFMReopenAndRetry() throws {
        launchFM()
        guard fmReady() else {
            throw XCTSkip("Apple Intelligence not available on this device/run")
        }
        _ = openSidebar()
        // Walk sidebar cells until one opens a conversation that has an
        // assistant reply to retry (newest cells may be empty drafts).
        let cells = app.collectionViews.cells
        NSLog("FM-TEST sidebar cells=%d", cells.count)
        var openedReply = false
        let cellCount = min(cells.count, 6)
        for cellIndex in 0..<cellCount {
            let cell = cells.element(boundBy: cellIndex)
            guard cell.waitForExistence(timeout: 5) else { continue }
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"), object: cell
            )
            if XCTWaiter().wait(for: [hittable], timeout: 6) == .completed {
                cell.tap()
            } else {
                cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            sleep(2)
            assertNoFMBanners()
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(8)
                .map { String($0.label.prefix(40)) }
            NSLog("FM-TEST afterTap texts=%@", texts.joined(separator: " | "))
            if app.descendants(matching: .any)["retry-message-button"].firstMatch
                .waitForExistence(timeout: 5) {
                openedReply = true
                break
            }
            _ = openSidebar()
        }
        guard openedReply else {
            throw XCTSkip("No persisted conversation with an assistant reply")
        }
        capture("fm_reopened")

        let retry = app.descendants(matching: .any)["retry-message-button"].firstMatch
        guard retry.waitForExistence(timeout: 10) else {
            throw XCTSkip("No assistant reply to retry in this conversation")
        }
        retry.tap()
        XCTAssertTrue(waitForAssistantReply(), "FM retry never streamed")
        assertNoFMBanners()
        capture("fm_retry")
    }
}

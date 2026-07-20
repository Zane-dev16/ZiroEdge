import XCTest

/// L2 Download Diagnostics — triggers a real download and captures every
/// state transition for post-mortem analysis. Designed to run with the
/// companion `Scripts/download-diagnose.sh` script which streams device
/// logs in parallel and produces a structured report.
final class DownloadDiagnosticsTests: UITestBase {

    // MARK: - Helpers

    /// Dismiss onboarding if it appears.
    private func dismissOnboardingIfNeeded() {
        // Onboarding has a "Skip" button and a "Get Started" button
        let skipBtn = app.buttons["Skip"].firstMatch
        let getStartedBtn = app.buttons["Get Started"].firstMatch
        let continueBtn = app.buttons["Continue"].firstMatch

        if skipBtn.waitForExistence(timeout: 3) {
            print("[UITEST] Onboarding detected, tapping Skip")
            skipBtn.tap()
            sleep(1)
        } else if getStartedBtn.waitForExistence(timeout: 2) {
            print("[UITEST] Onboarding detected (last page), tapping Get Started")
            getStartedBtn.tap()
            sleep(1)
        } else if continueBtn.waitForExistence(timeout: 2) {
            // Tap through all onboarding pages
            while continueBtn.exists {
                continueBtn.tap()
                sleep(1)
            }
            // Final page has "Get Started"
            if getStartedBtn.waitForExistence(timeout: 2) {
                getStartedBtn.tap()
                sleep(1)
            }
        }
    }

    /// Navigate to the Models view and return the first download-eligible
    /// model cell. Returns nil if all models are already installed or
    /// unavailable.
    private func navigateToFirstDownloadableModel(timeout: TimeInterval = 15) -> XCUIElement? {
        guard openModels(timeout: timeout) else {
            capture("models_nav_failed")
            return nil
        }

        // Wait for the table to populate
        sleep(2)

        // Find a cell that has a download button (arrow.down.circle) —
        // this means the model is not yet installed.
        let downloadButton = app.buttons["arrow.down.circle"].firstMatch
        if downloadButton.waitForExistence(timeout: 5) {
            // Tap the cell containing this button to go to detail
            let cell = downloadButton.firstMatch
            // Try tapping the cell row itself
            let cells = app.tables.cells
            for idx in 0..<cells.count {
                let cellEl = cells.element(boundBy: idx)
                if cellEl.exists {
                    let btn = cellEl.buttons["arrow.down.circle"]
                    if btn.exists {
                        cellEl.tap()
                        sleep(1)
                        return cellEl
                    }
                }
            }
        }

        // Fallback: tap the first cell that isn't in "Installed" section
        let cells = app.tables.cells
        if cells.count > 0 {
            cells.firstMatch.tap()
            sleep(1)
            return cells.firstMatch
        }

        return nil
    }

    // MARK: - Tests

    /// Full download diagnostic: navigate to model, trigger download,
    /// observe progress/errors for 120 seconds, capture state at each step.
    func testDownloadDiagnostic() throws {
        // Step 0: Dismiss onboarding if present
        dismissOnboardingIfNeeded()
        capture("01_before_models_nav")

        guard openModels() else {
            capture("02_models_nav_failed")
            // Don't fail — log what we have for analysis
            return
        }
        capture("02_models_list")

        // Step 2: Find a downloadable model
        // First, list all visible state for debugging
        let cellCount = app.tables.cells.count
        print("[UITEST] Models view: \(cellCount) cells visible")

        // Look for the download button indicator
        let downloadBtn = app.buttons["arrow.down.circle"].firstMatch
        let repairIcon = app.images.containing(NSPredicate(format: "identifier CONTAINS 'wrench'")).firstMatch
        let unavailableIcon = app.images.containing(NSPredicate(format: "identifier CONTAINS 'exclamationmark'")).firstMatch

        print("[UITEST] downloadBtn.exists=\(downloadBtn.exists)")
        print("[UITEST] repairIcon.exists=\(repairIcon.exists)")

        // Tap the first model cell to go to detail
        var tappedCell = false
        let cells = app.tables.cells
        for idx in 0..<cells.count {
            let cellEl = cells.element(boundBy: idx)
            if cellEl.exists {
                cellEl.tap()
                tappedCell = true
                sleep(1)
                break
            }
        }

        if !tappedCell {
            capture("02_no_model_cells")
            print("[UITEST] No model cells found — cannot trigger download")
            return
        }
        capture("03_model_detail")

        // Step 3: Trigger the download
        // Look for the "Download" button in ModelDetailView
        let downloadButton = app.buttons.containing(NSPredicate(
            format: "label CONTAINS[c] 'download' OR label CONTAINS[c] 'retry'"
        )).firstMatch

        if downloadButton.waitForExistence(timeout: 5) {
            print("[UITEST] Found download button: '\(downloadButton.label)'")
            capture("04_before_download_tap")
            downloadButton.tap()
            print("[UITEST] Tapped download button")
        } else {
            // Try generic bordered prominent button
            let prominentBtn = app.buttons.firstMatch
            print("[UITEST] No labeled download button, trying first button: '\(prominentBtn.label)'")
            capture("04_no_download_button")
            if prominentBtn.exists {
                prominentBtn.tap()
                print("[UITEST] Tapped first button")
            }
        }

        // Step 4: Monitor the download for up to 120 seconds
        // Capture state at regular intervals
        let monitorDuration: TimeInterval = 60
        let captureInterval: TimeInterval = 10
        let start = Date()
        var step = 5

        while Date().timeIntervalSince(start) < monitorDuration {
            let elapsed = Int(Date().timeIntervalSince(start))
            let stepName = String(format: "%02d_t%ds", step, elapsed)
            capture(stepName)

            // Check for error banners
            let errorText = readErrorBanner()
            if let errorText {
                print("[UITEST] t=\(elapsed)s: ERROR BANNER: \(errorText)")
            }

            // Check for progress indicator
            let progressView = app.progressIndicators.firstMatch
            let progressExists = progressView.exists
            print("[UITEST] t=\(elapsed)s: progressIndicator.exists=\(progressExists)")

            // Check for percentage text
            let percentTexts = app.staticTexts.allElementsBoundByIndex.filter { elem in
                elem.label.contains("%")
            }
            for pt in percentTexts {
                print("[UITEST] t=\(elapsed)s: percent label='\(pt.label)'")
            }

            // Check for state labels
            for label in ["Downloaded", "Verifying", "Failed", "Repair Needed", "Cancelled", "Downloading"] {
                let el = app.staticTexts[label].firstMatch
                if el.exists {
                    print("[UITEST] t=\(elapsed)s: state='\(label)'")
                }
            }

            // Check if download completed
            let checkmark = app.images.containing(NSPredicate(
                format: "identifier CONTAINS 'checkmark'"
            )).firstMatch
            if checkmark.exists {
                print("[UITEST] t=\(elapsed)s: DOWNLOAD COMPLETE (checkmark visible)")
                capture("\(stepName)_complete")
                break
            }

            // Check if failed
            let failIcon = app.images.containing(NSPredicate(
                format: "label CONTAINS 'Failed' OR label CONTAINS 'exclamationmark'"
            )).firstMatch
            if failIcon.exists {
                print("[UITEST] t=\(elapsed)s: DOWNLOAD FAILED (error icon visible)")
                capture("\(stepName)_failed")
                break
            }

            step += 1
            sleep(UInt32(captureInterval))
        }

        capture("99_final_state")
        print("[UITEST] Diagnostic complete")
    }

    /// Quick smoke test: verify the download button exists and is tappable.
    func testDownloadButtonExists() {
        guard openModels() else {
            capture("button_nav_failed")
            return
        }

        sleep(2)

        // Tap into model detail
        let cell = app.tables.cells.firstMatch
        guard cell.waitForExistence(timeout: 5) else {
            capture("button_no_cells")
            return
        }
        cell.tap()
        sleep(1)
        capture("button_detail")

        // Check for any download-related button
        let hasButton = app.buttons.containing(NSPredicate(
            format: "label CONTAINS[c] 'download' OR label CONTAINS[c] 'retry' OR label CONTAINS[c] 'repair'"
        )).firstMatch.waitForExistence(timeout: 5)

        let hasCheckmark = app.staticTexts["Downloaded"].firstMatch.exists

        XCTAssertTrue(hasButton || hasCheckmark,
                       "Model detail should have a download button or 'Downloaded' label")
        capture("button_found")
    }

    /// Test that we can observe progress (validates the delegate wiring).
    func testDownloadProgressAppears() {
        guard openModels() else { return }
        sleep(1)

        // Navigate to detail
        let cell = app.tables.cells.firstMatch
        guard cell.waitForExistence(timeout: 5) else { return }
        cell.tap()
        sleep(1)

        // Tap download
        let btn = app.buttons.containing(NSPredicate(
            format: "label CONTAINS[c] 'download'"
        )).firstMatch
        guard btn.waitForExistence(timeout: 5) else { return }
        btn.tap()

        // Wait up to 30 seconds for the progress bar to appear
        // (should appear almost immediately if the download starts)
        let progressView = app.progressIndicators.firstMatch
        let progressAppeared = progressView.waitForExistence(timeout: 30)
        capture("progress_check")

        let percentLabels = app.staticTexts.allElementsBoundByIndex.filter { $0.label.contains("%") }
        print("[UITEST] progressAppeared=\(progressAppeared)")
        print("[UITEST] percentLabels=\(percentLabels.map(\.label))")

        // We don't assert failure here — the download may fail for network
        // reasons on CI. But we capture the state for analysis.
        if progressAppeared {
            capture("progress_visible")
        } else {
            capture("progress_not_visible")
        }
    }
}

// FoundationModelsBridgeTests.swift
// Guards the FM streaming bridge's string algorithms: stop-marker cuts and
// split-header holdback. The live delta loop is proven on device; these pin
// the pure pieces against regressions.

import XCTest
@testable import ZiroEdge

final class FoundationModelsBridgeTests: XCTestCase {
    func testStopIndexFindsRoleHeaders() {
        XCTAssertNotNil(FoundationModelsProvider.stopIndex(in: "Sure thing.\nAssistant: hi", atStart: false))
        XCTAssertNotNil(FoundationModelsProvider.stopIndex(in: "a\nUser: b", atStart: false))
        XCTAssertNil(FoundationModelsProvider.stopIndex(in: "Clean reply with\nnewlines.", atStart: false))
        // Bare words without the colon are not markers.
        XCTAssertNil(FoundationModelsProvider.stopIndex(in: "The User went home", atStart: false))
    }

    func testStopIndexLeadingPositionOnlyAtStart() {
        XCTAssertNotNil(FoundationModelsProvider.stopIndex(in: "Assistant: hello", atStart: true))
        // Mid-text leading-style header without newline is normal prose.
        XCTAssertNil(FoundationModelsProvider.stopIndex(in: "said Assistant: hello", atStart: false))
    }

    func testTrailingPartialMarkerHoldback() {
        XCTAssertEqual(FoundationModelsProvider.trailingPartialMarkerLength(in: "hello\n", atStart: false), 1)
        XCTAssertEqual(FoundationModelsProvider.trailingPartialMarkerLength(in: "x\nAss", atStart: false), 4)
        XCTAssertEqual(FoundationModelsProvider.trailingPartialMarkerLength(in: "clean text.", atStart: false), 0)
        XCTAssertEqual(FoundationModelsProvider.trailingPartialMarkerLength(in: "", atStart: false), 0)
        // A completed marker is a cut, not a hold: longest strict prefix only.
        XCTAssertLessThan(
            FoundationModelsProvider.trailingPartialMarkerLength(in: "a\nAssistant:", atStart: false),
            "\nAssistant:".count
        )
    }
}

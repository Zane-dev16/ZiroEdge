import XCTest
@testable import ZiroEdge

final class InferenceDiagnosticTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InferenceDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEventsRetainStageOrderAndMonotonicSequence() throws {
        let recorder = InferenceDiagnosticRecorder(
            directory: directory,
            maximumRetainedEvents: 20,
            enabled: true,
            runID: "run-order"
        )

        recorder.record(modelID: "gemma-4-e4b-q4", requestID: nil, stage: .baseLoad, state: .start)
        recorder.record(modelID: "gemma-4-e4b-q4", requestID: nil, stage: .baseLoad, state: .end)
        recorder.record(modelID: "gemma-4-e4b-q4", requestID: nil, stage: .projectorInitialization, state: .start)
        recorder.record(modelID: "gemma-4-e4b-q4", requestID: nil, stage: .projectorInitialization, state: .end)

        let events = try recorder.readEvents()
        XCTAssertEqual(events.map(\.stage), [.baseLoad, .baseLoad, .projectorInitialization, .projectorInitialization])
        XCTAssertEqual(events.map(\.state), [.start, .end, .start, .end])
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertNil(InferenceDiagnosticValidator.firstOrderingViolation(in: events))
    }

    func testRetentionKeepsOnlyNewestBoundedEvents() throws {
        let recorder = InferenceDiagnosticRecorder(
            directory: directory,
            maximumRetainedEvents: 3,
            enabled: true,
            runID: "run-retention"
        )
        for _ in 0..<5 {
            recorder.record(modelID: "gemma-4-e4b-q4", requestID: nil, stage: .memory, state: .event)
        }

        let events = try recorder.readEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.sequence), [3, 4, 5])
    }

    func testStructuredSchemaCannotPersistSensitivePayloads() throws {
        let recorder = InferenceDiagnosticRecorder(
            directory: directory,
            maximumRetainedEvents: 20,
            enabled: true,
            runID: "run-redaction"
        )
        recorder.record(
            modelID: "gemma-4-e4b-q4",
            requestID: "request-safe",
            stage: .completion,
            state: .end,
            elapsedMilliseconds: 12,
            primaryCount: 1,
            secondaryCount: 2
        )

        let encoded = try String(contentsOf: recorder.logURL, encoding: .utf8)
        let forbidden = [
            "Describe this image", "response text", "<__media__>", "https://",
            "/private/var/", "tokenValue", "secret"
        ]
        for value in forbidden {
            XCTAssertFalse(encoded.contains(value), "diagnostics leaked forbidden payload: \(value)")
        }
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("imageData"))
        XCTAssertFalse(encoded.contains("localPath"))
        XCTAssertFalse(encoded.contains("url"))
    }

    func testValidatorReportsFirstMissingCheckpoint() {
        let events = [
            InferenceDiagnosticEvent.fixture(sequence: 1, stage: .baseLoad, state: .start),
            InferenceDiagnosticEvent.fixture(sequence: 2, stage: .baseLoad, state: .end),
            InferenceDiagnosticEvent.fixture(sequence: 3, stage: .projectorInitialization, state: .start)
        ]

        XCTAssertEqual(
            InferenceDiagnosticValidator.lastCompletedAndFirstMissing(in: events),
            "baseLoad.end → projectorInitialization.end"
        )
    }

    @MainActor
    func testVisionSmokeRequiresAVisualFixtureDetail() {
        XCTAssertTrue(VisionSmokeWorkload.responseDescribesFixture("A blue square on a red background."))
        XCTAssertFalse(VisionSmokeWorkload.responseDescribesFixture("The image is completely blank white."))
        XCTAssertFalse(VisionSmokeWorkload.responseDescribesFixture("I cannot identify the image."))
    }
}

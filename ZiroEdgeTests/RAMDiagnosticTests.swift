import XCTest
@testable import ZiroEdge

@MainActor
final class RAMDiagnosticTests: XCTestCase {
    func testSnapshotContainsCoherentProcessAndHostDiagnostics() throws {
        let snapshot = MemorySnapshotReader.capture(.cold)

        XCTAssertEqual(snapshot.checkpoint, .cold)
        XCTAssertGreaterThan(snapshot.totalPhysicalBytes, 0)
#if targetEnvironment(simulator)
        XCTAssertEqual(snapshot.processAvailableBytes, 0, "The simulator has no iOS process allocation limit")
#else
        XCTAssertGreaterThan(snapshot.processAvailableBytes, 0)
#endif
        XCTAssertGreaterThan(snapshot.physicalFootprintBytes, 0)
        XCTAssertGreaterThan(snapshot.systemReclaimableBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.processAvailableBytes, snapshot.totalPhysicalBytes)
        XCTAssertLessThanOrEqual(snapshot.physicalFootprintBytes, snapshot.totalPhysicalBytes)
        XCTAssertLessThan(abs(snapshot.timestamp.timeIntervalSinceNow), 5)
    }

    func testSnapshotExportsAsOneJSONRecordWithCheckpoint() throws {
        let snapshot = MemorySnapshotReader.capture(.beforeModelLoad)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["checkpoint"] as? String, "beforeModelLoad")
        XCTAssertNotNil(object["totalPhysicalBytes"])
        XCTAssertNotNil(object["processAvailableBytes"])
        XCTAssertNotNil(object["physicalFootprintBytes"])
        XCTAssertNotNil(object["systemReclaimableBytes"])
        XCTAssertNotNil(object["timestamp"])
    }

    func testDefaultDiagnosticTargetIsCalibrationOnlyE4BText() {
        XCTAssertEqual(MemoryDiagnosticRecorder.defaultTargetModelID, "gemma-4-e4b-q4-text-calibration")
        XCTAssertEqual(ModelRegistry.model(for: MemoryDiagnosticRecorder.defaultTargetModelID)?.modelType, .text)
        XCTAssertEqual(MemoryDiagnosticWorkload.cycleCount, 5)
        XCTAssertEqual(MemoryDiagnosticWorkload.promptCount, 20)
        XCTAssertEqual(MemoryDiagnosticWorkload.minimumHeadroomBytes, 750_000_000)
        XCTAssertEqual(MemoryDiagnosticWorkload.recoveryToleranceBytes, 100_000_000)
    }

    func testCalibrationLoadRequiresDebugBuildAndBothDiagnosticFlags() {
        let flags = ["ZiroEdge", "--memory-diagnostic", "--calibration-memory-load"]
        XCTAssertTrue(MemoryDiagnosticRecorder.allowsCalibrationLoad(arguments: flags, isDebugBuild: true))
        XCTAssertFalse(MemoryDiagnosticRecorder.allowsCalibrationLoad(arguments: flags, isDebugBuild: false))
        XCTAssertFalse(MemoryDiagnosticRecorder.allowsCalibrationLoad(arguments: ["ZiroEdge", "--calibration-memory-load"], isDebugBuild: true))
    }

    func testControlledWorkloadRequiresDebugOverrideAndWorkloadFlag() {
        let allFlags = [
            "ZiroEdge",
            "--memory-diagnostic",
            "--calibration-memory-load",
            "--memory-diagnostic-workload"
        ]
        XCTAssertTrue(MemoryDiagnosticRecorder.allowsControlledWorkload(arguments: allFlags, isDebugBuild: true))
        XCTAssertFalse(MemoryDiagnosticRecorder.allowsControlledWorkload(arguments: allFlags, isDebugBuild: false))
        XCTAssertFalse(
            MemoryDiagnosticRecorder.allowsControlledWorkload(
                arguments: allFlags.filter { $0 != "--memory-diagnostic" },
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            MemoryDiagnosticRecorder.allowsControlledWorkload(
                arguments: allFlags.filter { $0 != "--calibration-memory-load" },
                isDebugBuild: true
            )
        )
    }
}

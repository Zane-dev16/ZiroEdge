import XCTest
@testable import ZiroEdge

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

    func testDiagnosticTargetIsGemmaE2B() {
        XCTAssertEqual(MemoryDiagnosticRecorder.targetModelID, "gemma-4-e2b-q4")
        XCTAssertEqual(ModelRegistry.model(for: MemoryDiagnosticRecorder.targetModelID)?.totalFileSizeBytes, 3_985_228_864)
    }

    func testUnsafeOverrideRequiresDebugBuildAndBothDiagnosticFlags() {
        let flags = ["ZiroEdge", "--memory-diagnostic", "--unsafe-memory-load"]
        XCTAssertTrue(MemoryDiagnosticRecorder.allowsUnsafeOverride(arguments: flags, isDebugBuild: true))
        XCTAssertFalse(MemoryDiagnosticRecorder.allowsUnsafeOverride(arguments: flags, isDebugBuild: false))
        XCTAssertFalse(MemoryDiagnosticRecorder.allowsUnsafeOverride(arguments: ["ZiroEdge", "--unsafe-memory-load"], isDebugBuild: true))
    }

    func testControlledWorkloadRequiresDebugOverrideAndWorkloadFlag() {
        let allFlags = [
            "ZiroEdge",
            "--memory-diagnostic",
            "--unsafe-memory-load",
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
                arguments: allFlags.filter { $0 != "--unsafe-memory-load" },
                isDebugBuild: true
            )
        )
    }
}

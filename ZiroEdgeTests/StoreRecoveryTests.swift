import XCTest
@testable import ZiroEdge

final class StoreRecoveryTests: XCTestCase {
    func testQuarantineCopiesExistingSQLiteTrioByteForByte() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm")]
        for (index, source) in sources.enumerated() {
            try Data(repeating: UInt8(index + 1), count: index + 3).write(to: source)
        }
        let failure = PersistenceFailure(category: .storeUnavailable, operation: .loadStore, domain: "fixture", code: 1)
        let result = await StoreRecoveryCoordinator().quarantine(storeURL: store, failure: failure)
        guard case .success(let artifact) = result else { return XCTFail("Expected recovery artifact") }
        defer { try? FileManager.default.removeItem(at: artifact.directory) }
        XCTAssertEqual(artifact.copiedFiles.count, 3)
        for source in sources {
            let copy = artifact.directory.appendingPathComponent(source.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
        }
        XCTAssertTrue(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFailureAfterFirstCopyRemovesIncompleteArtifactAndLeavesSourceUntouched() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        let bytes = Data("history".utf8)
        try bytes.write(to: store)
        defer { try? FileManager.default.removeItem(at: store) }
        let recoveryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let injector = ScriptedPersistenceFaultInjector([
            .succeed(.quarantine),
            .fail(.quarantine, error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        ])
        let failure = PersistenceFailure(category: .storeUnavailable, operation: .loadStore, domain: "fixture", code: 1)
        let wal = URL(fileURLWithPath: store.path + "-wal")
        try Data("wal".utf8).write(to: wal)
        defer { try? FileManager.default.removeItem(at: wal) }
        let result = await StoreRecoveryCoordinator(
            faultInjector: injector,
            recoveryRoot: recoveryRoot
        ).quarantine(storeURL: store, failure: failure)
        guard case .failure(let mapped) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(mapped.category, .quarantineFailed)
        XCTAssertEqual(try Data(contentsOf: store), bytes)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testVerifiedArtifactAllowsDestroyAndStoreReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("history.sqlite")
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
                return XCTFail("Initial open failed")
            }
            _ = try await controller.createConversation(modelID: "fixture")
            _ = try await controller.closePersistentStores().get()
        }
        let failure = PersistenceFailure(category: .storeUnavailable, operation: .loadStore, domain: "fixture", code: 1)
        let coordinator = StoreRecoveryCoordinator(recoveryRoot: recoveryRoot)
        guard case .success(let artifact) = await coordinator.quarantine(storeURL: store, failure: failure) else {
            return XCTFail("Quarantine failed")
        }
        guard case .success = await coordinator.destroyStore(at: store, after: artifact) else {
            return XCTFail("Destroy failed")
        }
        guard case .success = await PersistenceController.open(configuration: .store(store)) else {
            return XCTFail("Fresh store should reopen")
        }
    }
}

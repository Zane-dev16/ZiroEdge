// Batch07StoreRecoveryTamperTests.swift
// ZiroEdge — BATCH-07 StoreRecoveryCoordinator.destroyStore tamper guards
//
// Pins the destroyStore guards (~lines 102/118 of StoreRecoveryCoordinator.swift):
// any divergence between the quarantined artifact and the live store trio between
// quarantine and confirmation must refuse destruction with a typed failure —
//   - WAL byte tampering            → .quarantineFailed / .destroyStore / 409
//   - SHM removed (file-set change) → .quarantineFailed / .destroyStore / 412
//   - artifact copy bytes tampered  → .destructionFailed / .destroyStore / 409
// and in every case the live database must survive untouched.

import XCTest
@testable import ZiroEdge

final class Batch07StoreRecoveryTamperTests: XCTestCase {

    private struct Trio {
        let store: URL
        let wal: URL
        let shm: URL
        var all: [URL] { [store, wal, shm] }
    }

    private func makeTrio(in root: URL) throws -> (Trio, [URL: Data]) {
        let trio = Trio(
            store: root.appendingPathComponent("history.sqlite"),
            wal: URL(fileURLWithPath: root.appendingPathComponent("history.sqlite").path + "-wal"),
            shm: URL(fileURLWithPath: root.appendingPathComponent("history.sqlite").path + "-shm")
        )
        var original: [URL: Data] = [:]
        try Data(repeating: 0x11, count: 96).write(to: trio.store)
        try Data(repeating: 0x22, count: 32).write(to: trio.wal)
        try Data(repeating: 0x33, count: 16).write(to: trio.shm)
        for url in trio.all { original[url] = try Data(contentsOf: url) }
        return (trio, original)
    }

    private func quarantineTrio(
        _ trio: Trio,
        coordinator: StoreRecoveryCoordinator
    ) async throws -> StoreRecoveryArtifact {
        let failure = PersistenceFailure(
            category: .storeUnavailable, operation: .loadStore, domain: "fixture", code: 1
        )
        guard case .success(let artifact) = await coordinator.quarantine(storeURL: trio.store, failure: failure) else {
            XCTFail("quarantine precondition failed")
            struct QuarantinePreconditionFailed: Error {}
            throw QuarantinePreconditionFailed()
        }
        return artifact
    }

    private func assertLiveStoreUntouched(_ trio: Trio, original: [URL: Data]) throws {
        for url in trio.all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(url.lastPathComponent) must not be deleted by a refused destroy")
            XCTAssertEqual(try Data(contentsOf: url), original[url],
                           "\(url.lastPathComponent) bytes must be unchanged by a refused destroy")
        }
    }

    // MARK: - WAL byte tampering

    func testDestroyStore_WALTamperedAfterQuarantine_RefusesAndPreservesDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (trio, original) = try makeTrio(in: root)
        let coordinator = StoreRecoveryCoordinator(recoveryRoot: recoveryRoot)
        let artifact = try await quarantineTrio(trio, coordinator: coordinator)

        // Tamper with the live WAL after quarantine.
        try Data(repeating: 0xEE, count: 40).write(to: trio.wal)

        let result = await coordinator.destroyStore(at: trio.store, after: artifact)

        guard case .failure(let failure) = result else {
            return XCTFail("Tampered WAL must refuse destruction")
        }
        XCTAssertEqual(
            failure,
            PersistenceFailure(
                category: .quarantineFailed, operation: .destroyStore,
                domain: "ZiroEdge.Persistence", code: 409
            ),
            "WAL divergence must surface as quarantineFailed 409 on destroyStore"
        )
        // The refused destroy must not delete anything. The WAL bytes were changed by
        // this test itself, so only its continued existence can be asserted; the store
        // and SHM were not touched by the tamper and must remain byte-identical.
        XCTAssertTrue(FileManager.default.fileExists(atPath: trio.wal.path),
                      "a refused destroy must not delete the diverged WAL")
        for url in [trio.store, trio.shm] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: url), original[url],
                           "\(url.lastPathComponent) bytes must be unchanged by a refused destroy")
        }
    }

    // MARK: - SHM removal (live file set diverges from manifest)

    func testDestroyStore_SHMRemovedAfterQuarantine_RefusesWith412AndPreservesDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (trio, original) = try makeTrio(in: root)
        let coordinator = StoreRecoveryCoordinator(recoveryRoot: recoveryRoot)
        let artifact = try await quarantineTrio(trio, coordinator: coordinator)

        // Remove a live source file so the current file set no longer matches the manifest.
        try FileManager.default.removeItem(at: trio.shm)

        let result = await coordinator.destroyStore(at: trio.store, after: artifact)

        guard case .failure(let failure) = result else {
            return XCTFail("Changed file set must refuse destruction")
        }
        XCTAssertEqual(
            failure,
            PersistenceFailure(
                category: .quarantineFailed, operation: .destroyStore,
                domain: "ZiroEdge.Persistence", code: 412
            ),
            "A missing live source file must surface as quarantineFailed 412"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: trio.store.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trio.wal.path))
        XCTAssertEqual(try Data(contentsOf: trio.store), original[trio.store],
                       "database bytes must be unchanged by a refused destroy")
    }

    // MARK: - Quarantined artifact bytes tampered

    func testDestroyStore_ArtifactBytesTampered_RefusesWithDestructionFailed409() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (trio, original) = try makeTrio(in: root)
        let coordinator = StoreRecoveryCoordinator(recoveryRoot: recoveryRoot)
        let artifact = try await quarantineTrio(trio, coordinator: coordinator)

        // Tamper with the quarantined COPY (not the live store).
        let tamperedCopy = artifact.directory.appendingPathComponent(trio.wal.lastPathComponent)
        try Data(repeating: 0xDD, count: 24).write(to: tamperedCopy)

        let result = await coordinator.destroyStore(at: trio.store, after: artifact)

        guard case .failure(let failure) = result else {
            return XCTFail("Tampered recovery artifact must refuse destruction")
        }
        XCTAssertEqual(
            failure,
            PersistenceFailure(
                category: .destructionFailed, operation: .destroyStore,
                domain: "ZiroEdge.Persistence", code: 409
            ),
            "Artifact-byte tampering must surface as destructionFailed 409"
        )
        try assertLiveStoreUntouched(trio, original: original)
    }
}

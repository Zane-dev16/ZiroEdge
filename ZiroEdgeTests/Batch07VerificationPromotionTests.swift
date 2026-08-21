// Batch07VerificationPromotionTests.swift
// ZiroEdge — BATCH-07 verifyAndPromoteOffMain branch hardening
//
// Pins the uncovered branches of DownloadManager.verifyAndPromoteOffMain
// (ZiroEdge/Services/DownloadManager+Promotion.swift):
//
// 1. SHA-256 mismatch after hashing → .failed(.sha256Mismatch), staging and durable
//    metadata discarded, activeTasks scrubbed, terminal state published via the
//    MainActor updateStatus hop.
// 2. Post-hash insufficient disk space → .failed(.diskSpaceInsufficient) with staging
//    PRESERVED byte-for-byte and durable metadata persisted (failed=true) so a relaunch
//    restores a resumable transfer instead of losing the verified download.
// 3. Cancellation while verification is mid-flight → activeTasks scrubbed immediately by
//    cancel and never resurrected by the late verification completion; no destination is
//    ever created.

import CryptoKit
import XCTest
@testable import ZiroEdge

@MainActor
final class Batch07VerificationPromotionTests: XCTestCase {

    private var manager: DownloadManager!

    override func setUp() {
        super.setUp()
        ModelMigrationService.ensureManagedDirectories()
        manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
    }

    override func tearDown() {
        manager.teardown()
        manager = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeModel(id: String, byteCount: Int64, sha256: String) -> AIModel {
        AIModel(
            id: id,
            displayName: "Batch07 Fixture",
            description: "Deterministic promotion fixture",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: byteCount,
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256,
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                copyright: "Test"
            )
        )
    }

    private func removeAllArtifactFiles(for task: DownloadTask) {
        for url in [task.stagingURL, task.metadataURL, task.resumeDataURL, task.destinationURL] {
            try? FileManager.default.removeItem(at: url)
        }
        let backup = task.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(task.destinationURL.lastPathComponent + ".promotion-backup")
        try? FileManager.default.removeItem(at: backup)
    }

    // MARK: - 1. SHA mismatch rejection

    func testVerifyAndPromoteOffMain_SHAMismatch() async throws {
        let bytes = TestModelFixtures.gguf(count: 4096)
        // Valid hex digest that cannot match the fixture bytes.
        let model = makeModel(
            id: "batch07-sha-mismatch-\(UUID().uuidString.lowercased())",
            byteCount: Int64(bytes.count),
            sha256: String(repeating: "f", count: 64)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { removeAllArtifactFiles(for: task) }
        try bytes.write(to: task.stagingURL, options: .atomic)

        let key = task.storageID
        manager.activeTasks[key] = task
        manager.verifyAndPromoteOffMain(task: task, key: key)
        XCTAssertEqual(task.state, .verifying, "entry must publish the verifying state synchronously")

        await task.verificationTask?.value

        XCTAssertEqual(task.state, .failed(error: .sha256Mismatch))
        XCTAssertNil(manager.activeTasks[key], "completion path must scrub activeTasks")
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.stagingURL.path),
            "SHA mismatch must discard staging (failVerification discardStaging: true)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.metadataURL.path),
            "durable metadata must be cleared on rejection"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertEqual(
            manager.downloadStatuses[model.id]?.baseState,
            .failed(error: .sha256Mismatch),
            "terminal failure must be published through the MainActor updateStatus hop"
        )
    }

    // MARK: - 2. Post-hash insufficient disk space preserves staging

    func testVerifyAndPromoteOffMain_postHashInsufficientSpace_preservesStaging() async throws {
        let bytes = TestModelFixtures.gguf(count: 2048)
        let model = makeModel(
            id: "batch07-posthash-space-\(UUID().uuidString.lowercased())",
            byteCount: Int64(bytes.count),
            sha256: TestModelFixtures.sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { removeAllArtifactFiles(for: task) }
        try bytes.write(to: task.stagingURL, options: .atomic)

        // The artifact itself is valid; only the post-hash space gate fails.
        // >0 but below the 512 MiB promotion safety margin.
        manager.injectAvailableDiskSpaceForTesting = 100 * 1024 * 1024

        let key = task.storageID
        manager.activeTasks[key] = task
        manager.verifyAndPromoteOffMain(task: task, key: key)

        await task.verificationTask?.value

        XCTAssertEqual(task.state, .failed(error: .diskSpaceInsufficient))
        XCTAssertEqual(
            try Data(contentsOf: task.stagingURL), bytes,
            "insufficient space after hashing must preserve staging byte-for-byte"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: task.metadataURL.path),
            "durable metadata must be retained so a relaunch restores the transfer"
        )
        let snapshot = try JSONDecoder().decode(
            DurableTransferSnapshot.self,
            from: try Data(contentsOf: task.metadataURL)
        )
        XCTAssertTrue(snapshot.failed, "durable snapshot must record the failure")
        XCTAssertTrue(snapshot.resumeAvailable, "durable snapshot must keep the transfer resumable")
        XCTAssertNil(manager.activeTasks[key])
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertEqual(
            manager.downloadStatuses[model.id]?.baseState,
            .failed(error: .diskSpaceInsufficient)
        )
    }

    // MARK: - 3. Cancellation scrubs active tasks exactly once

    func testVerifyAndPromoteOffMain_cancel_scrubsActiveTasks() async throws {
        // Sparse 2 GiB staged file: creation is instant, hashing takes long enough on
        // device that cancellation deterministically lands mid-verification.
        let totalBytes: Int64 = 2 * 1024 * 1024 * 1024
        let model = makeModel(
            id: "batch07-cancel-\(UUID().uuidString.lowercased())",
            byteCount: totalBytes,
            // Deliberately wrong digest: even in the pathological case where hashing
            // finishes before the cancel lands, the only possible outcome is a rejected
            // promotion — never a silent install.
            sha256: String(repeating: "a", count: 64)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { removeAllArtifactFiles(for: task) }
        try TestModelFixtures.gguf().write(to: task.stagingURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: task.stagingURL)
        try handle.seek(toOffset: UInt64(totalBytes) - 1)
        try handle.write(contentsOf: [0x00])
        try handle.close()

        let key = task.storageID
        manager.activeTasks[key] = task
        manager.verifyAndPromoteOffMain(task: task, key: key)

        // Wait until hashing is demonstrably mid-flight. Progress hops to MainActor from
        // the detached verifier, so observing progress > 0 proves both the off-main hash
        // loop and the MainActor hop are live.
        let deadline = Date().addingTimeInterval(10)
        while task.progress == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(
            task.progress, 0,
            "verification progress must reach the MainActor while hashing is still running"
        )

        manager.cancelArtifactDownload(model: model, artifact: .base, discardStaging: true)

        XCTAssertEqual(task.state, .cancelled)
        XCTAssertTrue(manager.activeTasks.isEmpty, "cancel must scrub activeTasks immediately")

        // The late verification completion must not resurrect any bookkeeping.
        await task.verificationTask?.value

        XCTAssertTrue(
            manager.activeTasks.isEmpty,
            "late verification completion must not re-register the cancelled task"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.stagingURL.path),
            "cancel with discardStaging must remove staging"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.metadataURL.path),
            "cancel with discardStaging must remove durable metadata"
        )
    }
}

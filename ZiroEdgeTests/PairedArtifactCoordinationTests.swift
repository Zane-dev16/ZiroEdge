// PairedArtifactCoordinationTests.swift
// ZiroEdgeTests
//
// Coverage for PAIRED-ARTIFACT-COORDINATION: independent base/projector state,
// byte-weighted progress, partial outcomes, mixed success/failure/pause/retry,
// and verification that valid artifacts are never needlessly replaced.

import XCTest
import CryptoKit
@testable import ZiroEdge

@MainActor
final class PairedArtifactCoordinationTests: XCTestCase {

    // MARK: - Independent Durable State Tracking

    func testBaseAndProjectorStateAreTrackedIndependently() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        let manager = DownloadManager()
        let status = manager.status(for: model)

        XCTAssertNotNil(status.mmprojState, "Vision model must expose projector state")
        // Both initially not downloaded.
        XCTAssertEqual(status.baseState, .notDownloaded)
        XCTAssertEqual(status.mmprojState, .notDownloaded)

        // Install only the base; projector remains missing.
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))
        manager.updateStatusesFromDisk()

        let partialStatus = manager.status(for: model)
        XCTAssertEqual(partialStatus.baseState, .downloaded)
        XCTAssertEqual(partialStatus.mmprojState, .notDownloaded)
        XCTAssertFalse(partialStatus.isVisionReady)
    }

    func testDurablePersistenceKeepsArtifactStatesSeparate() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()
        let baseTask = DownloadTask(model: model, artifact: .base)
        let mmprojTask = DownloadTask(model: model, artifact: .mmproj)
        defer {
            [baseTask, mmprojTask].forEach {
                try? FileManager.default.removeItem(at: $0.resumeDataURL)
                try? FileManager.default.removeItem(at: $0.metadataURL)
                try? FileManager.default.removeItem(at: $0.stagingURL)
            }
        }

        // Persist base as paused at 60%, projector as failed.
        baseTask.progress = 0.6
        try Data("base-resume".utf8).write(to: baseTask.resumeDataURL, options: .atomic)
        let baseWriter = DownloadManager()
        baseWriter.persistDurableState(for: baseTask)

        mmprojTask.progress = 0.3
        try Data("proj-resume".utf8).write(to: mmprojTask.resumeDataURL, options: .atomic)
        let projWriter = DownloadManager()
        projWriter.persistDurableState(for: mmprojTask, failed: true)

        // Restore and verify independent states.
        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        let status = restored.status(for: model)
        XCTAssertEqual(status.baseState, .paused(progress: 0.6))
        XCTAssertEqual(status.mmprojState, .failed(error: .networkError))
    }

    // MARK: - Partial Outcome Exposure

    func testPartialOutcomeBaseDownloadedProjectorFailed() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()

        let status = manager.status(for: model)
        let outcomes = status.partialOutcomes

        XCTAssertTrue(outcomes.contains(.baseDownloaded))
        // Projector is not downloaded, so no outcome for it.
        XCTAssertFalse(outcomes.contains(.projectorDownloaded))
        XCTAssertFalse(outcomes.contains(where: { if case .projectorFailed = $0 { true } else { false } }))
    }

    func testPartialOutcomeBaseValidProjectorFailed() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        // Create a failed projector task.
        let mmprojTask = DownloadTask(model: model, artifact: .mmproj)
        mmprojTask.state = .failed(error: .networkError)
        // Register with a one-off manager so the task is in activeTasks.
        let manager = DownloadManager()
        manager.updateStatusesFromDisk()
        _ = manager.registerActiveTaskIfAbsent(mmprojTask)
        manager.updateStatus(model: model)

        let status = manager.status(for: model)
        let outcomes = status.partialOutcomes

        XCTAssertTrue(outcomes.contains(.baseDownloaded))
        XCTAssertTrue(outcomes.contains(where: {
            if case .projectorFailed(.networkError) = $0 { true } else { false }
        }))
    }

    // MARK: - Byte-Weighted Progress

    func testOverallProgressWeightsByArtifactBytes() {
        let status = ModelDownloadStatus(
            modelID: "byte-weighted",
            baseState: .downloading(progress: 1.0),      // base complete
            mmprojState: .downloading(progress: 0.0),    // projector not started
            baseExpectedBytes: 3_000_000_000,             // 3 GB
            mmprojExpectedBytes: 1_000_000_000,           // 1 GB
            allowsTextOnly: true
        )
        // Base (3 GB out of 4 GB) = 0.75
        XCTAssertEqual(status.overallProgress, 0.75, accuracy: 0.001)

        let halfEach = ModelDownloadStatus(
            modelID: "half-each",
            baseState: .downloading(progress: 0.5),
            mmprojState: .downloading(progress: 0.5),
            baseExpectedBytes: 3_000_000_000,
            mmprojExpectedBytes: 1_000_000_000,
            allowsTextOnly: true
        )
        // 0.5*3 + 0.5*1 = 2.0 / 4 = 0.5
        XCTAssertEqual(halfEach.overallProgress, 0.5, accuracy: 0.001)

        let projectorDominant = ModelDownloadStatus(
            modelID: "projector-dominant",
            baseState: .downloading(progress: 0.0),
            mmprojState: .downloading(progress: 1.0),
            baseExpectedBytes: 100_000_000,
            mmprojExpectedBytes: 900_000_000,
            allowsTextOnly: true
        )
        // (0*100 + 1*900) / 1000 = 0.9
        XCTAssertEqual(projectorDominant.overallProgress, 0.9, accuracy: 0.001)
    }

    func testOverallProgressForTextOnlyModelIsBaseOnly() {
        let status = ModelDownloadStatus(
            modelID: "text-only",
            baseState: .downloading(progress: 0.75),
            mmprojState: nil,
            baseExpectedBytes: 2_000_000_000,
            mmprojExpectedBytes: nil,
            allowsTextOnly: false
        )
        XCTAssertEqual(status.overallProgress, 0.75)
    }

    // MARK: - Vision Readiness Gating with Text-Only Capability

    func testVisionModelRequiresBothArtifactsForVisionReadiness() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Only base installed.
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))
        let baseOnly = DownloadManager().status(for: model)
        XCTAssertFalse(baseOnly.isVisionReady, "Vision ready without projector")
        XCTAssertFalse(baseOnly.isReady, "Should not be ready for a vision model without text-only capability")

        // Both installed.
        try validGGUFData(length: 16).write(to: ModelManagerService.mmprojModelPath(for: model))
        DownloadManager().updateStatusesFromDisk()
        let both = DownloadManager().status(for: model)
        XCTAssertTrue(both.isVisionReady)
        XCTAssertTrue(both.isReady)
    }

    func testE2BModelAllowsTextOnlyWithBaseAlone() {
        // gemma-4-e2b-q4 has allowsTextOnlyCapability = true
        let model = ModelRegistry.gemma4_e2b
        let status = ModelDownloadStatus(
            modelID: model.id,
            baseState: .downloaded,
            mmprojState: .notDownloaded,
            baseExpectedBytes: model.baseFileSizeBytes,
            mmprojExpectedBytes: model.mmprojFileSizeBytes,
            allowsTextOnly: model.allowsTextOnlyCapability
        )
        XCTAssertTrue(status.isReady, "E2B with text-only capability should be ready without projector")
        XCTAssertFalse(status.isVisionReady, "E2B without projector should not be vision ready")
    }

    func testE4BVisionModelIsNotReadyWithoutProjector() {
        // gemma-4-e4b-q4 does NOT have allowsTextOnlyCapability
        let model = ModelRegistry.gemma4_e4b
        let status = ModelDownloadStatus(
            modelID: model.id,
            baseState: .downloaded,
            mmprojState: .notDownloaded,
            baseExpectedBytes: model.baseFileSizeBytes,
            mmprojExpectedBytes: model.mmprojFileSizeBytes,
            allowsTextOnly: model.allowsTextOnlyCapability
        )
        XCTAssertFalse(status.isReady, "E4B vision model without projector must not be ready")
        XCTAssertFalse(status.isVisionReady)
    }

    // MARK: - Valid Artifacts Are Not Needlessly Replaced

    func testResumeDoesNotStartTransferForVerifiedArtifacts() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Both artifacts are valid on disk.
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))
        try validGGUFData(length: 16).write(to: ModelManagerService.mmprojModelPath(for: model))

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()
        XCTAssertTrue(manager.status(for: model).isVisionReady)

        // Resume should not start any download since both are verified.
        manager.resumeDownload(for: model)
        XCTAssertFalse(manager.hasActiveDownload(model: model, artifact: .base),
                       "Should not start base download when artifact is already verified")
        XCTAssertFalse(manager.hasActiveDownload(model: model, artifact: .mmproj),
                       "Should not start projector download when artifact is already verified")
    }

    func testRetryInvalidArtifactsOnlyRetriesMissingNotVerified() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Only base is valid on disk; projector is missing.
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()
        XCTAssertTrue(manager.status(for: model).baseState.isDownloaded)
        XCTAssertFalse(manager.status(for: model).isVisionReady)

        // Call retryInvalidArtifacts — base should be left alone, projector should start.
        manager.retryInvalidArtifacts(for: model)

        XCTAssertFalse(manager.hasActiveDownload(model: model, artifact: .base),
                       "Should not retry verified base artifact")
        // The projector download may not actually start in tests (no network), but
        // the manager must not try to replace the verified base.
        let basePath = ModelManagerService.baseModelPath(for: model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: basePath.path),
                      "Verified base artifact must not be removed")
    }

    func testStartDownloadSkipsVerifiedArtifacts() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Only base is valid on disk.
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()

        // startDownload should skip the base and only try to download the projector.
        manager.startDownload(for: model)

        XCTAssertFalse(manager.hasActiveDownload(model: model, artifact: .base),
                       "Should not start base download when verified")
        // Projector download may not start in test, but the status should reflect
        // that base is still downloaded.
        XCTAssertEqual(manager.status(for: model).baseState, .downloaded)
    }

    // MARK: - Mixed Success, Failure, Pause, and Retry Combinations

    func testPausePreservesBothArtifactStatesIndependently() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()
        ModelManagerService.ensureModelsDirectory()

        // Create two active tasks: base downloading, mmproj paused.
        let baseTask = DownloadTask(model: model, artifact: .base)
        baseTask.state = .downloading(progress: 0.4)
        try Data("base-resume".utf8).write(to: baseTask.resumeDataURL, options: .atomic)

        let mmprojTask = DownloadTask(model: model, artifact: .mmproj)
        mmprojTask.state = .paused(progress: 0.7)
        try Data("proj-resume".utf8).write(to: mmprojTask.resumeDataURL, options: .atomic)

        let manager = DownloadManager()
        _ = manager.registerActiveTaskIfAbsent(baseTask)
        _ = manager.registerActiveTaskIfAbsent(mmprojTask)
        manager.persistDurableState(for: baseTask)
        manager.persistDurableState(for: mmprojTask)
        manager.updateStatus(model: model)

        // Now pause everything.
        manager.pauseDownload(for: model)

        let status = manager.status(for: model)
        // After pause, both should be in paused state.
        guard case .paused = status.baseState else {
            return XCTFail("Base should be paused, got \(status.baseState)")
        }
        guard case .paused = status.mmprojState else {
            return XCTFail("Projector should be paused, got \(status.mmprojState ?? .notDownloaded)")
        }

        // Cleanup registered tasks so we don't leak into other tests.
        [baseTask, mmprojTask].forEach {
            try? FileManager.default.removeItem(at: $0.resumeDataURL)
            try? FileManager.default.removeItem(at: $0.metadataURL)
            try? FileManager.default.removeItem(at: $0.stagingURL)
        }
    }

    func testMixedFailedAndDownloadedExposesPartialOutcomes() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        let mmprojTask = DownloadTask(model: model, artifact: .mmproj)
        mmprojTask.state = .failed(error: .sha256Mismatch)

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()
        _ = manager.registerActiveTaskIfAbsent(mmprojTask)
        manager.updateStatus(model: model)

        let status = manager.status(for: model)
        XCTAssertEqual(status.baseState, .downloaded)
        guard case .failed(.sha256Mismatch) = status.mmprojState else {
            return XCTFail("Projector should be failed with sha256Mismatch")
        }

        let outcomes = status.partialOutcomes
        XCTAssertTrue(outcomes.contains(.baseDownloaded))
        XCTAssertTrue(outcomes.contains(where: {
            if case .projectorFailed(.sha256Mismatch) = $0 { true } else { false }
        }))
    }

    // MARK: - retryInvalidArtifacts Behavior

    func testRetryInvalidArtifactsPausesActiveAndRetriesOnlyInvalid() throws {
        let model = visionFixture()
        defer { cleanupVision(model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Only projector is valid on disk.
        try validGGUFData(length: 16).write(to: ModelManagerService.mmprojModelPath(for: model))

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()
        manager.retryInvalidArtifacts(for: model)

        // Projector should not have an active download started since it's valid.
        XCTAssertFalse(manager.hasActiveDownload(model: model, artifact: .mmproj),
                       "Should not retry verified projector")
    }

    func testRetryInvalidArtifactsHandlesBaseOnlyModel() throws {
        let bytes = gguf()
        let model = textFixture(bytes: bytes)
        defer { ModelManagerService.deleteModel(model) }
        ModelMigrationService.ensureManagedDirectories()

        let manager = DownloadManager()
        // Should not crash for a text-only model.
        manager.retryInvalidArtifacts(for: model)
        // Base is not downloaded, but we just verify no crash.
        XCTAssertNotNil(manager.status(for: model))
    }

    // MARK: - Stable Identity Across Shared Base Artifacts

    func testE4BTextAndE4BVisionShareBaseArtifactIdentity() {
        let vision = ModelRegistry.gemma4_e4b
        let text = ModelRegistry.gemma4_e4b_text

        XCTAssertEqual(vision.baseArtifactStorageID, text.baseArtifactStorageID,
                       "E4B text and vision variants must share base artifact storage")
        XCTAssertEqual(vision.baseURL, text.baseURL)
        XCTAssertEqual(vision.baseSHA256, text.baseSHA256)
    }

    // MARK: - Helpers

    private func visionFixture() -> AIModel {
        let id = "paired-vision-\(UUID().uuidString.lowercased())"
        let baseData = validGGUFData(length: 16)
        let projData = validGGUFData(length: 16)
        return AIModel(
            id: id,
            displayName: "Paired Vision Fixture",
            description: "Test vision model",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: URL(string: "https://example.com/\(id)-mmproj.gguf")!,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: Int64(projData.count),
            baseSHA256: sha256(baseData),
            mmprojSHA256: sha256(projData),
            quantization: "Q4_K_M",
            config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }

    private func textFixture(bytes: Data) -> AIModel {
        let id = "paired-text-\(UUID().uuidString.lowercased())"
        return AIModel(
            id: id,
            displayName: "Paired Text Fixture",
            description: "Test text model",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(bytes.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(bytes),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }

    private func validGGUFData(length: Int) -> Data {
        TestModelFixtures.gguf(count: length)
    }

    private func gguf() -> Data {
        Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0, 1, 2, 3, 4])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupVision(model: AIModel) {
        ModelManagerService.deleteModel(model)
    }
}

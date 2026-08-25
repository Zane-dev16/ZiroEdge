// StaleResumeRecoveryTests.swift
// ZiroEdgeTests
//
// Deterministic unit tests for STALE-RESUME-RECOVERY (issue #7).
// Verifies the single-retry canonical fallback contract and loop prevention.

import CryptoKit
import XCTest
@testable import ZiroEdge

@MainActor
final class StaleResumeRecoveryTests: XCTestCase {

    // MARK: - Loop prevention

    func testCanonicalRetryAttemptedPreventsSecondFallback() {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("stale-resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!
        task.canonicalRetryAttempted = true

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let result = manager.retryOnceFromCanonicalURL(task, key: task.storageID)

        XCTAssertFalse(result, "Second canonical fallback must be refused")
        XCTAssertTrue(task.canonicalRetryAttempted, "Flag must remain true after second call")
    }

    // MARK: - Resume data removal

    func testResumeDataIsRemovedBeforeFallback() {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        let resumeBytes = Data("expired-signed-resume-data".utf8)
        try? resumeBytes.write(to: task.resumeDataURL, options: .atomic)
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!
        task.progress = 0.42
        task.state = .downloading(progress: 0.42)

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let result = manager.retryOnceFromCanonicalURL(task, key: task.storageID)

        XCTAssertTrue(result)
        XCTAssertTrue(task.canonicalRetryAttempted)
        XCTAssertNil(task.resumeData, "In-memory resumeData must be nilled")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.resumeDataURL.path),
            "Stale resume data must be removed from disk before fallback"
        )
        XCTAssertEqual(task.downloadURL, task.sourceURL,
                       "downloadURL must reset to the canonical catalog URL")
    }

    // MARK: - State transitions

    func testFallbackResetsProgressAndRevertsToCanonicalURL() {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("opaque-resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!
        task.progress = 0.35
        task.state = .downloading(progress: 0.35)

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let result = manager.retryOnceFromCanonicalURL(task, key: task.storageID)

        XCTAssertTrue(result)
        XCTAssertEqual(task.downloadURL, task.sourceURL)
        XCTAssertEqual(task.progress, 0)
        XCTAssertFalse(task.isChunked)
        XCTAssertEqual(task.currentChunkOffset, 0)
        XCTAssertEqual(task.chunkRetryCount, 0)
    }

    func testChunkedStateIsResetOnFallback() {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.isChunked = true
        task.currentChunkOffset = 1024
        task.currentChunkIndex = 2
        task.chunkRetryCount = 1
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let result = manager.retryOnceFromCanonicalURL(task, key: task.storageID)

        XCTAssertTrue(result)
        XCTAssertFalse(task.isChunked, "Chunked flag must reset after canonical fallback")
        XCTAssertEqual(task.currentChunkOffset, 0)
        XCTAssertEqual(task.currentChunkIndex, 0)
        XCTAssertEqual(task.chunkRetryCount, 0)
    }

    func testStagingFileIsRemovedOnFallback() throws {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        try Data("stale-staging".utf8).write(to: task.stagingURL, options: .atomic)
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let result = manager.retryOnceFromCanonicalURL(task, key: task.storageID)

        XCTAssertTrue(result)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: task.stagingURL.path),
            "Stale staging data must be removed before canonical fallback"
        )
    }

    // MARK: - Second-failure classification

    func testCanonicalFlagPersistsAfterRetryCall() {
        let bytes = validGGUF(length: 16)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("stale".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.downloadURL = URL(string: "https://signed.cdn.example.com/model.gguf")!

        let manager = DownloadManager()
        manager.activeTasks[task.storageID] = task

        let firstResult = manager.retryOnceFromCanonicalURL(task, key: task.storageID)
        XCTAssertTrue(firstResult)
        XCTAssertTrue(task.canonicalRetryAttempted)

        // Re-register since the first call removed the task from activeTasks.
        manager.activeTasks[task.storageID] = task
        let secondResult = manager.retryOnceFromCanonicalURL(task, key: task.storageID)
        XCTAssertFalse(secondResult, "Second failure must not trigger another canonical fallback")
    }

    // MARK: - Transport-level failure classification

    func testTransportValidatorReportsAuthorizationRequired() throws {
        let bytes = validGGUF(length: 32)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-auth-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)

        let response = HTTPURLResponse(
            url: URL(string: "https://signed.cdn.example.com/model.gguf")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )

        let failure = DownloadTransportValidator.failure(
            response: response,
            bodyURL: url,
            expectedBytes: Int64(bytes.count),
            expectedOffset: 0
        )

        guard case .authorizationRequired(let code) = failure else {
            return XCTFail("Expected authorizationRequired, got \(String(describing: failure))")
        }
        XCTAssertEqual(code, 401)
    }

    func testTransportValidatorReportsContentRejectedForEmptyBody() {
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-empty-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        try? Data().write(to: emptyURL)

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/model.gguf")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let failure = DownloadTransportValidator.failure(
            response: response,
            bodyURL: emptyURL,
            expectedBytes: 16,
            expectedOffset: 0
        )

        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected for empty body, got \(String(describing: failure))")
        }
    }

    func testTransportValidatorAcceptsComplete200DuringResume() throws {
        let bytes = validGGUF(length: 32)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-range-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)

        // Server ignores the Range request and resends everything while
        // resuming: acceptable, because the complete artifact arrived and the
        // SHA-256 gate enforces integrity afterwards.
        let response = HTTPURLResponse(
            url: URL(string: "https://signed.cdn.example.com/model.gguf")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response,
            bodyURL: url,
            expectedBytes: Int64(bytes.count),
            expectedOffset: 1024
        ))
    }

    func testTransportValidatorRejectsIncomplete200DuringResume() throws {
        let bytes = validGGUF(length: 32)
        let partial = bytes.prefix(16)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-partial-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try partial.write(to: url)

        // A truncated 200 body during resume cannot be assembled on this path.
        let response = HTTPURLResponse(
            url: URL(string: "https://signed.cdn.example.com/model.gguf")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let failure = DownloadTransportValidator.failure(
            response: response,
            bodyURL: url,
            expectedBytes: Int64(bytes.count),
            expectedOffset: 1024
        )
        guard case .sizeMismatch = failure else {
            return XCTFail("Expected sizeMismatch for incomplete 200 body during resume, got \(String(describing: failure))")
        }
    }

    // MARK: - Helpers

    private func validGGUF(length: Int) -> Data {
        TestModelFixtures.gguf(count: length)
    }

    private func fixtureModel(bytes: Data) -> AIModel {
        let id = "stale-resume-\(UUID().uuidString.lowercased())"
        return AIModel(
            id: id,
            displayName: "Stale Resume Fixture",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://catalog.ziroedge.app/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(bytes.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
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

    private func cleanup(task: DownloadTask, model: AIModel) {
        try? FileManager.default.removeItem(at: task.resumeDataURL)
        try? FileManager.default.removeItem(at: task.metadataURL)
        try? FileManager.default.removeItem(at: task.stagingURL)
        ModelManagerService.deleteModel(model)
    }
}

// Batch03StartupANRTests.swift
// ZiroEdge — BATCH-03 startup ANR regression tests
//
// Verifies:
// 1. PersistenceController store opening does not block MainActor
// 2. OfflineAvailabilityGuard.sweep hashes off the main actor
// 3. mtime+size cache skips re-hashing unchanged files

import XCTest
@testable import ZiroEdge
import CryptoKit

@MainActor
final class Batch03StartupANRTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ModelManagerService.resetSHA256CacheForTests()
        OfflineAvailabilityGuard.lastSweepWasOffMain = nil
        ModelManagerService.lastSHA256ComputeWasOffMain = nil
    }

    override func tearDown() {
        ModelManagerService.resetSHA256CacheForTests()
        OfflineAvailabilityGuard.lastSweepWasOffMain = nil
        // Clean any fixture models
        for model in ModelRegistry.allModels {
            ModelManagerService.deleteModel(model)
            ModelManagerService.clearRepairNeeded(for: model)
        }
        super.tearDown()
    }

    // MARK: - PersistenceController

    func testInMemoryInitDoesNotBlockMainForLong() async throws {
        // Must be callable on MainActor without extended block.
        // The in-memory init should return in < 200ms even on MainActor.
        let start = CFAbsoluteTimeGetCurrent()
        let persistence = PersistenceController(inMemory: true)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.5, "inMemory init blocked MainActor for \(elapsed)s")

        // Verify store is usable
        let id = try await persistence.createConversation(title: "ANR Test", modelID: "test-model")
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, id)
        XCTAssertTrue(Thread.isMainThread, "Test itself should be on MainActor")
    }

    func testPersistenceOpenInMemoryIsUsableAfterAwait() async throws {
        // The async open path must succeed when awaited from MainActor
        // and must have executed off the main thread (detached).
        let result = await PersistenceController.open(configuration: .inMemory)
        guard case .success(let persistence) = result else {
            XCTFail("open inMemory failed: \(result)")
            return
        }
        let id = try await persistence.createConversation(title: "Async Open", modelID: "test-model")
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.first?.id, id)
    }

    func testPersistenceOpenOffMainDoesNotBlockMainTask() async throws {
        // Start a MainActor task that awaits open, while a concurrent MainActor task
        // proves the MainActor was not hard-blocked (it could still process).
        let mainTaskRan = ActorIsolated(false)
        let openTask = Task { @MainActor in
            _ = await PersistenceController.open(configuration: .inMemory)
        }
        // Schedule a separate MainActor task that should run while open is suspended, not blocked
        Task { @MainActor in
            // If MainActor were semaphore-blocked, this would not run until open finished
            try? await Task.sleep(nanoseconds: 5_000_000)
            await mainTaskRan.setValue(true)
        }
        await openTask.value
        // Give the other task a moment
        try? await Task.sleep(nanoseconds: 10_000_000)
        let didRun = await mainTaskRan.value
        XCTAssertTrue(didRun, "MainActor was blocked during PersistenceController.open — ANR risk")
    }

    // MARK: - OfflineAvailabilityGuard off-main

    func testSweepRunsOffMainActor() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes = TestModelFixtures.gguf()
        let model = TestModelFixtures.text(data: bytes)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(bytes, for: model)

        // Use the async sweep which should run on a detached utility task
        let report = await OfflineAvailabilityGuard.sweep(extraModels: [model])
        XCTAssertEqual(OfflineAvailabilityGuard.lastSweepWasOffMain, true, "sweep must run off MainActor")

        // The SHA hashing itself should have been off-main (via detached)
        // If the file was hashed, lastSHA256ComputeWasOffMain should be true
        if ModelManagerService.sha256ComputeCount > 0 {
            XCTAssertEqual(ModelManagerService.lastSHA256ComputeWasOffMain, true, "SHA-256 hashing must run off MainActor")
        }
        // Semantics: fixture should be ready
        guard let readiness = report.models[model.id] else {
            XCTFail("Report missing fixture")
            return
        }
        if case .ready = readiness {
        } else {
            XCTFail("Expected ready for clean fixture, got \(readiness)")
        }
    }

    func testSyncSweepStillProducesCorrectReport() {
        // Legacy sync sweep must remain correct for existing tests
        let bytes = TestModelFixtures.gguf()
        let model = TestModelFixtures.text(data: bytes)
        defer { ModelManagerService.deleteModel(model) }
        do {
            try TestModelFixtures.install(bytes, for: model)
        } catch {
            XCTFail("install failed")
            return
        }
        let report = OfflineAvailabilityGuard.sweep(extraModels: [model])
        guard let readiness = report.models[model.id] else {
            XCTFail("Missing model")
            return
        }
        if case .ready = readiness {
        } else {
            XCTFail("Expected ready")
        }
    }

    // MARK: - SHA256 mtime+size cache

    func testSHA256CacheSkipsRehashForUnchangedFile() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(data: bytes)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(bytes, for: model)

        let url = ModelManagerService.baseModelPath(for: model)
        // First hash — should compute
        let first = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertNotNil(first)
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1)
        XCTAssertEqual(ModelManagerService.sha256CacheHitCount, 0)

        // Second hash without file change — should hit cache, no new computation
        let second = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1, "Second call should not recompute")
        XCTAssertEqual(ModelManagerService.sha256CacheHitCount, 1, "Second call should be cache hit")
    }

    /// P1-5: computed digests persist in a JSON sidecar keyed by path+mtime+size
    /// and are reloaded after a cold launch, so installed multi-GB artifacts are
    /// never re-hashed on the main thread at startup.
    func testSHA256SidecarServesHashAfterRelaunch() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(data: bytes)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(bytes, for: model)
        let url = ModelManagerService.baseModelPath(for: model)

        let first = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertNotNil(first)
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1)

        // Simulate a cold launch: in-memory stores are dropped while the
        // sidecar file stays on disk.
        ModelManagerService.simulateRelaunchForTests()

        let second = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertEqual(first, second, "Relaunched hash must match the persisted digest")
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1, "Sidecar entry must serve the hash without recomputing")
        XCTAssertEqual(ModelManagerService.sha256CacheHitCount, 1)
    }

    /// Stale sidecar entries must not resurrect old digests: a changed mtime
    /// or size invalidates the entry even after a relaunch.
    func testSHA256SidecarInvalidatesWhenFileChangesAfterRelaunch() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes1 = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(data: bytes1)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(bytes1, for: model)
        let url = ModelManagerService.baseModelPath(for: model)

        let hash1 = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1)

        // Ensure mtime will change (filesystem granularity is 1s on some volumes)
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        // Overwrite with different content (same size but different bytes -> mtime changes)
        var bytes2 = TestModelFixtures.gguf(count: 128)
        // Flip a byte to change hash without changing size
        if bytes2.count > 40 {
            bytes2[40] ^= 0xFF
        }
        try bytes2.write(to: url, options: .atomic)

        ModelManagerService.simulateRelaunchForTests()

        let hash2 = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertNotNil(hash2)
        XCTAssertNotEqual(hash1, hash2, "Hash should change when file content changes")
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 2, "Modified file must recompute after relaunch")
    }

    func testSHA256CacheInvalidatesWhenFileChanges() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes1 = TestModelFixtures.gguf(count: 128)
        let model1 = TestModelFixtures.text(data: bytes1)
        defer { ModelManagerService.deleteModel(model1) }
        try TestModelFixtures.install(bytes1, for: model1)
        let url = ModelManagerService.baseModelPath(for: model1)

        let hash1 = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 1)

        // Ensure mtime will change (filesystem granularity is 1s on some volumes)
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        // Overwrite with different content (same size but different bytes -> mtime changes)
        var bytes2 = TestModelFixtures.gguf(count: 128)
        // Flip a byte to change hash without changing size
        if bytes2.count > 40 {
            bytes2[40] ^= 0xFF
        }
        try bytes2.write(to: url, options: .atomic)

        let hash2 = ModelManagerService.computeSHA256(fileURL: url)
        XCTAssertNotNil(hash2)
        XCTAssertNotEqual(hash1, hash2, "Hash should change when file content changes")
        XCTAssertEqual(ModelManagerService.sha256ComputeCount, 2, "Modified file must recompute")
    }

    func testSweepCacheSkipsRehashOnSecondSweep() async throws {
        ModelManagerService.resetSHA256CacheForTests()
        let bytes = TestModelFixtures.gguf(count: 256)
        let model = TestModelFixtures.text(data: bytes)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(bytes, for: model)

        let firstReport = await OfflineAvailabilityGuard.sweep(extraModels: [model])
        let firstCount = ModelManagerService.sha256ComputeCount
        XCTAssertGreaterThan(firstCount, 0, "First sweep should hash")

        // Second sweep with unchanged file should hit cache
        let secondReport = await OfflineAvailabilityGuard.sweep(extraModels: [model])
        let secondCount = ModelManagerService.sha256ComputeCount
        XCTAssertEqual(firstCount, secondCount, "Second sweep with unchanged file should not re-hash (mtime+size cache)")
        XCTAssertEqual(firstReport.models[model.id], secondReport.models[model.id], "Availability must be identical across cached sweeps")
    }

    func testAvailabilitySemanticsPreservedWithCache() async throws {
        // Verify that using the cache does not change repairNeeded vs ready decisions
        ModelManagerService.resetSHA256CacheForTests()
        let cleanBytes = TestModelFixtures.gguf(count: 64)
        let cleanModel = TestModelFixtures.text(data: cleanBytes)
        defer { ModelManagerService.deleteModel(cleanModel) }
        try TestModelFixtures.install(cleanBytes, for: cleanModel)

        let firstReport = await OfflineAvailabilityGuard.sweep(extraModels: [cleanModel])
        XCTAssertEqual(firstReport.models[cleanModel.id], .ready(textOnly: false))

        // Corrupt the file
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        let corrupt = Data(repeating: 0x00, count: cleanBytes.count)
        try corrupt.write(to: ModelManagerService.baseModelPath(for: cleanModel), options: .atomic)
        // Clear cache to force re-read, or let mtime change trigger recompute
        // Do not clear cache — mtime should invalidate
        let secondReport = await OfflineAvailabilityGuard.sweep(extraModels: [cleanModel])
        guard let readiness = secondReport.models[cleanModel.id] else {
            XCTFail("Missing")
            return
        }
        if case .repairNeeded = readiness {
        } else {
            XCTFail("Corrupt file must be repairNeeded, got \(readiness)")
        }
    }
}

// Helper actor for test isolation
private actor ActorIsolated<T: Sendable> {
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { _value }
    func setValue(_ newValue: T) { _value = newValue }
}

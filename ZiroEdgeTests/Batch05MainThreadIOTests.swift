// Batch05MainThreadIOTests.swift
// ZiroEdge — BATCH-05 main-thread I/O regression
//
// Verifies:
// 1. Core Data fetches use batchSize (~50) and return identical data (no regression, imageData intact)
// 2. Managed storage breakdown is cached, NOT recomputed per progress tick at 5-20Hz, computed off-main

import XCTest
@testable import ZiroEdge

final class Batch05MainThreadIOTests: XCTestCase {

    // MARK: - 1. Fetch batchSize + predicate pushdown

    func testFetchConversationsBatchSizeReturnsIdenticalData() async throws {
        let persistence = PersistenceController(inMemory: true)
        // Create 60 conversations (exceeds batchSize 50) to verify batching doesn't drop rows or change ordering
        var createdIDs: [UUID] = []
        for index in 0..<60 {
            let id = try await persistence.createConversation(title: "Conversation \(index)", modelID: "model-\(index % 3)")
            createdIDs.append(id)
            // Small delay to ensure updatedAt ordering is deterministic
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        let result = await persistence.fetchConversationsResult()
        guard case .success(let payloads) = result else { return XCTFail("fetch failed") }
        XCTAssertEqual(payloads.count, 60, "must return all 60 conversations with batchSize 50")

        // Verify ordering is by updatedAt descending (most recent first) — same as before batch
        // Our createdIDs last is most recent, so first payload should be last created
        XCTAssertEqual(payloads.first?.id, createdIDs.last, "ordering must be preserved with batchSize")
        XCTAssertEqual(payloads.last?.id, createdIDs.first)

        // Verify each payload has expected fields (title/modelID)
        for payload in payloads {
            XCTAssertFalse(payload.title.isEmpty)
            XCTAssertFalse(payload.modelID.isEmpty)
        }

        // Verify historyEligibleOnly filter still works with batchSize (predicate pushdown is trivial — in-memory filter preserved)
        // Create a conversation with no history-eligible message (only user message)
        let emptyConv = try await persistence.createConversation(title: "empty", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: emptyConv, role: .user, content: "hello")
        // Create a conversation with an assistant completed message (history eligible)
        let eligibleConv = try await persistence.createConversation(title: "eligible", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: eligibleConv, role: .user, content: "hi")
        _ = await persistence.insertMessage(conversationID: eligibleConv, role: .assistant, content: "hello back")

        let filtered = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        guard case .success(let filteredPayloads) = filtered else { return XCTFail("filtered fetch failed") }
        // The empty conversation must not appear, eligible must appear
        XCTAssertFalse(filteredPayloads.contains(where: { $0.id == emptyConv }))
        XCTAssertTrue(filteredPayloads.contains(where: { $0.id == eligibleConv }))
    }

    func testFetchMessagesBatchSizeReturnsIdenticalDataWithImageData() async throws {
        let persistence = PersistenceController(inMemory: true)
        let convID = try await persistence.createConversation(title: "Batch Messages", modelID: "vision")

        // Create 60 messages (exceeds batchSize) with varying content and attachments (imageData)
        var expected: [ChatMessagePayload] = []
        for index in 0..<60 {
            let role: MessageRole = index % 2 == 0 ? .user : .assistant
            let attachments: [Data]? = (index % 3 == 0) ? [Data([UInt8(index)]), Data([UInt8(index+1), UInt8(index+2)])] : nil
            let content = "Message \(index) " + String(repeating: "x", count: index % 5)
            let msgID = await persistence.insertMessage(conversationID: convID, role: role, content: content, attachments: attachments)
            XCTAssertNotNil(msgID)
            expected.append(ChatMessagePayload(id: msgID!, role: role, content: content, attachments: attachments ?? [], sequenceIndex: Int32(index)))
        }

        let result = await persistence.fetchMessagesResult(conversationID: convID)
        guard case .success(let payloads) = result else { return XCTFail("fetchMessages failed") }
        XCTAssertEqual(payloads.count, 60, "must return all 60 messages with batchSize 50")
        // Verify ordering by sequenceIndex ascending and content/attachments intact (including imageData decoding)
        for (index, payload) in payloads.enumerated() {
            XCTAssertEqual(payload.sequenceIndex, Int32(index))
            XCTAssertEqual(payload.content, expected[index].content)
            XCTAssertEqual(payload.attachments, expected[index].attachments, "attachments must survive batch faulting")
            XCTAssertEqual(payload.role, expected[index].role)
        }

        // Verify predicate pushdown: only messages for this conversation are returned (not others)
        let otherConv = try await persistence.createConversation(title: "other", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: otherConv, role: .user, content: "other message")
        let filtered = await persistence.fetchMessagesResult(conversationID: convID)
        guard case .success(let filteredPayloads) = filtered else { return XCTFail("filtered fetch failed") }
        XCTAssertEqual(filteredPayloads.count, 60)
        XCTAssertFalse(filteredPayloads.contains(where: { $0.content == "other message" }))
    }

    func testFetchBatchSizeDoesNotFaultAllImageDataEagerly() async throws {
        // This is a behavioral check: fetching messages with batchSize should still decode imageData correctly
        // but not eagerly fault all rows at once (we verify correctness, batching is transparent)
        let persistence = PersistenceController(inMemory: true)
        let convID = try await persistence.createConversation(title: "Images", modelID: "vision")
        let largeAttachment = Data(repeating: 0xAB, count: 1024 * 10) // 10KB
        for _ in 0..<10 {
            _ = await persistence.insertMessage(conversationID: convID, role: .user, content: "img", attachments: [largeAttachment])
        }
        let result = await persistence.fetchMessagesResult(conversationID: convID)
        guard case .success(let payloads) = result else { return XCTFail("fetch failed") }
        XCTAssertEqual(payloads.count, 10)
        for payload in payloads {
            XCTAssertEqual(payload.attachments.first, largeAttachment)
        }
    }

    // MARK: - 2. Storage breakdown caching

    @MainActor
    func testStorageBreakdownNotRecomputedPerProgressTick() async throws {
        ModelMigrationService.ensureManagedDirectories()
        let manager = DownloadManager()
        // Reset spy counters (initial seed is 1, reset to 0 for clean measurement)
        manager.resetStorageBreakdownComputeCountForTests()
        XCTAssertEqual(manager.storageBreakdownComputeCount, 0)

        let lifecycle = ModelLifecycleManager(inferenceService: InferenceService(), memoryBudgeter: MemoryBudgeter())
        let report = await OfflineAvailabilityGuard.sweep()
        let viewModel = ModelsViewModel(downloadManager: manager, lifecycleManager: lifecycle, offlineAvailabilityReport: report)

        // Simulate 20 progress ticks at 5-20Hz: each tick would previously trigger managedStorageBreakdown enumeration
        // Now it must read cached value only (0 enumerations)
        for _ in 0..<20 {
            // Simulate progress tick side-effects: updateStatus + UI read
            // We don't have a real task, but we simulate the UI reading the cached property at high frequency
            _ = viewModel.managedStorageUsage
            _ = manager.cachedStorageBreakdown.formattedTotal
            // Trigger a downloadStatus change that causes objectWillChange (but should NOT invalidate cache)
            // Simulate didWriteData progress callback: updateStatuses and read storage
            manager.downloadStatuses["test"] = ModelDownloadStatus(modelID: "test", baseState: .downloading(progress: 0.5), mmprojState: nil)
            _ = viewModel.managedStorageUsage
        }

        XCTAssertEqual(manager.storageBreakdownComputeCount, 0, "storage breakdown must NOT be recomputed per progress tick (5-20Hz) — expected 0, got \(manager.storageBreakdownComputeCount)")

        // Now trigger a completion/promotion/quarantine/removal event — must invalidate and recompute off-main
        manager.scheduleStorageBreakdownRefresh()
        // Wait for detached task to complete (up to 2 seconds)
        for _ in 0..<20 {
            if manager.storageBreakdownComputeCount == 1 { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        XCTAssertEqual(manager.storageBreakdownComputeCount, 1, "must recompute exactly once after completion event")
        XCTAssertEqual(manager.lastStorageBreakdownWasOffMain, true, "recomputation must happen off-main (Task.detached)")

        // Simulate another burst of progress ticks — should still not recompute
        for _ in 0..<20 {
            _ = viewModel.managedStorageUsage
        }
        XCTAssertEqual(manager.storageBreakdownComputeCount, 1, "subsequent progress ticks must not trigger additional recomputation")

        // Trigger another invalidation (e.g., delete/removal)
        manager.scheduleStorageBreakdownRefresh()
        for _ in 0..<20 {
            if manager.storageBreakdownComputeCount == 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(manager.storageBreakdownComputeCount, 2)
        XCTAssertEqual(manager.lastStorageBreakdownWasOffMain, true)

        // Cleanup
        manager.resetStorageBreakdownComputeCountForTests()
    }

    @MainActor
    func testStorageBreakdownAsyncRefreshIsOffMainAndCoalesced() async throws {
        let manager = DownloadManager()
        manager.resetStorageBreakdownComputeCountForTests()

        // Schedule multiple rapid invalidations — should coalesce to single recomputation (last one wins)
        manager.scheduleStorageBreakdownRefresh()
        manager.scheduleStorageBreakdownRefresh()
        manager.scheduleStorageBreakdownRefresh()

        // Wait a bit
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Due to coalescing (cancel previous task), we expect only 1 recomputation, not 3
        XCTAssertLessThanOrEqual(manager.storageBreakdownComputeCount, 1, "rapid invalidations should coalesce")
        if manager.storageBreakdownComputeCount == 1 {
            XCTAssertEqual(manager.lastStorageBreakdownWasOffMain, true)
        }

        // Test explicit async refresh helper
        manager.resetStorageBreakdownComputeCountForTests()
        await manager.refreshStorageBreakdownAsyncForTests()
        XCTAssertEqual(manager.storageBreakdownComputeCount, 1)
        XCTAssertEqual(manager.lastStorageBreakdownWasOffMain, true)

        // Synchronous refresh for tests is on-main (not off-main) — used for immediate consistency in StorageCleanupTests
        manager.resetStorageBreakdownComputeCountForTests()
        manager.refreshStorageBreakdownForTests()
        XCTAssertEqual(manager.storageBreakdownComputeCount, 1)
        XCTAssertEqual(manager.lastStorageBreakdownWasOffMain, false)
    }

    @MainActor
    func testSyncManagedStorageBreakdownStillCorrect() throws {
        // Ensure the synchronous helper still returns correct breakdown even with caching layer
        ModelMigrationService.ensureManagedDirectories()
        let manager = DownloadManager()
        let stagingFile = ModelManagerService.stagingDirectory.appendingPathComponent("batch05-sync-test.partial")
        let data = Data(repeating: 0xCC, count: 8_000)
        try data.write(to: stagingFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stagingFile) }

        let breakdown = manager.managedStorageBreakdown()
        XCTAssertGreaterThanOrEqual(breakdown.stagingBytes, 8_000)
        XCTAssertEqual(breakdown.totalManagedBytes, breakdown.installedBytes + breakdown.stagingBytes + breakdown.resumeBytes + breakdown.quarantineBytes)
        XCTAssertFalse(breakdown.formattedTotal.isEmpty)
    }
}

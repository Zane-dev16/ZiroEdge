import XCTest
@testable import ZiroEdge

/// Recovery-durability verification for the BATCH-04 pending-tail journal.
/// Covers: tail-write error propagation, terminal-clear byte accounting,
/// overflow-preserve semantics, and mid-stream journal-write failure copy.
final class PendingTailDurabilityTests: XCTestCase {

    private func makeStore(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-tail-\(label)-\(UUID().uuidString).sqlite")
    }

    private func cleanup(_ store: URL) {
        for url in [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm")] {
            try? FileManager.default.removeItem(at: url)
        }
        let dir = store.deletingLastPathComponent()
        let prefix = ".\(store.lastPathComponent).stream-recovery"
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func journalURL(_ store: URL) -> URL {
        store.deletingLastPathComponent()
            .appendingPathComponent(".\(store.lastPathComponent).stream-recovery.json")
    }

    private func pendingURL(_ store: URL) -> URL {
        store.deletingLastPathComponent()
            .appendingPathComponent(".\(store.lastPathComponent).stream-recovery.pending.json")
    }

    // MARK: - Claim 1: tail-write failures must not be swallowed

    /// A faulted persistPendingTokens in the non-flush branch must surface as
    /// .failure(.journalWrite), mirroring the flush branch, instead of a silent
    /// .success while the tail bytes are not durable.
    func testTailWriteFailureIsNotSwallowed() async throws {
        let store = makeStore("tailfail")
        defer { cleanup(store) }

        guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
            return XCTFail("Open failed")
        }
        let conversationID = try await controller.createConversationResult(modelID: "fixture").get()
        let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()
        // Make the pending-file path unwritable by occupying it with a directory AFTER begin
        // (begin's own cleanup would otherwise remove it); the atomic write in
        // persistPendingTokens then fails deterministically.
        try FileManager.default.createDirectory(at: pendingURL(store), withIntermediateDirectories: true)

        let result = await controller.bufferTokens(messageID: messageID, tokens: "tail bytes")
        guard case .failure(let failure) = result else {
            return XCTFail("Tail-write failure was swallowed: caller saw success while bytes were not durable")
        }
        XCTAssertEqual(failure.operation, .journalWrite)
        XCTAssertEqual(failure.category, .journalWriteFailed)
        XCTAssertFalse(failure.errorDescription?.contains("damaged") ?? true,
                       "Transient tail-write failure must not be reported as damage")
    }

    // MARK: - Claim 2: terminal clear must not lose buffered tail

    /// Refutation proof for the terminal-clear byte-loss claim: bufferTokens folds
    /// every token into journal.targetContent synchronously (before any batching
    /// decision), and finalize persists+applies that full targetContent before
    /// clearRecoveryState runs. Tokens that never hit the batched flush therefore
    /// still reach the store verbatim at finalize.
    func testTerminalFinalizePersistsFullTailBeforeClear() async throws {
        let store = makeStore("terminal")
        defer { cleanup(store) }
        guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
            XCTFail("Open failed"); return
        }
        let conversationID = try await controller.createConversationResult(modelID: "fixture").get()
        let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()

        // Three tokens: below flushTokenCount(20) and inside flushIntervalMs, so
        // every token takes the non-flush pending-tail branch (no batched journal write).
        _ = try await controller.bufferTokens(messageID: messageID, tokens: "alpha").get()
        _ = try await controller.bufferTokens(messageID: messageID, tokens: "beta").get()
        _ = try await controller.bufferTokens(messageID: messageID, tokens: "gamma").get()
        let writes = await controller.getJournalWriteCount()
        XCTAssertEqual(writes, 1, "only beginStreamingMessage should have written the journal")

        do { _ = try await controller.endStreamingMessage(messageID: messageID).get() } catch {
            return XCTFail("finalize failed: \(error)")
        }
        let messages = try await controller.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "alphabetagamma",
                       "finalize must carry the un-flushed tail into the store before clearing recovery state")
    }

    // MARK: - Claim 3: oversized pending tail must survive recovery's clear

    /// When the restored journal + pending tail would exceed maximumBufferedBytes,
    /// the pending payload is kept "for inspection" — but a subsequent terminal
    /// replay (recoverIncompleteStreams) clears pendingTokensBuffer and deletes
    /// the pending file, silently destroying the only copy of those bytes.
    /// The overflow payload must be preserved durably instead.
    func testOverflowPendingTailSurvivesRecoveryClear() async throws {
        let store = makeStore("overflow")
        defer { cleanup(store) }
        let payload = String(repeating: "Z", count: 1_100_000)

        // Produce real crash-shaped state: flushed prefix in the journal, tail in the pending file.
        do {
            guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
                return XCTFail("Open failed")
            }
            let conversationID = try await controller.createConversationResult(modelID: "fixture").get()
            let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()
            for _ in 0..<25 { _ = await controller.bufferTokens(messageID: messageID, tokens: "tok ") }
            // No finalize — simulate crash here.
        }
        // Tamper the pending tail so journal+pending exceeds the buffering cap.
        let planted = try JSONEncoder().encode([payload])
        try planted.write(to: pendingURL(store), options: [.atomic])

        // Relaunch: restore hits the overflow branch, keeping the payload "for inspection".
        guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
            return XCTFail("Relaunch failed")
        }
        let recovery = await controller.recoverIncompleteStreams()
        XCTAssertNoThrow(try recovery.get(), "recovery must complete even with an overflowing pending tail")

        // The oversized payload must remain inspectable after recovery's terminal clear.
        let dir = store.deletingLastPathComponent()
        let artifacts = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains(".stream-recovery.pending") && $0.lastPathComponent.contains(".overflow-") }
        guard let artifact = artifacts.first else {
            return XCTFail("Overflow pending payload was silently destroyed by recovery's terminal clear; no inspection artifact preserved")
        }
        let preserved = try JSONDecoder().decode([String].self, from: Data(contentsOf: artifact))
        XCTAssertEqual(preserved, [payload], "preserved artifact must contain the exact pending payload")
    }

    // MARK: - Claim 4: mid-stream journal-write failure copy must match reality

    /// A transient journal-write failure during streaming leaves the prior journal
    /// intact — nothing is damaged. The user-facing copy must not claim damage.
    func testMidStreamJournalWriteFailureCopyIsAccurate() async throws {
        let store = makeStore("copy")
        defer { cleanup(store) }
        let faults = ScriptedPersistenceFaultInjector([
            .succeed(.journalWrite), // beginStreamingMessage journal
            .fail(.journalWrite, error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)),
        ])
        guard case .success(let controller) = await PersistenceController.open(
            configuration: .store(store),
            faultInjector: faults
        ) else {
            return XCTFail("Open failed")
        }
        let conversationID = try await controller.createConversationResult(modelID: "fixture").get()
        let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()

        // Token #20 crosses flushTokenCount and triggers the batched journal write that fails.
        var last: Result<Void, PersistenceMutationError>?
        for _ in 0..<20 { last = await controller.bufferTokens(messageID: messageID, tokens: "t ") }
        guard case .failure(let failure)? = last else {
            return XCTFail("Expected injected journal-write failure to surface on token #20")
        }
        XCTAssertEqual(failure.operation, .journalWrite)
        XCTAssertEqual(failure.category, .journalWriteFailed,
                       "Mid-stream journal-write failures must map to the transient category, not damage")
        let description = failure.errorDescription ?? ""
        XCTAssertFalse(description.contains("damaged"),
                       "Transient mid-stream write failure misreported as damaged data: \(description)")
    }
}

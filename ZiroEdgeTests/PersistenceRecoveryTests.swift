import XCTest
@testable import ZiroEdge

final class PersistenceRecoveryTests: XCTestCase {
    func testLoadFailureIsTypedAndRetryReopensSameStore() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-retry-\(UUID().uuidString).sqlite")
        defer { removeStoreTrio(store) }
        let injected = NSError(domain: "NSSQLiteErrorDomain", code: 14)
        let faults = ScriptedPersistenceFaultInjector([.fail(.loadStore, error: injected)])

        let first = await PersistenceController.open(configuration: .store(store), faultInjector: faults)
        guard case .failure(let failure) = first else { return XCTFail("Expected load failure") }
        XCTAssertEqual(failure.category, PersistenceFailureCategory.storeUnavailable)
        XCTAssertFalse(failure.sanitizedDiagnostic.contains(store.path))

        let second = await PersistenceController.open(configuration: .store(store), faultInjector: faults)
        guard case .success(let controller) = second else { return XCTFail("Retry should open the same store") }
        let created = await controller.createConversationResult(modelID: "fixture")
        guard case .success = created else { return XCTFail("Retry store should be writable") }
    }

    func testPermanentLoadFailureDoesNotCrash() async {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        for _ in 0..<2 {
            let faults = ScriptedPersistenceFaultInjector([.fail(.loadStore, error: error)])
            let result = await PersistenceController.open(configuration: .inMemory, faultInjector: faults)
            guard case .failure(let failure) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual(failure.operation, .loadStore)
        }
    }

    func testInjectedSaveRollsBackMutation() async throws {
        let faults = ScriptedPersistenceFaultInjector([.fail(.save, error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))])
        let opened = await PersistenceController.open(configuration: .inMemory, faultInjector: faults)
        guard case .success(let controller) = opened else { return XCTFail("Open failed") }

        let result = await controller.createConversationResult(modelID: "fixture")
        guard case .failure(let failure) = result else { return XCTFail("Expected save failure") }
        XCTAssertEqual(failure.category, .saveFailed)
        let conversations = await controller.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    func testInjectedOutOfSpaceEmergesThroughMutationPath() async {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let faults = ScriptedPersistenceFaultInjector([.fail(.save, error: error)])
        guard case .success(let controller) = await PersistenceController.open(
            configuration: .inMemory,
            faultInjector: faults
        ) else { return XCTFail("Open failed") }

        guard case .failure(let failure) = await controller.createConversationResult(modelID: "fixture") else {
            return XCTFail("Expected injected save failure")
        }
        XCTAssertEqual(failure.category, .insufficientStorage)
        let conversations = await controller.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    func testFailedFinalizationRetriesCanonicalContentExactlyOnce() async throws {
        let saveError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        let faults = ScriptedPersistenceFaultInjector([
            .succeed(.save),
            .succeed(.save),
            .fail(.save, error: saveError)
        ])
        guard case .success(let controller) = await PersistenceController.open(
            configuration: .inMemory,
            faultInjector: faults
        ) else { return XCTFail("Open failed") }
        let conversationID = try await controller.createConversation(modelID: "fixture")
        guard case .success(let messageID) = await controller.beginStreamingMessageResult(
            conversationID: conversationID
        ) else { return XCTFail("Begin failed") }
        let buffered = await controller.bufferTokens(messageID: messageID, tokens: "exact text")
        XCTAssertNoThrow(try buffered.get())
        guard case .failure = await controller.endStreamingMessage(messageID: messageID) else {
            return XCTFail("Expected final save failure")
        }
        guard let handle = await controller.recoveryHandle(messageID: messageID) else {
            return XCTFail("Recovery ownership must remain")
        }
        let firstRetry = await controller.retryStreamingSave(handle)
        XCTAssertNoThrow(try firstRetry.get())
        let secondRetry = await controller.retryStreamingSave(handle)
        XCTAssertNoThrow(try secondRetry.get())
        let messages = try await controller.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "exact text")
        XCTAssertFalse(messages.first?.isStreaming ?? true)
    }

    func testFailedPeriodicFlushRetainsSnapshotAndRetryFinalizesIt() async throws {
        let saveError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        let faults = ScriptedPersistenceFaultInjector([
            .succeed(.save), .succeed(.save), .fail(.save, error: saveError)
        ])
        guard case .success(let controller) = await PersistenceController.open(
            configuration: .inMemory,
            faultInjector: faults
        ) else { return XCTFail("Open failed") }
        let conversationID = try await controller.createConversation(modelID: "fixture")
        let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()
        for index in 0..<20 {
            let result = await controller.bufferTokens(messageID: messageID, tokens: "\(index),")
            if index < 19 { XCTAssertNoThrow(try result.get()) }
            else if case .success = result { XCTFail("Threshold flush should fail") }
        }
        let expected = (0..<20).map { "\($0)," }.joined()
        let snapshot = await controller.streamingRecoverySnapshot(messageID: messageID)
        XCTAssertEqual(String(data: snapshot ?? Data(), encoding: .utf8), expected)
        let optionalHandle = await controller.recoveryHandle(messageID: messageID)
        let handle = try XCTUnwrap(optionalHandle)
        let retry = await controller.retryStreamingSave(handle)
        XCTAssertNoThrow(try awaitResult(retry))
        let messages = try await controller.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertEqual(messages.first?.content, expected)
        XCTAssertFalse(messages.first?.isStreaming ?? true)
    }

    func testDurableJournalReplaysOnceAfterControllerRestart() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-replay-\(UUID().uuidString).sqlite")
        defer {
            removeStoreTrio(store)
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent()
                .appendingPathComponent(".\(store.lastPathComponent).stream-recovery.json"))
        }
        let conversationID = try await seedInterruptedJournal(store: store, text: "durable text")
        guard case .success(let reopened) = await PersistenceController.open(configuration: .store(store)) else {
            return XCTFail("Reopen failed")
        }
        let firstRecovery = await reopened.recoverIncompleteStreams()
        XCTAssertNoThrow(try awaitResult(firstRecovery))
        let secondRecovery = await reopened.recoverIncompleteStreams()
        XCTAssertNoThrow(try awaitResult(secondRecovery))
        let messages = try await reopened.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "durable text\n\n_[Interrupted — app was closed]_")
    }

    func testOneUnresolvedRecoveryGloballyBlocksAnotherStream() async throws {
        guard case .success(let controller) = await PersistenceController.open(configuration: .inMemory) else {
            return XCTFail("Open failed")
        }
        let conversationID = try await controller.createConversation(modelID: "fixture")
        guard case .success = await controller.beginStreamingMessageResult(conversationID: conversationID) else {
            return XCTFail("First stream failed")
        }
        guard case .failure(let failure) = await controller.beginStreamingMessageResult(
            conversationID: conversationID
        ) else { return XCTFail("Second stream must be blocked") }
        XCTAssertEqual(failure.category, .recoveryBufferFull)
    }

    func testCorruptSQLiteExercisesRealPersistentStoreLoadFailure() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-load-\(UUID().uuidString).sqlite")
        defer { removeStoreTrio(store) }
        try Data("not sqlite".utf8).write(to: store)
        guard case .failure(let failure) = await PersistenceController.open(configuration: .store(store)) else {
            return XCTFail("Core Data should reject corrupt SQLite")
        }
        XCTAssertEqual(failure.operation, .loadStore)
        XCTAssertEqual(failure.category, .storeUnavailable)
    }

    func testScriptConsumptionIsDeterministic() {
        let error = NSError(domain: "fixture", code: 1)
        let injector = ScriptedPersistenceFaultInjector([
            .fail(.save, error: error), .succeed(.save), .fail(.fetch, error: error)
        ])
        XCTAssertNotNil(injector.fault(for: .save))
        XCTAssertNil(injector.fault(for: .save))
        XCTAssertNotNil(injector.fault(for: .fetch))
        XCTAssertEqual(injector.remainingStepCount, 0)
    }

    private func seedInterruptedJournal(store: URL, text: String) async throws -> UUID {
        guard case .success(let controller) = await PersistenceController.open(configuration: .store(store)) else {
            throw PersistenceFailure.notFound()
        }
        let conversationID = try await controller.createConversation(modelID: "fixture")
        let messageID = try await controller.beginStreamingMessageResult(conversationID: conversationID).get()
        try await controller.bufferTokens(messageID: messageID, tokens: text).get()
        return conversationID
    }

    private func awaitResult<T>(_ result: Result<T, PersistenceFailure>) throws -> T {
        try result.get()
    }

    private func removeStoreTrio(_ url: URL) {
        for candidate in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}

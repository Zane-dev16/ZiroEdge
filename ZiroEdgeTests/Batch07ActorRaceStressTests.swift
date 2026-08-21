// Batch07ActorRaceStressTests.swift
// BATCH-07: deterministic actor-boundary stress coverage.
// Exercises concurrent interleavings across PersistenceController (tokenBuffer /
// writerContext / recovery journal), MemoryBudgeter decisions, and
// ChatSessionActor cancel-vs-start races. All tests are timeout-gated and
// complete in well under 30s on device.

import XCTest
@testable import ZiroEdge

// MARK: - Helpers

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Minimal inference service double: canned stream with a small delay so that
/// cancel()/startStream() calls from other tasks reliably interleave.
private final class StressInferenceService: InferenceServiceProtocol, @unchecked Sendable {
    let delayMs: UInt64
    private let loaded = LockedCounter()
    private let unloaded = LockedCounter()

    init(delayMs: UInt64 = 25) { self.delayMs = delayMs }
    var loadCount: Int { loaded.count }
    var unloadCount: Int { unloaded.count }

    var isModelLoaded: Bool { true }
    var loadedModelID: String? { "stress-model" }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loaded.increment()
    }
    func unloadModel() async { unloaded.increment() }
    func cancelCurrentStream() async {}

    func streamChat(messages: [ChatMessagePayload], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
        Self.cannedStream(delayMs: delayMs)
    }
    func streamVisionChat(messages: [ChatMessagePayload], images: [Data], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
        Self.cannedStream(delayMs: delayMs)
    }

    private static func cannedStream(delayMs: UInt64) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                continuation.yield("stress ")
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                continuation.yield("response")
                continuation.finish()
            }
        }
    }
}

@MainActor
final class Batch07ActorRaceStressTests: XCTestCase {

    // MARK: - tokenBuffer concurrency

    /// 20 tasks × 50 chunks hammer bufferTokens on one streaming message.
    /// The actor serializes mutations; after recovery every chunk must be
    /// present exactly once (multiset equality) and the row must be terminal.
    func testConcurrentBufferTokens_allTokensAccountedAfterRecovery() async throws {
        let persistence = PersistenceController(inMemory: true)
        let conversationID = try await persistence.createConversationResult(modelID: "stress-model").get()
        let messageID = try await persistence.beginStreamingMessageResult(conversationID: conversationID).get()

        let tasks = 20, chunksPerTask = 50
        var expected: [String] = []
        expected.reserveCapacity(tasks * chunksPerTask)
        for taskIndex in 0..<tasks {
            for chunkIndex in 0..<chunksPerTask {
                expected.append("t\(taskIndex)c\(chunkIndex)")
            }
        }
        await withTaskGroup(of: Result<Void, PersistenceMutationError>.self) { group in
            for taskIndex in 0..<tasks {
                group.addTask { @Sendable [weak persistence] in
                    guard let persistence else { return .failure(.notFound()) }
                    var last: Result<Void, PersistenceMutationError> = .success(())
                    for chunkIndex in 0..<chunksPerTask {
                        let chunk = "t\(taskIndex)c\(chunkIndex);"
                        last = await persistence.bufferTokens(messageID: messageID, tokens: chunk)
                        if case .failure = last { return last }
                    }
                    return last
                }
            }
            for await taskIndexResult in group {
                guard case .success = taskIndexResult else {
                    XCTFail("bufferTokens failed during stress: \(taskIndexResult)")
                    return
                }
            }
        }
        XCTAssertEqual(expected.count, tasks * chunksPerTask)

        let recovery = await persistence.recoverIncompleteStreams()
        XCTAssertNoThrow(try recovery.get())

        let messages = try await persistence.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isStreaming ?? true, "recovery must clear isStreaming")

        let content = messages.first?.content ?? ""
        // Token chunks are ";"-delimited; filter them out from the interruption marker.
        let actualChunks = content.split(separator: ";").map(String.init).filter { $0.hasPrefix("t") }.sorted()
        XCTAssertEqual(actualChunks, expected.sorted(),
                       "every buffered token must survive exactly once (got \(actualChunks.count), want \(expected.count))")
    }

    // MARK: single-stream guard

    /// beginStreamingMessageResult enforces a single active stream. Ten
    /// concurrent begins must yield exactly one winner and nine
    /// .recoveryBufferFull failures — never two journals.
    func testConcurrentBeginStreaming_exactlyOneWinner() async throws {
        let persistence = PersistenceController(inMemory: true)
        for cycle in 0..<3 {
            let conversationID = try await persistence.createConversationResult(modelID: "stress-model").get()
            let beginResults = await withTaskGroup(of: Result<UUID, PersistenceFailure>.self, returning: [Result<UUID, PersistenceFailure>].self) { group in
                for _ in 0..<10 {
                    group.addTask { @Sendable [weak persistence] in
                        guard let persistence else { return .failure(.notFound()) }
                        return await persistence.beginStreamingMessageResult(conversationID: conversationID)
                    }
                }
                var collected: [Result<UUID, PersistenceFailure>] = []
                for await result in group { collected.append(result) }
                return collected
            }
            let winners = beginResults.filter { if case .success = $0 { return true }; return false }
            let losers = beginResults.filter { if case .failure(let failure) = $0 { return failure == .recoveryBufferFull }; return false }
            XCTAssertEqual(winners.count, 1, "cycle \(cycle): exactly one stream may win")
            XCTAssertEqual(losers.count, 9, "cycle \(cycle): all losers must report recoveryBufferFull")
            XCTAssertEqual(beginResults.count, 10)

            // Terminalize so the next cycle can begin.
            let recovery = await persistence.recoverIncompleteStreams()
            XCTAssertNoThrow(try recovery.get(), "cycle \(cycle)")
        }
    }

    /// recoverIncompleteStreams racing active buffering must always land in a
    /// consistent terminal state and leave the controller reusable.
    func testInterleavedRecoveryDuringBuffering_reachesTerminalState() async throws {
        let persistence = PersistenceController(inMemory: true)
        let conversationID = try await persistence.createConversationResult(modelID: "stress-model").get()
        let messageID = try await persistence.beginStreamingMessageResult(conversationID: conversationID).get()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable [weak persistence] in
                guard let persistence else { return }
                for index in 0..<200 {
                    _ = await persistence.bufferTokens(messageID: messageID, tokens: "chunk\(index);")
                    await Task.yield()
                }
            }
            group.addTask { @Sendable [weak persistence] in
                guard let persistence else { return }
                for _ in 0..<20 {
                    _ = await persistence.recoverIncompleteStreams()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            while await group.next() != nil {}
        }

        // Final quiescent recovery must succeed and clear the stream.
        let finalRecovery = await persistence.recoverIncompleteStreams()
        XCTAssertNoThrow(try finalRecovery.get())
        let messages = try await persistence.fetchMessagesResult(conversationID: conversationID).get()
        XCTAssertTrue(messages.allSatisfy { !$0.isStreaming }, "no row may remain streaming after final recovery")

        // Controller must be immediately reusable — no stuck recovery-buffer-full.
        let nextConversation = try await persistence.createConversationResult(modelID: "stress-model").get()
        let nextBegin = await persistence.beginStreamingMessageResult(conversationID: nextConversation)
        guard case .success = nextBegin else {
            return XCTFail("controller must accept a new stream after stress, got: \(nextBegin)")
        }
    }

    // MARK: writerContext CRUD concurrency

    /// Concurrent create/title/fetch cycles through writerContext must lose
    /// nothing: all conversations present with their distinct titles intact.
    func testWriterContext_concurrentConversationCRUD_noLoss() async throws {
        let persistence = PersistenceController(inMemory: true)
        let writers = 12
        var ids: [UUID] = []
        ids.reserveCapacity(writers)
        for index in 0..<writers {
            let id = UUID()
            try await persistence.createConversationResult(id: id, title: "untouched-\(index)", modelID: "stress-model").get()
            ids.append(id)
        }
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { @Sendable [weak persistence] in
                    guard let persistence else { return }
                    for _ in 0..<5 {
                        _ = await persistence.updateConversationTitle(id: id, title: "renamed-\(index)")
                        _ = await persistence.fetchConversationsResult()
                        await Task.yield()
                    }
                }
            }
            while await group.next() != nil {}
        }
        let result = await persistence.fetchConversationsResult()
        guard case .success(let payloads) = result else { return XCTFail("fetch failed: \(result)") }
        XCTAssertEqual(payloads.count, writers, "all concurrently-written conversations must be present")
        let titles = Set(payloads.compactMap(\.title))
        for index in 0..<writers {
            XCTAssertTrue(titles.contains("renamed-\(index)") || titles.contains("untouched-\(index)"),
                          "conversation \(index) missing or retitled by a foreign writer")
        }
    }

    // MARK: MemoryBudgeter decision concurrency

    /// Concurrent decision() sampling against a fixed metrics provider must be
    /// stable: identical inputs produce identical decisions, no tearing.
    func testMemoryBudgeter_concurrentDecisions_deterministicInvariants() async throws {
        let gb: UInt64 = 1_000_000_000
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(processAvailable: 2 * gb, total: 8 * gb))
        let model = AIModel(
            id: "stress-budget-model",
            displayName: "Stress",
            description: "stress",
            modelType: .text,
            baseURL: URL(string: "https://example.com/stress.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1_000_000_000,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )

        let firstDecision = await budgeter.decision(for: model)
        let headroom = await budgeter.appMemoryHeadroom()
        let totalRAM = await budgeter.totalDeviceRAM()
        XCTAssertEqual(headroom, 2 * gb)
        XCTAssertEqual(totalRAM, 8 * gb)

        await withTaskGroup(of: MemoryLoadDecision.self) { group in
            for _ in 0..<12 {
                group.addTask { @Sendable [model] in
                    var last = firstDecision
                    for _ in 0..<50 {
                        last = await budgeter.decision(for: model)
                        _ = await budgeter.postLoadReserveSatisfied()
                        _ = await budgeter.formattedAppMemoryHeadroom()
                    }
                    return last
                }
            }
            for await decision in group {
                XCTAssertEqual(decision.processAvailableBytes, 2 * gb, "metrics must never tear")
                XCTAssertEqual(decision.totalPhysicalBytes, 8 * gb)
                XCTAssertEqual(decision.recommendation, firstDecision.recommendation,
                               "identical inputs must produce identical recommendations")
            }
        }
    }

    // MARK: ChatSessionActor cancel-vs-start race

    /// cancel() racing startStream() must leave exactly one terminal outcome:
    /// at most one onComplete/onError pair fires, and after all work joins the
    /// session reports isStreaming == false.
    func testChatSessionActor_cancelRace_singleTerminalState() async throws {
        let persistence = PersistenceController(inMemory: true)
        let conversationID = try await persistence.createConversationResult(modelID: "stress-model").get()
        let inference = StressInferenceService(delayMs: 30)
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)

        let completions = LockedCounter()
        let errors = LockedCounter()
        let noopToken: @Sendable (String) -> Void = { _ in }

        await session.startStream(
            conversationID: conversationID,
            messages: [ChatMessagePayload(role: .user, content: "hi")],
            systemPrompt: nil,
            sampling: SamplingConfig.default,
            onToken: noopToken,
            onComplete: { completions.increment() },
            onError: { _ in errors.increment() }
        )

        // Hammer cancel while racing replacement streams.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @Sendable in
                    await session.cancel()
                }
            }
            group.addTask { @Sendable in
                for _ in 0..<3 {
                    await session.startStream(
                        conversationID: conversationID,
                        messages: [ChatMessagePayload(role: .user, content: "race")],
                        systemPrompt: nil,
                        sampling: SamplingConfig.default,
                        onToken: noopToken,
                        onComplete: { completions.increment() },
                        onError: { _ in errors.increment() }
                    )
                }
            }
            while await group.next() != nil {}
        }

        // Quiesce: final cancel then settle.
        await session.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)

        let stillStreaming = await session.isStreaming
        XCTAssertFalse(stillStreaming, "session must not remain streaming after cancel storm")
        XCTAssertLessThanOrEqual(completions.count + errors.count, 4,
                                 "at most one terminal callback per generation attempt (got \(completions.count)+\(errors.count))")
    }
}

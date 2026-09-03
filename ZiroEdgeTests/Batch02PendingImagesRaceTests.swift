// Batch02PendingImagesRaceTests.swift
// BATCH-02: pendingImages lost-update race
// Reproduction: inject addImage between insert and streaming awaits and assert
// interleaved batch is not lost.

import XCTest
@testable import ZiroEdge
import UIKit

@MainActor
final class Batch02PendingImagesRaceTests: XCTestCase {

    // MARK: - Helpers

    private final class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        var readyModelID: String?
        func status(for model: AIModel) -> ModelDownloadStatus {
            guard model.id == readyModelID else {
                return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
            }
            // Vision ready: both base and projector downloaded
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .downloaded,
                mmprojState: .downloaded
            )
        }
    }

    private actor DelayedRecordingInferenceService: InferenceServiceProtocol {
        enum Kind: Equatable, Sendable { case text, vision }
        struct Call: Sendable {
            let kind: Kind
            let messages: [ChatMessagePayload]
            let images: [Data]
            let sampling: SamplingConfig
        }
        private var recorded: [Call] = []
        private var loadedID: String?
        private var cannedChunks: [String] = ["Canned ", "response"]
        let streamingDelay: Duration

        init(streamingDelay: Duration = .milliseconds(350)) {
            self.streamingDelay = streamingDelay
        }

        func setCannedChunks(_ chunks: [String]) { cannedChunks = chunks }

        var isModelLoaded: Bool { loadedID != nil }
        var loadedModelID: String? { loadedID }

        func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
            loadedID = model.id
        }
        func unloadModel() async { loadedID = nil }
        func cancelCurrentStream() async {}

        func streamChat(messages: [ChatMessagePayload], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            // Simulate the await window between insert and streaming
            try? await Task.sleep(for: streamingDelay)
            recorded.append(Call(kind: .text, messages: messages, images: [], sampling: sampling))
            return cannedStream()
        }
        func streamVisionChat(messages: [ChatMessagePayload], images: [Data], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            try? await Task.sleep(for: streamingDelay)
            recorded.append(Call(kind: .vision, messages: messages, images: images, sampling: sampling))
            return cannedStream()
        }
        func calls() -> [Call] { recorded }

        private func cannedStream() -> AsyncThrowingStream<String, Error> {
            let chunks = cannedChunks
            return AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    private func makeImageData(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.pngData() ?? Data(repeating: 0xAA, count: 64)
    }

    private struct Harness {
        let viewModel: ChatViewModel
        let persistence: PersistenceController
        let inference: DelayedRecordingInferenceService
        let session: ChatSessionActor
        let lifecycle: ModelLifecycleManager
        let root: URL
    }

    private func makeHarness(
        streamingDelay: Duration = .milliseconds(300)
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Batch02-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = PersistenceController(inMemory: true)
        let inference = DelayedRecordingInferenceService(streamingDelay: streamingDelay)
        let memoryBudgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(processAvailable: UInt64.max, total: UInt64.max))
        let loadSafetyStore = try LoadSafetyStore(directory: root.appendingPathComponent("load-safety"))
        let importedStore = ImportedModelStore(directory: root.appendingPathComponent("imports"))
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: memoryBudgeter,
            loadSafetyStore: loadSafetyStore,
            importedModelStore: importedStore,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let visionModel = ModelRegistry.gemma4_e2b
        let status = MockDownloadStatusProvider()
        status.readyModelID = visionModel.id
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: { [visionModel] }
        )
        return Harness(
            viewModel: viewModel,
            persistence: persistence,
            inference: inference,
            session: session,
            lifecycle: lifecycle,
            root: root
        )
    }

    private func waitForCompletion(_ viewModel: ChatViewModel, timeout: Duration = .seconds(4)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while viewModel.isStreaming || viewModel.messages.last?.content != "Canned response" {
            guard clock.now < deadline else {
                let msg = "Timed out. streaming=\(viewModel.isStreaming) "
                    + "messages=\(viewModel.messages.map(\.content))"
                throw NSError(domain: "Batch02", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForStreamingEnd(_ viewModel: ChatViewModel, timeout: Duration = .seconds(4)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while viewModel.isStreaming {
            guard clock.now < deadline else {
                let msg = "Timed out. streaming=\(viewModel.isStreaming) "
                    + "messages=\(viewModel.messages.map(\.content))"
                throw NSError(domain: "Batch02", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// P2-10: `tokenCount` must accumulate real generated tokens (one per
    /// streamed yield), not flush batches.
    func testSessionActorTokenCountCountsYields() async throws {
        let harness = try await makeHarness(streamingDelay: .milliseconds(50))
        let viewModel = harness.viewModel
        let persistence = harness.persistence
        let session = harness.session
        let root = harness.root
        defer { try? FileManager.default.removeItem(at: root) }

        let visionModel = ModelRegistry.gemma4_e2b
        let conversationID = try await persistence.createConversation(title: "Token Count", modelID: visionModel.id)
        await viewModel.loadConversation(conversationID)

        viewModel.inputText = "count my tokens"
        await viewModel.sendMessage()
        try await waitForCompletion(viewModel)

        // The mock yields exactly two chunks; each is one decode step.
        let tokenCount = await session.tokenCount
        XCTAssertEqual(tokenCount, 2, "tokenCount must count yielded tokens, not flush batches")
    }

    /// P2-6: a whitespace-only assistant reply is persisted by
    /// endStreamingMessage, so the in-memory transcript must mirror the
    /// persisted row (user-unloaded conversations never reload from disk —
    /// the old trimmed-empty check silently dropped the reply).
    func testWhitespaceOnlyReplyMirrorsPersistedRowWhenUserUnloaded() async throws {
        let harness = try await makeHarness(streamingDelay: .milliseconds(350))
        let viewModel = harness.viewModel
        let persistence = harness.persistence
        let inference = harness.inference
        let lifecycle = harness.lifecycle
        let root = harness.root
        defer { try? FileManager.default.removeItem(at: root) }

        let whitespaceReply = "  \n\t"
        await inference.setCannedChunks([whitespaceReply])

        let visionModel = ModelRegistry.gemma4_e2b
        let conversationID = try await persistence.createConversation(title: "Whitespace", modelID: visionModel.id)
        await viewModel.loadConversation(conversationID)

        viewModel.inputText = "hello"
        await viewModel.sendMessage()
        XCTAssertTrue(viewModel.isStreaming)

        // User-initiated unload mid-generation: the stub stream completes
        // naturally afterwards, so onComplete runs with isUserUnloaded set.
        _ = await lifecycle.unloadCurrentModel(userInitiated: true)
        try await waitForStreamingEnd(viewModel)

        let lastContent = viewModel.messages.last?.content
        XCTAssertEqual(
            lastContent,
            whitespaceReply,
            "Whitespace-only reply persisted by endStreamingMessage must be mirrored in the transcript"
        )
        // And the persisted row carries the same bytes.
        let persisted = await persistence.fetchMessages(conversationID: conversationID)
        XCTAssertEqual(persisted.last?.content, whitespaceReply)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }

    // MARK: - Race Test (must be RED before fix, GREEN after)

    /// Simulates: user has batch1 pending, taps send, then while sendMessage is suspended
    /// between insert and streaming (await window), user attaches batch2.
    /// Bug: clearAll after streaming wipes batch2 → silent loss.
    /// Fix: prefix-remove before await preserves batch2.
    func testPendingImagesRaceDuringStreamingPreservesInterleavedAdds() async throws {
        let harness = try await makeHarness(streamingDelay: .milliseconds(100))
        let viewModel = harness.viewModel
        let persistence = harness.persistence
        let inference = harness.inference
        let root = harness.root
        defer { try? FileManager.default.removeItem(at: root) }

        let visionModel = ModelRegistry.gemma4_e2b
        let conversationID = try await persistence.createConversation(title: "Batch02 Race", modelID: visionModel.id)
        await viewModel.loadConversation(conversationID)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.activeConversationID, conversationID)

        let batch1 = makeImageData(color: .red)
        let batch2 = makeImageData(color: .blue)

        viewModel.pendingImages = [batch1]
        viewModel.inputText = "hello with image"

        // Deterministically inject batch2 between the two awaits (insert and
        // streaming) via the DEBUG hook. This is the lost-update race.
        viewModel.testHookBetweenAwaits = { [weak viewModel] in
            await viewModel?.addImage(batch2)
        }
        await viewModel.sendMessage()
        viewModel.testHookBetweenAwaits = nil

        try await waitForCompletion(viewModel)

        // BOTH batches must be accounted for: batch1 in history, batch2 still pending (not lost)
        let persisted = await persistence.fetchMessages(conversationID: conversationID)
        let userMessages = persisted.filter { $0.role == .user }
        XCTAssertFalse(userMessages.isEmpty, "User message should have been persisted")
        let persistedAttachments = userMessages.first?.attachments ?? []
        XCTAssertEqual(persistedAttachments, [batch1], "History must contain the original batch1 (sent message)")

        let calls = await inference.calls()
        let visionCall = calls.first(where: { $0.kind == .vision })
        XCTAssertNotNil(visionCall, "Vision stream should have been invoked")
        XCTAssertEqual(visionCall?.images, [batch1], "Stream should have received only batch1, not batch2")

        // Pending must still contain batch2 — not wiped by clearAll
        XCTAssertEqual(viewModel.pendingImages, [batch2], "Interleaved batch2 must survive streaming; buggy clearAll would make this []")

        // Also ensure pending not empty and history not containing batch2 (batch2 stays pending for next message)
        XCTAssertEqual(viewModel.pendingImages.count, 1)
        XCTAssertEqual(viewModel.pendingImages.first, batch2)
    }

    /// Failure path: if insert fails, snapshot must be restored (including preserving interleaved).
    func testPendingImagesRestoredOnInsertFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Batch02-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let injectedError = NSError(domain: "Test", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "injected save failure"])
        let fault = ScriptedPersistenceFaultInjector([
            .succeed(.save),
            .fail(.save, error: injectedError)
        ])
        let persistence = try await PersistenceController.open(configuration: .inMemory, faultInjector: fault).get()
        let inference = DelayedRecordingInferenceService(streamingDelay: .milliseconds(100))
        let memoryBudgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(processAvailable: UInt64.max, total: UInt64.max))
        let loadSafetyStore = try LoadSafetyStore(directory: root.appendingPathComponent("load-safety"))
        let importedStore = ImportedModelStore(directory: root.appendingPathComponent("imports"))
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: memoryBudgeter,
            loadSafetyStore: loadSafetyStore,
            importedModelStore: importedStore,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let visionModel = ModelRegistry.gemma4_e2b
        let status = MockDownloadStatusProvider()
        status.readyModelID = visionModel.id
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: { [visionModel] }
        )

        let conversationID = try await persistence.createConversation(title: "Failure test", modelID: visionModel.id)
        await viewModel.loadConversation(conversationID)
        try await Task.sleep(for: .milliseconds(100))

        let batch1 = makeImageData(color: .red)
        viewModel.pendingImages = [batch1]
        viewModel.inputText = "will fail"

        await viewModel.sendMessage()

        // On failure, pendingImages must be restored (not lost) and inputText restored
        XCTAssertEqual(viewModel.pendingImages, [batch1], "On insert failure, pendingImages must be restored")
        XCTAssertEqual(viewModel.inputText, "will fail", "Input text must be restored on failure")
        XCTAssertNotNil(viewModel.errorMessage)
    }
}

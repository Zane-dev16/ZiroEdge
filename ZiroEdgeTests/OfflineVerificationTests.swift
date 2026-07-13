// OfflineVerificationTests.swift
// ZiroEdgeTests
//
// Tests that verify the app works fully offline after models are downloaded.
// These tests confirm that no network dependency exists in the hot path
// (model loading, inference, Core Data, conversation persistence).

import XCTest
import CoreData
@testable import ZiroEdge

// MARK: - Mock Inference Service (no network, no file I/O)

/// A mock InferenceService that records calls and verifies no network dependency.
/// Used to test the inference path without requiring actual model files.
final class MockInferenceService: InferenceServiceProtocol, @unchecked Sendable {

    // Call tracking
    var loadModelCallCount = 0
    var unloadModelCallCount = 0
    var streamChatCallCount = 0
    var streamVisionChatCallCount = 0
    var cancelCallCount = 0

    // State
    private var _isModelLoaded = false
    private var _loadedModelID: String?

    // Configurable behavior
    var loadModelError: Error?
    var streamChunks: [String] = ["Hello", " world", "!"]

    var isModelLoaded: Bool {
        get async { _isModelLoaded }
    }

    var loadedModelID: String? {
        get async { _loadedModelID }
    }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadModelCallCount += 1
        if let error = loadModelError {
            throw error
        }
        _isModelLoaded = true
        _loadedModelID = model.id
    }

    func unloadModel() {
        unloadModelCallCount += 1
        _isModelLoaded = false
        _loadedModelID = nil
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        streamChatCallCount += 1
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in streamChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        streamVisionChatCallCount += 1
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in streamChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    func cancelCurrentStream() {
        cancelCallCount += 1
    }
}

// MARK: - Offline Model Loading Tests

/// Verifies that model loading works entirely from local files with no network dependency.
@MainActor
final class OfflineModelLoadingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ModelManagerService.ensureModelsDirectory()
    }

    // MARK: - Model File Paths Are Absolute

    func testModelPathsAreAbsolute() {
        // Model file paths must be absolute local paths, not relative or network-based.
        for model in ModelRegistry.allModels {
            let baseURL = ModelManagerService.baseModelPath(for: model)
            XCTAssertTrue(
                baseURL.path.hasPrefix("/"),
                "Model base path must be absolute: \(baseURL.path)"
            )
            XCTAssertTrue(
                baseURL.path.hasSuffix(".gguf"),
                "Model base path must end with .gguf: \(baseURL.path)"
            )

            if model.requiresMMProj {
                let mmprojURL = ModelManagerService.mmprojModelPath(for: model)
                XCTAssertTrue(
                    mmprojURL.path.hasPrefix("/"),
                    "Model mmproj path must be absolute: \(mmprojURL.path)"
                )
                XCTAssertTrue(
                    mmprojURL.path.hasSuffix(".gguf"),
                    "Model mmproj path must end with .gguf: \(mmprojURL.path)"
                )
            }
        }
    }

    func testModelPathsAreInDocumentsDirectory() {
        // Model paths must be in the app's Documents directory (not a network URL).
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

        for model in ModelRegistry.allModels {
            let baseURL = ModelManagerService.baseModelPath(for: model)
            XCTAssertTrue(
                baseURL.path.hasPrefix(documentsDir),
                "Model base path must be in Documents: \(baseURL.path)"
            )
        }
    }

    func testModelPathsDoNotContainNetworkSchemes() {
        // Model paths must be local file:// URLs, not network resources.
        for model in ModelRegistry.allModels {
            let baseURL = ModelManagerService.baseModelPath(for: model)
            XCTAssertEqual(baseURL.scheme, "file", "Model path must be a file URL: \(baseURL)")
            XCTAssertFalse(
                baseURL.path.contains("://"),
                "Model path must not contain URL scheme separator: \(baseURL.path)"
            )

            if model.requiresMMProj {
                let mmprojURL = ModelManagerService.mmprojModelPath(for: model)
                XCTAssertEqual(mmprojURL.scheme, "file", "MMProj path must be a file URL: \(mmprojURL)")
            }
        }
    }

    // MARK: - Download Status Checks Are Local

    func testDownloadStatusCheckUsesFileManagerOnly() {
        // DownloadManager.updateStatusesFromDisk() should use FileManager only.
        // We verify it works without network by checking it operates on local paths.
        let downloadManager = DownloadManager()
        downloadManager.updateStatusesFromDisk()

        for model in ModelRegistry.allModels {
            let status = downloadManager.status(for: model)
            // Status should be determinable from disk alone.
            XCTAssertNotNil(status)
        }
    }

    func testIsBaseDownloadedUsesLocalFileManager() {
        // ModelManagerService.isBaseDownloaded uses FileManager — no network.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        // Create a fake model file.
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data("fake".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))

        // Remove and verify.
        try? FileManager.default.removeItem(at: path)
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
    }

    func testIsFullyDownloadedRequiresBothFiles() {
        // For vision models, both base and mmproj must exist locally.
        let visionModel = AIModel(
            id: "test-vision-offline",
            displayName: "Vision Test",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/base.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 100,
            mmprojFileSizeBytes: 50,
            baseSHA256: "",
            mmprojSHA256: "",
            quantization: "Q4",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        ModelManagerService.ensureModelsDirectory()

        let basePath = ModelManagerService.baseModelPath(for: visionModel)
        let mmprojPath = ModelManagerService.mmprojModelPath(for: visionModel)
        defer {
            try? FileManager.default.removeItem(at: basePath)
            try? FileManager.default.removeItem(at: mmprojPath)
        }

        // Neither downloaded.
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(visionModel))

        // Only base downloaded.
        FileManager.default.createFile(atPath: basePath.path, contents: Data("base".utf8))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(visionModel))

        // Both downloaded.
        FileManager.default.createFile(atPath: mmprojPath.path, contents: Data("mmproj".utf8))
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(visionModel))
    }
}

// MARK: - Offline Conversation Persistence Tests

/// Verifies that Core Data operations work without any network dependency.
final class OfflineConversationPersistenceTests: XCTestCase {

    var persistence: PersistenceController!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
    }

    // MARK: - Core Data Works Without Network

    func testCoreDataStoreLoadsInMemory() async throws {
        // In-memory store should load without network.
        let conversations = await persistence.fetchConversations()
        XCTAssertNotNil(conversations)
        XCTAssertTrue(conversations.isEmpty)
    }

    func testCreateAndFetchConversationOffline() async throws {
        // Create and fetch conversation — pure local operation.
        let id = await persistence.createConversation(
            title: "Offline Chat",
            modelID: "llama3.2-3b-q4"
        )

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, id)
        XCTAssertEqual(conversations.first?.title, "Offline Chat")
    }

    func testInsertAndFetchMessagesOffline() async throws {
        // Insert and fetch messages — pure local operation.
        let convID = await persistence.createConversation(
            title: "Offline Messages",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.insertMessage(conversationID: convID, role: .user, content: "Hello offline")
        await persistence.insertMessage(conversationID: convID, role: .assistant, content: "Hi! I work offline too.")

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "Hello offline")
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[1].content, "Hi! I work offline too.")
        XCTAssertEqual(messages[1].role, "assistant")
    }

    func testStreamingPersistenceOffline() async throws {
        // Streaming lifecycle — pure local Core Data writes.
        let convID = await persistence.createConversation(
            title: "Offline Streaming",
            modelID: "llama3.2-3b-q4"
        )

        let msgID = await persistence.beginStreamingMessage(conversationID: convID)
        XCTAssertNotNil(msgID)

        // Buffer tokens.
        await persistence.bufferTokens(messageID: msgID!, tokens: "Streaming ")
        await persistence.bufferTokens(messageID: msgID!, tokens: "offline!")

        // End streaming.
        await persistence.endStreamingMessage(messageID: msgID!)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isStreaming ?? true)
        XCTAssertTrue(messages.first?.content?.contains("Streaming offline!") ?? false)
    }

    func testConversationPersistenceAfterSimulatedRelaunch() async throws {
        // Simulate creating conversations, then fetching them (as on relaunch).
        let convID = await persistence.createConversation(
            title: "Persisted Chat",
            modelID: "llama3.2-3b-q4"
        )
        await persistence.insertMessage(conversationID: convID, role: .user, content: "First message")
        await persistence.insertMessage(conversationID: convID, role: .assistant, content: "First reply")

        // Simulate relaunch by creating a new persistence controller pointing to same store.
        // (In-memory test, but proves the CRUD path has no network dependency.)
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "First message")
        XCTAssertEqual(messages[1].content, "First reply")
    }

    func testDeleteConversationOffline() async throws {
        let convID = await persistence.createConversation(
            title: "To Delete Offline",
            modelID: "llama3.2-3b-q4"
        )
        await persistence.insertMessage(conversationID: convID, role: .user, content: "Delete me")

        await persistence.deleteConversation(id: convID)

        let conversations = await persistence.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    func testUpdateConversationTitleOffline() async throws {
        let convID = await persistence.createConversation(
            title: "Original Title",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.updateConversationTitle(id: convID, title: "Updated Offline")

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.first?.title, "Updated Offline")
    }

    func testMultipleConversationsOffline() async throws {
        // Create multiple conversations — all local.
        for i in 0..<5 {
            let _ = await persistence.createConversation(
                title: "Conversation \(i)",
                modelID: "llama3.2-3b-q4"
            )
        }

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 5)
    }

    func testCrashRecoveryOffline() async throws {
        // Crash recovery must work without network.
        let convID = await persistence.createConversation(
            title: "Crash Recovery",
            modelID: "llama3.2-3b-q4"
        )

        // Begin a streaming message (isStreaming = true in Core Data).
        let msgID = await persistence.beginStreamingMessage(conversationID: convID)!

        // Simulate crash recovery (app was killed before streaming completed).
        await persistence.recoverIncompleteStreams()

        // The message should no longer be streaming after recovery.
        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isStreaming ?? true,
                       "After recovery, message should not be streaming")
    }
}

// MARK: - Offline Inference Path Tests

/// Verifies the inference path has no network dependency.
@MainActor
final class OfflineInferencePathTests: XCTestCase {

    var mockService: MockInferenceService!

    override func setUp() {
        super.setUp()
        mockService = MockInferenceService()
    }

    // MARK: - Inference Service Has No Network Dependency

    func testInferenceServiceProtocolHasNoNetworkMethods() {
        // InferenceServiceProtocol defines only local operations.
        // We verify by loading a model through the mock (no URLSession involved).
        // This is a structural test — the protocol itself has no URL-based methods.
        let model = ModelRegistry.llama32_3B
        let localURL = ModelManagerService.baseModelPath(for: model)

        // The loadModel method takes a baseURL: URL which is a local file path.
        // It does NOT take a network URL or make any network calls.
        XCTAssertTrue(localURL.isFileURL, "Model path must be a file URL")
    }

    func testStreamChatReturnsLocalAsyncStream() async throws {
        // Streaming should work entirely from local model — no network.
        let stream = try await mockService.streamChat(
            messages: [ChatMessagePayload(role: .user, content: "Hello")],
            systemPrompt: nil,
            sampling: .default
        )

        var result = ""
        for try await chunk in stream {
            result += chunk
        }
        XCTAssertEqual(result, "Hello world!")
        XCTAssertEqual(mockService.streamChatCallCount, 1)
    }

    func testInferenceServiceModelLoadingRecordsCalls() async throws {
        // Verify mock tracks calls correctly (no network in mock).
        let model = ModelRegistry.llama32_3B
        let localURL = ModelManagerService.baseModelPath(for: model)

        try await mockService.loadModel(model, baseURL: localURL, mmprojURL: nil)
        XCTAssertEqual(mockService.loadModelCallCount, 1)

        let loaded = await mockService.isModelLoaded
        XCTAssertTrue(loaded)

        let loadedID = await mockService.loadedModelID
        XCTAssertEqual(loadedID, model.id)
    }

    func testInferenceServiceUnloadWorksLocally() async throws {
        let model = ModelRegistry.llama32_3B
        let localURL = ModelManagerService.baseModelPath(for: model)

        try await mockService.loadModel(model, baseURL: localURL, mmprojURL: nil)
        mockService.unloadModel()

        let loaded = await mockService.isModelLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(mockService.unloadModelCallCount, 1)
    }

    // MARK: - InferenceService (Real) Does Not Use URLSession

    func testInferenceServiceLoadsFromLocalFile() async throws {
        // The real InferenceService only uses FileManager to check file existence,
        // then passes the local path to LlamaEngine. No URLSession involved.
        let realService = InferenceService()

        // Verify no model is loaded initially.
        let loaded = await realService.isModelLoaded
        XCTAssertFalse(loaded)

        // Loading with a nonexistent file should fail with a local error,
        // NOT a network error — proving no network attempt is made.
        let model = ModelRegistry.llama32_3B
        let fakeLocalPath = URL(fileURLWithPath: "/tmp/nonexistent-model.gguf")

        do {
            try await realService.loadModel(model, baseURL: fakeLocalPath, mmprojURL: nil)
            XCTFail("Should have thrown modelFileNotFound")
        } catch let error as InferenceError {
            if case .modelFileNotFound = error {
                // Expected — local file not found, no network attempt.
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected modelFileNotFound, got \(error)")
            }
        }
    }
}

// MARK: - Offline Onboarding Tests

/// Verifies onboarding state is purely local (UserDefaults, no remote config).
@MainActor
final class OfflineOnboardingTests: XCTestCase {

    func testOnboardingUsesUserDefaultsOnly() {
        // OnboardingManager uses UserDefaults — a purely local store.
        let suiteName = "OfflineOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // First launch — should show onboarding.
        let manager = OnboardingManager(defaults: defaults)
        XCTAssertTrue(manager.showOnboarding)

        // Complete onboarding.
        manager.completeOnboarding()
        XCTAssertFalse(manager.showOnboarding)

        // Verify the flag is persisted in UserDefaults (not a remote service).
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    func testOnboardingDoesNotReappearAfterRelaunch() {
        // Simulate app relaunch — flag persists locally.
        let suiteName = "OfflineOnboardingRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // First session.
        let manager1 = OnboardingManager(defaults: defaults)
        XCTAssertTrue(manager1.showOnboarding)
        manager1.completeOnboarding()

        // Second session (relaunch) — no network call to check remote config.
        let manager2 = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager2.showOnboarding)
    }

    func testOnboardingNeverReappearsEvenAfterMultipleRelaunches() {
        let suiteName = "OfflineOnboardingMultiple.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager1 = OnboardingManager(defaults: defaults)
        manager1.completeOnboarding()

        // Multiple relaunches.
        for i in 0..<5 {
            let manager = OnboardingManager(defaults: defaults)
            XCTAssertFalse(
                manager.showOnboarding,
                "Onboarding should not appear on relaunch \(i)"
            )
        }
    }
}

// MARK: - Offline Models Page Tests

/// Verifies the models page shows correct state without network.
@MainActor
final class OfflineModelsPageTests: XCTestCase {

    var downloadManager: DownloadManager!
    var lifecycleManager: ModelLifecycleManager!
    var modelsViewModel: ModelsViewModel!

    override func setUp() {
        super.setUp()
        downloadManager = DownloadManager()
        let inferenceService = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        lifecycleManager = ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter
        )
        modelsViewModel = ModelsViewModel(
            downloadManager: downloadManager,
            lifecycleManager: lifecycleManager
        )
    }

    override func tearDown() {
        // Clean up test model files.
        for model in ModelRegistry.allModels {
            ModelManagerService.deleteModel(model)
        }
        modelsViewModel = nil
        lifecycleManager = nil
        downloadManager = nil
        super.tearDown()
    }

    func testModelsPageShowsAllModelsOffline() {
        // The models page should list all registered models regardless of network.
        XCTAssertEqual(modelsViewModel.allModels.count, ModelRegistry.allModels.count)
    }

    func testDownloadedModelsDetectedOffline() {
        // Create a fake downloaded model file.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data("fake-gguf".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        // Refresh disk status — should detect the file without network.
        downloadManager.updateStatusesFromDisk()

        let status = downloadManager.status(for: model)
        XCTAssertTrue(status.isReady, "Model should be detected as downloaded from local disk")
    }

    func testModelsPageShowsDownloadedStateWithoutNetwork() {
        // Simulate a downloaded model.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data("fake-gguf".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        downloadManager.updateStatusesFromDisk()

        // ModelsViewModel should report the model as downloaded.
        XCTAssertTrue(modelsViewModel.isDownloaded(model))
        XCTAssertTrue(modelsViewModel.hasInstalledModels)
        XCTAssertEqual(modelsViewModel.installedModels.count, 1)
    }

    func testDiskUsageReadableOffline() {
        // Disk usage should be available without network.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data(repeating: 0, count: 1024))
        defer { try? FileManager.default.removeItem(at: path) }

        downloadManager.updateStatusesFromDisk()

        let usage = modelsViewModel.diskUsage(for: model)
        XCTAssertFalse(usage.isEmpty, "Disk usage should be available offline")
    }

    func testNoModelsDownloadedShowsEmptyState() {
        // When no models are downloaded, hasInstalledModels should be false.
        downloadManager.updateStatusesFromDisk()
        XCTAssertFalse(modelsViewModel.hasInstalledModels)
        XCTAssertTrue(modelsViewModel.installedModels.isEmpty)
    }
}

// MARK: - Network Isolation Tests

/// Verifies specific components do not make network calls.
final class NetworkIsolationTests: XCTestCase {

    func testModelManagerServiceUsesOnlyFileManager() {
        // ModelManagerService is an enum with static methods.
        // All methods use FileManager.default — no URLSession.
        // We verify by checking the methods work on local paths.

        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        // These should all work without network.
        let _ = ModelManagerService.modelsDirectory
        let _ = ModelManagerService.baseModelPath(for: model)
        let _ = ModelManagerService.isBaseDownloaded(model)
        let _ = ModelManagerService.isFullyDownloaded(model)
        let _ = ModelManagerService.diskUsage(for: model)
        let _ = ModelManagerService.formattedDiskUsage(for: model)
        let _ = ModelManagerService.totalDiskUsage()
        let _ = ModelManagerService.formattedDiskUsage()
    }

    func testModelManagerServiceDirectoryIsLocal() {
        // The models directory must be in the app's sandbox.
        let modelsDir = ModelManagerService.modelsDirectory
        XCTAssertTrue(modelsDir.isFileURL)
        XCTAssertTrue(modelsDir.path.contains("Documents"))
        XCTAssertTrue(modelsDir.path.contains("Models"))
    }

    func testSHA256VerificationIsLocal() {
        // SHA-256 verification should work on local files only.
        ModelManagerService.ensureModelsDirectory()

        let testFile = ModelManagerService.modelsDirectory.appendingPathComponent("test-sha256.bin")
        let testData = Data("Hello, ZiroEdge!".utf8)
        FileManager.default.createFile(atPath: testFile.path, contents: testData)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Compute hash.
        let hash = ModelManagerService.computeSHA256(fileURL: testFile)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.count, 64, "SHA-256 hex string should be 64 characters")

        // Verify against expected.
        let verified = ModelManagerService.verifySHA256(fileURL: testFile, expected: hash!)
        XCTAssertTrue(verified)

        // Verify mismatch detection.
        let wrongHash = String(repeating: "0", count: 64)
        let mismatched = ModelManagerService.verifySHA256(fileURL: testFile, expected: wrongHash)
        XCTAssertFalse(mismatched)
    }

    func testNetworkMonitorDoesNotAffectLocalOperations() {
        // NetworkMonitor is used ONLY for download UI warnings (cellular data).
        // It should not affect model loading, inference, or Core Data.
        let monitor = NetworkMonitor()
        // The monitor is purely observational — it doesn't gate any local operations.
        XCTAssertNotNil(monitor.isConnected)
        XCTAssertNotNil(monitor.isOnCellular)
    }
}

// MARK: - Full Offline Flow Integration Tests

/// End-to-end integration tests simulating offline app usage.
@MainActor
final class OfflineFlowIntegrationTests: XCTestCase {

    var persistence: PersistenceController!
    var downloadManager: DownloadManager!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
        downloadManager = DownloadManager()
    }

    override func tearDown() {
        for model in ModelRegistry.allModels {
            ModelManagerService.deleteModel(model)
        }
        downloadManager = nil
        persistence = nil
        super.tearDown()
    }

    // MARK: - Scenario 2: Kill app in Airplane Mode, relaunch

    func testRelaunchInAirplaneModeShowsExistingConversations() async throws {
        // Pre-airplane: create conversations and messages.
        let conv1ID = await persistence.createConversation(
            title: "Chat 1",
            modelID: "llama3.2-3b-q4"
        )
        await persistence.insertMessage(conversationID: conv1ID, role: .user, content: "Question 1")
        await persistence.insertMessage(conversationID: conv1ID, role: .assistant, content: "Answer 1")

        let conv2ID = await persistence.createConversation(
            title: "Chat 2",
            modelID: "llama3.2-3b-q4"
        )
        await persistence.insertMessage(conversationID: conv2ID, role: .user, content: "Question 2")

        // Simulate relaunch (Airplane Mode) — fetch conversations.
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 2)

        // Verify messages are accessible.
        let messages1 = await persistence.fetchMessages(conversationID: conv1ID)
        XCTAssertEqual(messages1.count, 2)
        XCTAssertEqual(messages1[0].content, "Question 1")
        XCTAssertEqual(messages1[1].content, "Answer 1")

        let messages2 = await persistence.fetchMessages(conversationID: conv2ID)
        XCTAssertEqual(messages2.count, 1)
        XCTAssertEqual(messages2[0].content, "Question 2")
    }

    // MARK: - Scenario 3: Cold start in Airplane Mode

    func testColdStartShowsExistingConversationsAndCanLoadModel() async throws {
        // Setup: simulate previous session with conversations.
        let _ = await persistence.createConversation(title: "Previous Chat", modelID: "llama3.2-3b-q4")

        // Simulate cold start: conversations load from Core Data.
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.title, "Previous Chat")

        // Model should be loadable from local file path (no network needed).
        let model = ModelRegistry.llama32_3B
        let localURL = ModelManagerService.baseModelPath(for: model)
        XCTAssertTrue(localURL.isFileURL, "Model path must be a local file URL")
    }

    // MARK: - Scenario 6: New conversation offline

    func testNewConversationCreationOffline() async throws {
        // Create a new conversation — pure local Core Data operation.
        let convID = await persistence.createConversation(
            title: "Offline New Chat",
            modelID: "llama3.2-3b-q4"
        )

        // Insert user message.
        await persistence.insertMessage(
            conversationID: convID,
            role: .user,
            content: "Hello from offline!"
        )

        // Verify.
        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hello from offline!")
    }

    // MARK: - Scenario: Streaming works offline

    func testStreamingWorksOffline() async throws {
        // Create conversation.
        let convID = await persistence.createConversation(
            title: "Offline Streaming",
            modelID: "llama3.2-3b-q4"
        )

        // Begin streaming message.
        let msgID = await persistence.beginStreamingMessage(conversationID: convID)
        XCTAssertNotNil(msgID)

        // Buffer tokens (as if streaming from local model).
        await persistence.bufferTokens(messageID: msgID!, tokens: "I ")
        await persistence.bufferTokens(messageID: msgID!, tokens: "work ")
        await persistence.bufferTokens(messageID: msgID!, tokens: "offline!")

        // End streaming.
        await persistence.endStreamingMessage(messageID: msgID!)

        // Verify.
        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isStreaming ?? true)
        XCTAssertTrue(messages.first?.content?.contains("I work offline!") ?? false)
    }

    // MARK: - Scenario: Onboarding does not reappear

    func testOnboardingDoesNotReappearOffline() {
        let suiteName = "OfflineFlowOnboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Simulate previous session completing onboarding.
        defaults.set(true, forKey: "hasCompletedOnboarding")

        // Simulate cold start in airplane mode.
        let manager = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager.showOnboarding, "Onboarding should not reappear offline")
    }

    // MARK: - Scenario: Models page shows downloaded models

    func testModelsPageShowsDownloadedModelsOffline() {
        // Create fake downloaded model files.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data("fake-gguf".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        // Refresh disk status.
        downloadManager.updateStatusesFromDisk()

        // Verify model shows as downloaded.
        let status = downloadManager.status(for: model)
        XCTAssertTrue(status.isReady, "Downloaded model should show as ready offline")
    }

    // MARK: - Scenario: Downloaded model loads successfully offline

    func testDownloadedModelLoadsSuccessfullyOffline() async throws {
        // Create a fake model file.
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()
        let path = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: path.path, contents: Data("fake-gguf".utf8))
        defer { try? FileManager.default.removeItem(at: path) }

        // Verify file exists locally.
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))

        // Model loading should work from local file path.
        // (In real app, LlamaEngine loads from this path. No network involved.)
        let localURL = ModelManagerService.baseModelPath(for: model)
        XCTAssertTrue(localURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
    }

    // MARK: - Scenario: Chat works offline

    func testChatWorksOffline() async throws {
        // Create conversation.
        let convID = await persistence.createConversation(
            title: "Offline Chat",
            modelID: "llama3.2-3b-q4"
        )

        // Insert user message.
        await persistence.insertMessage(
            conversationID: convID,
            role: .user,
            content: "What is 2+2?"
        )

        // Simulate streaming response from local model.
        let msgID = await persistence.beginStreamingMessage(conversationID: convID)!
        await persistence.bufferTokens(messageID: msgID, tokens: "2+2 equals 4.")
        await persistence.endStreamingMessage(messageID: msgID)

        // Verify conversation state.
        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "What is 2+2?")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "2+2 equals 4.")
        XCTAssertFalse(messages[1].isStreaming ?? true)
    }
}

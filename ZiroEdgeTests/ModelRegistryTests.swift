// ModelRegistryTests.swift
// ZiroEdgeTests
//
// Tests for model registry, configuration, and download state.

import XCTest
import CryptoKit

/// Direct inference test — loads Gemma, sends prompt, streams response.
/// Uses InferenceService directly — no UI, no MainActor wrappers.
final class DirectInferenceTest: XCTestCase {

    func testGemmaResponds() async throws {
        // Find the first downloaded model.
        guard let model = ModelRegistry.allModels.first(where: { ModelManagerService.isFullyDownloaded($0) }) else {
            print("[INFERENCE-TEST] No model downloaded — skipping")
            throw XCTSkip("No model downloaded on device")
        }
        print("[INFERENCE-TEST] Using model: \(model.id)")

        let inference = InferenceService()
        let baseURL = ModelManagerService.baseModelPath(for: model)
        let mmprojURL = model.requiresMMProj ? ModelManagerService.mmprojModelPath(for: model) : nil

        print("[INFERENCE-TEST] Loading from: \(baseURL.path)")
        do {
            try await inference.loadModel(model, baseURL: baseURL, mmprojURL: mmprojURL)
            print("[INFERENCE-TEST] Model loaded successfully")
        } catch {
            print("[INFERENCE-TEST] Load failed: \(error)")
            XCTFail("Model load failed: \(error)")
            return
        }

        // Use streamRawCompletion with a manually formatted Gemma 4 prompt.
        // Gemma 4 format: <start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n
        let prompt = "<start_of_turn>user\nHello, say hi in one word<end_of_turn>\n<start_of_turn>model\n"
        let sampling = SamplingConfig(
            temperature: 0.7, topP: 0.9, topK: 40,
            maxTokens: 64, repeatPenalty: 1.1
        )
        let stopStrings = model.config.stopStrings

        print("[INFERENCE-TEST] Prompt tokens: \(prompt.count) chars")
        print("[INFERENCE-TEST] Sending...")
        var responseText = ""
        do {
            let stream = try await inference.streamRawCompletion(
                prompt: prompt,
                sampling: sampling,
                stopStrings: stopStrings,
                addBos: model.config.addBos
            )
            for try await token in stream {
                responseText += token
                print("[INFERENCE-TEST] T: \(token)")
            }
            print("[INFERENCE-TEST] Stream done")
        } catch {
            print("[INFERENCE-TEST] Error: \(error)")
            XCTFail("Stream failed: \(error)")
            return
        }

        print("[INFERENCE-TEST] Response: \(responseText)")
        XCTAssertFalse(responseText.isEmpty, "Empty response")
        print("[INFERENCE-TEST] SUCCESS — \(responseText.count) chars")
    }
}
@testable import ZiroEdge

final class ModelRegistryTests: XCTestCase {

    // MARK: - Model Registry

    func testRegistryHasModels() throws {
        XCTAssertFalse(ModelRegistry.allModels.isEmpty)
    }

    func testLlama32InRegistry() throws {
        let model = ModelRegistry.model(for: "llama3.2-3b-q4")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.displayName, "Llama 3.2 3B")
        XCTAssertEqual(model?.modelType, .text)
        XCTAssertEqual(model?.quantization, "Q4_K_M")
        XCTAssertNil(model?.mmprojURL)
        XCTAssertFalse(model?.requiresMMProj ?? true)
    }

    func testModelLookupByID() throws {
        let model = ModelRegistry.model(for: "llama3.2-3b-q4")
        XCTAssertNotNil(model)
        XCTAssertNil(ModelRegistry.model(for: "nonexistent"))
    }

    func testDeviceRAMGating() throws {
        let allModels = ModelRegistry.availableModels(deviceRAM: 16_000_000_000)
        XCTAssertFalse(allModels.isEmpty)
        let noModels = ModelRegistry.availableModels(deviceRAM: 500_000_000)
        XCTAssertTrue(noModels.isEmpty)
    }

    func testModelFileSizeFormatting() throws {
        let model = ModelRegistry.llama32ThreeB
        XCTAssertFalse(model.formattedSize.isEmpty)
        XCTAssertGreaterThan(model.totalFileSizeBytes, 0)
    }

    // MARK: - Model Configuration

    func testLlama32Config() throws {
        let config = ModelConfiguration.llama32
        XCTAssertEqual(config.contextLength, 4096)
        XCTAssertEqual(config.threadCount, 2)
        XCTAssertTrue(config.useMmap)
        XCTAssertTrue(config.f16KV)
        XCTAssertEqual(config.gpuLayers, 0)
        XCTAssertNil(config.addBos)
        XCTAssertTrue(config.stopStrings.contains("<|eot_id|>"))
    }

    func testSamplingConfigDefaults() throws {
        let sampling = SamplingConfig.default
        XCTAssertEqual(sampling.temperature, 0.7)
        XCTAssertEqual(sampling.topP, 0.9)
        XCTAssertEqual(sampling.topK, 40)
        XCTAssertEqual(sampling.maxTokens, 2048)
    }

    func testGreedySamplingConfig() throws {
        let greedy = SamplingConfig.greedy
        XCTAssertEqual(greedy.temperature, 0.0)
        XCTAssertEqual(greedy.topP, 1.0)
        XCTAssertEqual(greedy.topK, 1)
    }

    // MARK: - Download State

    func testDownloadStateNotDownloaded() throws {
        let state = DownloadState.notDownloaded
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateDownloading() throws {
        let state = DownloadState.downloading(progress: 0.5)
        XCTAssertFalse(state.isDownloaded)
        XCTAssertTrue(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    func testDownloadStateDownloaded() throws {
        let state = DownloadState.downloaded
        XCTAssertTrue(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testModelDownloadStatusReady() throws {
        let status = ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.isDownloading)
        XCTAssertEqual(status.overallProgress, 1.0)
    }

    func testModelDownloadStatusPartial() throws {
        let status = ModelDownloadStatus(
            baseState: .downloading(progress: 0.5),
            mmprojState: .notDownloaded
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isDownloading)
    }

    func testModelDownloadStatusVisionModel() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .downloaded
        )
        XCTAssertTrue(status.isReady)
    }

    func testModelDownloadStatusVisionIncomplete() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .downloading(progress: 0.3)
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isDownloading)
    }

    // MARK: - Vision Model Registry

    func testGemma4E2BInRegistry() throws {
        let model = ModelRegistry.model(for: "gemma-4-e2b-q4")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.displayName, "Gemma 4 E2B")
        XCTAssertEqual(model?.modelType, .vision)
        XCTAssertTrue(model?.requiresMMProj ?? false)
        XCTAssertNotNil(model?.mmprojURL)
        XCTAssertEqual(model?.quantization, "Q4_K_M")
    }

    func testGemma4E4BInRegistry() throws {
        let model = ModelRegistry.model(for: "gemma-4-e4b-q4")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.displayName, "Gemma 4 E4B")
        XCTAssertEqual(model?.modelType, .vision)
        XCTAssertTrue(model?.requiresMMProj ?? false)
        XCTAssertNotNil(model?.mmprojURL)
    }

    func testGemma4Config() throws {
        let config = ModelConfiguration.gemma4
        XCTAssertTrue(config.addBos == true)
        XCTAssertTrue(config.stopStrings.contains("<end_of_turn>"))
        XCTAssertEqual(config.contextLength, 4096)
        XCTAssertEqual(config.threadCount, 2)
        XCTAssertTrue(config.useMmap)
        XCTAssertTrue(config.f16KV)
        XCTAssertEqual(config.gpuLayers, 0)
    }

    func testVisionModelDownloadStatusBothNeeded() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .notDownloaded
        )
        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.isDownloading)
    }

    func testVisionModelDownloadStatusBothReady() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .downloaded
        )
        XCTAssertTrue(status.isReady)
    }

    func testVisionModelsHaveMMProjURL() throws {
        let visionModels = ModelRegistry.allModels.filter { $0.modelType == .vision }
        XCTAssertFalse(visionModels.isEmpty)
        for model in visionModels {
            XCTAssertNotNil(model.mmprojURL, "\(model.id) should have mmprojURL")
            XCTAssertTrue(model.requiresMMProj, "\(model.id) should require mmproj")
            XCTAssertNotNil(model.mmprojFileSizeBytes, "\(model.id) should have mmproj size")
        }
    }

    // MARK: - Catalog Integrity

    func testProductionCatalogSatisfiesIntegrityContract() throws {
        let issues = ModelRegistry.validationIssues
        XCTAssertTrue(issues.isEmpty, issues.map(\.description).joined(separator: "\n"))
    }

    func testCatalogValidationRejectsMalformedArtifactMetadata() throws {
        let invalid = makeCatalogModel(
            modelType: .vision,
            baseURL: URL(string: "http://example.com/model.gguf")!,
            mmprojURL: URL(string: "https://example.com/projector.gguf")!,
            baseFileSizeBytes: 0,
            mmprojFileSizeBytes: 0,
            baseSHA256: "not-a-sha256",
            mmprojSHA256: "bad"
        )

        let issues = ModelRegistry.validate([invalid])
        XCTAssertTrue(issues.contains {
            if case .malformedURL(artifact: .base) = $0 { return true }
            return false
        })
        XCTAssertTrue(issues.contains {
            if case .invalidSHA256(artifact: .base) = $0 { return true }
            return false
        })
        XCTAssertTrue(issues.contains {
            if case .nonPositiveSize(artifact: .base) = $0 { return true }
            return false
        })
        XCTAssertTrue(issues.contains {
            if case .invalidSHA256(artifact: .mmproj) = $0 { return true }
            return false
        })
        XCTAssertTrue(issues.contains {
            if case .nonPositiveSize(artifact: .mmproj) = $0 { return true }
            return false
        })
    }

    func testCatalogValidationRejectsVisionModelWithoutProjectorMetadata() throws {
        let invalid = makeCatalogModel(modelType: .vision)
        let issues = ModelRegistry.validate([invalid])

        XCTAssertTrue(issues.contains {
            if case .missingProjectorMetadata = $0 { return true }
            return false
        })
    }

    func testCatalogValidationRejectsDuplicateDestinations() throws {
        let first = makeCatalogModel(id: "duplicate-model")
        let second = makeCatalogModel(id: "duplicate-model")
        let issues = ModelRegistry.validate([first, second])

        XCTAssertTrue(issues.contains {
            if case .duplicateDestination("duplicate-model.gguf") = $0 { return true }
            return false
        })
    }

    func testUnverifiableModelCannotStartDownload() throws {
        let invalid = makeCatalogModel(baseSHA256: "")
        let downloadManager = DownloadManager()

        downloadManager.startDownload(for: invalid)

        guard case .failed(let error) = downloadManager.status(for: invalid).baseState else {
            return XCTFail("An unverifiable catalog entry must remain unavailable")
        }
        guard case .catalogUnavailable(let reason) = error else {
            return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(reason.contains("SHA-256"))
    }

    private func makeCatalogModel(
        id: String = "catalog-test",
        modelType: ModelType = .text,
        baseURL: URL = URL(string: "https://example.com/model.gguf")!,
        mmprojURL: URL? = nil,
        baseFileSizeBytes: Int64 = 1,
        mmprojFileSizeBytes: Int64? = nil,
        baseSHA256: String = String(repeating: "a", count: 64),
        mmprojSHA256: String? = nil
    ) -> AIModel {
        AIModel(
            id: id,
            displayName: "Catalog Test",
            description: "Test model",
            modelType: modelType,
            baseURL: baseURL,
            mmprojURL: mmprojURL,
            baseFileSizeBytes: baseFileSizeBytes,
            mmprojFileSizeBytes: mmprojFileSizeBytes,
            baseSHA256: baseSHA256,
            mmprojSHA256: mmprojSHA256,
            quantization: "Q4_K_M",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                copyright: "Test"
            )
        )
    }
}

/// Diagnostic test that mimics the chat UI flow:
/// autoLoadFirstModel -> loadModel -> isModelLoaded
@MainActor
final class ChatFlowDiagnosticTest: XCTestCase {

    func testChatUIFlowLoadsModel() async throws {
        guard ModelRegistry.allModels.contains(where: { ModelManagerService.isFullyDownloaded($0) }) else {
            throw XCTSkip("No verified model downloaded for the chat-flow diagnostic")
        }
        print("[CHATFLOW-TEST] === Starting chat UI flow diagnostic ===")
        
        // Step 1: Create the same objects the chat UI uses
        let inference = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: memoryBudgeter
        )
        
        // Step 2: Check current state
        print("[CHATFLOW-TEST] Initial state: \(lifecycle.currentState)")
        print("[CHATFLOW-TEST] isModelLoaded: \(lifecycle.isModelLoaded)")
        print("[CHATFLOW-TEST] activeModel: \(lifecycle.activeModel?.id ?? "nil")")
        
        // Step 3: Call autoLoadFirstModel (same as chat UI does on new conversation)
        print("[CHATFLOW-TEST] Calling autoLoadFirstModel()...")
        await lifecycle.autoLoadFirstModel()
        
        // Step 4: Check result
        print("[CHATFLOW-TEST] After autoLoad:")
        print("[CHATFLOW-TEST]   currentState: \(lifecycle.currentState)")
        print("[CHATFLOW-TEST]   isModelLoaded: \(lifecycle.isModelLoaded)")
        print("[CHATFLOW-TEST]   activeModel: \(lifecycle.activeModel?.id ?? "nil")")
        
        // Step 5: Assert
        XCTAssertTrue(lifecycle.isModelLoaded, "Model was not loaded by autoLoadFirstModel(). state=\(lifecycle.currentState)")
        print("[CHATFLOW-TEST] === PASSED ===")
    }

    /// Full chat flow: autoLoad -> send message -> capture response
    func testFullChatFlowWithResponse() async throws {
        guard ModelRegistry.allModels.contains(where: { ModelManagerService.isFullyDownloaded($0) }) else {
            throw XCTSkip("No verified model downloaded for the full chat-flow diagnostic")
        }
        print("[FULLFLOW] === Starting full chat flow ===")
        
        let inference = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: memoryBudgeter
        )
        
        // Load model (same as UI flow)
        await lifecycle.autoLoadFirstModel()
        guard lifecycle.isModelLoaded else {
            XCTFail("Model not loaded")
            return
        }
        print("[FULLFLOW] Model loaded: \(lifecycle.activeModel!.id)")
        
        // Get the model config for prompt formatting
        guard let model = lifecycle.activeModel else {
            XCTFail("No active model")
            return
        }
        
        // Format a prompt using the SAME code path as streamChat
        let messages = [ChatMessagePayload(role: .user, content: "Say hello in exactly one word")]
        let sampling = SamplingConfig(
            temperature: 0.7, topP: 0.9, topK: 40,
            maxTokens: 32, repeatPenalty: 1.1
        )
        
        print("[FULLFLOW] Sending via streamChat...")
        var response = ""
        do {
            let stream = try await inference.streamChat(
                messages: messages, systemPrompt: nil, sampling: sampling
            )
            for try await token in stream {
                response += token
            }
            print("[FULLFLOW] Stream complete. Response: \(response)")
        } catch {
            print("[FULLFLOW] Stream error: \(error)")
            XCTFail("Stream error: \(error)")
            return
        }
        
        XCTAssertFalse(response.isEmpty, "Empty response from model")
        print("[FULLFLOW] === PASSED — response: \(response) ===")
    }
}

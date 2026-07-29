// ImportedModelLoadFailureTests.swift
// ZiroEdgeTests
//
// Tests for native load failure handling: retained artifacts, categorized
// diagnostics, retry after configuration change, and no local paths in messages.

import XCTest
@testable import ZiroEdge

@MainActor
final class ImportedModelLoadFailureTests: XCTestCase {

    private func makeStore() throws -> LoadSafetyStore {
        try LoadSafetyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    private func makeBudgeter() -> MemoryBudgeter {
        MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000,
            total: 8_054_095_872
        ))
    }

    // MARK: - Load status tracking

    func testNativeLoadFailureUpdatesImportedRecordWithCategorizedDiagnostic() async throws {
        let inference = LifecycleInferenceStub(
            loadError: InferenceError.nativeFailure(
                kind: .contextCreation,
                diagnostic: "/private/var/mobile/Containers/Data/model.gguf"
            )
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let importedRecord = makeImportedRecord()
        let store = ImportedModelStore(directory: directory)
        try store.upsert(importedRecord)

        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            importedModelStore: store,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: importedRecord.model)
        defer { ExperimentalModelConsent.setGranted(false, for: importedRecord.model) }

        _ = await manager.loadModel(importedRecord.model)

        let updatedRecord = store.record(id: importedRecord.id)
        guard case .loadFailed(let kind, let diagnostic, _) = updatedRecord?.loadStatus else {
            return XCTFail("Expected loadFailed status")
        }
        XCTAssertEqual(kind, "contextCreation")
        XCTAssertFalse(diagnostic.contains("/private/"))
        XCTAssertFalse(diagnostic.contains("/var/"))
    }

    func testSuccessfulLoadUpdatesImportedRecordToLoaded() async throws {
        let inference = LifecycleInferenceStub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let importedRecord = makeImportedRecord()
        let store = ImportedModelStore(directory: directory)
        try store.upsert(importedRecord)

        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            importedModelStore: store,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: importedRecord.model)
        defer { ExperimentalModelConsent.setGranted(false, for: importedRecord.model) }

        _ = await manager.loadModel(importedRecord.model)

        let updatedRecord = store.record(id: importedRecord.id)
        XCTAssertEqual(updatedRecord?.loadStatus, .loaded)
    }

    func testConfigurationChangeResetsFailedStatusForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        var record = makeImportedRecord()
        record.loadStatus = .loadFailed(kind: "contextCreation", diagnostic: "Test failure", at: Date())
        let store = ImportedModelStore(directory: directory)
        try store.upsert(record)

        try store.update(id: record.id) { rec in
            rec.config = .imported(promptPath: .chatTemplate, contextLength: 2048)
            if case .loadFailed = rec.loadStatus {
                rec.loadStatus = .configurationChanged
            }
        }

        let updated = store.record(id: record.id)
        XCTAssertEqual(updated?.loadStatus, .configurationChanged)
    }

    // MARK: - Artifact retention

    func testNativeLoadFailureDoesNotDeleteVerifiedArtifacts() async throws {
        // Install a valid GGUF artifact first.
        let data = TestModelFixtures.gguf()
        let sha = TestModelFixtures.sha256(data)
        let modelID = "hf-test-retain-\(UUID().uuidString.prefix(8))"
        let record = ImportedModelRecord(
            id: modelID, displayName: "Test", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count), mmprojFileSizeBytes: nil,
            baseSHA256: sha, mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .raw, contextLength: 512),
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            provenance: HuggingFaceProvenance(
                repositoryID: "acme/model", revision: String(repeating: "a", count: 40),
                baseFilename: "model.gguf", baseSHA256: sha,
                architecture: "llama", projectorFilename: nil, projectorSHA256: nil
            ),
            importedAt: Date(), loadStatus: .neverLoaded
        )
        try data.write(to: ModelManagerService.baseModelPath(for: record.model))
        defer { ModelManagerService.deleteModel(record.model) }

        let inference = LifecycleInferenceStub(
            loadError: InferenceError.nativeFailure(
                kind: .modelMapping, diagnostic: "mmap failed"
            )
        )
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )

        _ = await manager.loadModel(record.model)

        // The artifact must still exist on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: record.model).path),
            "Verified artifact must be retained after load failure"
        )
    }

    // MARK: - Error message sanitization

    func testErrorMessageNeverLeaksLocalPaths() async throws {
        let paths = [
            "/private/var/mobile/Containers/Data/Application/abc/model.gguf",
            "/var/mobile/Containers/Data/foo/bar.gguf",
            "/Users/irellzane/Library/Developer/CoreSimulator/Devices/abc/data/model.gguf",
        ]
        for (index, path) in paths.enumerated() {
            let inference = LifecycleInferenceStub(
                loadError: InferenceError.nativeFailure(
                    kind: NativeFailureKind.allCases[index % NativeFailureKind.allCases.count],
                    diagnostic: path
                )
            )
            let manager = ModelLifecycleManager(
                inferenceService: inference,
                memoryBudgeter: makeBudgeter(),
                loadSafetyStore: try makeStore(),
                availabilityProvider: { _ in .ready },
                recoveryDelay: .zero
            )

            let result = await manager.loadModel(ModelRegistry.gemma4_e2b)

            guard case .failed(let failure) = result else {
                return XCTFail("Expected failure")
            }
            XCTAssertFalse(failure.message.contains("/private/"), "Message must not contain local paths")
            XCTAssertFalse(failure.message.contains("/var/"), "Message must not contain local paths")
            XCTAssertFalse(failure.message.contains("/Users/"), "Message must not contain local paths")
        }
    }

    // MARK: - Helpers

    private func makeImportedRecord() -> ImportedModelRecord {
        let data = TestModelFixtures.gguf()
        let sha = TestModelFixtures.sha256(data)
        let modelID = "hf-\(UUID().uuidString.prefix(24))"
        return ImportedModelRecord(
            id: modelID, displayName: "Fixture Import", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count), mmprojFileSizeBytes: nil,
            baseSHA256: sha, mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .raw, contextLength: 512),
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            provenance: HuggingFaceProvenance(
                repositoryID: "acme/model", revision: String(repeating: "a", count: 40),
                baseFilename: "model.gguf", baseSHA256: sha,
                architecture: "llama", projectorFilename: nil, projectorSHA256: nil
            ),
            importedAt: Date(), loadStatus: .neverLoaded
        )
    }
}

private actor LifecycleInferenceStub: InferenceServiceProtocol {
    private var loaded: Bool
    private let loadError: Error?
    private(set) var loadCount = 0
    private(set) var unloadCount = 0

    init(initiallyLoaded: Bool = false, loadError: Error? = nil) {
        loaded = initiallyLoaded
        self.loadError = loadError
    }

    var isModelLoaded: Bool { loaded }
    var loadedModelID: String? { loaded ? "fixture" : nil }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadCount += 1
        if let loadError { throw loadError }
        loaded = true
    }

    func unloadModel() async {
        unloadCount += 1
        loaded = false
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw InferenceError.modelNotLoaded
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw InferenceError.modelNotLoaded
    }

    func cancelCurrentStream() async {}
}

extension NativeFailureKind: CaseIterable {
    public static var allCases: [NativeFailureKind] {
        [.modelMapping, .contextCreation, .projectorInitialization, .memoryPressure, .suspectedJetsam, .inference]
    }
}

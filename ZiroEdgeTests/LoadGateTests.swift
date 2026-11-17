// LoadGateTests.swift
// ZiroEdgeTests
//
// Load-time gates: a constructed engine is not proof a model can decode or be
// prompted. These tests drive the seams without native construction.

import XCTest
@testable import ZiroEdge
import SwiftLlama

/// Engine double for the load gates. Records what the service asked it to do.
private final class StubEngine: LoadedEngine, @unchecked Sendable {
    enum Failure: Error { case preflight }

    private let lock = NSLock()
    private let warmupError: Error?
    private let gate: ChatTemplateGate

    private var verifyCount = 0
    private var templateCheckCount = 0
    private var unloadCount = 0

    init(warmupError: Error? = nil, gate: ChatTemplateGate = .ready) {
        self.warmupError = warmupError
        self.gate = gate
    }

    var verifyCalls: Int { locked { verifyCount } }
    var templateChecks: Int { locked { templateCheckCount } }
    var unloadCalls: Int { locked { unloadCount } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func verifyLoad() async throws {
        lock.withLock { verifyCount += 1 }
        if let warmupError { throw warmupError }
    }

    func chatTemplateGate() async -> ChatTemplateGate {
        lock.withLock { templateCheckCount += 1 }
        return gate
    }

    func supportsThinkingControl() async -> Bool { gate == .ready }

    func unload() async {
        lock.withLock { unloadCount += 1 }
    }

    nonisolated func cancel() {}

    func streamCompletion(
        prompt: String,
        addBos: Bool?,
        parseSpecial: Bool,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) async throws -> AsyncThrowingStream<String, Error> {
        Self.emptyStream()
    }

    func streamChatCompletion(
        messages: [(role: String, content: String)],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) async throws -> AsyncThrowingStream<String, Error> {
        Self.emptyStream()
    }

    func streamVisionCompletion(
        prompt: String,
        images: [Data],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) async throws -> AsyncThrowingStream<String, Error> {
        Self.emptyStream()
    }

    func streamVisionChatCompletion(
        messages: [(role: String, content: String)],
        images: [Data],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) async throws -> AsyncThrowingStream<String, Error> {
        Self.emptyStream()
    }

    private static func emptyStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class LoadGateTests: XCTestCase {
    private struct Harness {
        let service: InferenceService
        let engine: StubEngine
        let store: LoadSafetyStore
        let model: AIModel
        let modelURL: URL
        let directory: URL
    }

    private func makeHarness(
        warmupError: Error? = nil,
        gate: ChatTemplateGate = .ready
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LoadSafetyStore(directory: directory)
        let model = try XCTUnwrap(ModelRegistry.model(for: "bonsai-4b-q1"))
        let modelURL = directory.appendingPathComponent("model.gguf")
        try Data(repeating: 0, count: 16).write(to: modelURL)
        let engine = StubEngine(warmupError: warmupError, gate: gate)
        let service = InferenceService(loadSafetyStore: store) { _ in engine }
        return Harness(
            service: service,
            engine: engine,
            store: store,
            model: model,
            modelURL: modelURL,
            directory: directory
        )
    }

    func testSuccessfulLoadRunsPreflightAndTemplateGate() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try await harness.service.loadModel(
            harness.model,
            baseURL: harness.modelURL,
            mmprojURL: nil
        )

        let loaded = await harness.service.isModelLoaded
        let loadedID = await harness.service.loadedModelID
        XCTAssertTrue(loaded)
        XCTAssertEqual(loadedID, harness.model.id)
        XCTAssertEqual(harness.engine.verifyCalls, 1, "preflight must run before the load is committed")
        XCTAssertEqual(harness.engine.templateChecks, 1)
        XCTAssertEqual(harness.engine.unloadCalls, 0)
    }

    func testPreflightDecodeFailureFailsTheLoadAndClearsTheEngine() async throws {
        let harness = try makeHarness(warmupError: StubEngine.Failure.preflight)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        do {
            try await harness.service.loadModel(
                harness.model,
                baseURL: harness.modelURL,
                mmprojURL: nil
            )
            XCTFail("A model that cannot decode must not load")
        } catch let error as InferenceError {
            guard case .nativeFailure(let kind, let diagnostic) = error else {
                return XCTFail("Expected nativeFailure, got \(error)")
            }
            XCTAssertEqual(kind, .inference)
            XCTAssertTrue(diagnostic.contains("load-warmup"), diagnostic)
        }

        let loaded = await harness.service.isModelLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(harness.engine.unloadCalls, 1)
        // A returned failure is clean for crash classification: the marker must
        // be cleared, so the next attempt is not blocked by a stale pending load.
        XCTAssertNoThrow(try harness.store.beginLoad(profileID: harness.model.id))
    }

    func testModelWithoutAUsableTemplateIsRefusedAtLoad() async throws {
        let harness = try makeHarness(gate: .missing)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        do {
            try await harness.service.loadModel(
                harness.model,
                baseURL: harness.modelURL,
                mmprojURL: nil
            )
            XCTFail("A model with no usable chat template must not load")
        } catch let error as InferenceError {
            guard case .nativeFailure(let kind, let diagnostic) = error else {
                return XCTFail("Expected nativeFailure, got \(error)")
            }
            XCTAssertEqual(kind, .contextCreation)
            XCTAssertEqual(diagnostic, "chat-template-missing")
        }

        let loaded = await harness.service.isModelLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(harness.engine.unloadCalls, 1)
    }

    /// A row that reasons with no way to switch it off is refused at load, with
    /// copy that names the reason instead of the generic memory sentence.
    func testModelThatCannotStopThinkingIsRefusedAtLoad() async throws {
        let harness = try makeHarness(gate: .thinkingUnsupported)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        do {
            try await harness.service.loadModel(
                harness.model,
                baseURL: harness.modelURL,
                mmprojURL: nil
            )
            XCTFail("A row whose thinking policy cannot be honored must not load")
        } catch let error as InferenceError {
            guard case .nativeFailure(let kind, let diagnostic) = error else {
                return XCTFail("Expected nativeFailure, got \(error)")
            }
            XCTAssertEqual(kind, .contextCreation)
            XCTAssertEqual(diagnostic, "chat-template-thinking-unsupported")
        }

        let loaded = await harness.service.isModelLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(harness.engine.unloadCalls, 1)
    }
}

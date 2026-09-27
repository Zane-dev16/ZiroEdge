// CompositeInferenceService.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Chat-path router: Apple Intelligence vs llama.cpp behind the single
// `InferenceServiceProtocol`. ChatSessionActor / ChatViewModel /
// TitleGenerator keep taking `any InferenceServiceProtocol` — they never
// learn which engine answers.
//
// Default rule (per product decision): last working engine wins. No
// hardcoded llama default — persisted selection resolves against what is
// actually available right now (FM ready / GGUF downloaded).

import Foundation
import os

/// Which engine answers chat.
enum InferenceEngine: String, Sendable, CaseIterable {
    case llama
    case appleIntelligence

    /// Vision policy lives here, not in callers: FM is text-only in v1,
    /// so vision always routes to llama regardless of text selection.
    var supportsVision: Bool {
        switch self {
        case .llama: return true
        case .appleIntelligence: return false
        }
    }
}

/// Persists the last working engine. GGUF model choice keeps living in
/// `DefaultsKeys.lastUsedModelID` untouched.
///
/// Single routing authority: selection, availability gating, and launch
/// resolution all live here so ChatViewModel's engine extension stays a
/// thin delegate and the router resolves from the same store.
enum EngineStore {
    private static let lastEngineKey = "lastUsedInferenceEngine"

    static var lastEngine: InferenceEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastEngineKey),
                  let engine = InferenceEngine(rawValue: raw) else {
                return .llama
            }
            return engine
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastEngineKey) }
    }

    /// True when the FM engine is selected and actually ready.
    static var isAppleActive: Bool {
        lastEngine == .appleIntelligence && AppleIntelligenceAvailability.isReady
    }

    /// Switch engines. Selecting FM when unavailable is a no-op returning false.
    @discardableResult
    static func select(_ engine: InferenceEngine) -> Bool {
        if engine == .appleIntelligence, !AppleIntelligenceAvailability.isReady {
            return false
        }
        lastEngine = engine
        return true
    }

    /// Resolve what should answer now: persisted choice if still viable,
    /// else FM when ready, else llama. Never invents availability.
    static func resolve(isFMReady: Bool, hasDownloadedGGUF: Bool) -> InferenceEngine {
        switch lastEngine {
        case .appleIntelligence where isFMReady:
            return .appleIntelligence
        case .llama where hasDownloadedGGUF:
            return .llama
        default:
            if isFMReady { return .appleIntelligence }
            return .llama
        }
    }

    /// Resolve at appear/launch and persist the outcome. Returns the
    /// resolved engine plus whether the persisted choice changed.
    @discardableResult
    static func resolveAndPersist(hasDownloadedGGUF: Bool) -> (engine: InferenceEngine, changed: Bool) {
#if DEBUG
        // UI-test hook: force the real FM engine deterministically.
        if CommandLine.arguments.contains("--uitesting-fm-engine"),
           AppleIntelligenceAvailability.isReady {
            lastEngine = .appleIntelligence
        }
#endif
        let fmStatus = AppleIntelligenceAvailability.status()
        let resolved = resolve(
            isFMReady: fmStatus.isReady,
            hasDownloadedGGUF: hasDownloadedGGUF
        )
        // print (not Logger): surfaces in `devicectl process launch --console` for device acceptance.
        print("[ENGINE-RESOLVE] engine=\(resolved.rawValue) fm=\(fmStatus) gguf=\(hasDownloadedGGUF ? 1 : 0)")
        let changed = resolved != lastEngine
        if changed {
            lastEngine = resolved
        }
        return (resolved, changed)
    }
}

/// Routes every `InferenceServiceProtocol` call to the selected engine.
actor CompositeInferenceService: InferenceServiceProtocol {
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "engine-router")
    private let llama: InferenceService
    private let apple: FoundationModelsProvider

    /// Explicit selection; nil means "resolve at call time".
    private var override: InferenceEngine?

    var selectedEngine: InferenceEngine {
        override ?? EngineStore.lastEngine
    }

    init(llama: InferenceService, apple: FoundationModelsProvider) {
        self.llama = llama
        self.apple = apple
    }

    func selectEngine(_ engine: InferenceEngine) {
        override = engine
        EngineStore.lastEngine = engine
        logger.info("Engine selected: \(engine.rawValue, privacy: .public)")
    }

    /// Active provider for the current selection, falling back to llama
    /// when FM is not ready (minimalist: no badge, just answers).
    private var activeIsApple: Bool {
        selectedEngine == .appleIntelligence && AppleIntelligenceAvailability.isReady
    }

    // MARK: - InferenceServiceProtocol

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        if activeIsApple {
            try await apple.markReady()
        } else {
            try await llama.loadModel(model, baseURL: baseURL, mmprojURL: mmprojURL)
        }
    }

    func unloadModel() async {
        // Unloading is per-engine; FM unload is a flag clear.
        await llama.unloadModel()
        await apple.unloadModel()
    }

    var isModelLoaded: Bool {
        get async {
            if activeIsApple { return await apple.isModelLoaded }
            return await llama.isModelLoaded
        }
    }

    var loadedModelID: String? {
        get async {
            if activeIsApple { return await apple.loadedModelID }
            return await llama.loadedModelID
        }
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        if activeIsApple {
            do {
                return try await apple.streamChat(
                    messages: messages, systemPrompt: systemPrompt, sampling: sampling
                )
            } catch {
                // Minimalist fallback: FM failure surfaces as model-not-loaded
                // so the existing retry/inline rows handle it — no new UI.
                logger.warning("FM stream failed, surfacing for fallback")
                throw error
            }
        }
        return try await llama.streamChat(
            messages: messages, systemPrompt: systemPrompt, sampling: sampling
        )
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Vision policy (`InferenceEngine.supportsVision`): FM is text-only,
        // so vision always goes to llama even when FM answers text.
        // Callers already show the vision warning otherwise.
        return try await llama.streamVisionChat(
            messages: messages, images: images, systemPrompt: systemPrompt, sampling: sampling
        )
    }

    func cancelCurrentStream() async {
        await apple.cancelCurrentStream()
        await llama.cancelCurrentStream()
    }

    func releaseGenerationGateForEviction() async {
        await llama.releaseGenerationGateForEviction()
    }

    func ensureIdleForNewChat() async throws {
        // FM sessions are independent; only the llama gate can wedge.
        try await llama.ensureIdleForNewChat()
    }
}

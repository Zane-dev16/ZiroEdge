// ChatEngineSelection.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Engine selection (llama GGUF vs Apple Intelligence) for ChatViewModel.
// Lives here — not in ChatViewModel.swift — because that file sits at its
// length gates. State persists via EngineStore (UserDefaults); the router
// resolves from the same store, so no direct router access is needed.

import Foundation

extension ChatViewModel {
    /// Which engine answers. Backed by EngineStore — last working engine
    /// wins, never a hardcoded default (downloads vary per device).
    var selectedEngine: InferenceEngine {
        get { EngineStore.lastEngine }
        set {
            EngineStore.lastEngine = newValue
            refreshModelLoadPhase()
        }
    }

    /// True when the FM engine is selected and actually ready.
    var isAppleEngineActive: Bool {
        selectedEngine == .appleIntelligence && AppleIntelligenceAvailability.isReady
    }

    /// Switch engines. Selecting FM when unavailable is a no-op returning false.
    @discardableResult
    func selectEngine(_ engine: InferenceEngine) -> Bool {
        if engine == .appleIntelligence, !AppleIntelligenceAvailability.isReady {
            return false
        }
        selectedEngine = engine
        return true
    }

    /// Resolve at appear/launch: persisted choice if still viable, else FM
    /// when ready, else llama. Persists the resolution.
    @discardableResult
    func resolveEngineIfNeeded(hasDownloadedGGUF: Bool) -> InferenceEngine {
#if DEBUG
        // UI-test hook: force the real FM engine deterministically.
        if CommandLine.arguments.contains("--uitesting-fm-engine"),
           AppleIntelligenceAvailability.isReady {
            EngineStore.lastEngine = .appleIntelligence
        }
#endif
        let fmStatus = AppleIntelligenceAvailability.status()
        let resolved = EngineStore.resolve(
            isFMReady: fmStatus.isReady,
            hasDownloadedGGUF: hasDownloadedGGUF
        )
        // print (not Logger): surfaces in `devicectl process launch --console` for device acceptance.
        print("[ENGINE-RESOLVE] engine=\(resolved.rawValue) fm=\(fmStatus) gguf=\(hasDownloadedGGUF ? 1 : 0)")
        if resolved != EngineStore.lastEngine {
            EngineStore.lastEngine = resolved
            refreshModelLoadPhase()
        }
        return resolved
    }

    /// FM send gate. Nil stops the send; non-nil is the conversation to send into.
    /// Vision is text-only in v1 — image sends stop with the picker warning.
    func fmSendConversationID(hasImages: Bool) async -> UUID? {
        print("[FM-VAL] draft=\(isDraftConversation ? 1 : 0) active=\(activeConversationID?.uuidString ?? "nil")")
        if hasImages {
            visionWarning = "Vision not supported with Apple Intelligence yet. Switch to a vision model."
            return nil
        }
        if let conversationID = activeConversationID { return conversationID }
        guard isDraftConversation else {
            errorMessage = "No active conversation."; showError = true; return nil
        }
        return await materializeDraftForEngine(modelID: AppleIntelligenceMarker.modelID)
    }

    /// Draft materialization for a non-registry engine (FM marker id).
    /// Mirrors `materializeDraftForSend` without touching `selectedModel`.
    func materializeDraftForEngine(modelID: String) async -> UUID? {
        guard !isMaterializingDraft else { return nil }
        isMaterializingDraft = true
        defer { isMaterializingDraft = false }
        let stagedPrompt = activeConversationSystemPrompt
        let defaultPrompt = UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)
        let result = await persistence.createConversationResult(
            id: UUID(),
            title: "New Conversation",
            modelID: modelID,
            systemPrompt: stagedPrompt ?? defaultPrompt?.nilIfBlank
        )
        guard case .success(let id) = result else {
            if case .failure(let error) = result {
                errorMessage = "Could not start the conversation. \(error.localizedDescription)"
                showError = true
                isStartupError = true
            }
            return nil
        }
        isDraftConversation = false
        draftForNewChat = ""
        activeConversationID = id
        activeConversationSystemPrompt = stagedPrompt ?? defaultPrompt?.nilIfBlank
        await conversationListViewModel?.loadConversations()
        conversationListViewModel?.selectedConversationID = id
        return id
    }
}

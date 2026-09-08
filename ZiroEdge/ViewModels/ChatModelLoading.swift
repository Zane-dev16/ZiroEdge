// ChatModelLoading.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Deferred model-load machinery for ChatViewModel: the observable
// ModelLoadPhase projection, best-available candidate selection inputs, and
// the asynchronous autoload kicked off when the chat surface appears. Lives
// in its own file to keep ChatViewModel's type body focused; shares state via
// the narrowly promoted `lifecycleManager`, `modelLoadPhase`, and
// `deferredLoadTask` members. Behavior matches the pre-extraction inline code.

import Foundation
import os
import UIKit

extension ChatViewModel {

    // MARK: - Phase Projection

    /// Pure projection of lifecycle-manager state onto the observable phase.
    /// Driven by a Combine sink plus explicit calls at mutation points.
    func refreshModelLoadPhase() {
        let previousPhase = modelLoadPhase
        switch lifecycleManager.currentState {
        case .loading:
            modelLoadPhase = .loading
        case .loaded where lifecycleManager.activeModel?.id == selectedModel?.id,
             .loaded where selectedModel == nil && lifecycleManager.activeModel != nil && unavailableConversationModelID == nil,
             // A failed switch can leave the prior model resident: the new
             // selection's preflight fails before the prior model unloads, so
             // the identity still matches. The working model must read ready —
             // retryModelLoad no-ops while a model is resident, and re-selecting
             // the resident model returns .alreadyLoaded without touching
             // currentState, so only this projection can unstick the composer.
             // Nil-selection ready is gated on no unavailable conversation
             // model: opening a removed-model conversation clears the
             // selection while another model stays resident, and that state
             // must stay idle until the user explicitly picks a model.
             .loadFailed where lifecycleManager.activeModel?.id == selectedModel?.id,
             .loadFailed where selectedModel == nil && lifecycleManager.activeModel != nil && unavailableConversationModelID == nil:
            modelLoadPhase = .ready
        case .evicted:
            modelLoadPhase = .evicted
        case .loadFailed:
            modelLoadPhase = .failed(lifecycleManager.loadFailureMessage
                ?? "\(selectedModel?.displayName ?? "The model") could not be loaded.")
            // Failure projection stays observable: the banner text alone
            // never says which gate refused the load.
            let projectedMessage = lifecycleManager.loadFailureMessage ?? "no-message"
            logger.warning("Phase projected to failed: \(projectedMessage, privacy: .private)")
        default:
            // `.unloaded`, or `.loaded` with a transient identity mismatch.
            if selectedModel == nil {
                modelLoadPhase = availableModels.isEmpty ? .needsDownload : .idle
            } else if availableModels.isEmpty {
                modelLoadPhase = .needsDownload
            } else if lifecycleManager.activeModel == nil {
                // Candidate named but not resident; the deferred loader bridges it.
                modelLoadPhase = deferredLoadTask == nil ? .idle : .loading
            } else if lifecycleManager.isLoadAttemptInFlight || deferredLoadTask != nil {
                // Identity mismatch while a load is genuinely in flight: busy.
                modelLoadPhase = .loading
            } else {
                // Mismatch with nothing loading (e.g. loadConversation named a
                // non-resident model, or a draft nominated a candidate while a
                // different model stayed resident). Nothing will resolve this
                // on its own, and a permanent .loading would disable the pill
                // menu, lock the composer, and offer no retry row — project
                // the retryable idle phase so selection recovers it.
                modelLoadPhase = .idle
            }
        }
        announceModelLoadTransitionIfNeeded(from: previousPhase)
    }

    /// Post a VoiceOver announcement when the model becomes resident or the
    /// load fails: both transitions silently flip composer availability, and
    /// a failure is otherwise only discoverable by browsing to the retry
    /// banner. Posting is transition-gated because this projection runs at
    /// many mutation points — level-triggered announcements would spam.
    /// Reduce Motion does not apply here (announcements are auditory, not
    /// animated), so nothing is gated on it.
    private func announceModelLoadTransitionIfNeeded(from previousPhase: ModelLoadPhase) {
        guard modelLoadPhase != previousPhase else { return }
        switch modelLoadPhase {
        case .ready:
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(selectedModel?.displayName ?? "Model") is ready."
            )
        case .failed(let message):
            UIAccessibility.post(notification: .announcement, argument: message)
        default:
            break
        }
    }

    /// Kick off the automatic best-available model load once the chat surface
    /// appears. Idempotent per surface lifetime; eviction recovers exactly once
    /// per appear.
    func startDeferredModelLoadIfNeeded() {
        refreshModelLoadPhase()
        guard deferredLoadTask == nil,
              lifecycleManager.activeModel == nil,
              !lifecycleManager.isLoadAttemptInFlight,
              isEligibleForDeferredStart(manual: false) else { return }
        spawnDeferredLoadTask()
    }

    /// Foreground re-kick for background/memory-pressure eviction. The chat
    /// stays mounted across backgrounding (AppShell keeps ChatView as the
    /// base layer), so `onAppear` never re-fires — without this the `.evicted`
    /// projection parks on the inline "Model unloaded" banner with a
    /// disabled composer until the user taps Reload. Reuses the same
    /// `isUserUnloaded` gate as the appear-time kick: system eviction
    /// reloads, Settings → Unload stays parked.
    func handleForegroundTransition() {
        // P2-8: restore parked per-conversation drafts first (cheap, sync,
        // idempotent) so the composer shows the right text even if its state
        // was purged while backgrounded; the model re-kick below is separate.
        noteForegroundTransition()
        startDeferredModelLoadIfNeeded()
    }

    /// Explicit user-driven retry from the header pill or inline row. Unlike
    /// the appear-time kick this may also replay `.failed` attempts.
    /// P1-4: a refused retry surfaces its reason in-place — the inline
    /// Retry row disables with `retryIneligibilityHint` — instead of the
    /// previous silent guard return (which read as a dead button).
    func retryModelLoad() {
        refreshModelLoadPhase()
        let retryEligible = isEligibleForDeferredStart(manual: true)
        let retryActiveID = lifecycleManager.activeModel?.id ?? "nil"
        let retryInFlight = lifecycleManager.isLoadAttemptInFlight ? 1 : 0
        let retryEligibleFlag = retryEligible ? 1 : 0
        // Manual-retry decisions stay observable: a no-op retry with no log
        // is indistinguishable from a tap the app never received.
        let retryPhase = String(describing: modelLoadPhase)
        logger.info("Manual retry phase=\(retryPhase, privacy: .public) active=\(retryActiveID, privacy: .public)")
        logger.info("Manual retry inFlight=\(retryInFlight, privacy: .public) eligible=\(retryEligibleFlag, privacy: .public)")
        guard deferredLoadTask == nil,
              lifecycleManager.activeModel == nil,
              !lifecycleManager.isLoadAttemptInFlight,
              retryEligible else {
            let hint = retryBlockedHint(eligible: retryEligible)
            retryIneligibilityHint = hint
            logger.warning("Manual retry refused: \(hint, privacy: .public)")
            return
        }
        retryIneligibilityHint = nil
        spawnDeferredLoadTask()
    }

    /// User-visible reason a manual retry refused to start, for the inline
    /// hint under the disabled Retry row. Pure over current state for tests.
    func retryBlockedHint(eligible: Bool) -> String {
        if lifecycleManager.activeModel != nil {
            return "The model is already loaded."
        }
        if lifecycleManager.isLoadAttemptInFlight || deferredLoadTask != nil {
            return "A load is already in progress."
        }
        if !eligible {
            switch modelLoadPhase {
            case .needsDownload:
                return "No downloaded model is available yet. Download one to continue."
            case .loading, .ready:
                return "A load is already in progress."
            default:
                return "Retry is not available right now."
            }
        }
        return "Retry is not available right now."
    }

    /// Appear-time kicks allow fresh starts plus eviction retries; manual taps
    /// additionally replay failures. `.failed` is never auto-retried because
    /// native-load failures would simply repeat.
    /// A user-initiated unload (Settings → Unload Model) suppresses only the
    /// automatic kick — without this gate the next `.onAppear` (any pop from
    /// Settings/Models routes) would silently reload the just-unloaded model,
    /// reversing the user's explicit action and burning a full load cycle.
    private func isEligibleForDeferredStart(manual: Bool) -> Bool {
        if !manual, lifecycleManager.isUserUnloaded { return false }
        switch modelLoadPhase {
        case .idle, .evicted:
            return true
        case .needsDownload:
            // A stale .needsDownload can linger after a download completes
            // (phase derived before the artifact landed). When a candidate is
            // now available, treat it as eligible so the deferred kick bridges
            // it without forcing a Models round-trip. Still ineligible when no
            // candidate exists.
            return preferredAutoLoadCandidate() != nil
        case .failed:
            return manual
        default:
            return false
        }
    }

    // MARK: - Load Execution

    private func spawnDeferredLoadTask() {
        // Autoload kicks stay observable: silent kicks hide eligibility bugs.
        let spawnID = selectedModel?.id ?? "nil"
        logger.info("Spawning deferred load for \(spawnID, privacy: .public)")
        // Reaching the loader consumes a prior user-unload intent: an explicit
        // retry here (or a fresh nomination below) deliberately loads.
        lifecycleManager.consumeUserUnloadIntent()
        // An auto-recovery load supersedes the pressure-eviction modal: drop
        // it now so it never lingers over a successful reload (the inline
        // loading/retry rows own recovery from here). Harmless when no modal
        // is up (background eviction never presents one; user-unload never
        // sets it).
        lifecycleManager.dismissMemoryWarning()
        // Controlled-workload UI tests drive their own load choreography.
        if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled {
            deferredLoadTask = Task { @MainActor [weak self] in
                await self?.runControlledWorkloadBootstrap()
                self?.deferredLoadTask = nil
            }
            modelLoadPhase = .loading
            return
        }

        guard let candidate = preferredAutoLoadCandidate() else {
            modelLoadPhase = .needsDownload
            return
        }
        needsModelRedirect = false
        selectedModel = candidate
        modelLoadPhase = .loading
        deferredLoadTask = Task { @MainActor [weak self] in
            await self?.performDeferredLoad(candidate: candidate)
            self?.deferredLoadTask = nil
        }
    }

    private func performDeferredLoad(candidate: AIModel) async {
        let result = await lifecycleManager.loadModel(candidate)
        refreshModelLoadPhase()
        guard case .failed(let failure) = result else {
            // Belt-and-suspenders: spawn already dismissed the modal when the
            // load started; re-assert on success in case pressure raised one
            // mid-flight without invalidating the load.
            lifecycleManager.dismissMemoryWarning()
            return
        }
        modelLoadPhase = .failed(failure.message)
        // The chat surface owns recovery for auto-loads — the inline retry row
        // replaces an alert dump here; failures initiated elsewhere still raise
        // the shell alert.
        if lifecycleManager.loadFailureMessage == failure.message {
            lifecycleManager.showLoadFailure = false
        }
    }

    private func runControlledWorkloadBootstrap() async {
        await lifecycleManager.autoLoadFirstModel()
        selectedModel = lifecycleManager.activeModel ?? selectedModel
        refreshModelLoadPhase()
    }

    // MARK: - Auto-Select Candidate (moved from ChatViewModel.swift to keep
    // that file within the type-body-length gate; behavior unchanged).

    /// Auto-select a model for a new conversation. Uses the fallback chain:
    /// last used model → first available → redirect to models page.
    /// Reimplemented atop `preferredAutoLoadCandidate()`; behavior (and the
    /// `needsModelRedirect` contract relied on by unit tests) is unchanged.
    func autoSelectModel() {
        guard let candidate = preferredAutoLoadCandidate() else {
            selectedModel = nil
            needsModelRedirect = true
            return
        }
        selectedModel = candidate
        needsModelRedirect = false
        refreshModelLoadPhase()
    }

    /// The best available model for the untitled draft chat's deferred load:
    /// last used model, then the first fully downloaded model.
    /// Hermetic test runtimes only ever satisfy llama32_3B paths downstream,
    /// so they are pinned to that profile. Controlled-workload diagnostics
    /// route through `lifecycleManager.autoLoadFirstModel()` instead and never
    /// consult this method.
    /// Unconsented experimental imports are excluded: `availableModels`
    /// deliberately includes them for picker discoverability, but the deferred
    /// auto-loader (launch autoload, `beginNewDraft`, Start-Chatting) must not
    /// silently load and enable chatting on a model `selectModel` would have
    /// gated behind the first-use consent dialog. They stay picker-only until
    /// consent is granted.
    func preferredAutoLoadCandidate() -> AIModel? {
        let downloaded = availableModels.filter { model in
            !(model.runtimeEligibility == .experimental
                && model.isImported
                && !ExperimentalModelConsent.isGranted(for: model))
        }
        #if DEBUG
        if HermeticUITestRuntime.isEnabled {
            return downloaded.first { $0.id == ModelRegistry.llama32_3B.id }
        }
        #endif
        if let lastID = UserDefaults.standard.string(forKey: DefaultsKeys.lastUsedModelID),
           let lastModel = downloaded.first(where: { $0.id == lastID }) {
            return lastModel
        }
        return downloaded.first
    }

    // MARK: - Send Preflight

    /// Verifier-backed send gate. Reads the download status derived from
    /// `authoritativeDiskStatus` (per-artifact SHA-256 + GGUF structure), not
    /// `modelType` alone: a vision row whose projector is missing or corrupt
    /// must block image sends even though the model advertises vision, and an
    /// incomplete pair must block text sends before the lifecycle's load
    /// attempt. Surfaces the matching banner and returns false when the send
    /// must stop; true when it may proceed.
    func sendPreflightPassed(for model: AIModel, hasImages: Bool) -> Bool {
        let status = downloadStatusProvider.status(for: model)
        guard status.isReady else {
            let reason = status.incompleteReason ?? "incomplete"
            logger.warning("Send blocked, model incomplete: \(model.id, privacy: .public)")
            logger.warning("Incomplete reason: \(reason, privacy: .public)")
            errorMessage = "\(model.displayName) is not fully downloaded (\(reason)). " +
                "Repair it or choose another model, then retry."
            showError = true
            return false
        }
        // Text-only models keep the legacy modelType message at the call
        // site; this gate only covers vision rows with an unverified projector.
        if hasImages, model.modelType == .vision, !status.isVisionReady {
            logger.warning("Send blocked, vision not ready: \(model.id, privacy: .public)")
            visionWarning = "Vision is not ready for this model yet. " +
                "Finish downloading its image processing files, or switch to a vision-ready model."
            return false
        }
        return true
    }

    // MARK: - Send Validation (moved from ChatViewModel.swift to hold the
    // type-body-length gate; behavior plus P3 R2/R8 post-suspension re-gates).

    /// Validate preconditions for sending a message. Returns nil on success,
    /// or the conversationID. Sets error/warning state on failure.
    func validateSendPreconditions(
        text: String, hasImages: Bool
    ) async -> UUID? {
        if CommandLine.arguments.contains("--uitesting-sendtest") {
            print("[UITEST] sendMessage: textLength=\(text.count) isEmpty=\(text.isEmpty) hasImages=\(hasImages)")
            print("[UITEST] sendMessage: selectedModel=\(selectedModel?.id ?? "nil")")
            print("[UITEST] sendMessage: isModelLoaded=\(lifecycleManager.isModelLoaded)")
        }

        guard !text.isEmpty || hasImages else { return nil }
        guard !isLoadingConversation else {
            surfaceSendBlockedDuringConversationLoad()
            return nil
        }

        if selectedModel == nil { autoSelectModel() }
        guard let selectedModel else { needsModelRedirect = true; return nil }

        // Verifier-backed preflight (SHA-256 + GGUF structure via download
        // status), not modelType alone — see sendPreflightPassed(for:hasImages:).
        guard sendPreflightPassed(for: selectedModel, hasImages: hasImages) else { return nil }
        if hasImages && !isVisionModel {
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            return nil
        }
        // Belt-and-braces residency gate: the composer stays disabled until
        // modelLoadPhase == .ready, so manual sends always pass this.
        if lifecycleManager.activeModel?.id != selectedModel.id {
            let selected = await selectModel(selectedModel)
            if !selected, showingExperimentalConsent { return nil }
        }
        guard lifecycleManager.activeModel?.id == selectedModel.id else {
            errorMessage = "\(selectedModel.displayName) could not be loaded. Choose another downloaded model."
            showError = true
            return nil
        }
        // R2/R8: re-gate after the selectModel suspension — a switch, evict,
        // or unload may have moved residency or the vision capability while
        // suspended. IDs are public; messages stay private.
        if hasImages, !isVisionModel {
            logger.info("Send re-gate refused vision post-suspension model=\(selectedModel.id, privacy: .public)")
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            return nil
        }
        guard lifecycleManager.isModelLoaded else {
            logger.info("Send re-gate refused residency lost post-suspension model=\(selectedModel.id, privacy: .public)")
            errorMessage = "\(selectedModel.displayName) is no longer loaded. Retry once it reloads."
            showError = true
            return nil
        }

        // Untitled drafts materialize their persistence row just-in-time — only
        // after the model is confirmed resident.
        guard let conversationID = activeConversationID else {
            guard isDraftConversation else {
                errorMessage = "No active conversation."; showError = true; return nil
            }
            guard let materialized = await materializeDraftForSend() else { return nil }
            // R2: residency may have been lost during the materialization
            // suspension (evict/unload racing first-send creation).
            guard lifecycleManager.activeModel?.id == selectedModel.id,
                  lifecycleManager.isModelLoaded else {
                logger.info("Send re-gate refused residency lost post-materialize model=\(selectedModel.id, privacy: .public)")
                errorMessage = "\(selectedModel.displayName) is no longer loaded. Retry once it reloads."
                showError = true
                return nil
            }
            return materialized
        }
        return conversationID
    }
}

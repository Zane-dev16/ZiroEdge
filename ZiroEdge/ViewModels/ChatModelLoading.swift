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
             .loaded where selectedModel == nil && lifecycleManager.activeModel != nil:
            modelLoadPhase = .ready
        case .evicted:
            modelLoadPhase = .evicted
        case .loadFailed:
            modelLoadPhase = .failed(lifecycleManager.loadFailureMessage
                ?? "\(selectedModel?.displayName ?? "The model") could not be loaded.")
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

    /// Explicit user-driven retry from the header pill or inline row. Unlike
    /// the appear-time kick this may also replay `.failed` attempts.
    func retryModelLoad() {
        refreshModelLoadPhase()
        guard deferredLoadTask == nil,
              lifecycleManager.activeModel == nil,
              !lifecycleManager.isLoadAttemptInFlight,
              isEligibleForDeferredStart(manual: true) else { return }
        spawnDeferredLoadTask()
    }

    /// Appear-time kicks allow fresh starts plus eviction retries; manual taps
    /// additionally replay failures. `.failed` is never auto-retried because
    /// native-load failures would simply repeat.
    private func isEligibleForDeferredStart(manual: Bool) -> Bool {
        switch modelLoadPhase {
        case .idle, .evicted:
            return true
        case .failed:
            return manual
        default:
            return false
        }
    }

    // MARK: - Load Execution

    private func spawnDeferredLoadTask() {
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
        guard case .failed(let failure) = result else { return }
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
}

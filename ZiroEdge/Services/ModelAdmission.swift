// ModelAdmission.swift
// ZiroEdge — Privacy-first local AI assistant
//
// One admission seam for model loads: calibration consent and narrow-miss
// teardown policy. Load gates in
// ModelLifecycleManager call this; MemoryBudgeter stays the verdict math.
// Memory-refusal changes land here instead of bouncing across three modules.

import Foundation

/// Deep module hiding model-admission inputs behind one interface.
enum ModelAdmission {
    /// Calibration consent, previously triplicated across the preflight,
    /// pre-teardown, and pre-mmap gates. Returns the override/consent split
    /// for gate logging plus their combination for budget decisions.
    static func calibrationGate(for model: AIModel) -> (override: Bool, consent: Bool, allow: Bool) {
        let override = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled
            && model.id == MemoryDiagnosticRecorder.targetModelID
        let consent = model.runtimeEligibility == .experimental
            && ExperimentalModelConsent.isGranted(for: model)
        return (override, consent, override || consent)
    }

    /// Narrow-miss teardown policy (moved from ModelLifecycleManager):
    /// pre-teardown projections are conservative on both sides, so a miss
    /// inside `transientDipSettleWindowBytes` with a resident prior attempts
    /// teardown and lets the post-teardown gates measure reality
    /// (prior-restore is the net). Wide misses refuse, preserving the
    /// resident; fresh loads (no prior) never proceed.
    static func shouldAttemptTeardownOnNarrowMiss(
        decision: MemoryLoadDecision, priorActive: AIModel?
    ) -> Bool {
        guard priorActive != nil,
              decision.reason == .insufficientProcessHeadroom,
              let required = decision.requiredBytes,
              let projected = decision.projectedAvailableBytes,
              required > projected,
              required - projected <= MemoryBudgeter.transientDipSettleWindowBytes else {
            return false
        }
        return true
    }
}

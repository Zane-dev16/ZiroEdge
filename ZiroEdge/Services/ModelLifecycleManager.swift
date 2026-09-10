// ModelLifecycleManager.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Coordinates lazy model loading, switching, and unloading.
// Uses MemoryBudgeter to verify RAM before every load.
// Observes memory pressure notifications for automatic eviction.

import Foundation
import SwiftLlama
import UIKit
import os

/// The current state of a model in the lifecycle.
enum ModelLoadFailureKind: String, Sendable, Equatable {
    case unavailableArtifact
    case runtimeProfileUnavailable
    case safetyDisabled
    case insufficientMemory
    case invalidatedBySafetyEvent
    case nativeLoadFailure
    case safetyPersistence
}

struct ModelLoadFailure: Sendable, Equatable {
    let kind: ModelLoadFailureKind
    let message: String
    let nativeKind: NativeFailureKind?
}

enum ModelLoadResult: Sendable, Equatable {
    case loaded
    case alreadyLoaded
    case failed(ModelLoadFailure)
}

enum ModelSafetyResetResult: Sendable, Equatable {
    case reset
    case notDisabled
    case failed(message: String)
}

enum ModelState: Sendable, Equatable {
    case unloaded
    case loading
    case loaded
    case evicted
    case loadFailed
}

// MARK: - Model Lifecycle Manager

/// Manages model lifecycle: lazy load, switch, unload, and memory pressure eviction.
@MainActor
final class ModelLifecycleManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentState: ModelState = .unloaded
    @Published private(set) var activeModel: AIModel?
    @Published var showMemoryWarning = false
    @Published var showInsufficientMemoryWarning = false
    @Published private(set) var insufficientMemoryMessage: String?
    @Published var showLoadFailure = false
    @Published private(set) var loadFailureMessage: String?
    /// Set when the user explicitly unloaded the active model (Settings →
    /// Unload Model). The deferred auto-loader treats this as intent that must
    /// not be silently reversed by the next appear-time kick: while set it
    /// refuses automatic loads, and the flag clears when the user selects a
    /// model, starts a fresh draft, or explicitly retries. Programmatic
    /// unloads (memory-pressure/background eviction, diagnostics, delete,
    /// update promotion) never set it so eviction recovery keeps working.
    @Published private(set) var isUserUnloaded = false

    /// Clears the user-unload intent when the user deliberately re-engages a
    /// model: selecting one, starting a fresh draft, or an explicit retry.
    func consumeUserUnloadIntent() {
        isUserUnloaded = false
    }

    // MARK: - Dependencies

    private let inferenceService: any InferenceServiceProtocol
    private let memoryBudgeter: MemoryBudgeter
    private let loadSafetyStore: LoadSafetyStore
    private let importedModelStore: ImportedModelStore
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "lifecycle")
    private let availabilityProvider: @Sendable (AIModel) -> ModelAvailability
    private let recoveryDelay: Duration
    private var safetyEpoch: UInt64 = 0
    private var loadInProgress = false
    // P1-3 coalesces concurrent safety evictions onto one teardown so rapid
    // pressure/background pairs can't spawn duplicate backend_free work.
    // Single warning: eviction only ever sets showMemoryWarning true (never
    // clears it); dismissal owns the reset.
    private var evictTask: Task<Void, Never>?
    private var evictGeneration: UInt64 = 0

    // MARK: - Initialization

    init(
        inferenceService: any InferenceServiceProtocol,
        memoryBudgeter: MemoryBudgeter,
        loadSafetyStore: LoadSafetyStore,
        importedModelStore: ImportedModelStore = .shared,
        availabilityProvider: @escaping @Sendable (AIModel) -> ModelAvailability = { ModelManagerService.availability(for: $0) },
        recoveryDelay: Duration = .seconds(5)
    ) {
        self.inferenceService = inferenceService
        self.memoryBudgeter = memoryBudgeter
        self.loadSafetyStore = loadSafetyStore
        self.importedModelStore = importedModelStore
        self.availabilityProvider = availabilityProvider
        self.recoveryDelay = recoveryDelay

        // Observe memory pressure notifications.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

#if DEBUG
    convenience init(
        inferenceService: any InferenceServiceProtocol,
        memoryBudgeter: MemoryBudgeter
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZiroEdge-LifecycleSafety-\(UUID().uuidString)")
        do {
            let store = try LoadSafetyStore(directory: directory)
            self.init(
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter,
                loadSafetyStore: store
            )
        } catch {
            preconditionFailure("Could not create isolated lifecycle test storage")
        }
    }
#endif

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Model Operations

    /// Load a model. Every exit returns a typed result and user-visible failures.
    /// P0-1: preflight runs off-main via `Task.detached(.utility)` with loading
    /// state + cancellation. P0-3: profile/isDisabled/budget admit before any
    /// teardown so a refusal keeps `activeModel` resident; recovery sleep is
    /// cancellable per 100ms with epoch checks.
    @discardableResult
    func loadModel(_ model: AIModel) async -> ModelLoadResult {
        if let active = activeModel, active.id == model.id, currentState == .loaded {
            return .alreadyLoaded
        }
        let priorActive = activeModel
        let priorState = currentState
        loadInProgress = true
        currentState = .loading
        let loadEpoch = safetyEpoch
        defer { loadInProgress = false }
        MemoryDiagnosticRecorder.shared.capture(.beforeModelLoad)
        logger.info("Load preflight started \(model.id, privacy: .public)")
        let admission = await preflightAndAdmit(model, loadEpoch: loadEpoch, priorActive: priorActive, priorState: priorState)
        if let early = admission.early { return early }
        guard admission.profile != nil else {
            logger.fault("Load admission missing profile \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        // P0 chat-switch teardown-then-fail: re-sample the budget immediately
        // BEFORE teardownAndRecover. Headroom that fell after preflight refuses
        // here with the prior model still resident instead of tearing it down
        // for a load the pre-mmap resample would refuse.
        if let refused = await freshBudgetGateBeforeTeardown(
            model, loadEpoch: loadEpoch, priorActive: priorActive, priorState: priorState
        ) { return refused }
        if let early = await teardownAndRecover(model, loadEpoch: loadEpoch) { return early }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load invalidated before construction \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        return await constructAndCommit(model, loadEpoch: loadEpoch, priorActive: priorActive)
    }

    /// P0-1 async preflight + P0-3 admission (profile/safety/budget) before teardown.
    /// Returns `.early` for any refusal/invalidation, else the admitted profile.
    private func recordImportedLoadSuccess(for model: AIModel) {
        guard model.isImported else { return }
        try? importedModelStore.update(id: model.id) { $0.loadStatus = .loaded }
    }

    private func recordImportedLoadFailure(
        for model: AIModel, nativeKind: NativeFailureKind?, message: String
    ) {
        guard model.isImported else { return }
        try? importedModelStore.update(id: model.id) {
            $0.loadStatus = .loadFailed(
                kind: nativeKind?.rawValue ?? "native-load-failure",
                diagnostic: message,
                at: Date()
            )
        }
    }

    private func failLoad(
        kind: ModelLoadFailureKind, message: String, nativeKind: NativeFailureKind? = nil
    ) -> ModelLoadResult {
        currentState = .loadFailed
        logger.warning("Load failed kind=\(String(describing: kind), privacy: .public) message=\(message, privacy: .private)")
        loadFailureMessage = message
        showLoadFailure = true
        return .failed(ModelLoadFailure(kind: kind, message: message, nativeKind: nativeKind))
    }

    private func invalidateLoadAttempt() async -> ModelLoadResult {
        await inferenceService.cancelCurrentStream()
        await inferenceService.unloadModel()
        // A deliberately cancelled load is not a crash: withdraw its safety
        // marker so it can never be misread as an unclean attempt at next
        // launch (previously every backgrounding during a load burned one of
        // the profile's five slots toward a permanent disable).
        // P1-2: profile-agnostic withdraw reports persistence; fault-log a
        // write failure (in-memory still cleared, best-effort).
        if !loadSafetyStore.withdrawPendingLoad() {
            logger.error("Withdraw pending load persist failed during invalidation")
        }
        activeModel = nil
        currentState = .evicted
        return .failed(ModelLoadFailure(
            kind: .invalidatedBySafetyEvent,
            message: "Model loading stopped because the app left the foreground or received memory pressure.",
            nativeKind: .memoryPressure
        ))
    }

    private static func userMessage(for error: InferenceError?) -> String {
        guard let error else { return "The local model could not be loaded. Try repairing the download." }
        switch error {
        case .modelFileNotFound:
            return "The model artifact is missing. Repair the download and try again."
        case .mmprojFileNotFound:
            return "The vision projector is missing. Repair the download and try again."
        case .nativeFailure(let kind, _):
            switch kind {
            case .modelMapping: return "The model file could not be mapped into memory."
            case .contextCreation: return "The model context could not be created safely."
            case .projectorInitialization: return "The vision projector could not be initialized."
            case .memoryPressure: return "The model was unloaded because the required memory reserve was not available."
            case .suspectedJetsam: return "Load safety state could not be committed. Loading remains blocked."
            case .inference: return "The local inference engine could not load this model."
            }
        case .modelNotLoaded, .visionNotSupported, .generationBusy:
            return error.localizedDescription
        }
    }

    /// Unload the current model, freeing memory. Persistence failures are surfaced.
    /// Pass `userInitiated: true` only for explicit user actions (Settings →
    /// Unload Model); those record `isUserUnloaded` so the deferred auto-loader
    /// does not reload the model behind the user's back.
    @discardableResult
    func unloadCurrentModel(userInitiated: Bool = false) async -> Bool {
        let unloadStarted = ContinuousClock.now
        if userInitiated { isUserUnloaded = true }
        // Cancel any in-flight stream first, mirroring cancelAndUnloadForSafety:
        // the engine actor's decode loop runs as one non-suspending job, so a
        // queued unload would otherwise wait out the whole generation (up to
        // maxTokens) before freeing memory — tokens kept streaming and the
        // Settings Active-Model section kept showing the model after unload.
        await inferenceService.cancelCurrentStream()
        await inferenceService.unloadModel()
        let previousModel = activeModel
        activeModel = nil
        currentState = .unloaded
        if let previousModel,
           let profileID = MemoryProfileRegistry.profile(for: previousModel)?.id {
            do {
                try loadSafetyStore.clearAfterCleanUnload(profileID: profileID)
            } catch {
                loadFailureMessage = "The model unloaded, but its load-safety state could not be saved."
                showLoadFailure = true
                return false
            }
        }
        MemoryDiagnosticRecorder.shared.capture(
            .afterUnload,
            elapsedMilliseconds: unloadStarted.elapsedMilliseconds
        )
        logger.info("Model unloaded: \(previousModel?.id ?? "none", privacy: .public)")
        return true
    }

    /// Switch models; safety failures never trigger an automatic reload.
    @discardableResult
    func switchToModel(_ model: AIModel) async -> ModelLoadResult {
        if let active = activeModel, active.id == model.id { return .alreadyLoaded }
        return await loadModel(model)
    }

    func resetLoadSafety(for model: AIModel) -> ModelSafetyResetResult {
        guard let profile = MemoryProfileRegistry.profile(for: model) else { return .failed(message: "No runtime profile exists for this model.") }
        guard loadSafetyStore.isDisabled(profileID: profile.id) else { return .notDisabled }
        do {
            try loadSafetyStore.reset(profileID: profile.id)
            return .reset
        } catch {
            return .failed(message: "The safety history could not be reset. Loading remains blocked.")
        }
    }

    func isLoadSafetyDisabled(for model: AIModel) -> Bool {
        guard let profile = MemoryProfileRegistry.profile(for: model) else { return false }
        return loadSafetyStore.isDisabled(profileID: profile.id)
    }

    /// Whether a model is currently loaded and ready.
    var isModelLoaded: Bool {
        if case .loaded = currentState { return true }
        return false
    }

    /// Read-shared gate for opportunistic loaders preventing stacked loads.
    var isLoadAttemptInFlight: Bool { loadInProgress }

    /// Current safety epoch for tests. Eviction bumps this; loads capture it
    /// at entry and stale evictions/loads invalidate against it.
    var currentSafetyEpochForTests: UInt64 { safetyEpoch }

    // MARK: - Memory Pressure

    // Critical path stays allocation-free apart from dispatching actor work.
    @objc private func handleMemoryPressure() {
        guard currentState == .loaded || currentState == .loading || loadInProgress else { return }
        safetyEpoch &+= 1
        let evictEpoch = safetyEpoch
        currentState = .evicted
        logger.info("Memory pressure evict epoch=\(evictEpoch, privacy: .public)")
        Task { await cancelAndUnloadForSafety(showWarning: true, expectedEpoch: evictEpoch) }
    }

    func handleBackgroundTransition() async {
        guard currentState == .loaded || currentState == .loading || loadInProgress else { return }
        safetyEpoch &+= 1
        let evictEpoch = safetyEpoch
        currentState = .evicted
        logger.info("Background evict epoch=\(evictEpoch, privacy: .public)")
        await cancelAndUnloadForSafety(showWarning: false, expectedEpoch: evictEpoch)
    }

    /// Epoch-gated safety eviction (P0-2). A stale Task from an older epoch
    /// must never wipe a fresh load that started after the bump: every
    /// destructive step re-checks `expectedEpoch == safetyEpoch` and bails
    /// with a fault log when stale. Serialized with loads via the MainActor
    /// plus epoch checks (loads capture `loadEpoch` and invalidate on mismatch).
    /// P1-3 coalesces concurrent evictions onto one teardown via evictTask:
    /// a joiner awaits the in-flight work and returns early when it already
    /// evicted (no duplicate backend_free); a stale join falls through to run
    /// its own epoch. Single warning: only sets true, never clears here.
    func cancelAndUnloadForSafety(showWarning: Bool, expectedEpoch: UInt64) async {
        if let running = evictTask {
            logger.info("Safety eviction coalesced expected=\(expectedEpoch, privacy: .public) current=\(self.safetyEpoch, privacy: .public)")
            await running.value
            if activeModel == nil && currentState == .evicted { return }
        }
        evictGeneration &+= 1
        let myGeneration = evictGeneration
        let work = Task<Void, Never> { [weak self, showWarning, expectedEpoch] in
            await self?.evictWork(showWarning: showWarning, expectedEpoch: expectedEpoch)
        }
        evictTask = work
        await work.value
        if evictGeneration == myGeneration { evictTask = nil }
    }

    /// Dismiss the memory warning banner.
    func dismissMemoryWarning() {
        showMemoryWarning = false
    }

    /// Load the first fully downloaded model. Used for UI testing.
    /// P0-1: candidate scan uses hash-free `quickAvailability` so auto-load
    /// never hashes multi-GB artifacts on the MainActor. The authoritative
    /// full SHA-256 verdict lands in `loadModel`'s async off-main preflight.
    func autoLoadFirstModel() async {
        guard activeModel == nil, !isLoadAttemptInFlight else { return }

        let candidates: [AIModel]
        if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled,
           let target = ModelRegistry.model(for: MemoryDiagnosticRecorder.targetModelID) {
            candidates = [target]
        } else {
            candidates = ModelRegistry.selectableModels
        }

        guard let model = candidates.first(where: {
            if case .ready = ModelManagerService.quickAvailability(for: $0) { return true }
            return false
        }) else {
            logger.warning("autoLoadFirstModel: required model is not installed and verified")
            return
        }
        logger.info("autoLoadFirstModel: loading \(model.id, privacy: .public)")
        await loadModel(model)
    }

    /// P0-3: admission refusal before teardown keeps the working model resident.
    /// Teardown hasn't run yet, so `activeModel` is still `priorActive` (untouched).
    /// Restores `priorState` when a prior model exists instead of parking on
    /// `.loadFailed` with a nilled engine. IDs are public; messages stay private.
    private func refuseLoadPreservingResident(
        kind: ModelLoadFailureKind,
        message: String,
        nativeKind: NativeFailureKind? = nil,
        priorActive: AIModel?,
        priorState: ModelState,
        modelID: String
    ) -> ModelLoadResult {
        logger.error("Load refused \(modelID, privacy: .public) kind=\(String(describing: kind), privacy: .public)")
        loadFailureMessage = message
        showLoadFailure = true
        if kind == .insufficientMemory {
            insufficientMemoryMessage = message
            showInsufficientMemoryWarning = true
        }
        if priorActive != nil {
            currentState = priorState == .loading ? .loadFailed : priorState
        } else {
            currentState = .loadFailed
        }
        return .failed(ModelLoadFailure(kind: kind, message: message, nativeKind: nativeKind))
    }

    // MARK: - Fix verify diagnostics + transient-dip settle

    /// One-line consent gate log (Fix verify a): eligibility, consent,
    /// override, allow, and reclaimable credit with its prior cause.
    /// IDs public; makes profileUnvalidated-vs-headroom unambiguous.
    private static func logConsentGate(
        _ logger: Logger, phase: String, model: AIModel,
        override: Bool, consent: Bool,
        reclaimable: UInt64, priorActive: AIModel?
    ) {
        let credit = MemoryBudgeter.reclaimableCreditDetails(for: priorActive)
        let priorID = priorActive?.id ?? "nil"
        let creditEvidence = credit.evidenceStatus ?? "nil"
        let consentFlag = consent ? 1 : 0
        let overrideFlag = override ? 1 : 0
        logger.info("Load gate \(phase, privacy: .public) model=\(model.id, privacy: .public) consent=\(consentFlag, privacy: .public) override=\(overrideFlag, privacy: .public)")
        logger.info("Load gate reclaim=\(reclaimable, privacy: .public) prior=\(priorID, privacy: .public) evidence=\(creditEvidence, privacy: .public)")
    }

    /// Refusal cause log (Fix verify a+b): distinguishes consent-missing
    /// profileUnvalidated from genuine headroom misses, and names the
    /// unvalidated prior behind a zero-credit projected==raw refusal.
    private static func logBudgetRefusal(
        _ logger: Logger, phase: String, model: AIModel,
        decision: MemoryLoadDecision, priorActive: AIModel?
    ) {
        if decision.reason == .profileUnvalidated {
            logger.fault("Load \(phase, privacy: .public) refused unconsented model=\(model.id, privacy: .public) \(decision.logSummary, privacy: .public)")
        } else if decision.reason == .insufficientProcessHeadroom,
                  (decision.reclaimableBytes ?? 0) == 0,
                  let prior = priorActive {
            let credit = MemoryBudgeter.reclaimableCreditDetails(for: prior)
            let creditProfile = credit.profileID ?? "nil"
            let creditEvidence = credit.evidenceStatus ?? "nil"
            logger.fault("Load refused zero-credit phase=\(phase, privacy: .public) model=\(model.id, privacy: .public) prior=\(prior.id, privacy: .public)")
            logger.fault("Zero-credit cause profile=\(creditProfile, privacy: .public) evidence=\(creditEvidence, privacy: .public) \(decision.logSummary, privacy: .public)")
        }
    }

    /// Settle-once for transient dips (Fix verify c): when the first sample
    /// misses on headroom but the shortfall fits inside
    /// `transientDipSettleWindowBytes`, wait 1s (10×100ms, cancellable +
    /// epoch-checked) and resample once with identical inputs. Returns the
    /// second decision, or nil when no retry was warranted (pass, non-headroom
    /// refusal, or large shortfall). Callers re-check cancel/epoch and adopt
    /// the returned decision.
    private func settleResampleForTransientDip(
        _ model: AIModel, loadEpoch: UInt64, priorActive: AIModel?,
        allow: Bool, reclaimable: UInt64,
        first: MemoryLoadDecision, phase: String
    ) async -> MemoryLoadDecision? {
        guard first.reason == .insufficientProcessHeadroom,
              let required = first.requiredBytes,
              let projected = first.projectedAvailableBytes,
              required > projected else { return nil }
        let shortfall = required - projected
        guard shortfall <= MemoryBudgeter.transientDipSettleWindowBytes else {
            return nil
        }
        logger.info("Load \(phase, privacy: .public) transient dip settle model=\(model.id, privacy: .public) shortfall=\(shortfall, privacy: .public) \(first.logSummary, privacy: .public)")
        let start = ContinuousClock.now
        let chunk: Duration = .milliseconds(100)
        while start.duration(to: .now) < .seconds(1) {
            if Task.isCancelled { return nil }
            guard loadEpoch == safetyEpoch else { return nil }
            do {
                try await Task.sleep(for: chunk)
            } catch {
                return nil
            }
        }
        guard loadEpoch == safetyEpoch, !Task.isCancelled else { return nil }
        let second = await memoryBudgeter.decision(
            for: model, allowUnvalidatedCalibration: allow,
            reclaimableBytes: reclaimable
        )
        logger.info("Load \(phase, privacy: .public) post-settle resample model=\(model.id, privacy: .public) \(second.logSummary, privacy: .public)")
        return second
    }
}
// MARK: - Load pipeline (extension keeps the manager type body focused for
// type_body_length; same-file extension retains private access).
@MainActor
extension ModelLifecycleManager {
    private func preflightAndAdmit(
        _ model: AIModel,
        loadEpoch: UInt64,
        priorActive: AIModel?,
        priorState: ModelState
    ) async -> (profile: MemoryProfile?, early: ModelLoadResult?) {
        let provider = availabilityProvider
        let availability = await Task.detached(priority: .utility) { provider(model) }.value
        if Task.isCancelled {
            logger.info("Load preflight cancelled \(model.id, privacy: .public)")
            return (nil, await invalidateLoadAttempt())
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load preflight invalidated by safety epoch \(model.id, privacy: .public)")
            return (nil, await invalidateLoadAttempt())
        }
        logger.info("Load preflight \(model.id, privacy: .public) availability=\(String(describing: availability), privacy: .public)")
        guard case .ready = availability else {
            logger.error("Load refused unavailable artifact \(model.id, privacy: .public)")
            let msg = "The downloaded model files are missing or failed integrity verification. Repair the download and try again."
            return (nil, refuseLoadPreservingResident(kind: .unavailableArtifact, message: msg, priorActive: priorActive, priorState: priorState, modelID: model.id))
        }
        guard let profile = MemoryProfileRegistry.profile(for: model) else {
            logger.error("Load refused no runtime profile \(model.id, privacy: .public)")
            let msg = model.runtimeEligibilityExplanation
            let refused = refuseLoadPreservingResident(kind: .runtimeProfileUnavailable, message: msg, priorActive: priorActive, priorState: priorState, modelID: model.id)
            return (nil, refused)
        }
        if loadSafetyStore.isDisabled(profileID: profile.id) {
            let unclean = loadSafetyStore.recentUncleanAttemptCount(profileID: profile.id)
            logger.error("Load refused safety-disabled profile \(profile.id, privacy: .public) unclean=\(unclean, privacy: .public) model=\(model.id, privacy: .public)")
            let msg = "This exact runtime profile was disabled after two unclean attempts among its last five loads. "
                + "Open the model details and explicitly reset its safety history before trying again."
            return (nil, refuseLoadPreservingResident(kind: .safetyDisabled, message: msg, priorActive: priorActive, priorState: priorState, modelID: model.id))
        }
        let override = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled && model.id == MemoryDiagnosticRecorder.targetModelID
        let consent = model.runtimeEligibility == .experimental && ExperimentalModelConsent.isGranted(for: model)
        // Pre-teardown sample WHILE priorActive is still resident: credit its
        // reclaimable footprint so a B-alone-fits switch is not refused as
        // if A+B had to coexist. .unloadCurrentFirst proceeds to teardown;
        // only a projected miss refuses with the resident preserved.
        let reclaimable = MemoryBudgeter.reclaimableBytes(for: priorActive)
        // Fix verify (a)(b): log the full consent gate + reclaimable cause
        // so a profileUnvalidated (consent missing, required=nil) never
        // masquerades as a headroom shortfall, and a zero-credit
        // insufficientProcessHeadroom names its unvalidated prior.
        Self.logConsentGate(
            logger, phase: "preflight", model: model,
            override: override, consent: consent,
            reclaimable: reclaimable, priorActive: priorActive
        )
        var decision = await memoryBudgeter.decision(for: model, allowUnvalidatedCalibration: override || consent, reclaimableBytes: reclaimable)
        // Fix verify (c): one settle + resample on a narrow headroom miss
        // (transient jetsam dip). Large shortfalls skip the delay.
        if let settled = await settleResampleForTransientDip(
            model, loadEpoch: loadEpoch, priorActive: priorActive,
            allow: override || consent, reclaimable: reclaimable,
            first: decision, phase: "preflight"
        ) {
            if Task.isCancelled {
                logger.info("Load budget check cancelled \(model.id, privacy: .public)")
                return (nil, await invalidateLoadAttempt())
            }
            guard loadEpoch == safetyEpoch else {
                logger.info("Load budget check invalidated by epoch \(model.id, privacy: .public)")
                return (nil, await invalidateLoadAttempt())
            }
            decision = settled
        }
        if Task.isCancelled {
            logger.info("Load budget check cancelled \(model.id, privacy: .public)")
            return (nil, await invalidateLoadAttempt())
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load budget check invalidated by epoch \(model.id, privacy: .public)")
            return (nil, await invalidateLoadAttempt())
        }
        if decision.recommendation == .unloadCurrentFirst {
            logger.info("Load proceeds to teardown reclaiming resident \(model.id, privacy: .public) \(decision.logSummary, privacy: .public)")
            return (profile, nil)
        }
        guard decision.recommendation == .proceed else {
            Self.logBudgetRefusal(logger, phase: "preflight", model: model, decision: decision, priorActive: priorActive)
            logger.error("Load refused insufficient memory \(model.id, privacy: .public) \(decision.logSummary, privacy: .public)")
            let alert = decision.alertMessage(modelName: model.displayName, priorActive: priorActive)
            let refused = refuseLoadPreservingResident(kind: .insufficientMemory, message: alert, priorActive: priorActive, priorState: priorState, modelID: model.id)
            return (nil, refused)
        }
        return (profile, nil)
    }

    /// P0-3 teardown + cancellable recovery sleep (epochs per 100ms).
    /// Returns nil to continue, or an invalidation result to return early.
    private func teardownAndRecover(_ model: AIModel, loadEpoch: UInt64) async -> ModelLoadResult? {
        let engineLoaded = await inferenceService.isModelLoaded
        if Task.isCancelled {
            logger.info("Load cancelled before teardown \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load invalidated before teardown \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard activeModel != nil || engineLoaded else { return nil }
        await inferenceService.cancelCurrentStream()
        if Task.isCancelled {
            logger.info("Load cancelled during teardown \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load invalidated during teardown \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        await inferenceService.unloadModel()
        guard loadEpoch == safetyEpoch else {
            logger.info("Load invalidated after unload \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        activeModel = nil
        currentState = .loading
        let sleepStart = ContinuousClock.now
        let chunk: Duration = .milliseconds(100)
        while sleepStart.duration(to: .now) < recoveryDelay {
            if Task.isCancelled {
                logger.info("Load recovery sleep cancelled \(model.id, privacy: .public)")
                return await invalidateLoadAttempt()
            }
            guard loadEpoch == safetyEpoch else {
                logger.info("Load recovery sleep invalidated by epoch \(model.id, privacy: .public)")
                return await invalidateLoadAttempt()
            }
            do {
                try await Task.sleep(for: chunk)
            } catch {
                logger.info("Load recovery sleep interrupted \(model.id, privacy: .public)")
                return await invalidateLoadAttempt()
            }
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load recovery completed stale \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        if Task.isCancelled {
            logger.info("Load recovery cancelled after sleep \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        return nil
    }

    /// Native construction + post-load reserve + commit. Post-teardown failures
    /// funnel through failPostTeardownOrRestorePrior so a displaced resident
    /// gets one bring-back attempt instead of stranding .loadFailed + nil.
    private func constructAndCommit(_ model: AIModel, loadEpoch: UInt64, priorActive: AIModel?) async -> ModelLoadResult {
        let baseURL = ModelManagerService.baseModelPath(for: model)
        let mmprojURL = model.requiresMMProj ? ModelManagerService.mmprojModelPath(for: model) : nil
        // P1-1 fresh resample immediately pre-mmap: the preflight decision is
        // stale after teardown sleep. Recompute consent/override identically,
        // refuse closed with fault logs; never reuse the old decision.
        let freshOverride = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled && model.id == MemoryDiagnosticRecorder.targetModelID
        let freshConsent = model.runtimeEligibility == .experimental && ExperimentalModelConsent.isGranted(for: model)
        // Fix verify (a): same consent gate log as preflight so the
        // pre-mmap resample's allow flag is observable (post-teardown,
        // reclaimable 0 by construction).
        Self.logConsentGate(
            logger, phase: "pre-mmap", model: model,
            override: freshOverride, consent: freshConsent,
            reclaimable: 0, priorActive: nil
        )
        let freshDecision = await memoryBudgeter.decision(for: model, allowUnvalidatedCalibration: freshOverride || freshConsent)
        if Task.isCancelled {
            logger.info("Load pre-mmap resample cancelled \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load pre-mmap resample invalidated by epoch \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard freshDecision.recommendation == .proceed else {
            Self.logBudgetRefusal(logger, phase: "pre-mmap", model: model, decision: freshDecision, priorActive: priorActive)
            logger.error("Load refused stale-budget resample \(model.id, privacy: .public) \(freshDecision.logSummary, privacy: .public)")
            let alert = freshDecision.alertMessage(modelName: model.displayName, priorActive: priorActive)
            insufficientMemoryMessage = alert
            showInsufficientMemoryWarning = true
            return await failPostTeardownOrRestorePrior(
                target: model, priorActive: priorActive, loadEpoch: loadEpoch,
                kind: .insufficientMemory, message: alert
            )
        }
        let started = ContinuousClock.now
        do {
            try await inferenceService.loadModel(model, baseURL: baseURL, mmprojURL: mmprojURL)
            guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
            guard await memoryBudgeter.postLoadReserveSatisfied() else {
                await inferenceService.unloadModel()
                throw InferenceError.nativeFailure(kind: .memoryPressure, diagnostic: MemoryAdmissionFailure.postLoadReserveBreached.rawValue)
            }
            guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
            activeModel = model
            currentState = .loaded
            recordImportedLoadSuccess(for: model)
            MemoryDiagnosticRecorder.shared.capture(.afterModelLoad, elapsedMilliseconds: started.elapsedMilliseconds)
            logger.info("Model loaded: \(model.id, privacy: .public)")
            return .loaded
        } catch {
            MemoryDiagnosticRecorder.shared.capture(.afterModelLoad, elapsedMilliseconds: started.elapsedMilliseconds, error: error.localizedDescription)
            let inferenceError = error as? InferenceError
            let detail = inferenceError?.sanitizedDiagnostic ?? "unknown-load-failure"
            let kindName = inferenceError?.nativeFailureKind.map(String.init(describing:)) ?? "none"
            logger.error("Model load failed: \(detail, privacy: .private) nativeKind=\(kindName, privacy: .public)")
            let nativeKind = inferenceError?.nativeFailureKind
            let message = Self.userMessage(for: inferenceError)
            recordImportedLoadFailure(for: model, nativeKind: nativeKind, message: message)
            let kind: ModelLoadFailureKind = inferenceError?.sanitizedDiagnostic.contains("load-safety") == true ? .safetyPersistence : .nativeLoadFailure
            return await failPostTeardownOrRestorePrior(
                target: model, priorActive: priorActive, loadEpoch: loadEpoch,
                kind: kind, message: message, nativeKind: nativeKind
            )
        }
    }

    /// P0 chat-switch teardown-then-fail: fresh budget sample between admission
    /// and teardown. Refusals keep the resident via refuseLoadPreservingResident
    /// (same consent/override inputs as preflight and the pre-mmap resample).
    /// IDs are public; the decision summary stays public, messages private.
    private func freshBudgetGateBeforeTeardown(
        _ model: AIModel,
        loadEpoch: UInt64,
        priorActive: AIModel?,
        priorState: ModelState
    ) async -> ModelLoadResult? {
        let override = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled && model.id == MemoryDiagnosticRecorder.targetModelID
        let consent = model.runtimeEligibility == .experimental && ExperimentalModelConsent.isGranted(for: model)
        // Same reclaimable credit as preflight: a projected pass proceeds to
        // teardown instead of refusing with the resident preserved.
        let reclaimable = MemoryBudgeter.reclaimableBytes(for: priorActive)
        Self.logConsentGate(
            logger, phase: "pre-teardown", model: model,
            override: override, consent: consent,
            reclaimable: reclaimable, priorActive: priorActive
        )
        var fresh = await memoryBudgeter.decision(for: model, allowUnvalidatedCalibration: override || consent, reclaimableBytes: reclaimable)
        // Fix verify (c): settle-once on a narrow headroom miss before
        // refusing with the resident preserved.
        if let settled = await settleResampleForTransientDip(
            model, loadEpoch: loadEpoch, priorActive: priorActive,
            allow: override || consent, reclaimable: reclaimable,
            first: fresh, phase: "pre-teardown"
        ) {
            if Task.isCancelled {
                logger.info("Load pre-teardown resample cancelled \(model.id, privacy: .public)")
                return await invalidateLoadAttempt()
            }
            guard loadEpoch == safetyEpoch else {
                logger.info("Load pre-teardown resample invalidated by epoch \(model.id, privacy: .public)")
                return await invalidateLoadAttempt()
            }
            fresh = settled
        }
        if Task.isCancelled {
            logger.info("Load pre-teardown resample cancelled \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        guard loadEpoch == safetyEpoch else {
            logger.info("Load pre-teardown resample invalidated by epoch \(model.id, privacy: .public)")
            return await invalidateLoadAttempt()
        }
        if fresh.recommendation == .unloadCurrentFirst {
            logger.info("Load pre-teardown resample proceeds to teardown \(model.id, privacy: .public) \(fresh.logSummary, privacy: .public)")
            return nil
        }
        guard fresh.recommendation == .proceed else {
            Self.logBudgetRefusal(logger, phase: "pre-teardown", model: model, decision: fresh, priorActive: priorActive)
            logger.fault("Load refused pre-teardown resample \(model.id, privacy: .public) \(fresh.logSummary, privacy: .public)")
            let alert = fresh.alertMessage(modelName: model.displayName, priorActive: priorActive)
            return refuseLoadPreservingResident(
                kind: .insufficientMemory, message: alert,
                priorActive: priorActive, priorState: priorState, modelID: model.id
            )
        }
        return nil
    }

    /// Post-teardown failure with a displaced resident: single attempt to bring
    /// the prior model back with a direct engine load — never via loadModel, so
    /// no recursion into admit/teardown — else park .loadFailed for the failed
    /// target. IDs are public; messages stay private.
    private func failPostTeardownOrRestorePrior(
        target: AIModel,
        priorActive: AIModel?,
        loadEpoch: UInt64,
        kind: ModelLoadFailureKind,
        message: String,
        nativeKind: NativeFailureKind? = nil
    ) async -> ModelLoadResult {
        guard let priorActive, loadEpoch == safetyEpoch else {
            return failLoad(kind: kind, message: message, nativeKind: nativeKind)
        }
        logger.fault("Post-teardown load failed, restoring prior target=\(target.id, privacy: .public) prior=\(priorActive.id, privacy: .public)")
        do {
            try await inferenceService.loadModel(
                priorActive,
                baseURL: ModelManagerService.baseModelPath(for: priorActive),
                mmprojURL: priorActive.requiresMMProj ? ModelManagerService.mmprojModelPath(for: priorActive) : nil
            )
            guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
            activeModel = priorActive
            currentState = .loaded
            recordImportedLoadSuccess(for: priorActive)
            loadFailureMessage = message
            showLoadFailure = true
            return .failed(ModelLoadFailure(kind: kind, message: message, nativeKind: nativeKind))
        } catch {
            logger.error("Prior restore failed \(priorActive.id, privacy: .public)")
            return failLoad(kind: kind, message: message, nativeKind: nativeKind)
        }
    }

    /// P1-3 single-teardown worker behind the evictTask coalescer. Epoch-gated
    /// at every destructive step; single warning (sets true only, never clears).
    /// R6: cancel engine, release gate (actor teardown releases idempotently),
    /// then unload. VM completion paths gate reload on evicted state.
    private func evictWork(showWarning: Bool, expectedEpoch: UInt64) async {
        guard expectedEpoch == safetyEpoch else {
            logger.info("Stale safety eviction ignored expected=\(expectedEpoch, privacy: .public) current=\(self.safetyEpoch, privacy: .public)")
            return
        }
        await inferenceService.cancelCurrentStream()
        await inferenceService.releaseGenerationGateForEviction()
        guard expectedEpoch == safetyEpoch else {
            logger.info("Stale safety eviction ignored after cancel expected=\(expectedEpoch, privacy: .public) current=\(self.safetyEpoch, privacy: .public)")
            return
        }
        await unloadCurrentModel()
        guard expectedEpoch == safetyEpoch else {
            logger.info("Stale safety eviction ignored after unload expected=\(expectedEpoch, privacy: .public) current=\(self.safetyEpoch, privacy: .public)")
            return
        }
        currentState = .evicted
        if showWarning, !showMemoryWarning { showMemoryWarning = true }
        logger.info("Safety eviction completed epoch=\(expectedEpoch, privacy: .public) warning=\(showWarning, privacy: .public)")
    }

}

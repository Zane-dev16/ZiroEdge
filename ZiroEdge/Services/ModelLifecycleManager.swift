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

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.unloaded, .unloaded), (.loading, .loading), (.loaded, .loaded), (.evicted, .evicted), (.loadFailed, .loadFailed):
            return true
        default:
            return false
        }
    }
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

    // MARK: - Initialization

    init(
        inferenceService: any InferenceServiceProtocol,
        memoryBudgeter: MemoryBudgeter,
        loadSafetyStore: LoadSafetyStore,
        importedModelStore: ImportedModelStore = .shared,
        availabilityProvider: @escaping @Sendable (AIModel) -> ModelAvailability = {
            ModelManagerService.availability(for: $0)
        },
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
    @discardableResult
    func loadModel(_ model: AIModel) async -> ModelLoadResult {
        guard case .ready = availabilityProvider(model) else {
            return failLoad(
                kind: .unavailableArtifact,
                message: "The downloaded model files are missing or failed integrity verification. Repair the download and try again."
            )
        }
        if let active = activeModel, active.id == model.id, currentState == .loaded {
            return .alreadyLoaded
        }

        loadInProgress = true
        currentState = .loading
        let loadEpoch = safetyEpoch
        defer { loadInProgress = false }
        MemoryDiagnosticRecorder.shared.capture(.beforeModelLoad)

        let engineReportsLoaded = await inferenceService.isModelLoaded
        let hadPriorEngine = activeModel != nil || engineReportsLoaded
        if hadPriorEngine {
            await inferenceService.cancelCurrentStream()
            await inferenceService.unloadModel()
            activeModel = nil
            currentState = .loading
            do {
                try await Task.sleep(for: recoveryDelay)
            } catch {
                return await invalidateLoadAttempt()
            }
        }
        guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }

        guard let profile = MemoryProfileRegistry.profile(for: model) else {
            return failLoad(kind: .runtimeProfileUnavailable, message: model.runtimeEligibilityExplanation)
        }
        if loadSafetyStore.isDisabled(profileID: profile.id) {
            return failLoad(
                kind: .safetyDisabled,
                message: "This exact runtime profile was disabled after two unclean attempts among its last five loads. "
                    + "Open the model details and explicitly reset its safety history before trying again."
            )
        }

        let calibrationOverride = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled
            && model.id == MemoryDiagnosticRecorder.targetModelID
        let experimentalConsent = model.runtimeEligibility == .experimental
            && ExperimentalModelConsent.isGranted(for: model)
        let decision = await memoryBudgeter.decision(
            for: model,
            allowUnvalidatedCalibration: calibrationOverride || experimentalConsent
        )
        guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
        guard decision.recommendation == .proceed else {
            logger.warning("Blocking unsafe load for \(model.id, privacy: .public): \(decision.logSummary, privacy: .public)")
            insufficientMemoryMessage = decision.alertMessage(modelName: model.displayName)
            showInsufficientMemoryWarning = true
            currentState = .loadFailed
            return .failed(ModelLoadFailure(
                kind: .insufficientMemory,
                message: decision.alertMessage(modelName: model.displayName),
                nativeKind: nil
            ))
        }

        let baseURL = ModelManagerService.baseModelPath(for: model)
        let mmprojURL = model.requiresMMProj ? ModelManagerService.mmprojModelPath(for: model) : nil
        let loadStarted = ContinuousClock.now
        do {
            try await inferenceService.loadModel(model, baseURL: baseURL, mmprojURL: mmprojURL)
            guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
            guard await memoryBudgeter.postLoadReserveSatisfied() else {
                await inferenceService.unloadModel()
                throw InferenceError.nativeFailure(
                    kind: .memoryPressure,
                    diagnostic: MemoryAdmissionFailure.postLoadReserveBreached.rawValue
                )
            }
            guard loadEpoch == safetyEpoch else { return await invalidateLoadAttempt() }
            activeModel = model
            currentState = .loaded
            recordImportedLoadSuccess(for: model)
            MemoryDiagnosticRecorder.shared.capture(
                .afterModelLoad,
                elapsedMilliseconds: loadStarted.elapsedMilliseconds
            )
            logger.info("Model loaded: \(model.id, privacy: .public)")
            return .loaded
        } catch {
            MemoryDiagnosticRecorder.shared.capture(
                .afterModelLoad,
                elapsedMilliseconds: loadStarted.elapsedMilliseconds,
                error: error.localizedDescription
            )
            let inferenceError = error as? InferenceError
            logger.error("Model load failed: \(inferenceError?.sanitizedDiagnostic ?? "unknown-load-failure", privacy: .private)")
            let nativeKind = inferenceError?.nativeFailureKind
            let message = Self.userMessage(for: inferenceError)
            recordImportedLoadFailure(for: model, nativeKind: nativeKind, message: message)
            return failLoad(
                kind: inferenceError?.sanitizedDiagnostic.contains("load-safety") == true
                    ? .safetyPersistence : .nativeLoadFailure,
                message: message,
                nativeKind: nativeKind
            )
        }
    }

    private func recordImportedLoadSuccess(for model: AIModel) {
        guard model.isImported else { return }
        try? importedModelStore.update(id: model.id) { $0.loadStatus = .loaded }
    }

    private func recordImportedLoadFailure(
        for model: AIModel,
        nativeKind: NativeFailureKind?,
        message: String
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
        kind: ModelLoadFailureKind,
        message: String,
        nativeKind: NativeFailureKind? = nil
    ) -> ModelLoadResult {
        currentState = .loadFailed
        loadFailureMessage = message
        showLoadFailure = true
        return .failed(ModelLoadFailure(kind: kind, message: message, nativeKind: nativeKind))
    }

    private func invalidateLoadAttempt() async -> ModelLoadResult {
        await inferenceService.cancelCurrentStream()
        await inferenceService.unloadModel()
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
    @discardableResult
    func unloadCurrentModel() async -> Bool {
        let unloadStarted = ContinuousClock.now
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

    /// Switch to a different model. Safety failures never trigger an automatic reload.
    @discardableResult
    func switchToModel(_ model: AIModel) async -> ModelLoadResult {
        if let active = activeModel, active.id == model.id { return .alreadyLoaded }
        return await loadModel(model)
    }

    func resetLoadSafety(for model: AIModel) -> ModelSafetyResetResult {
        guard let profile = MemoryProfileRegistry.profile(for: model) else {
            return .failed(message: "No runtime profile exists for this model.")
        }
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

    // MARK: - Memory Pressure

    @objc private func handleMemoryPressure() {
        // Keep the critical notification path allocation-free apart from dispatching existing actor work.
        guard currentState == .loaded || currentState == .loading || loadInProgress else { return }
        safetyEpoch &+= 1
        currentState = .evicted
        Task { await cancelAndUnloadForSafety(showWarning: true) }
    }

    func handleBackgroundTransition() async {
        guard currentState == .loaded || currentState == .loading || loadInProgress else { return }
        safetyEpoch &+= 1
        currentState = .evicted
        await cancelAndUnloadForSafety(showWarning: false)
    }

    private func cancelAndUnloadForSafety(showWarning: Bool) async {
        await inferenceService.cancelCurrentStream()
        await unloadCurrentModel()
        currentState = .evicted
        showMemoryWarning = showWarning
    }

    /// Dismiss the memory warning banner.
    func dismissMemoryWarning() {
        showMemoryWarning = false
    }

    /// Load the first fully downloaded model. Used for UI testing.
    func autoLoadFirstModel() async {
        guard activeModel == nil else { return }

        let candidates: [AIModel]
        if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled,
           let target = ModelRegistry.model(for: MemoryDiagnosticRecorder.targetModelID) {
            candidates = [target]
        } else {
            candidates = ModelRegistry.selectableModels
        }

        guard let model = candidates.first(where: ModelManagerService.isFullyDownloaded) else {
            logger.warning("autoLoadFirstModel: required model is not installed and verified")
            return
        }
        logger.info("autoLoadFirstModel: loading \(model.id, privacy: .public)")
        await loadModel(model)
    }
}

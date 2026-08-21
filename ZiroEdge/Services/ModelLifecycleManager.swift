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

    // MARK: - Download Status (injected from ModelManagerService)

    /// Tracks download state per model ID. Populated by ModelManagerService.
    @Published var downloadStatuses: [String: ModelDownloadStatus] = [:]

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
        case .modelNotLoaded, .visionNotSupported:
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

// MARK: - Model Manager Service (Download + Verify)

/// Handles model file management: download, SHA-256 verification, storage queries.
/// This is a separate concern from lifecycle — it manages files on disk.
enum ModelManagerService {

    private static let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "model-manager")

    /// Managed installed-model library. Documents/Models remains legacy input only.
    static var modelsDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Installed", isDirectory: true)
    }

    /// File path for a model's base .gguf.
    static func baseModelPath(for model: AIModel) -> URL {
        modelsDirectory.appendingPathComponent("\(model.baseArtifactStorageID).gguf")
    }

    /// File path for a model's mmproj.gguf (vision models).
    static func mmprojModelPath(for model: AIModel) -> URL {
        if model.isImported, let digest = model.mmprojSHA256 {
            return modelsDirectory.appendingPathComponent("hf-\(digest.prefix(24))-mmproj.gguf")
        }
        return modelsDirectory.appendingPathComponent("\(model.id)-mmproj.gguf")
    }

    /// Whether the base artifact passes the complete catalog contract.
    /// Download planning must use the digest too: header and size alone cannot
    /// distinguish a repairable same-size corruption from an installed model.
    static func isBaseDownloaded(_ model: AIModel) -> Bool {
        isArtifactDownloaded(model, artifact: .base)
    }

    /// Whether the projector passes the complete catalog contract.
    /// Always returns true for text-only models.
    static func isMMProjDownloaded(_ model: AIModel) -> Bool {
        guard model.requiresMMProj else { return true }
        return isArtifactDownloaded(model, artifact: .mmproj)
    }

    private static func isArtifactDownloaded(_ model: AIModel, artifact: ArtifactType) -> Bool {
        let path: URL
        let expectedBytes: Int64
        let expectedSHA: String
        switch artifact {
        case .base:
            path = baseModelPath(for: model)
            expectedBytes = model.baseFileSizeBytes
            expectedSHA = model.baseSHA256
        case .mmproj:
            guard let bytes = model.mmprojFileSizeBytes,
                  let sha = model.mmprojSHA256 else { return false }
            path = mmprojModelPath(for: model)
            expectedBytes = bytes
            expectedSHA = sha
        }
        guard isValidSHA256(expectedSHA),
              FileManager.default.fileExists(atPath: path.path) else { return false }
        // Canonical validation pass; the quarantine decision stays here.
        let outcome = ModelArtifactVerifier.validate(
            fileURL: path,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA,
            isCancelled: { false },
            digestProvider: { computeSHA256(fileURL: $0) }
        )
        guard outcome == .valid else {
            quarantineInvalidArtifact(at: path, storageID: model.id)
            markRepairNeeded(for: model)
            return false
        }
        return true
    }

    /// Whether a model is fully downloaded AND passes validation (GGUF header, size, SHA-256).
    static func isFullyDownloaded(_ model: AIModel) -> Bool {
        if case .ready = availability(for: model) { return true }
        return false
    }

    /// Disk usage in bytes for a specific model (base + mmproj).
    static func diskUsage(for model: AIModel) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        let basePath = baseModelPath(for: model)
        if let attrs = try? fm.attributesOfItem(atPath: basePath.path),
           let size = attrs[.size] as? Int64 {
            total = SaturatedArithmetic.add(total, size)
        }

        if model.requiresMMProj {
            let mmprojPath = mmprojModelPath(for: model)
            if let attrs = try? fm.attributesOfItem(atPath: mmprojPath.path),
               let size = attrs[.size] as? Int64 {
                total = SaturatedArithmetic.add(total, size)
            }
        }

        return total
    }

    /// Formatted disk usage for a specific model.
    static func formattedDiskUsage(for model: AIModel) -> String {
        StorageByteFormatter.string(fromByteCount: diskUsage(for: model))
    }

    /// Total disk usage of all downloaded models in bytes.
    static func totalDiskUsage() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total = SaturatedArithmetic.add(total, Int64(size))
            }
        }
        return total
    }

    /// Formatted total disk usage string.
    static func formattedDiskUsage() -> String {
        StorageByteFormatter.string(fromByteCount: totalDiskUsage())
    }

    /// Verify SHA-256 of a downloaded file.
    static func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard isValidSHA256(expected), let hex = computeSHA256(fileURL: fileURL) else { return false }
        return hex == expected
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isBaseArtifactShared(_ model: AIModel) -> Bool {
        ModelRegistry.transferModels.contains {
            $0.id != model.id && $0.baseArtifactStorageID == model.baseArtifactStorageID
        }
    }

    static func isProjectorArtifactShared(_ model: AIModel) -> Bool {
        guard let digest = model.mmprojSHA256 else { return false }
        return ModelRegistry.transferModels.contains {
            $0.id != model.id && $0.mmprojSHA256 == digest
        }
    }

    static func isVisionReady(_ model: AIModel) -> Bool {
        guard isFullyDownloaded(model) else { return false }
        return model.modelType != .vision || isMMProjDownloaded(model)
    }

    static func advertisesVisionCapability(_ model: AIModel) -> Bool {
        model.modelType == .vision && isVisionReady(model)
    }

    /// Delete artifacts owned exclusively by one catalog entry. A shared base
    /// remains installed while another catalog variant references that storage ID.
    static func deleteModel(
        _ model: AIModel,
        preservingReferences references: [AIModel] = []
    ) {
        let fm = FileManager.default
        let otherReferences = references.filter { $0.id != model.id }
        let baseIsReferenced = otherReferences.contains {
            $0.baseArtifactStorageID == model.baseArtifactStorageID
        }
        if !baseIsReferenced, !isBaseArtifactShared(model) {
            try? fm.removeItem(at: baseModelPath(for: model))
        }
        let projectorIsReferenced = model.requiresMMProj && otherReferences.contains {
            $0.requiresMMProj
                && mmprojModelPath(for: $0) == mmprojModelPath(for: model)
        }
        if model.requiresMMProj,
           !projectorIsReferenced,
           !isProjectorArtifactShared(model) {
            try? fm.removeItem(at: mmprojModelPath(for: model))
        }
        logger.info("Deleted model-owned files: \(model.id, privacy: .public)")
    }

    /// Remove only artifacts made obsolete by a successful record replacement.
    /// A new revision may intentionally reuse an unchanged digest-addressed base
    /// or projector; those paths must survive even though the stable model ID is
    /// the same before and after the registry swap.
    static func deleteReplacedArtifacts(previous: AIModel, retaining replacement: AIModel) {
        let fm = FileManager.default
        let previousBasePath = baseModelPath(for: previous)
        if previousBasePath != baseModelPath(for: replacement),
           !isBaseArtifactShared(previous) {
            try? fm.removeItem(at: previousBasePath)
        }

        if previous.requiresMMProj {
            let previousProjectorPath = mmprojModelPath(for: previous)
            let replacementProjectorPath = replacement.requiresMMProj
                ? mmprojModelPath(for: replacement)
                : nil
            if previousProjectorPath != replacementProjectorPath,
               !isProjectorArtifactShared(previous) {
                try? fm.removeItem(at: previousProjectorPath)
            }
        }
        logger.info("Deleted replaced model files: \(previous.id, privacy: .public)")
    }

    /// Create the models directory if it doesn't exist.
    static func ensureModelsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: modelsDirectory.path) {
            try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Availability Check

extension ModelManagerService {

    /// Comprehensive model availability check. Validates files on disk
    /// and returns ready, repair-needed, or unavailable.
    static func availability(for modelID: String) -> ModelAvailability {
        guard let model = ModelRegistry.model(for: modelID) else {
            return .unavailable
        }
        return availability(for: model)
    }

    /// Comprehensive model availability check for an AIModel.
    static func availability(for model: AIModel) -> ModelAvailability {
#if DEBUG
        if HermeticUITestRuntime.isEnabled, model.id == ModelRegistry.llama32_3B.id {
            return .ready
        }
#endif
        // Missing or malformed integrity metadata is a catalog configuration error.
        guard model.catalogUnavailableReason == nil,
              ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels) == nil else {
            return .unavailable
        }

        var issues: [ArtifactIssue] = []

        // Single canonical validation pass per artifact (ModelArtifactVerifier);
        // outcomes map onto the historical ArtifactIssue taxonomy.
        // Returns true when the caller must stop processing further artifacts
        // (unreadable file during hashing — the legacy short-circuit).
        @discardableResult
        func validateArtifact(
            _ path: URL,
            expectedBytes: Int64,
            expectedSHA: String,
            artifact: ArtifactType
        ) -> Bool {
            switch ModelArtifactVerifier.validate(
                fileURL: path,
                expectedBytes: expectedBytes,
                expectedSHA256: expectedSHA,
                isCancelled: { false },
                digestProvider: { computeSHA256(fileURL: $0) }
            ) {
            case .valid:
                return false
            case .missingFile:
                issues.append(.missing(artifact: artifact))
                return false
            case .unreadableSize, .sizeMismatch:
                issues.append(.sizeMismatch)
                return false
            case .structureInvalid:
                issues.append(.missingGGUFHeader)
                return false
            case .readFailure:
                // Legacy behavior: an unreadable file aborts the whole sweep
                // immediately with a SHA-256 issue for this artifact.
                issues.append(.sha256Mismatch)
                return true
            case .hashMismatch:
                issues.append(.sha256Mismatch)
                return false
            case .invalidMetadata, .cancelled:
                // Unreachable: the catalog guard above guarantees positive
                // sizes and lowercase digests, and cancellation is disabled.
                issues.append(.unknown("invalid catalog integrity metadata"))
                return true
            }
        }

        // Check base artifact.
        if validateArtifact(
            baseModelPath(for: model),
            expectedBytes: model.baseFileSizeBytes,
            expectedSHA: model.baseSHA256,
            artifact: .base
        ) {
            return .repairNeeded(issues: issues)
        }

        // Check mmproj artifact for vision models.
        if model.requiresMMProj {
            if validateArtifact(
                mmprojModelPath(for: model),
                expectedBytes: model.mmprojFileSizeBytes ?? 0,
                expectedSHA: model.mmprojSHA256 ?? "",
                artifact: .mmproj
            ) {
                return .repairNeeded(issues: issues)
            }
        }

        if issues.isEmpty {
            return .ready
        }
        return .repairNeeded(issues: issues)
    }
}

// MARK: - Managed Storage Directories

extension ModelManagerService {

#if DEBUG
    /// Redirects migration storage into a test-owned root.
    static var storageRootOverride: URL?
#endif

    /// Root directory for managed, backup-excluded model storage.
    static var managedStorageDirectory: URL {
#if DEBUG
        if let storageRootOverride {
            return storageRootOverride.appendingPathComponent("Managed", isDirectory: true)
        }
#endif
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("ZiroEdge/Models", isDirectory: true)
    }

    /// Staging area for in-progress downloads.
    static var stagingDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Resume data for interrupted downloads.
    static var resumeDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Resume", isDirectory: true)
    }

    /// Quarantine area for files that failed validation.
    static var quarantineDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    static func quarantineInvalidArtifact(at source: URL, storageID: String) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        ModelMigrationService.ensureManagedDirectories()
        let safeID = storageID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let destination = quarantineDirectory.appendingPathComponent(
            "\(safeID)-\(UUID().uuidString.lowercased()).quarantined"
        )
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: source)
        }
        // BATCH-05: notify storage cache to refresh (quarantine is a managed-storage mutation)
        NotificationCenter.default.post(name: .managedStorageDidChange, object: nil)
    }

    /// Legacy models directory (pre-#4 location in Documents).
    static var legacyModelsDirectory: URL {
#if DEBUG
        if let storageRootOverride {
            return storageRootOverride.appendingPathComponent("Legacy/Models", isDirectory: true)
        }
#endif
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("Models", isDirectory: true)
    }
}

// MARK: - Repair Tracking

extension ModelManagerService {

    private static let repairMarkerPrefix = ".repair-needed-"

    /// Mark a model as needing repair (e.g. after a failed migration).
    static func markRepairNeeded(for model: AIModel) {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        try? Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// Check whether a model has been marked for repair.
    static func isRepairNeeded(for model: AIModel) -> Bool {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Clear the repair marker after a successful repair.
    static func clearRepairNeeded(for model: AIModel) {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        try? FileManager.default.removeItem(at: marker)
    }
}


extension Notification.Name {
    static let managedStorageDidChange = Notification.Name("managedStorageDidChange")
}

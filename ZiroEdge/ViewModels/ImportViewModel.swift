import Foundation
import SwiftUI

@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case inspecting
        case review
        case importing
        case completed
        case failed(String)
    }

    @Published var repositoryInput = ""
    @Published private(set) var phase: Phase = .idle
    @Published var review: HFRepositoryReview?
    @Published var selectedBase: HFArtifact?
    @Published var importAsVision = false
    @Published var licenseConfirmed = false
    @Published var ramRiskAccepted = false
    @Published private(set) var existingModel: AIModel?
    /// When true, the user has explicitly confirmed the suggested vision pair.
    @Published var visionPairConfirmed = false

    private let inspector: HFRepositoryInspector
    private let store: ImportedModelStore
    private let downloadManager: DownloadManager
    private let physicalRAM: @Sendable () -> UInt64
    private let pairResolver = VisionPairResolver()

    init(
        inspector: HFRepositoryInspector = HFRepositoryInspector(),
        store: ImportedModelStore = .shared,
        downloadManager: DownloadManager,
        physicalRAM: @escaping @Sendable () -> UInt64 = { ProcessInfo.processInfo.physicalMemory },
        repositoryInput: String = ""
    ) {
        self.repositoryInput = repositoryInput
        self.inspector = inspector
        self.store = store
        self.downloadManager = downloadManager
        self.physicalRAM = physicalRAM
    }

    var baseCandidates: [HFArtifact] { review?.baseArtifacts ?? [] }

    // MARK: - Vision Pair Resolution

    /// All compatible vision pairs for the current review, ranked by confidence.
    var pairCandidates: [VisionPairCandidate] {
        guard let review else { return [] }
        return pairResolver.resolvePairs(from: review)
    }

    /// The suggested (highest-confidence) vision pair for the currently selected base.
    var suggestedPair: VisionPairCandidate? {
        guard let review, let selectedBase else { return nil }
        return pairResolver.bestPair(for: selectedBase, in: review)
    }

    /// The selected projector from the suggested pair (only when importAsVision is true).
    var selectedProjector: HFArtifact? {
        guard importAsVision else { return nil }
        return suggestedPair?.projector
    }

    /// Whether the repository has any viable vision pairs.
    var hasViableVisionPair: Bool {
        guard let review else { return false }
        return pairResolver.hasViableVisionPair(review)
    }

    /// Human-readable reason why no vision pair is available.
    var noVisionPairReason: String? {
        guard let review else { return nil }
        return pairResolver.noVisionPairReason(for: review)
    }

    /// Error from vision pair resolution, if any.
    var visionPairingError: String? {
        guard importAsVision else { return nil }
        guard let review else { return nil }
        if review.projectorArtifacts.isEmpty {
            return "No vision projector was found at this revision. Only text-only import is available."
        }
        if suggestedPair == nil {
            return noVisionPairReason ?? "No compatible vision pair could be resolved."
        }
        return nil
    }

    /// Whether the user needs to confirm the vision pair before import.
    var needsVisionPairConfirmation: Bool {
        importAsVision && suggestedPair != nil && !visionPairConfirmed
    }

    // MARK: - Size & Storage

    var selectedBytes: Int64 {
        guard let selectedBase else { return 0 }
        return selectedBase.size + (selectedProjector?.size ?? 0)
    }

    var storagePreflight: ImportStoragePreflight {
        let reusableBase = selectedBase.map { artifact in
            ModelRegistry.libraryModels.contains {
                $0.baseSHA256 == artifact.sha256 && ModelManagerService.isBaseDownloaded($0)
            }
        } ?? false
        let reusableProjector = selectedProjector.map { artifact in
            ModelRegistry.libraryModels.contains {
                $0.mmprojSHA256 == artifact.sha256 && ModelManagerService.isMMProjDownloaded($0)
            }
        } ?? false
        let required = (reusableBase ? 0 : (selectedBase?.size ?? 0))
            + (reusableProjector ? 0 : (selectedProjector?.size ?? 0))
        return ImportStoragePreflight(
            requiredBytes: required,
            safetyMarginBytes: downloadManager.storageSafetyMargin(for: required),
            availableBytes: downloadManager.availableDiskSpace
        )
    }

    var ramAssessment: ImportRAMAssessment {
        let estimate = ImportRAMAssessment.estimatedBytes(
            artifactBytes: selectedBytes,
            contextLength: selectedBase?.metadata.contextLength ?? 2048
        )
        let physical = physicalRAM()
        return ImportRAMAssessment(
            estimatedBytes: estimate,
            physicalBytes: physical,
            classification: estimate < physical ? .likelyFits : .risky
        )
    }

    // MARK: - Confirmation Gate

    var canConfirm: Bool {
        selectedBase != nil
            && licenseConfirmed
            && storagePreflight.canProceed
            && (ramAssessment.classification == .likelyFits || ramRiskAccepted)
            && visionPairingError == nil
            && (!needsVisionPairConfirmation)
    }

    // MARK: - Actions

    func inspect() async {
        phase = .inspecting
        review = nil
        selectedBase = nil
        existingModel = nil
        visionPairConfirmed = false
        do {
            let result = try await inspector.inspect(repositoryInput)
            review = result
            selectedBase = result.baseArtifacts.count == 1 ? result.baseArtifacts.first : nil
            if selectedBase != nil, !hasViableVisionPair {
                importAsVision = false
            }
            phase = .review
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func retryInspection() async { await inspect() }

    /// Called when the user toggles vision import. Resets confirmation state.
    func toggleVisionImport() {
        visionPairConfirmed = false
    }

    /// User explicitly confirms the suggested vision pair.
    func confirmVisionPair() {
        visionPairConfirmed = true
    }

    func confirmImport() {
        guard canConfirm, let review, let selectedBase else { return }
        let projector = selectedProjector
        if let duplicate = store.record(
            repositoryID: review.repositoryID,
            revision: review.revision,
            baseFilename: selectedBase.filename,
            projectorFilename: projector?.filename
        ) {
            existingModel = duplicate.model
            phase = .completed
            return
        }
        let record = ImportedModelFactory.makeRecord(review: review, base: selectedBase, projector: projector)
        do {
            let persisted = try store.upsert(record)
            downloadManager.updateStatusesFromDisk()
            downloadManager.startDownload(for: persisted.model)
            phase = .importing
        } catch {
            phase = .failed("The imported-model record could not be saved.")
        }
    }
}

// MARK: - Imported Model Update Coordinator

@MainActor
final class ImportedModelUpdateCoordinator: ObservableObject {
    enum CheckResult: Equatable {
        case upToDate
        case review(HFRepositoryReview)
    }

    /// Result of an atomic paired update attempt.
    enum PairedUpdateResult: Equatable {
        /// Both artifacts staged, verified, and promoted together.
        case promoted(AIModel)
        /// Staging is in progress; the installed pair remains usable.
        case staging(AIModel)
        /// The update was rejected without changing the installed model.
        case rejected(String)
    }

    private let inspector: HFRepositoryInspector
    private let store: ImportedModelStore
    private let downloadManager: DownloadManager
    private let updateStore: ImportedModelUpdateStore
    private let lifecycleManager: ModelLifecycleManager?
    private let physicalRAM: @Sendable () -> UInt64
    private let pairResolver = VisionPairResolver()
    private var stagedRecords: [String: ImportedModelRecord]

    init(
        inspector: HFRepositoryInspector = HFRepositoryInspector(),
        store: ImportedModelStore = .shared,
        downloadManager: DownloadManager,
        updateStore: ImportedModelUpdateStore? = nil,
        lifecycleManager: ModelLifecycleManager? = nil,
        physicalRAM: @escaping @Sendable () -> UInt64 = { ProcessInfo.processInfo.physicalMemory }
    ) {
        self.inspector = inspector
        self.store = store
        self.downloadManager = downloadManager
        let resolvedUpdateStore = updateStore ?? (store === ImportedModelStore.shared
            ? .shared
            : ImportedModelUpdateStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZiroEdge-Updates-\(UUID().uuidString)")))
        self.updateStore = resolvedUpdateStore
        self.lifecycleManager = lifecycleManager
        self.physicalRAM = physicalRAM
        self.stagedRecords = Dictionary(
            resolvedUpdateStore.allRecords.map { ($0.updateTargetModelID ?? $0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func checkForUpdate(model: AIModel) async throws -> CheckResult {
        guard let source = model.huggingFaceProvenance else { return .upToDate }
        let review = try await inspector.inspect(source.repositoryID)
        return review.revision == source.revision ? .upToDate : .review(review)
    }

    func storagePreflight(base: HFArtifact, projector: HFArtifact?) -> ImportStoragePreflight {
        let reusableBase = ModelRegistry.libraryModels.contains {
            $0.baseSHA256 == base.sha256 && ModelManagerService.isBaseDownloaded($0)
        }
        let reusableProjector = projector.map { artifact in
            ModelRegistry.libraryModels.contains {
                $0.mmprojSHA256 == artifact.sha256 && ModelManagerService.isMMProjDownloaded($0)
            }
        } ?? false
        let required = (reusableBase ? 0 : base.size)
            + (reusableProjector ? 0 : (projector?.size ?? 0))
        return ImportStoragePreflight(
            requiredBytes: required,
            safetyMarginBytes: downloadManager.storageSafetyMargin(for: required),
            availableBytes: downloadManager.availableDiskSpace
        )
    }

    func ramAssessment(base: HFArtifact, projector: HFArtifact?) -> ImportRAMAssessment {
        let bytes = base.size + (projector?.size ?? 0)
        let estimated = ImportRAMAssessment.estimatedBytes(
            artifactBytes: bytes,
            contextLength: base.metadata.contextLength ?? 2048
        )
        let physical = physicalRAM()
        return ImportRAMAssessment(
            estimatedBytes: estimated,
            physicalBytes: physical,
            classification: estimated < physical ? .likelyFits : .risky
        )
    }

    /// Stage a replacement under digest-addressed artifact paths. The installed
    /// record is not mutated until every selected artifact is fully verified.
    /// Storage preflight runs before any download begins, so insufficient temp
    /// storage refuses the update without deleting the installed revision.
    func stageUpdate(existing: AIModel, review: HFRepositoryReview, base: HFArtifact, projector: HFArtifact?) throws -> AIModel {
        guard existing.isImported else { throw HFInspectionError.noCompatibleArtifact }
        if existing.modelType == .vision {
            guard let projector else { throw HFInspectionError.projectorMissing }
            // Validate this exact projector is the unique best-supported pair.
            guard pairResolver.bestPair(for: base, in: review)?.projector == projector,
                  review.artifacts.contains(projector) else {
                throw HFInspectionError.incompatibleVisionPair
            }
        }
        let record = ImportedModelFactory.makeRecord(
            review: review,
            base: base,
            projector: projector,
            updateTargetModelID: existing.id
        )
        // Reuse already-installed artifacts that match by SHA-256 so we never
        // download what is already verified.
        let reusableBase = ModelRegistry.libraryModels.contains {
            $0.baseSHA256 == base.sha256 && ModelManagerService.isBaseDownloaded($0)
        }
        let reusableProjector = projector.map { proj in
            ModelRegistry.libraryModels.contains {
                $0.mmprojSHA256 == proj.sha256 && ModelManagerService.isMMProjDownloaded($0)
            }
        } ?? false
        if !reusableBase || (projector != nil && !reusableProjector) {
            guard storagePreflight(base: base, projector: projector).canProceed else {
                throw DownloadError.diskSpaceInsufficient
            }
        }
        try updateStore.upsert(record)
        stagedRecords[existing.id] = record
        downloadManager.startDownload(for: record.model)
        return record.model
    }

    /// Attempt an atomic paired update for a vision model. Both the new base
    /// and new projector download into staging paths that do not collide with
    /// the installed pair. The installed pair remains usable until both staged
    /// artifacts pass all checks, at which point they are promoted together.
    func stagePairedUpdate(
        existing: AIModel,
        review: HFRepositoryReview,
        candidate: VisionPairCandidate
    ) throws -> PairedUpdateResult {
        guard existing.isImported, existing.modelType == .vision else {
            return .rejected("Only imported vision models can receive paired updates.")
        }
        guard existing.huggingFaceProvenance?.repositoryID == review.repositoryID else {
            return .rejected("The update must target the same repository.")
        }
        if existing.huggingFaceProvenance?.revision == review.revision {
            return .rejected("Already at the current revision.")
        }
        guard review.artifacts.contains(candidate.base),
              review.artifacts.contains(candidate.projector),
              pairResolver.bestPair(for: candidate.base, in: review) == candidate else {
            return .rejected("Selected artifacts are not a compatible pair in the repository review.")
        }

        let record = ImportedModelFactory.makeRecord(
            review: review,
            base: candidate.base,
            projector: candidate.projector,
            updateTargetModelID: existing.id
        )
        guard storagePreflight(base: candidate.base, projector: candidate.projector).canProceed else {
            return .rejected("Not enough storage to stage both updated artifacts. The installed model is unchanged.")
        }

        try updateStore.upsert(record)
        stagedRecords[existing.id] = record
        downloadManager.startDownload(for: record.model)
        return .staging(record.model)
    }

    /// Promote the staged update atomically only after every selected artifact
    /// is verified. Old unshared artifacts are cleaned up after the record swap.
    @discardableResult
    func promoteIfVerified(modelID: String) async throws -> AIModel? {
        guard let staged = stagedRecords[modelID] else { return nil }
        let baseReady = ModelManagerService.isBaseDownloaded(staged.model)
        let projectorReady = !staged.model.requiresMMProj || ModelManagerService.isMMProjDownloaded(staged.model)
        guard baseReady, projectorReady else { return nil }

        let oldModel = store.record(id: modelID)?.model
        if lifecycleManager?.activeModel?.id == modelID {
            // The engine may mmap the old digest-addressed artifacts. Complete
            // unload and clear active provenance before swapping the registry
            // and deleting the old files.
            _ = await lifecycleManager?.unloadCurrentModel()
        }

        var promoted = staged
        promoted.id = modelID
        promoted.updateTargetModelID = nil
        try updateStore.remove(targetModelID: modelID)
        do {
            try store.update(id: modelID) { $0 = promoted }
        } catch {
            try? updateStore.upsert(staged)
            throw error
        }
        stagedRecords.removeValue(forKey: modelID)

        if let oldModel {
            ModelManagerService.deleteModel(oldModel)
        }
        downloadManager.downloadStatuses.removeValue(forKey: staged.id)
        downloadManager.updateStatusesFromDisk()
        // Reset experimental consent after update — the new revision needs fresh consent.
        ExperimentalModelConsent.setGranted(false, for: promoted.model)
        return promoted.model
    }

    /// Discard a staged update, cancelling any in-flight downloads and removing
    /// partial artifacts. The installed revision is never touched.
    func discardStagedUpdate(modelID: String) {
        guard let staged = stagedRecords.removeValue(forKey: modelID) else { return }
        try? updateStore.remove(targetModelID: modelID)
        downloadManager.cancelDownload(for: staged.model)
        downloadManager.discardPartialDownload(for: staged.model)
        ModelManagerService.deleteModel(staged.model)
    }

    /// Whether a staged update exists for the given model ID.
    func hasStagedUpdate(modelID: String) -> Bool {
        stagedRecords[modelID] != nil
    }

    /// The staged model, if any. Nil when no update is in progress.
    func stagedModel(modelID: String) -> AIModel? {
        stagedRecords[modelID]?.model
    }
}

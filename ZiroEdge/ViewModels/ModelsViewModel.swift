// ModelsViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the Models page. Bridges DownloadManager + ModelLifecycleManager.

import Foundation
import SwiftUI
import Combine

@MainActor
final class ModelsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var showingDownloadWarning = false
    @Published var pendingDownloadModel: AIModel?
    @Published var pendingDownloadIncludesVision = true
    @Published var showingDeleteConfirmation = false
    @Published var pendingDeleteModel: AIModel?
    @Published var showingCancelConfirmation = false
    @Published var pendingCancelModel: AIModel?
    @Published var showingExperimentalConsent = false
    @Published var pendingExperimentalModel: AIModel?
    @Published var showingSafetyResetResult = false
    @Published var safetyResetMessage = ""
    @Published var showingImporter = false
    @Published var updateMessage: String?

    // MARK: - Dependencies

    let downloadManager: DownloadManager
    let lifecycleManager: ModelLifecycleManager
    private let launchOfflineAvailabilityReport: OfflineAvailabilityReport

    // MARK: - Computed

    /// The catalog is never filtered by runtime validation. Eligibility gates loading.
    var allModels: [AIModel] { ModelRegistry.libraryModels }
    var curatedModels: [AIModel] { ModelRegistry.allModels }
    var importedModels: [AIModel] { ModelRegistry.importedModels }

    /// Whether any model is downloaded.
    var hasInstalledModels: Bool {
        allModels.contains { downloadManager.status(for: $0).isReady }
    }

    /// Installed models for the empty state check.
    var installedModels: [AIModel] {
        allModels.filter { downloadManager.status(for: $0).isReady }
    }

    // MARK: - Init

    private var cancellables: Set<AnyCancellable> = []

    init(
        downloadManager: DownloadManager,
        lifecycleManager: ModelLifecycleManager,
        offlineAvailabilityReport: OfflineAvailabilityReport = OfflineAvailabilityGuard.sweep()
    ) {
        self.downloadManager = downloadManager
        self.lifecycleManager = lifecycleManager
        self.launchOfflineAvailabilityReport = offlineAvailabilityReport

        // Forward download manager changes to trigger UI updates
        downloadManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .importedModelsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.downloadManager.updateStatusesFromDisk()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Get download status for a model.
    func status(for model: AIModel) -> ModelDownloadStatus {
        downloadManager.status(for: model)
    }

    /// Check if model is downloaded.
    func isDownloaded(_ model: AIModel) -> Bool {
        downloadManager.status(for: model).isReady
    }

    /// Whether the launch-time offline sweep verified this model and the
    /// download coordinator still considers its local artifacts ready.
    func isVerifiedForOfflineUse(_ model: AIModel) -> Bool {
        guard case .ready = launchOfflineAvailabilityReport.models[model.id] else {
            return false
        }
        return downloadManager.status(for: model).isReady
    }

    /// Total bytes owned by managed model storage, including partial and
    /// quarantined artifacts rather than installed models alone.
    var managedStorageUsage: String {
        downloadManager.managedStorageBreakdown().formattedTotal
    }

    /// Disk usage for a specific model.
    func diskUsage(for model: AIModel) -> String {
        guard isDownloaded(model) else { return "" }
        var total: Int64 = 0
        let basePath = ModelManagerService.baseModelPath(for: model)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: basePath.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }
        if model.requiresMMProj {
            let mmprojPath = ModelManagerService.mmprojModelPath(for: model)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: mmprojPath.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Initiate a capability-specific download with one consolidated risk review.
    func initiateDownload(for model: AIModel, includeOptionalProjector: Bool = true) {
        if downloadManager.networkMonitor.isOnCellular
            || !downloadManager.hasSufficientStorage(
                for: model,
                includeOptionalProjector: includeOptionalProjector
            ) {
            pendingDownloadModel = model
            pendingDownloadIncludesVision = includeOptionalProjector
            showingDownloadWarning = true
            return
        }
        downloadManager.startDownload(
            for: model,
            includeOptionalProjector: includeOptionalProjector
        )
    }

    var pendingDownloadWarningMessage: String {
        guard let model = pendingDownloadModel else { return "Review the download details before continuing." }
        var concerns: [String] = []
        if downloadManager.networkMonitor.isOnCellular {
            let bytes = downloadManager.requiredDownloadBytes(
                for: model,
                includeOptionalProjector: pendingDownloadIncludesVision
            )
            concerns.append("You are using cellular data for a \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) download.")
        }
        if !downloadManager.hasSufficientStorage(
            for: model,
            includeOptionalProjector: pendingDownloadIncludesVision
        ) {
            concerns.append(downloadManager.insufficientStorageMessage(
                for: model,
                includeOptionalProjector: pendingDownloadIncludesVision
            ))
        }
        return concerns.joined(separator: "\n\n")
    }

    var canConfirmPendingDownload: Bool {
        guard let model = pendingDownloadModel else { return false }
        return downloadManager.hasSufficientStorage(
            for: model,
            includeOptionalProjector: pendingDownloadIncludesVision
        )
    }

    func confirmPendingDownload() {
        guard let model = pendingDownloadModel,
              downloadManager.hasSufficientStorage(
                for: model,
                includeOptionalProjector: pendingDownloadIncludesVision
              ) else { return }
        showingDownloadWarning = false
        downloadManager.startDownload(
            for: model,
            includeOptionalProjector: pendingDownloadIncludesVision
        )
        pendingDownloadModel = nil
    }

    func cancelPendingDownload() {
        pendingDownloadModel = nil
        pendingDownloadIncludesVision = true
        showingDownloadWarning = false
    }

    func requestExperimentalConsent(for model: AIModel) {
        guard model.runtimeEligibility == .experimental else { return }
        pendingExperimentalModel = model
        showingExperimentalConsent = true
    }

    func confirmExperimentalConsent() {
        guard let model = pendingExperimentalModel else { return }
        ExperimentalModelConsent.setGranted(true, for: model)
        pendingExperimentalModel = nil
        showingExperimentalConsent = false
        objectWillChange.send()
    }

    func revokeExperimentalConsent(for model: AIModel) {
        ExperimentalModelConsent.setGranted(false, for: model)
        objectWillChange.send()
    }

    func hasExperimentalConsent(for model: AIModel) -> Bool {
        ExperimentalModelConsent.isGranted(for: model)
    }

    func isLoadSafetyDisabled(for model: AIModel) -> Bool {
        lifecycleManager.isLoadSafetyDisabled(for: model)
    }

    func resetLoadSafety(for model: AIModel) {
        switch lifecycleManager.resetLoadSafety(for: model) {
        case .reset:
            safetyResetMessage = "Load-safety history was reset for \(model.displayName). You can try loading it again."
        case .notDisabled:
            safetyResetMessage = "\(model.displayName) is not currently disabled by load safety."
        case .failed(let message):
            safetyResetMessage = message
        }
        showingSafetyResetResult = true
        objectWillChange.send()
    }

    /// Pause a download.
    func pauseDownload(for model: AIModel) {
        downloadManager.pauseDownload(for: model)
    }

    /// Resume a download.
    func resumeDownload(for model: AIModel) {
        downloadManager.resumeDownload(for: model)
    }

    /// Request download cancellation with confirmation.
    func requestCancelDownload(for model: AIModel) {
        pendingCancelModel = model
        showingCancelConfirmation = true
    }

    /// Pause every active artifact and retry only missing or invalid ones.
    /// Verified artifacts on disk are never replaced.
    func retryInvalidArtifacts(for model: AIModel) {
        downloadManager.retryInvalidArtifacts(for: model)
    }

    /// Cancel a download while preserving resumable state.
    func cancelDownload(for model: AIModel) {
        downloadManager.cancelDownload(for: model)
    }

    /// Confirm the pending cancellation.
    func confirmCancelDownload() {
        guard let model = pendingCancelModel else { return }
        showingCancelConfirmation = false
        downloadManager.cancelDownload(for: model)
        pendingCancelModel = nil
    }

    /// Discard partial download state and staging files.
    func discardPartialDownload(for model: AIModel) {
        downloadManager.discardPartialDownload(for: model)
    }

    /// Request model deletion.
    func requestDelete(_ model: AIModel) {
        pendingDeleteModel = model
        showingDeleteConfirmation = true
    }

    /// Confirm deletion. Unloads the model first if it shares the currently loaded base artifact.
    func confirmDelete() async {
        guard let model = pendingDeleteModel else { return }
        // The engine may mmap the artifact. Finish unloading before deleting it.
        if let active = lifecycleManager.activeModel,
           !downloadManager.isSafeToDelete(model, activeModel: active) {
            await lifecycleManager.unloadCurrentModel()
        }
        downloadManager.deleteModel(model)
        if model.isImported {
            _ = try? ImportedModelStore.shared.remove(id: model.id)
            ExperimentalModelConsent.setGranted(false, for: model)
        }
        showingDeleteConfirmation = false
        pendingDeleteModel = nil
    }

    func unavailableModelReason(for modelID: String) -> UnavailableModelReason? {
        ModelRegistry.unavailableModelReason(for: modelID)
    }

    func resolveConversationModel(_ modelID: String) -> AIModel? {
        guard ModelRegistry.selectableModels.contains(where: { $0.id == modelID }) else { return nil }
        return ModelRegistry.model(for: modelID)
    }

    func updateImportedConfiguration(
        for model: AIModel,
        contextLength: Int,
        sampling: SamplingConfig
    ) {
        guard model.isImported else { return }
        try? ImportedModelStore.shared.update(id: model.id) { record in
            record.config = .imported(
                promptPath: record.config.promptPath,
                contextLength: contextLength,
                sampling: sampling,
                addBos: record.config.addBos,
                stopStrings: record.config.stopStrings
            )
            if case .loadFailed = record.loadStatus { record.loadStatus = .configurationChanged }
        }
    }

    func retryImportedModel(_ model: AIModel) async {
        guard model.isImported else { return }
        _ = await lifecycleManager.loadModel(model)
    }
}

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
    @Published var showingDeleteConfirmation = false
    @Published var pendingDeleteModel: AIModel?
    @Published var showingExperimentalConsent = false
    @Published var pendingExperimentalModel: AIModel?
    @Published var showingSafetyResetResult = false
    @Published var safetyResetMessage = ""
    @Published var showingImporter = false
    @Published var updateMessage: String?

    // MARK: - Dependencies

    let downloadManager: DownloadManager
    let lifecycleManager: ModelLifecycleManager

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

    init(downloadManager: DownloadManager, lifecycleManager: ModelLifecycleManager) {
        self.downloadManager = downloadManager
        self.lifecycleManager = lifecycleManager

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

    /// Initiate a download, presenting one consolidated confirmation for all risks.
    func initiateDownload(for model: AIModel) {
        if downloadManager.networkMonitor.isOnCellular || !downloadManager.hasSufficientStorage(for: model) {
            pendingDownloadModel = model
            showingDownloadWarning = true
            return
        }
        downloadManager.startDownload(for: model)
    }

    var pendingDownloadWarningMessage: String {
        guard let model = pendingDownloadModel else { return "Review the download details before continuing." }
        var concerns: [String] = []
        if downloadManager.networkMonitor.isOnCellular {
            concerns.append("You are using cellular data for a \(model.formattedSize) download.")
        }
        if !downloadManager.hasSufficientStorage(for: model) {
            concerns.append("Only \(downloadManager.formattedAvailableSpace()) is available, less than the recommended \(model.formattedSize).")
        }
        return concerns.joined(separator: "\n\n")
    }

    var canConfirmPendingDownload: Bool {
        guard let model = pendingDownloadModel else { return false }
        return downloadManager.hasSufficientStorage(for: model)
    }

    func confirmPendingDownload() {
        guard let model = pendingDownloadModel,
              downloadManager.hasSufficientStorage(for: model) else { return }
        showingDownloadWarning = false
        downloadManager.startDownload(for: model)
        pendingDownloadModel = nil
    }

    func cancelPendingDownload() {
        pendingDownloadModel = nil
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

    /// Cancel a download.
    func cancelDownload(for model: AIModel) {
        downloadManager.cancelDownload(for: model)
    }

    /// Request model deletion.
    func requestDelete(_ model: AIModel) {
        pendingDeleteModel = model
        showingDeleteConfirmation = true
    }

    /// Confirm deletion.
    func confirmDelete() async {
        guard let model = pendingDeleteModel else { return }
        // The engine may mmap the artifact. Finish unloading before deleting it.
        if lifecycleManager.activeModel?.id == model.id {
            await lifecycleManager.unloadCurrentModel()
        }
        downloadManager.deleteModel(model)
        if model.isImported {
            try? ImportedModelStore.shared.remove(id: model.id)
            ExperimentalModelConsent.setGranted(false, for: model)
        }
        showingDeleteConfirmation = false
        pendingDeleteModel = nil
    }

    /// Returns an unavailable-model reason for a model ID that a conversation
    /// references but is no longer in the library. Conversations referencing a
    /// removed model must show an explicit unavailable-model state with a
    /// manual reselection path.
    func unavailableModelReason(for modelID: String) -> UnavailableModelReason? {
        ModelRegistry.unavailableModelReason(for: modelID)
    }

    /// Resolve what to show when a conversation references a model that is not
    /// currently selectable. Returns the model if found, or an unavailable reason.
    func resolveConversationModel(_ modelID: String) -> AIModel? {
        if let model = ModelRegistry.model(for: modelID),
           ModelRegistry.selectableModels.contains(where: { $0.id == modelID }) {
            return model
        }
        return nil
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
        _ = await lifecycleManager.loadModel(ModelRegistry.model(for: model.id) ?? model)
    }
}

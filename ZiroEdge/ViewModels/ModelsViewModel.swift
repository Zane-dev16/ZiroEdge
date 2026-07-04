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

    @Published var showingCellularWarning = false
    @Published var showingStorageWarning = false
    @Published var pendingDownloadModel: AIModel?
    @Published var showingDeleteConfirmation = false
    @Published var pendingDeleteModel: AIModel?

    // MARK: - Dependencies

    let downloadManager: DownloadManager
    let lifecycleManager: ModelLifecycleManager

    // MARK: - Computed

    /// All models in the registry.
    var allModels: [AIModel] {
        ModelRegistry.allModels
    }

    /// Whether any model is downloaded.
    var hasInstalledModels: Bool {
        allModels.contains { downloadManager.status(for: $0).isReady }
    }

    /// Installed models for the empty state check.
    var installedModels: [AIModel] {
        allModels.filter { downloadManager.status(for: $0).isReady }
    }

    // MARK: - Init

    private var cancellable: Any?

    init(downloadManager: DownloadManager, lifecycleManager: ModelLifecycleManager) {
        self.downloadManager = downloadManager
        self.lifecycleManager = lifecycleManager

        // Forward download manager changes to trigger UI updates
        cancellable = downloadManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
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

    /// Initiate download with appropriate warnings.
    func initiateDownload(for model: AIModel) {
        // Check cellular
        if downloadManager.networkMonitor.isOnCellular {
            pendingDownloadModel = model
            showingCellularWarning = true
            return
        }

        // Check storage
        if !downloadManager.hasSufficientStorage(for: model) {
            pendingDownloadModel = model
            showingStorageWarning = true
            return
        }

        downloadManager.startDownload(for: model)
    }

    /// Proceed with download after cellular warning.
    func confirmCellularDownload() {
        guard let model = pendingDownloadModel else { return }
        showingCellularWarning = false

        // Also check storage
        if !downloadManager.hasSufficientStorage(for: model) {
            showingStorageWarning = true
            return
        }

        downloadManager.startDownload(for: model)
        pendingDownloadModel = nil
    }

    /// Proceed with download after storage warning.
    func confirmStorageDownload() {
        guard let model = pendingDownloadModel else { return }
        showingStorageWarning = false
        downloadManager.startDownload(for: model)
        pendingDownloadModel = nil
    }

    /// Cancel pending download warnings.
    func cancelPendingDownload() {
        pendingDownloadModel = nil
        showingCellularWarning = false
        showingStorageWarning = false
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
    func confirmDelete() {
        guard let model = pendingDeleteModel else { return }
        downloadManager.deleteModel(model)
        showingDeleteConfirmation = false
        pendingDeleteModel = nil
        // Unload if this was the active model
        if lifecycleManager.activeModel?.id == model.id {
            lifecycleManager.unloadCurrentModel()
        }
    }
}

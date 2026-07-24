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

    func confirmPendingDownload() {
        guard let model = pendingDownloadModel else { return }
        showingDownloadWarning = false
        downloadManager.startDownload(for: model)
        pendingDownloadModel = nil
    }

    func cancelPendingDownload() {
        pendingDownloadModel = nil
        showingDownloadWarning = false
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
        showingDeleteConfirmation = false
        pendingDeleteModel = nil
    }
}

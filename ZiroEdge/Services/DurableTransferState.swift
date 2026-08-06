// DurableTransferState.swift
// Restores user-controlled model transfers without starting network work.

import Foundation

struct DurableTransferSnapshot: Codable {
    let version: Int
    let modelID: String
    let artifact: String
    let expectedBytes: Int64
    let progress: Double
    let resumeAvailable: Bool
    let failed: Bool

    static let currentVersion = 1
}

@MainActor
extension DownloadManager {
    /// Persist durable state for every actively tracked transfer so a relaunch
    /// can restore it even when no explicit pause was recorded.
    func persistAllActiveTransferState() {
        for (_, task) in activeTasks {
            guard !task.isCancelled else { continue }
            persistDurableState(for: task)
        }
    }

    /// Invoked when the app enters the background. Persists all active task
    /// state and then allows the URLSession to continue in the background.
    func handleBackgroundTransition() {
        persistAllActiveTransferState()
        // URLSession background tasks continue autonomously; we do not cancel
        // or suspend them here so that the system can finish transfers while
        // the app is backgrounded or suspended.
    }

    func persistDurableState(for task: DownloadTask, failed: Bool = false) {
        let hasResumeData = fileManager.fileExists(atPath: task.resumeDataURL.path)
        let hasStaging = fileManager.fileExists(atPath: task.stagingURL.path)
        let snapshot = DurableTransferSnapshot(
            version: DurableTransferSnapshot.currentVersion,
            modelID: task.model.id,
            artifact: task.artifact == .base ? "base" : "mmproj",
            expectedBytes: task.expectedBytes,
            progress: min(max(task.progress, 0), 1),
            resumeAvailable: hasResumeData || hasStaging,
            failed: failed
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: task.metadataURL, options: .atomic)
        DownloadDiagnosticRecorder.shared.record(
            event: .durableStateWritten,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                modelID: task.model.id,
                artifact: task.artifact == .base ? "base" : "mmproj"
            ),
            modelID: task.model.id,
            artifact: task.artifact == .base ? "base" : "mmproj",
            state: failed ? "failed" : "in_progress",
            progress: task.progress
        )
    }

    func removeDurableState(for task: DownloadTask, discardStaging: Bool) {
        try? fileManager.removeItem(at: task.metadataURL)
        try? fileManager.removeItem(at: task.resumeDataURL)
        if discardStaging { try? fileManager.removeItem(at: task.stagingURL) }
        DownloadDiagnosticRecorder.shared.record(
            event: .durableStateCleared,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                modelID: task.model.id,
                artifact: task.artifact == .base ? "base" : "mmproj"
            ),
            modelID: task.model.id,
            artifact: task.artifact == .base ? "base" : "mmproj"
        )
    }

    /// Reconcile durable metadata with disk. Valid resumable state becomes
    /// Paused and never starts a transfer until the user explicitly resumes.
    func restoreDurableTransfers(models: [AIModel] = ModelRegistry.libraryModels) {
        DownloadDiagnosticRecorder.shared.record(
            event: .reconciliationStart,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: "all",
            artifact: "all"
        )
        var restoredStorageIDs = Set<String>()
        for model in models {
            let artifacts: [ArtifactType] = model.requiresMMProj ? [.base, .mmproj] : [.base]
            for artifact in artifacts {
                let task = DownloadTask(model: model, artifact: artifact)
                guard restoredStorageIDs.insert(task.storageID).inserted,
                      activeTasks[task.storageID] == nil,
                      fileManager.fileExists(atPath: task.metadataURL.path) else { continue }
                restoreSingleDurableTransfer(task)
            }
        }
        DownloadDiagnosticRecorder.shared.record(
            event: .reconciliationDone,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: "all",
            artifact: "all"
        )
    }

    func promoteAtomically(_ task: DownloadTask) throws {
        if injectPromotionFailureForTesting {
            throw CocoaError(.fileWriteUnknown)
        }
        guard fileManager.fileExists(atPath: task.destinationURL.path) else {
            try fileManager.moveItem(at: task.stagingURL, to: task.destinationURL)
            return
        }

        let backupName = task.destinationURL.lastPathComponent + ".promotion-backup"
        let backupURL = task.destinationURL.deletingLastPathComponent().appendingPathComponent(backupName)
        try? fileManager.removeItem(at: backupURL)
        do {
            _ = try fileManager.replaceItemAt(
                task.destinationURL,
                withItemAt: task.stagingURL,
                backupItemName: backupName,
                options: [.usingNewMetadataOnly]
            )
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if !fileManager.fileExists(atPath: task.destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: task.destinationURL)
            }
            throw error
        }
    }

    /// A crash during replacement may leave a backup. Keep the verified new
    /// destination when present; otherwise restore a verified old artifact.
    /// Map a storage ID (e.g. "base-abc123" or "mmproj-model-id") back to a
    /// DownloadTask. Returns nil when no matching catalog row exists.
    static func resolveStorageID(_ storageID: String) -> DownloadTask? {
        let candidates = ModelRegistry.libraryModels + ModelRegistry.calibrationModels
        for model in candidates {
            let base = DownloadTask(model: model, artifact: .base)
            if base.storageID == storageID { return base }
            if model.requiresMMProj {
                let projector = DownloadTask(model: model, artifact: .mmproj)
                if projector.storageID == storageID { return projector }
            }
        }
        return nil
    }

    func reconcileInterruptedPromotions() {
        DownloadDiagnosticRecorder.shared.record(
            event: .reconciliationStart,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: "all",
            artifact: "all"
        )
        var seen = Set<String>()
        for model in ModelRegistry.libraryModels {
            let artifacts: [ArtifactType] = model.requiresMMProj ? [.base, .mmproj] : [.base]
            for artifact in artifacts {
                let task = DownloadTask(model: model, artifact: artifact)
                guard seen.insert(task.storageID).inserted else { continue }
                let backup = task.destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(task.destinationURL.lastPathComponent + ".promotion-backup")
                guard fileManager.fileExists(atPath: backup.path) else { continue }
                let destinationIssues = ModelManagerService.artifactValidationIssues(
                    at: task.destinationURL, model: model, artifact: artifact
                )
                if destinationIssues.isEmpty {
                    try? fileManager.removeItem(at: backup)
                    continue
                }
                let backupIssues = ModelManagerService.artifactValidationIssues(
                    at: backup, model: model, artifact: artifact
                )
                guard backupIssues.isEmpty else {
                    try? fileManager.removeItem(at: backup)
                    continue
                }
                try? fileManager.removeItem(at: task.destinationURL)
                try? fileManager.moveItem(at: backup, to: task.destinationURL)
            }
        }
        DownloadDiagnosticRecorder.shared.record(
            event: .reconciliationDone,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: "all",
            artifact: "all"
        )
    }
}

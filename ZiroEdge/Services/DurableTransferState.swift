// DurableTransferState.swift
// Restores user-controlled model transfers without starting network work.

import Foundation

struct DurableTransferSnapshot: Codable {
    let version: Int
    /// Version 1/2 compatibility only. Ownership is artifact-scoped in v3.
    let modelID: String?
    let artifact: String
    let expectedSHA256: String?
    let expectedBytes: Int64
    let progress: Double
    let resumeAvailable: Bool
    /// A non-chunked background URLSession task was active when persisted.
    /// This keeps metadata alive through relaunch even though URLSession owns
    /// the temporary file and no staging/resume bytes exist yet.
    let activeBackgroundTask: Bool
    let failed: Bool

    static let currentVersion = 3

    init(
        version: Int,
        modelID: String? = nil,
        artifact: String,
        expectedSHA256: String? = nil,
        expectedBytes: Int64,
        progress: Double,
        resumeAvailable: Bool,
        activeBackgroundTask: Bool,
        failed: Bool
    ) {
        self.version = version
        self.modelID = modelID
        self.artifact = artifact
        self.expectedSHA256 = expectedSHA256
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.resumeAvailable = resumeAvailable
        self.activeBackgroundTask = activeBackgroundTask
        self.failed = failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        artifact = try container.decode(String.self, forKey: .artifact)
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        expectedBytes = try container.decode(Int64.self, forKey: .expectedBytes)
        progress = try container.decode(Double.self, forKey: .progress)
        resumeAvailable = try container.decode(Bool.self, forKey: .resumeAvailable)
        // Version 1 snapshots predate background-task reconciliation. Treat
        // the absent field as false so existing paused transfers survive an
        // app update instead of losing valid staging or resume data.
        activeBackgroundTask = try container.decodeIfPresent(
            Bool.self,
            forKey: .activeBackgroundTask
        ) ?? false
        failed = try container.decode(Bool.self, forKey: .failed)
    }
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
            artifact: task.artifact == .base ? "base" : "mmproj",
            expectedSHA256: task.expectedSHA256,
            expectedBytes: task.expectedBytes,
            progress: min(max(task.progress, 0), 1),
            resumeAvailable: hasResumeData || hasStaging,
            activeBackgroundTask: !task.isChunked && task.task != nil && !task.isCancelled,
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
        if discardStaging,
           (activeTasks[task.storageID].map({ $0.model.id != task.model.id }) == true
            || hasOtherTransferReference(for: task)) {
            return
        }
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
    func restoreDurableTransfers(models: [AIModel] = ModelRegistry.transferModels) {
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
                guard !restoredStorageIDs.contains(task.storageID),
                      activeTasks[task.storageID] == nil,
                      fileManager.fileExists(atPath: task.metadataURL.path) else { continue }
                if restoreSingleDurableTransfer(task) {
                    restoredStorageIDs.insert(task.storageID)
                }
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
        let candidates = ModelRegistry.transferModels + ModelRegistry.calibrationModels
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
        for model in ModelRegistry.transferModels {
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

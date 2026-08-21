import Foundation
import os

// Progress and status bookkeeping: the single writer for downloadStatuses
// and the last-progress timestamps consumed by the stuck-transfer watchdog.
// Every transfer state change funnels through updateStatus(model:) here;
// progress timestamps go through noteTransferProgress/clearTransferProgress.
extension DownloadManager {
    func updateStatus(model: AIModel) {
        var affectedModels = ModelRegistry.libraryModels.filter {
            $0.baseArtifactStorageID == model.baseArtifactStorageID
        }
        if !affectedModels.contains(where: { $0.id == model.id }) {
            affectedModels.append(model)
        }
        for affectedModel in affectedModels {
            let baseKey = artifactTaskKey(model: affectedModel, artifact: .base)
            let mmprojKey = artifactTaskKey(model: affectedModel, artifact: .mmproj)
            let diskStatus = authoritativeDiskStatus(for: affectedModel)
            let baseState = activeTasks[baseKey]?.state ?? diskStatus.baseState
            let mmprojState: DownloadState? = affectedModel.requiresMMProj
                ? (activeTasks[mmprojKey]?.state ?? diskStatus.mmprojState)
                : nil
            downloadStatuses[affectedModel.id] = ModelDownloadStatus(
                modelID: affectedModel.id,
                baseState: baseState,
                mmprojState: mmprojState,
                baseExpectedBytes: affectedModel.baseFileSizeBytes,
                mmprojExpectedBytes: affectedModel.mmprojFileSizeBytes,
                allowsTextOnly: affectedModel.allowsTextOnlyCapability
            )
        }
    }
    func cleanupPartialFiles(for model: AIModel) {
        let baseTask = DownloadTask(model: model, artifact: .base)
        removeDurableState(for: baseTask, discardStaging: true)
        logger.info("Cleaned transfer state: \(baseTask.storageID, privacy: .public)")
        if model.requiresMMProj {
            removeDurableState(
                for: DownloadTask(model: model, artifact: .mmproj),
                discardStaging: true
            )
        }
        scheduleStorageBreakdownRefresh()
    }

    // MARK: - Progress Timestamps

    /// Record a liveness heartbeat for a transfer (read by the stuck watchdog).
    func noteTransferProgress(_ key: String) {
        lastProgressTime[key] = Date()
    }

    /// Drop a transfer's liveness heartbeat (on removal, cancel, or restart).
    func clearTransferProgress(_ key: String) {
        lastProgressTime.removeValue(forKey: key)
    }
}

import Foundation
import os

// Artifact transfer lifecycle beyond the initial start: resuming paused
// or failed transfers, the one-shot fallback to the canonical catalog URL
// when a signed URL goes stale, and cancellation.
extension DownloadManager {
    func resumeArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let task = activeTasks[key] else {
            if (artifact == .base && !ModelManagerService.isBaseDownloaded(model))
                || (artifact == .mmproj && !ModelManagerService.isMMProjDownloaded(model)) {
                startArtifactDownload(model: model, artifact: artifact)
            }
            return
        }
        guard task.model.id == model.id else { return }
        guard task.isPaused || task.state == .failed(error: .networkError) else { return }

        // Recheck storage before resuming — space may have changed since the pause.
        let stagedBytes = ((try? fileManager.attributesOfItem(atPath: task.stagingURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let remaining = max(0, task.expectedBytes - stagedBytes)
        let required = SaturatedArithmetic.add(
            remaining,
            remaining > 0 ? Self.storageSafetyMarginBytes : 0
        )
        if required > 0 && availableDiskSpace < required {
            task.state = .failed(error: .diskSpaceInsufficient)
            updateStatus(model: model)
            logger.error("Refusing resume without sufficient free storage: \(key, privacy: .public)")
            return
        }

        task.isPaused = false
        task.isCancelled = false
        task.state = .resuming(progress: task.progress)
        DownloadDiagnosticRecorder.shared.record(
            event: .downloadResume,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                modelID: model.id,
                artifact: artifact.label
            ),
            modelID: model.id,
            artifact: artifact.label,
            state: "resuming",
            progress: task.progress
        )
        updateStatus(model: model)
        if task.isChunked {
            task.state = .downloading(progress: task.progress)
            updateStatus(model: model)
            chunkedDownload(task: task, key: key)
            return
        }
        if let resumeData = task.resumeData ?? (try? Data(contentsOf: task.resumeDataURL)) {
            task.task = getSession().downloadTask(withResumeData: resumeData)
        } else {
            task.task = getSession().downloadTask(with: task.downloadURL ?? task.sourceURL)
        }
        task.state = .downloading(progress: task.progress)
        updateStatus(model: model)
        task.task?.taskDescription = key
        task.task?.resume()
        logger.info("Resumed download: \(key, privacy: .public)")
    }
    func retryOnceFromCanonicalURL(_ task: DownloadTask, key: String) -> Bool {
        guard !task.canonicalRetryAttempted else { return false }
        task.canonicalRetryAttempted = true

        // Remove every trace of the stale signed URL: resume data, staging, chunk handle.
        closeChunkFile(for: task)
        task.resumeData = nil
        try? fileManager.removeItem(at: task.resumeDataURL)
        try? fileManager.removeItem(at: task.stagingURL)

        task.isChunked = false
        task.currentChunkOffset = 0
        task.currentChunkIndex = 0
        task.chunkRetryCount = 0
        task.progress = 0
        task.isPaused = false
        task.downloadURL = task.sourceURL

        task.state = .resuming(progress: 0)
        updateStatus(model: task.model)

        // De-register so the fresh path below can re-register, then start from
        // the canonical catalog URL with full chunking support.
        activeTasks.removeValue(forKey: key)
        clearTransferProgress(key)

        startArtifactDownload(model: task.model, artifact: task.artifact, skipCDNResolution: true)
        return true
    }
    func cancelArtifactDownload(model: AIModel, artifact: ArtifactType, discardStaging: Bool) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let task = activeTasks[key], task.model.id == model.id else { return }
        guard !hasOtherTransferReference(for: task) else {
            logger.info("Preserving shared active transfer: \(key, privacy: .public)")
            return
        }
        task.isCancelled = true
        task.resolutionTask?.cancel()
        task.task?.cancel()
        task.chunkTask?.cancel()
        task.verificationTask?.cancel()
        closeChunkFile(for: task)
        task.state = .cancelled
        DownloadDiagnosticRecorder.shared.record(
            event: .downloadCancel,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
            modelID: task.model.id,
            artifact: task.artifact.label,
            state: "cancelled"
        )
        if discardStaging {
            removeDurableState(for: task, discardStaging: true)
        }
        activeTasks.removeValue(forKey: key)
        clearTransferProgress(key)
        stopStuckWatchdogIfIdle()
        logger.info("Cancelled download: \(key, privacy: .public) discardStaging=\(discardStaging)")
    }
}

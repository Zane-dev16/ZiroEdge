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
        // P3: never hash multi-GB artifacts on MainActor. Tests stay
        // synchronous authoritative (byte-scale fixtures, deterministic);
        // production seeds hash-free quick status and verifies off-main.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            for affectedModel in affectedModels {
                publishAuthoritativeStatus(for: affectedModel)
            }
            return
        }
        for affectedModel in affectedModels {
            downloadStatuses[affectedModel.id] = quickStatusMergingActiveTasks(
                for: affectedModel,
                quick: Self.quickDiskStatus(for: affectedModel)
            )
        }
        logger.info("Status update seeded quick for \(model.id, privacy: .public)")
        Task { [weak self] in
            let verified = await Task.detached(priority: .utility) { () -> [(AIModel, ModelDownloadStatus)] in
                affectedModels.map { ($0, DownloadManager.diskStatus(for: $0)) }
            }.value
            guard let self else { return }
            for (affectedModel, diskStatus) in verified {
                let baseKey = self.artifactTaskKey(model: affectedModel, artifact: .base)
                let mmprojKey = self.artifactTaskKey(model: affectedModel, artifact: .mmproj)
                let baseState = self.activeTasks[baseKey]?.state ?? diskStatus.baseState
                let mmprojState: DownloadState? = affectedModel.requiresMMProj
                    ? (self.activeTasks[mmprojKey]?.state ?? diskStatus.mmprojState)
                    : nil
                self.downloadStatuses[affectedModel.id] = ModelDownloadStatus(
                    modelID: affectedModel.id,
                    baseState: baseState,
                    mmprojState: mmprojState,
                    baseExpectedBytes: affectedModel.baseFileSizeBytes,
                    mmprojExpectedBytes: affectedModel.mmprojFileSizeBytes,
                    allowsTextOnly: affectedModel.allowsTextOnlyCapability
                )
            }
            self.lastStatusRefreshWasOffMain = true
            self.logger.info("Status async verify landed for \(model.id, privacy: .public)")
        }
    }

    /// Synchronous authoritative publish (XCTest path + shared helper).
    private func publishAuthoritativeStatus(for affectedModel: AIModel) {
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
    // MARK: - P0-1 Status (moved from DownloadManager.swift for file-length)
    /// P0-1 cached-status + async refresh: never hash multi-GB on MainActor on memo miss.
    /// Tests keep synchronous authoritative truth (fixtures byte-scale, deterministic).
    /// Production seeds hash-free quick status and refreshes authoritative off-main.
    func status(for model: AIModel) -> ModelDownloadStatus {
        if let cached = downloadStatuses[model.id] { return cached }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return authoritativeDiskStatus(for: model)
        }
        let quick = Self.quickDiskStatus(for: model)
        let merged = quickStatusMergingActiveTasks(for: model, quick: quick)
        downloadStatuses[model.id] = merged
        logger.info("Status cache miss seeded quick for \(model.id, privacy: .public)")
        Task { [weak self, model] in
            let verified = await Task.detached(priority: .utility) {
                DownloadManager.diskStatus(for: model)
            }.value
            guard let self else { return }
            let baseKey = self.artifactTaskKey(model: model, artifact: .base)
            let mmprojKey = self.artifactTaskKey(model: model, artifact: .mmproj)
            let baseState = self.activeTasks[baseKey]?.state ?? verified.baseState
            let mmprojState: DownloadState? = model.requiresMMProj
                ? (self.activeTasks[mmprojKey]?.state ?? verified.mmprojState)
                : nil
            let refreshed = ModelDownloadStatus(
                modelID: model.id,
                baseState: baseState,
                mmprojState: mmprojState,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
            self.downloadStatuses[model.id] = refreshed
            self.logger.info("Status async refresh landed for \(model.id, privacy: .public)")
        }
        return merged
    }
    func updateStatusesFromDisk() {
        for model in ModelRegistry.libraryModels {
            downloadStatuses[model.id] = authoritativeDiskStatus(for: model)
        }
    }

    /// Launch seed: hash-free statuses so init never hashes multi-GB
    /// artifacts on the critical path. Replaced with verified values by
    /// `refreshStatusesFromDisk` after first frame.
    func seedStatusesFromDiskQuick() {
        for model in ModelRegistry.libraryModels {
            downloadStatuses[model.id] = Self.quickDiskStatus(for: model)
        }
    }

    /// Post-first-frame refresh: full digest verification computed off-main,
    /// then orphan reclamation, storage accounting, and background-task
    /// reconciliation. Driven by AppRuntime after `.ready`; idempotent.
    func refreshStatusesFromDisk() async {
        let verified = await Task.detached(priority: .utility) {
            var fresh: [String: ModelDownloadStatus] = [:]
            for model in ModelRegistry.libraryModels {
                fresh[model.id] = DownloadManager.diskStatus(for: model)
            }
            return fresh
        }.value
        for (id, status) in verified {
            downloadStatuses[id] = status
        }
        reclaimOrphanedStorage()
        scheduleStorageBreakdownRefresh()
        reconcileBackgroundTasks()
    }

    func recoverProtectedImportedState() {
        guard ModelRegistry.importedRegistriesAvailable else { return }
        updateStatusesFromDisk()
        restoreDurableTransfers()
        reconcileBackgroundTasks()
        _ = reclaimOrphanedStorage()
    }
    // MARK: - Pause/Resume/Retry (moved from DownloadManager.swift for file-length)
    func pauseDownload(for model: AIModel) {
        pauseArtifactDownload(model: model, artifact: .base)
        if model.requiresMMProj {
            pauseArtifactDownload(model: model, artifact: .mmproj)
        }
        updateStatus(model: model)
    }
    func pauseArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let downloadTask = activeTasks[key], downloadTask.model.id == model.id else {
            // R6: pause-before-start — no transfer exists yet (CDN resolution
            // queued or tap-verify in flight). Remember the intent so the
            // transfer parks instead of starting bytes when it arrives.
            notePendingPause(key: key)
            return
        }
        guard !downloadTask.isPaused else { return }
        downloadTask.isPaused = true
        downloadTask.state = .pausing(progress: downloadTask.progress)
        DownloadDiagnosticRecorder.shared.record(
            event: .downloadPause,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                modelID: model.id,
                artifact: artifact.label
            ),
            modelID: model.id,
            artifact: artifact.label,
            state: "pausing",
            progress: downloadTask.progress
        )
        updateStatus(model: model)
        if downloadTask.isChunked {
            downloadTask.chunkTask?.cancel()
            downloadTask.chunkTask = nil
            closeChunkFile(for: downloadTask, synchronize: true)
            persistDurableState(for: downloadTask)
            downloadTask.state = .paused(progress: downloadTask.progress)
            updateStatus(model: model)
            return
        }
        guard let urlTask = downloadTask.task else {
            if downloadTask.resolutionTask != nil {
                // Pause arrived while CDN resolution is still in flight: cancel
                // it and park as paused. The old path flipped isPaused back to
                // false and reported a network failure even though nothing had
                // failed — and the resolution completion then started the
                // transfer anyway, silently overriding the user's pause.
                downloadTask.resolutionTask?.cancel()
                downloadTask.resolutionTask = nil
                persistDurableState(for: downloadTask)
                downloadTask.state = .paused(progress: downloadTask.progress)
                updateStatus(model: model)
                return
            }
            let hasResumeData = fileManager.fileExists(atPath: downloadTask.resumeDataURL.path)
            let hasStaging = fileManager.fileExists(atPath: downloadTask.stagingURL.path)
            if hasResumeData || hasStaging {
                persistDurableState(for: downloadTask)
                downloadTask.state = .paused(progress: downloadTask.progress)
            } else {
                downloadTask.isPaused = false
                downloadTask.state = .failed(error: .networkError)
                persistDurableState(for: downloadTask, failed: true)
            }
            updateStatus(model: model)
            return
        }
        urlTask.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, let pausedTask = self.activeTasks[key], pausedTask.isPaused else { return }
                pausedTask.resumeData = data
                guard let data, !data.isEmpty else {
                    pausedTask.isPaused = false
                    pausedTask.state = .failed(error: .networkError)
                    self.persistDurableState(for: pausedTask, failed: true)
                    self.updateStatus(model: model)
                    return
                }
                try? data.write(to: pausedTask.resumeDataURL, options: .atomic)
                self.persistDurableState(for: pausedTask)
                pausedTask.state = .paused(progress: pausedTask.progress)
                self.updateStatus(model: model)
            }
        })
    }
    func resumeDownload(for model: AIModel) {
        let baseKey = artifactTaskKey(model: model, artifact: .base)
        let mmprojKey = artifactTaskKey(model: model, artifact: .mmproj)
        if activeTasks[baseKey] != nil {
            resumeArtifactDownload(model: model, artifact: .base)
        } else if !ModelManagerService.isBaseDownloaded(model) {
            startArtifactDownload(model: model, artifact: .base)
        }
        if model.requiresMMProj {
            if activeTasks[mmprojKey] != nil {
                resumeArtifactDownload(model: model, artifact: .mmproj)
            } else if !ModelManagerService.isMMProjDownloaded(model) {
                startArtifactDownload(model: model, artifact: .mmproj)
            }
        }
        updateStatus(model: model)
    }
    /// Pause every active artifact and retry only missing or
    /// invalid artifacts. Verified artifacts on disk are never replaced.
    /// Staged bytes left behind by an interrupted promotion are re-verified
    /// off-main and promoted when valid instead of being redownloaded.
    func retryInvalidArtifacts(for model: AIModel) {
        let baseKey = artifactTaskKey(model: model, artifact: .base)
        let mmprojKey = artifactTaskKey(model: model, artifact: .mmproj)
        logger.info("Healer retrying invalid artifacts: \(model.id, privacy: .public)")

        // Pause every active artifact first.
        if let baseTask = activeTasks[baseKey], !baseTask.isPaused {
            pauseArtifactDownload(model: model, artifact: .base)
        }
        if model.requiresMMProj, let mmprojTask = activeTasks[mmprojKey], !mmprojTask.isPaused {
            pauseArtifactDownload(model: model, artifact: .mmproj)
        }

        // Retry only artifacts that are missing or invalid (verifier truth:
        // full SHA-256 + GGUF structure via isBaseDownloaded/isMMProjDownloaded).
        let baseNeedsRetry = !ModelManagerService.isBaseDownloaded(model)
        let mmprojNeedsRetry = model.requiresMMProj && !ModelManagerService.isMMProjDownloaded(model)
        DownloadDiagnosticRecorder.shared.record(
            event: .healerAction,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: model.id,
            artifact: "pair",
            state: "retrying",
            failureSummary: "baseNeedsRetry=\(baseNeedsRetry) mmprojNeedsRetry=\(mmprojNeedsRetry)"
        )

        if baseNeedsRetry {
            if !repromoteStagingIfValid(model: model, artifact: .base) {
                if activeTasks[baseKey] != nil {
                    resumeArtifactDownload(model: model, artifact: .base)
                } else {
                    startArtifactDownload(model: model, artifact: .base)
                }
            }
        } else if activeTasks[baseKey] != nil {
            activeTasks.removeValue(forKey: baseKey)
            clearTransferProgress(baseKey)
            stopStuckWatchdogIfIdle()
        }

        if mmprojNeedsRetry {
            if !repromoteStagingIfValid(model: model, artifact: .mmproj) {
                if activeTasks[mmprojKey] != nil {
                    resumeArtifactDownload(model: model, artifact: .mmproj)
                } else {
                    startArtifactDownload(model: model, artifact: .mmproj)
                }
            }
        } else if activeTasks[mmprojKey] != nil {
            activeTasks.removeValue(forKey: mmprojKey)
            clearTransferProgress(mmprojKey)
            stopStuckWatchdogIfIdle()
        }

        updateStatus(model: model)
    }
    func cancelDownload(for model: AIModel) {
        discardPartialDownload(for: model)
    }

    /// Discard partial download state including staging and resume data.
    /// This is idempotent and is also the user-visible cancellation behavior.
    func discardPartialDownload(for model: AIModel) {
        for artifact: ArtifactType in [.base, .mmproj] {
            cancelArtifactDownload(model: model, artifact: artifact, discardStaging: true)
            let task = DownloadTask(model: model, artifact: artifact)
            removeDurableState(for: task, discardStaging: true)
        }
        updateStatus(model: model)
    }

    /// Whether a model can be safely deleted without affecting a loaded runtime.
    /// A model is unsafe to delete when its base artifact backs the currently loaded model.
    /// Supply the active model to check against shared base artifacts.
    func isSafeToDelete(_ model: AIModel, activeModel: AIModel? = nil) -> Bool {
        guard let active = activeModel else { return true }
        // The model's base artifact must not be the one backing the loaded runtime.
        return model.baseArtifactStorageID != active.baseArtifactStorageID
    }

    /// Reason why deletion is unsafe, or nil when safe.
    func unsafeDeletionReason(for model: AIModel, activeModel: AIModel? = nil) -> String? {
        guard !isSafeToDelete(model, activeModel: activeModel) else { return nil }
        return "\(model.displayName) shares its base model artifact with the currently loaded model. Unload the model first, then try again."
    }


}

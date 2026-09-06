import Foundation
import os

// Verification and promotion flow: staging bytes are hash-verified
// (ModelArtifactVerifier) and atomically promoted into the installed
// models directory, with durable-state and diagnostics bookkeeping.
extension DownloadManager {
    @discardableResult
    func verifyAndPromote(task: DownloadTask) -> Result<Void, DownloadError> {
        task.state = .verifying
        updateStatus(model: task.model)
        let artifactStr = task.artifact.label
        let verifyCID = DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: artifactStr)
        let stagingName = DownloadDiagnosticRedactor.sanitizedFilename(task.stagingURL)
        logger.info("Verifying \(task.storageID, privacy: .public) staging=\(stagingName, privacy: .public) expectedBytes=\(task.expectedBytes)")
        DownloadDiagnosticRecorder.shared.record(
            event: .validationStart,
            correlationID: verifyCID,
            modelID: task.model.id,
            artifact: artifactStr,
            expectedBytes: task.expectedBytes
        )
        let space = availableDiskSpace
        // A zero return means the value is unavailable (e.g. simulator); skip the check.
        guard space == 0 || space >= Self.storageSafetyMarginBytes else {
            DownloadDiagnosticRecorder.shared.record(
                event: .validationFailed,
                correlationID: verifyCID,
                modelID: task.model.id,
                artifact: artifactStr,
                failureCategory: .storage,
                failureSummary: "disk space insufficient"
            )
            return failVerification(task, error: .diskSpaceInsufficient, discardStaging: false)
        }
        let failure = ModelArtifactVerifier.failure(
            fileURL: task.stagingURL,
            expectedBytes: task.expectedBytes,
            expectedSHA256: task.expectedSHA256
        )
        return finishVerifiedPromotion(task, validationFailure: failure, correlationID: verifyCID, durationMs: 0)
    }

    func hasOtherTransferReference(for task: DownloadTask) -> Bool {
        (ModelRegistry.transferModels + additionalTransferModelsProvider()).contains { candidate in
            candidate.id != task.model.id
                && DownloadTask(model: candidate, artifact: task.artifact).storageID == task.storageID
        }
    }

    func verifyAndPromoteOffMain(task: DownloadTask, key: String) {
        task.state = .verifying
        updateStatus(model: task.model)
        let fileURL = task.stagingURL
        let expectedBytes = task.expectedBytes
        let expectedSHA256 = task.expectedSHA256
        let modelID = task.model.id
        let artifactStr = task.artifact.label
        let verifyCID = DownloadDiagnosticRecorder.transferCorrelationID(modelID: modelID, artifact: artifactStr)
        let stagingName = DownloadDiagnosticRedactor.sanitizedFilename(fileURL)
        logger.info("Verifying \(key, privacy: .public) staging=\(stagingName, privacy: .public) expectedBytes=\(expectedBytes)")
        DownloadDiagnosticRecorder.shared.record(
            event: .validationStart,
            correlationID: verifyCID,
            modelID: modelID,
            artifact: artifactStr,
            expectedBytes: expectedBytes
        )
        let verifyStart = ContinuousClock.now
        let detachedVerification = Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: fileURL,
                expectedBytes: expectedBytes,
                expectedSHA256: expectedSHA256,
                onProgress: { progress in
                    Task { @MainActor [weak task] in
                        task?.progress = progress.fraction
                    }
                }
            )
        }
        task.verificationTask = Task { [weak self, weak task] in
            let failure = await withTaskCancellationHandler {
                await detachedVerification.value
            } onCancel: {
                detachedVerification.cancel()
            }
            let durationMs = verifyStart.elapsedMilliseconds
            guard !Task.isCancelled,
                  let self, let task,
                  self.activeTasks[key] === task,
                  !task.isCancelled else { return }
            let space = self.availableDiskSpace
            if space > 0, space < Self.storageSafetyMarginBytes {
                DownloadDiagnosticRecorder.shared.record(
                    event: .validationFailed,
                    correlationID: verifyCID,
                    modelID: modelID,
                    artifact: artifactStr,
                    state: "failed",
                    failureCategory: .storage,
                    failureSummary: "disk space insufficient for promotion",
                    durationMs: durationMs
                )
                _ = self.failVerification(task, error: .diskSpaceInsufficient, discardStaging: false)
            } else {
                _ = self.finishVerifiedPromotion(task, validationFailure: failure, correlationID: verifyCID, durationMs: durationMs)
            }
            task.verificationTask = nil
            let succeeded: Bool
            if case .downloaded = task.state { succeeded = true } else { succeeded = false }
            if succeeded {
                // Success: drop the active entry first so the published status
                // reflects installed-disk truth, then check pair completion.
                self.activeTasks.removeValue(forKey: key)
                self.clearTransferProgress(key)
                self.updateStatus(model: task.model)
                self.recordPairCompletionIfReady(for: task.model)
            } else {
                // Failure: publish the terminal `.failed` state from the
                // active entry first so the UI can surface it; the next
                // disk-driven refresh will re-derive `.notDownloaded`.
                self.updateStatus(model: task.model)
                self.activeTasks.removeValue(forKey: key)
                self.clearTransferProgress(key)
            }
            self.stopStuckWatchdogIfIdle()
        }
    }

    func finishVerifiedPromotion(
        _ task: DownloadTask,
        validationFailure: DownloadError?,
        correlationID: String,
        durationMs: UInt64
    ) -> Result<Void, DownloadError> {
        if let validationFailure {
            let category = DownloadFailureCategory.from(validationFailure)
            DownloadDiagnosticRecorder.shared.record(
                event: .validationFailed,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                state: "failed",
                failureCategory: category,
                failureSummary: validationFailure.localizedDescription,
                durationMs: durationMs
            )
            return failVerification(task, error: validationFailure, discardStaging: true)
        }
        do {
            DownloadDiagnosticRecorder.shared.record(
                event: .promotionAttempt,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                expectedBytes: task.expectedBytes,
                actualBytes: task.expectedBytes
            )
            try promoteAtomically(task)
            removeDurableState(for: task, discardStaging: false)
            clearRepairMarkersForSharedBase(of: task.model)
            task.progress = 1
            task.state = .downloaded
            let destName = DownloadDiagnosticRedactor.sanitizedFilename(task.destinationURL)
            let stagingName = DownloadDiagnosticRedactor.sanitizedFilename(task.stagingURL)
            DownloadDiagnosticRecorder.shared.record(
                event: .promotionSuccess,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                state: "downloaded",
                expectedBytes: task.expectedBytes,
                actualBytes: task.expectedBytes,
                durationMs: durationMs
            )
            DownloadDiagnosticRecorder.shared.record(
                event: .validationComplete,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                state: "downloaded",
                expectedBytes: task.expectedBytes,
                actualBytes: task.expectedBytes,
                durationMs: durationMs
            )
            logger.info("Download verified and promoted: \(task.storageID, privacy: .public) file=\(destName, privacy: .public) bytes=\(task.expectedBytes)")
            scheduleStorageBreakdownRefresh()
            return .success(())
        } catch {
            // A promotion failure is a transient storage problem, not proof of
            // corrupted content: the staged bytes already passed SHA-256.
            // Preserve staging and durable metadata so retry/re-launch recovery
            // can re-promote instead of destroying multi-GB verified bytes.
            DownloadDiagnosticRecorder.shared.record(
                event: .promotionFailed,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                state: "failed",
                failureCategory: .storage,
                failureSummary: "atomic promotion failed: \(error.localizedDescription)"
            )
            return failVerification(task, error: .promotionFailed(underlying: error.localizedDescription), discardStaging: false)
        }
    }

    /// Clear repair markers for every catalog identity sharing this model's
    /// installed base artifact. E4B vision + E4B text share one base file, so
    /// clearing only the promoted identity would leave a stale sibling marker
    /// (and a phantom repair banner) behind.
    func clearRepairMarkersForSharedBase(of model: AIModel) {
        let siblings = ModelRegistry.libraryModels.filter {
            $0.baseArtifactStorageID == model.baseArtifactStorageID
        }
        for sibling in siblings {
            ModelManagerService.clearRepairNeeded(for: sibling)
        }
        if !siblings.contains(where: { $0.id == model.id }) {
            ModelManagerService.clearRepairNeeded(for: model)
        }
    }

    /// Record a pair-level completion event when the installed pair is now
    /// usable. Called after the status has been republished from disk truth,
    /// so the verdict reflects verifier-backed `authoritativeDiskStatus`, not
    /// a transient active-task state.
    func recordPairCompletionIfReady(for model: AIModel) {
        let status = downloadStatuses[model.id] ?? authoritativeDiskStatus(for: model)
        let pairReady = model.requiresMMProj ? status.isVisionReady : status.isReady
        guard pairReady else { return }
        let scope = model.requiresMMProj
            ? (status.isVisionReady ? "text+vision" : "text")
            : "text"
        DownloadDiagnosticRecorder.shared.record(
            event: .pairComplete,
            correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
            modelID: model.id,
            artifact: "pair",
            state: "downloaded",
            failureSummary: "pair complete scope=\(scope)"
        )
        logger.info("Pair complete: \(model.id, privacy: .public) scope=\(scope, privacy: .public)")
    }

    /// Re-verify staged bytes left by an interrupted promotion and promote
    /// them when valid, instead of redownloading multi-GB artifacts. Returns
    /// true when a re-verify was queued (caller must not start a transfer).
    /// Cheap gate on the main actor (existence + byte size + memoized GGUF
    /// header); the full SHA-256 runs off-main inside verifyAndPromoteOffMain.
    @discardableResult
    func repromoteStagingIfValid(model: AIModel, artifact: ArtifactType) -> Bool {
        let probe = DownloadTask(model: model, artifact: artifact)
        guard fileManager.fileExists(atPath: probe.stagingURL.path) else { return false }
        guard let stagedBytes = (try? fileManager.attributesOfItem(atPath: probe.stagingURL.path)[.size] as? NSNumber)?.int64Value,
              stagedBytes == probe.expectedBytes,
              ModelManagerService.verifyGGUFHeader(fileURL: probe.stagingURL) else { return false }
        let key = probe.storageID
        if activeTasks[key] == nil {
            probe.progress = 1
            probe.state = .verifying
            activeTasks[key] = probe
            noteTransferProgress(key)
        }
        guard let task = activeTasks[key] else { return false }
        task.isPaused = false
        task.isCancelled = false
        let stagingName = DownloadDiagnosticRedactor.sanitizedFilename(task.stagingURL)
        let transferCID = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: model.id, artifact: artifact.label
        )
        logger.info("Healer re-verifying staged bytes: \(key, privacy: .public) file=\(stagingName, privacy: .public)")
        DownloadDiagnosticRecorder.shared.record(
            event: .healerAction,
            correlationID: transferCID,
            modelID: model.id,
            artifact: artifact.label,
            state: "re-verifying-staging"
        )
        verifyAndPromoteOffMain(task: task, key: key)
        return true
    }

    func failVerification(
        _ task: DownloadTask,
        error: DownloadError,
        discardStaging: Bool
    ) -> Result<Void, DownloadError> {
        task.state = .failed(error: error)
        let stagingName = DownloadDiagnosticRedactor.sanitizedFilename(task.stagingURL)
        logger.error("Artifact failed: \(task.storageID, privacy: .public) staging=\(stagingName, privacy: .public)")
        logger.error("Failure detail: \(error.localizedDescription, privacy: .public) discardStaging=\(discardStaging)")
        switch error {
        case .diskSpaceInsufficient:
            // Keep durable metadata so the user can resume once space frees up.
            persistDurableState(for: task, failed: true)
        case .promotionFailed:
            // Verified staging survives; advertise it as resumable so a retry
            // (or next-launch restore) can re-promote without redownloading.
            persistDurableState(for: task, failed: false)
        default:
            removeDurableState(for: task, discardStaging: discardStaging)
        }
        scheduleStorageBreakdownRefresh()
        return .failure(error)
    }
}

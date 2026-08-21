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
            self.updateStatus(model: task.model)
            self.activeTasks.removeValue(forKey: key)
            self.clearTransferProgress(key)
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
        if injectPromotionFailureForTesting {
            return failVerification(task, error: .fileCorrupted, discardStaging: true)
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
            ModelManagerService.clearRepairNeeded(for: task.model)
            task.progress = 1
            task.state = .downloaded
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
            logger.info("Download verified and promoted: \(task.storageID, privacy: .public)")
            scheduleStorageBreakdownRefresh()
            return .success(())
        } catch {
            DownloadDiagnosticRecorder.shared.record(
                event: .promotionFailed,
                correlationID: correlationID,
                modelID: task.model.id,
                artifact: task.artifact.label,
                state: "failed",
                failureCategory: .verification,
                failureSummary: "atomic promotion failed"
            )
            return failVerification(task, error: .fileCorrupted, discardStaging: true)
        }
    }

    func failVerification(
        _ task: DownloadTask,
        error: DownloadError,
        discardStaging: Bool
    ) -> Result<Void, DownloadError> {
        task.state = .failed(error: error)
        if error == .diskSpaceInsufficient {
            persistDurableState(for: task, failed: true)
        } else {
            removeDurableState(for: task, discardStaging: discardStaging)
        }
        scheduleStorageBreakdownRefresh()
        return .failure(error)
    }
}

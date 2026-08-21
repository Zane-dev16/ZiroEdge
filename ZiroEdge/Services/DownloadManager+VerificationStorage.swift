import CryptoKit
import Foundation
import os

extension DownloadManager {
    func chunkedDownload(task: DownloadTask, key: String) {
        guard activeTasks[key] === task,
              !task.isPaused,
              !task.isCancelled,
              task.chunkTask == nil else { return }
        do {
            let stagedBytes = try resumableChunkOffset(for: task)
            task.currentChunkOffset = stagedBytes
            task.currentChunkIndex = stagedBytes / Self.chunkSize
            if stagedBytes == task.expectedBytes {
                finishChunkedDownload(task: task, key: key)
                return
            }
            guard stagedBytes < task.expectedBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let end = min(
                SaturatedArithmetic.add(stagedBytes, Self.chunkSize - 1),
                task.expectedBytes - 1
            )
            var request = URLRequest(url: task.downloadURL ?? task.sourceURL)
            request.setValue("bytes=\(stagedBytes)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 300
            task.state = .downloading(progress: Double(stagedBytes) / Double(task.expectedBytes))
            task.progress = Double(stagedBytes) / Double(task.expectedBytes)
            updateStatus(model: task.model)
            lastProgressTime[key] = Date()
            let handle = try FileHandle(forWritingTo: task.stagingURL)
            try handle.seek(toOffset: UInt64(stagedBytes))
            task.chunkFileHandle = handle
            task.currentChunkEnd = end
            task.chunkBytesReceived = 0
            task.chunkResponseValidated = false
            task.chunkFailureReason = nil
            let dataTask = getChunkSession().dataTask(with: request)
            task.chunkTask = dataTask
            dataTask.taskDescription = key
            dataTask.resume()
        } catch {
            failChunkedDownload(task: task, key: key, error: error)
        }
    }
    func resumableChunkOffset(for task: DownloadTask) throws -> Int64 {
        guard fileManager.fileExists(atPath: task.stagingURL.path) else {
            fileManager.createFile(atPath: task.stagingURL.path, contents: nil)
            return 0
        }
        let attributes = try fileManager.attributesOfItem(atPath: task.stagingURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size == task.expectedBytes { return size }
        let validSize = min(size, task.expectedBytes) / Self.chunkSize * Self.chunkSize
        if validSize != size {
            let handle = try FileHandle(forWritingTo: task.stagingURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(validSize))
        }
        return validSize
    }
    func closeChunkFile(for task: DownloadTask, synchronize: Bool = false) {
        guard let handle = task.chunkFileHandle else { return }
        if synchronize {
            try? handle.synchronize()
        }
        try? handle.close()
        task.chunkFileHandle = nil
    }
    func completeChunk(task: DownloadTask, key: String) {
        let completedBytes = task.currentChunkEnd + 1
        task.currentChunkOffset = completedBytes
        task.currentChunkIndex = Self.chunkCount(for: completedBytes)
        task.chunkRetryCount = 0
        task.progress = Double(completedBytes) / Double(task.expectedBytes)
        task.state = .downloading(progress: task.progress)
        persistDurableState(for: task)
        lastProgressTime[key] = Date()
        updateStatus(model: task.model)
        DownloadDiagnosticRecorder.shared.record(
            event: .chunkReceived,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
            modelID: task.model.id,
            artifact: task.artifact.label,
            progress: task.progress,
            chunkIndex: task.currentChunkIndex
        )
        if completedBytes == task.expectedBytes {
            finishChunkedDownload(task: task, key: key)
        } else {
            chunkedDownload(task: task, key: key)
        }
    }
    func contentRange(
        _ response: HTTPURLResponse,
        matchesStart start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "Content-Range")?.lowercased() else {
            return false
        }
        return value == "bytes \(start)-\(end)/\(total)"
    }
    func isValidChunkResponse(
        _ response: HTTPURLResponse,
        start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        response.statusCode == 206
            && contentRange(response, matchesStart: start, end: end, total: total)
    }

    func retryChunk(task: DownloadTask, key: String, reason: String) {
        guard activeTasks[key] === task, !task.isPaused, !task.isCancelled else { return }
        closeChunkFile(for: task)
        task.chunkTask = nil
        task.chunkRetryCount += 1
        guard task.chunkRetryCount <= Self.maximumChunkRetries else {
            failChunkedDownload(
                task: task,
                key: key,
                error: NSError(domain: "DownloadManager.Chunk", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            )
            return
        }
        let delay = min(Double(task.chunkRetryCount * 2), 6)
        DownloadDiagnosticRecorder.shared.record(
            event: .chunkRetry,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
            modelID: task.model.id,
            artifact: task.artifact.label,
            failureSummary: reason,
            chunkIndex: task.currentChunkIndex,
            chunkRetryCount: task.chunkRetryCount
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak task] in
            guard let self, let task else { return }
            self.chunkedDownload(task: task, key: key)
        }
    }
    func finishChunkedDownload(task: DownloadTask, key: String) {
        closeChunkFile(for: task, synchronize: true)
        verifyAndPromoteOffMain(task: task, key: key)
    }
    func failChunkedDownload(task: DownloadTask, key: String, error: Error) {
        guard activeTasks[key] === task else { return }
        closeChunkFile(for: task)
        task.chunkTask = nil
        task.state = .failed(error: .networkError)
        persistDurableState(for: task, failed: true)
        DownloadDiagnosticRecorder.shared.record(
            event: .chunkFailed,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
            modelID: task.model.id,
            artifact: task.artifact.label,
            failureCategory: .network,
            failureSummary: error.localizedDescription
        )
        updateStatus(model: task.model)
        activeTasks.removeValue(forKey: key)
        lastProgressTime.removeValue(forKey: key)
    }
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
        lastProgressTime.removeValue(forKey: key)

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
        logger.info("Cancelled download: \(key, privacy: .public) discardStaging=\(discardStaging)")
    }
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
            self.lastProgressTime.removeValue(forKey: key)
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
        return .failure(error)
    }
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
    }

    // MARK: - Orphan Reclamation

    /// Scan staging and resume directories for files not associated with any active
    /// transfer or known model identity. Returns total bytes reclaimed.
    @discardableResult
    func reclaimOrphanedStorage() -> Int64 {
        guard ModelRegistry.importedRegistriesAvailable else {
            logger.info("Skipping orphan reclamation while imported registries are unavailable")
            return 0
        }
        var reclaimed: Int64 = 0
        var knownPaths = Set<String>()

        func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        // Collect every known path from active tasks and all model identities.
        for (_, task) in activeTasks {
            knownPaths.insert(canonicalPath(task.stagingURL))
            knownPaths.insert(canonicalPath(task.resumeDataURL))
            knownPaths.insert(canonicalPath(task.metadataURL))
        }
        for model in ModelRegistry.transferModels {
            let calibrationModels = ModelRegistry.calibrationModels
            for candidateModel in [model] + calibrationModels {
                for artifact: ArtifactType in [.base, .mmproj] {
                    let candidateTask = DownloadTask(model: candidateModel, artifact: artifact)
                    knownPaths.insert(canonicalPath(candidateTask.stagingURL))
                    knownPaths.insert(canonicalPath(candidateTask.resumeDataURL))
                    knownPaths.insert(canonicalPath(candidateTask.metadataURL))
                }
            }
        }

        let directories: [(URL, String)] = [
            (ModelManagerService.stagingDirectory, "staging"),
            (ModelManagerService.resumeDirectory, "resume"),
            (ModelManagerService.quarantineDirectory, "quarantine")
        ]

        for (directory, label) in directories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                guard !knownPaths.contains(canonicalPath(fileURL)) else { continue }

                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                do {
                    try fileManager.removeItem(at: fileURL)
                    reclaimed += Int64(size)
                    logger.info("Reclaimed orphaned \(label) file: \(fileURL.lastPathComponent, privacy: .public) (\(size) bytes)")
                } catch {
                    logger.warning("Failed to reclaim orphaned \(label) file: \(fileURL.lastPathComponent, privacy: .public)")
                }
            }
        }
        return reclaimed
    }

    // MARK: - Managed Storage Breakdown

    /// Breakdown of managed storage usage across all managed directories.
    struct ManagedStorageBreakdown {
        let installedBytes: Int64
        let stagingBytes: Int64
        let resumeBytes: Int64
        let quarantineBytes: Int64

        var totalManagedBytes: Int64 { installedBytes + stagingBytes + resumeBytes + quarantineBytes }

        var formattedTotal: String {
            ByteCountFormatter.string(fromByteCount: totalManagedBytes, countStyle: .file)
        }

        var formattedInstalled: String {
            ByteCountFormatter.string(fromByteCount: installedBytes, countStyle: .file)
        }
    }

    func managedStorageBreakdown() -> ManagedStorageBreakdown {
        func directorySize(_ url: URL) -> Int64 {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }

        return ManagedStorageBreakdown(
            installedBytes: ModelManagerService.totalDiskUsage(),
            stagingBytes: directorySize(ModelManagerService.stagingDirectory),
            resumeBytes: directorySize(ModelManagerService.resumeDirectory),
            quarantineBytes: directorySize(ModelManagerService.quarantineDirectory)
        )
    }

    /// Actionable out-of-space message that includes required vs available bytes.
    func insufficientStorageMessage(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) -> String {
        let required = requiredDownloadBytes(for: model, includeOptionalProjector: includeOptionalProjector)
        let available = availableDiskSpace
        let formattedRequired = ByteCountFormatter.string(fromByteCount: max(required, 0), countStyle: .file)
        let formattedAvailable = ByteCountFormatter.string(fromByteCount: max(available, 0), countStyle: .file)
        return "Not enough disk space: \(formattedRequired) needed, but only \(formattedAvailable) is available."
    }
}

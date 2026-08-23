import Foundation
import os

// Storage accounting for managed directories: orphaned-byte reclamation,
// the cached storage breakdown published to UI, and user-facing
// insufficient-space messaging.
extension DownloadManager {
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
        reclaimed += reclaimOrphanedInstalledArtifacts()
        if reclaimed > 0 { scheduleStorageBreakdownRefresh() }
        return reclaimed
    }

    /// Removes stranded artifacts from the installed directory: an interrupted
    /// imported-update promotion commits the registry swap before deleting
    /// replaced files, and a crash in between strands multi-GB artifacts that
    /// no other reclamation path scans. Only unreferenced .gguf /
    /// .promotion-backup files older than a grace period are removed so
    /// in-flight promotions are never raced.
    private func reclaimOrphanedInstalledArtifacts() -> Int64 {
        var reclaimed: Int64 = 0
        func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        var referencedInstalled = Set<String>()
        var seenModelIDs = Set<String>()
        for model in ModelRegistry.transferModels + ModelRegistry.calibrationModels {
            guard seenModelIDs.insert(model.id).inserted else { continue }
            referencedInstalled.insert(canonicalPath(DownloadTask(model: model, artifact: .base).destinationURL))
            if model.requiresMMProj {
                referencedInstalled.insert(canonicalPath(DownloadTask(model: model, artifact: .mmproj).destinationURL))
            }
        }
        guard let installedEnumerator = fileManager.enumerator(
            at: ModelManagerService.modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        ) else { return 0 }
        let orphanGraceInterval: TimeInterval = 24 * 60 * 60
        for case let fileURL as URL in installedEnumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let fileName = fileURL.lastPathComponent
            guard fileName.hasSuffix(".gguf") || fileName.hasSuffix(".promotion-backup") else { continue }
            guard !referencedInstalled.contains(canonicalPath(fileURL)) else { continue }
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            guard Date().timeIntervalSince(modified) > orphanGraceInterval else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try fileManager.removeItem(at: fileURL)
                reclaimed += Int64(size)
                logger.info("Reclaimed orphaned installed file: \(fileName, privacy: .public) (\(size) bytes)")
            } catch {
                logger.warning("Failed to reclaim orphaned installed file: \(fileName, privacy: .public)")
            }
        }
        return reclaimed
    }

    // MARK: - Managed Storage Breakdown

    /// Breakdown of managed storage usage across all managed directories.
    struct ManagedStorageBreakdown: Equatable, Sendable {
        let installedBytes: Int64
        let stagingBytes: Int64
        let resumeBytes: Int64
        let quarantineBytes: Int64

        var totalManagedBytes: Int64 { installedBytes + stagingBytes + resumeBytes + quarantineBytes }

        var formattedTotal: String {
            StorageByteFormatter.string(fromByteCount: totalManagedBytes)
        }

        var formattedInstalled: String {
            StorageByteFormatter.string(fromByteCount: installedBytes)
        }
    }

    func managedStorageBreakdown() -> ManagedStorageBreakdown {
        ManagedStorageBreakdown(
            installedBytes: ModelManagerService.totalDiskUsage(),
            stagingBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.stagingDirectory),
            resumeBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.resumeDirectory),
            quarantineBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.quarantineDirectory)
        )
    }

    // BATCH-05: cached breakdown computed off-main, invalidated only on completion/promotion/quarantine/removal
    func scheduleStorageBreakdownRefresh() {
        storageBreakdownTask?.cancel()
        storageBreakdownTask = Task { [weak self] in
            guard let self else { return }
            // Compute off-main via detached task
            let breakdown = await Task.detached(priority: .utility) {
                ManagedStorageBreakdown(
                    installedBytes: ManagedDirectoryMetrics.installedBytesOffMain(),
                    stagingBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.stagingDirectory),
                    resumeBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.resumeDirectory),
                    quarantineBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.quarantineDirectory)
                )
            }.value
            guard !Task.isCancelled else { return }
            // Back on MainActor (self is MainActor-isolated)
            self.cachedStorageBreakdown = breakdown
            self.storageBreakdownComputeCount += 1
            self.lastStorageBreakdownWasOffMain = true
        }
    }

    /// Synchronous refresh for tests that need immediate consistency without async wait.
    func refreshStorageBreakdownForTests() {
        let breakdown = managedStorageBreakdown()
        cachedStorageBreakdown = breakdown
        storageBreakdownComputeCount += 1
        lastStorageBreakdownWasOffMain = false
    }

    /// Async refresh that tests can await; verifies off-main execution.
    func refreshStorageBreakdownAsyncForTests() async {
        let breakdown = await Task.detached(priority: .utility) {
            ManagedStorageBreakdown(
                installedBytes: ManagedDirectoryMetrics.installedBytesOffMain(),
                stagingBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.stagingDirectory),
                resumeBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.resumeDirectory),
                quarantineBytes: ManagedDirectoryMetrics.directorySize(ModelManagerService.quarantineDirectory)
            )
        }.value
        cachedStorageBreakdown = breakdown
        storageBreakdownComputeCount += 1
        lastStorageBreakdownWasOffMain = true
    }

    /// Actionable out-of-space message that includes required vs available bytes.
    func insufficientStorageMessage(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) -> String {
        let required = requiredDownloadBytes(for: model, includeOptionalProjector: includeOptionalProjector)
        let available = availableDiskSpace
        let formattedRequired = StorageByteFormatter.string(fromByteCount: required)
        let formattedAvailable = StorageByteFormatter.string(fromByteCount: available)
        return "Not enough disk space: \(formattedRequired) needed, but only \(formattedAvailable) is available."
    }
}

/// Shared byte-counting for managed directories. Counts regular files only;
/// used by both the synchronous breakdown path and off-main detached tasks,
/// which previously carried three copies of the same enumeration loop.
enum ManagedDirectoryMetrics {
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
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

    /// Installed-bytes walk of the models directory for callers already
    /// executing off-main (mirrors the inline enumeration it replaces).
    static func installedBytesOffMain() -> Int64 {
        directorySize(ModelManagerService.modelsDirectory)
    }
}

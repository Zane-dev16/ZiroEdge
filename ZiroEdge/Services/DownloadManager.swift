// DownloadTask and NetworkMonitor live in DownloadTransferTypes.swift.
import Foundation
import Network
import CryptoKit
import UIKit
import os
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published var downloadStatuses: [String: ModelDownloadStatus] = [:]
    var activeTasks: [String: DownloadTask] = [:]
    let networkMonitor = NetworkMonitor()
    static let backgroundSessionIdentifier = "com.zanish-labs.ziroedge.model-downloads.v1"
    nonisolated(unsafe) var urlSessionStorage: URLSession?
    nonisolated(unsafe) var chunkSessionStorage: URLSession?
    // Weak proxy to break URLSession strong-retain cycle (session -> delegate -> manager -> session)
    private final class WeakDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate {
        weak var owner: DownloadManager?
        init(owner: DownloadManager) { self.owner = owner; super.init() }
        nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            guard let owner else {
                Task { @MainActor in BackgroundDownloadCompletionStore.drain(identifier: session.configuration.identifier ?? "") }
                return
            }
            owner.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        }
        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let owner else { return }
            owner.urlSession(session, dataTask: dataTask, didReceive: data)
        }
        nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let owner else { return }
            owner.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
        }
        nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let owner else { return }
            owner.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let owner else { return }
            owner.urlSession(session, task: task, didCompleteWithError: error)
        }
        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let owner else { completionHandler(nil); return }
            owner.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler
            )
        }
    }
    func getSession() -> URLSession {
        if let existing = urlSessionStorage { return existing }
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let config = isTesting
            ? URLSessionConfiguration.default
            : URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = true
        let proxy = WeakDelegate(owner: self)
        let session = URLSession(configuration: config, delegate: proxy, delegateQueue: .main)
        urlSessionStorage = session
        return session
    }
    func getChunkSession() -> URLSession {
        if let existing = chunkSessionStorage { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = true
        let proxy = WeakDelegate(owner: self)
        let session = URLSession(configuration: config, delegate: proxy, delegateQueue: .main)
        chunkSessionStorage = session
        return session
    }
    let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "download")
    let fileManager = FileManager.default
    var injectPromotionFailureForTesting = false
    var injectAvailableDiskSpaceForTesting: Int64?
    private var availableDiskSpaceProviderForTesting: (@MainActor () -> Int64)?
    var additionalTransferModelsProvider: @MainActor () -> [AIModel] = { [] }
    var lastProgressTime: [String: Date] = [:]
    // BATCH-05: cached storage breakdown — invalidated only on completion/promotion/quarantine/removal, computed off-main
    @Published var cachedStorageBreakdown: ManagedStorageBreakdown = ManagedStorageBreakdown(installedBytes: 0, stagingBytes: 0, resumeBytes: 0, quarantineBytes: 0)
    var storageBreakdownTask: Task<Void, Never>?
    var storageBreakdownComputeCount: Int = 0
    var lastStorageBreakdownWasOffMain: Bool?
    func resetStorageBreakdownComputeCountForTests() { storageBreakdownComputeCount = 0; lastStorageBreakdownWasOffMain = nil }
    nonisolated(unsafe) var stuckTimer: Timer?
    nonisolated(unsafe) var protectedDataObserver: NSObjectProtocol?
    nonisolated(unsafe) var storageObserver: NSObjectProtocol?
    static let chunkSize: Int64 = 100 * 1_024 * 1_024
    static let chunkedDownloadThreshold: Int64 = 2_147_483_648
    static let maximumChunkRetries = 3

    static func chunkCount(for byteCount: Int64) -> Int64 {
        guard byteCount > 0 else { return 0 }
        return byteCount / chunkSize + (byteCount.isMultiple(of: chunkSize) ? 0 : 1)
    }

    /// Free-space reserve kept beyond missing artifact bytes so filesystem
    /// metadata, atomic promotion, and normal app writes cannot consume the
    /// device's final capacity during a multi-gigabyte installation.
    static let storageSafetyMarginBytes: Int64 = 512 * 1_024 * 1_024
    override convenience init() {
        self.init(availableDiskSpaceProvider: nil)
    }
    init(availableDiskSpaceProvider: (@MainActor () -> Int64)?) {
        self.availableDiskSpaceProviderForTesting = availableDiskSpaceProvider
        super.init()
        ModelMigrationService.ensureManagedDirectories()
        reconcileInterruptedPromotions()
        updateStatusesFromDisk()
        restoreDurableTransfers()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            reclaimOrphanedStorage()
        }
        // BATCH-05: seed cache synchronously once at startup to avoid initial 0 flash; subsequent refreshes are off-main and coalesced
        cachedStorageBreakdown = managedStorageBreakdown()
        storageBreakdownComputeCount = 1
        lastStorageBreakdownWasOffMain = false
        reconcileBackgroundTasks()
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverProtectedImportedState()
            }
        }
        storageObserver = NotificationCenter.default.addObserver(
            forName: .managedStorageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStorageBreakdownRefresh()
            }
        }
    }
    /// Lifecycle-safe teardown that invalidates URLSessions and breaks the
    /// delegate retain cycle. Chooses finish vs cancel based on active tasks,
    /// nils storage to prevent recreation collisions, and is idempotent.
    @MainActor
    func teardown() {
        if let session = urlSessionStorage {
            let hasActiveBackgroundTask = activeTasks.values.contains { $0.task != nil && !$0.isCancelled }
            if hasActiveBackgroundTask {
                session.finishTasksAndInvalidate()
            } else {
                session.invalidateAndCancel()
            }
            urlSessionStorage = nil
        }
        if let session = chunkSessionStorage {
            session.invalidateAndCancel()
            chunkSessionStorage = nil
        }
        stuckTimer?.invalidate()
        stuckTimer = nil
        if let observer = protectedDataObserver {
            NotificationCenter.default.removeObserver(observer)
            protectedDataObserver = nil
        }
        if let observer = storageObserver {
            NotificationCenter.default.removeObserver(observer)
            storageObserver = nil
        }
        storageBreakdownTask?.cancel()
        storageBreakdownTask = nil
    }
    deinit {
        // Non-trapping cleanup: must not use MainActor.assumeIsolated because
        // the last reference may drop off the main thread (XCTest / service teardown).
        // URLSession invalidate is thread-safe; timer/observer need main.
        let backgroundSession = urlSessionStorage
        let chunkSession = chunkSessionStorage
        let timer = stuckTimer
        let observer = protectedDataObserver
        let storageObs = storageObserver
        let breakdownTask = storageBreakdownTask
        backgroundSession?.invalidateAndCancel()
        chunkSession?.invalidateAndCancel()
        breakdownTask?.cancel()
        if Thread.isMainThread {
            timer?.invalidate()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let storageObs {
                NotificationCenter.default.removeObserver(storageObs)
            }
        } else {
            DispatchQueue.main.async {
                timer?.invalidate()
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                if let storageObs {
                    NotificationCenter.default.removeObserver(storageObs)
                }
            }
        }
    }
    func status(for model: AIModel) -> ModelDownloadStatus {
        if let cached = downloadStatuses[model.id] { return cached }
        return authoritativeDiskStatus(for: model)
    }
    func updateStatusesFromDisk() {
        for model in ModelRegistry.libraryModels {
            downloadStatuses[model.id] = authoritativeDiskStatus(for: model)
        }
    }

    func recoverProtectedImportedState() {
        guard ModelRegistry.importedRegistriesAvailable else { return }
        updateStatusesFromDisk()
        restoreDurableTransfers()
        reconcileBackgroundTasks()
        _ = reclaimOrphanedStorage()
    }
}
extension DownloadManager {
    var availableDiskSpace: Int64 {
        if let provider = availableDiskSpaceProviderForTesting { return provider() }
        if let injected = injectAvailableDiskSpaceForTesting { return injected }
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return 0 }
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
    func hasSufficientStorage(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) -> Bool {
        let required = requiredDownloadBytes(
            for: model,
            includeOptionalProjector: includeOptionalProjector
        )
        guard required >= 0, required < Int64.max else { return false }
        return availableDiskSpace >= required
    }
    func requiredDownloadBytes(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) -> Int64 {
        func remaining(_ task: DownloadTask, installed: Bool) -> Int64 {
            guard !installed else { return 0 }
            let staged = ((try? fileManager.attributesOfItem(atPath: task.stagingURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return max(0, task.expectedBytes - min(staged, task.expectedBytes))
        }
        var required = remaining(
            DownloadTask(model: model, artifact: .base),
            installed: ModelManagerService.isBaseDownloaded(model)
        )
        if model.requiresMMProj && (!model.allowsTextOnlyCapability || includeOptionalProjector) {
            let projector = remaining(
                DownloadTask(model: model, artifact: .mmproj),
                installed: ModelManagerService.isMMProjDownloaded(model)
            )
            let (sum, overflow) = required.addingReportingOverflow(projector)
            if overflow { return .max }
            required = sum
        }
        guard required > 0 else { return 0 }
        let (withMargin, overflow) = required.addingReportingOverflow(storageSafetyMargin(for: required))
        return overflow ? .max : withMargin
    }
    func formattedAvailableSpace() -> String {
        StorageByteFormatter.string(fromByteCount: availableDiskSpace)
    }
    func startDownload(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) {
        guard hasSufficientStorage(
            for: model,
            includeOptionalProjector: includeOptionalProjector
        ) else {
            let message = insufficientStorageMessage(
                for: model,
                includeOptionalProjector: includeOptionalProjector
            )
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .diskSpaceInsufficient),
                mmprojState: model.requiresMMProj ? .failed(error: .diskSpaceInsufficient) : nil
            )
            logger.error("Refusing download without sufficient free storage: \(model.id, privacy: .public) — \(message, privacy: .public)")
            return
        }
        guard model.catalogUnavailableReason == nil,
              ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels) == nil else {
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .invalidCatalogMetadata),
                mmprojState: model.requiresMMProj ? .failed(error: .invalidCatalogMetadata) : nil
            )
            logger.error("Refusing download with invalid integrity metadata: \(model.id, privacy: .public)")
            return
        }
        let storageCID = DownloadDiagnosticRecorder.freshCorrelationID()
        let available = availableDiskSpace
        let required = requiredDownloadBytes(for: model, includeOptionalProjector: includeOptionalProjector)
        DownloadDiagnosticRecorder.shared.record(
            event: available >= required ? .storageCheck : .storageInsufficient,
            correlationID: storageCID,
            modelID: model.id,
            artifact: "base",
            availableStorageBytes: available,
            requiredStorageBytes: required
        )
        startStuckWatchdog()
        let currentStatus = authoritativeDiskStatus(for: model)
        downloadStatuses[model.id] = currentStatus
        let requestedCapabilityReady = model.allowsTextOnlyCapability && includeOptionalProjector
            ? currentStatus.isVisionReady
            : currentStatus.isReady
        guard !requestedCapabilityReady, !currentStatus.isDownloading else { return }
        ModelManagerService.ensureModelsDirectory()
        if !ModelManagerService.isBaseDownloaded(model) {
            startArtifactDownload(model: model, artifact: .base)
        }
        if model.requiresMMProj,
           (!model.allowsTextOnlyCapability || includeOptionalProjector),
           !ModelManagerService.isMMProjDownloaded(model) {
            startArtifactDownload(model: model, artifact: .mmproj)
        }
    }
    func pauseDownload(for model: AIModel) {
        pauseArtifactDownload(model: model, artifact: .base)
        if model.requiresMMProj {
            pauseArtifactDownload(model: model, artifact: .mmproj)
        }
        updateStatus(model: model)
    }
    func pauseArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let downloadTask = activeTasks[key], downloadTask.model.id == model.id else { return }
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
    /// Pause every active artifact for a model and retry only missing or
    /// invalid artifacts. Verified artifacts on disk are never replaced.
    func retryInvalidArtifacts(for model: AIModel) {
        let baseKey = artifactTaskKey(model: model, artifact: .base)
        let mmprojKey = artifactTaskKey(model: model, artifact: .mmproj)

        // Pause every active artifact first.
        if let baseTask = activeTasks[baseKey], !baseTask.isPaused {
            pauseArtifactDownload(model: model, artifact: .base)
        }
        if model.requiresMMProj, let mmprojTask = activeTasks[mmprojKey], !mmprojTask.isPaused {
            pauseArtifactDownload(model: model, artifact: .mmproj)
        }

        // Retry only artifacts that are missing or invalid.
        let baseNeedsRetry = !ModelManagerService.isBaseDownloaded(model)
        let mmprojNeedsRetry = model.requiresMMProj && !ModelManagerService.isMMProjDownloaded(model)

        if baseNeedsRetry {
            if activeTasks[baseKey] != nil {
                resumeArtifactDownload(model: model, artifact: .base)
            } else {
                startArtifactDownload(model: model, artifact: .base)
            }
        } else if activeTasks[baseKey] != nil {
            activeTasks.removeValue(forKey: baseKey)
            clearTransferProgress(baseKey)
        }

        if mmprojNeedsRetry {
            if activeTasks[mmprojKey] != nil {
                resumeArtifactDownload(model: model, artifact: .mmproj)
            } else {
                startArtifactDownload(model: model, artifact: .mmproj)
            }
        } else if activeTasks[mmprojKey] != nil {
            activeTasks.removeValue(forKey: mmprojKey)
            clearTransferProgress(mmprojKey)
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

    func deleteModel(_ model: AIModel) {
        cancelDownload(for: model)
        discardPartialDownload(for: model)
        ModelManagerService.deleteModel(
            model,
            preservingReferences: additionalTransferModelsProvider()
        )
        let baseTask = DownloadTask(model: model, artifact: .base)
        if !hasOtherTransferReference(for: baseTask) {
            try? fileManager.removeItem(at: baseTask.resumeDataURL)
        }
        if model.requiresMMProj {
            let projectorTask = DownloadTask(model: model, artifact: .mmproj)
            if !hasOtherTransferReference(for: projectorTask) {
                try? fileManager.removeItem(at: projectorTask.resumeDataURL)
            }
        }
        updateStatusesFromDisk()
        downloadStatuses[model.id] = authoritativeDiskStatus(for: model)
        scheduleStorageBreakdownRefresh()
    }
    func startStuckWatchdog() {
        stuckTimer?.invalidate()
        stuckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let now = Date()
                for (key, task) in self.activeTasks {
                    guard case .downloading = task.state else { continue }
                    guard !task.isChunked else { continue }
                    let lastProgress = self.lastProgressTime[key] ?? Date()
                    let elapsed = now.timeIntervalSince(lastProgress)
                    if elapsed > 120 {
                        DownloadDiagnosticRecorder.shared.record(
                            event: .stuckWatchdogFired,
                            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                                modelID: task.model.id,
                                artifact: task.artifact.label
                            ),
                            modelID: task.model.id,
                            artifact: task.artifact.label,
                            state: "retrying",
                            progress: task.progress,
                            failureCategory: .network,
                            failureSummary: "no transfer progress for \(Int(elapsed)) seconds"
                        )
                        self.clearTransferProgress(key)
                        task.task?.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak task] in
                            guard let self, let task else { return }
                            // Intent may have changed during the backoff window:
                            // never resurrect a cancelled/deleted transfer, and
                            // never double-start when the error path already
                            // retried via a fresh task under the same key.
                            let key = self.artifactTaskKey(model: task.model, artifact: task.artifact)
                            guard !task.isCancelled,
                                  self.activeTasks[key] == nil || self.activeTasks[key] === task else { return }
                            self.startArtifactDownload(model: task.model, artifact: task.artifact)
                        }
                    }
                }
            }
        }
        if let stuckTimer {
            RunLoop.main.add(stuckTimer, forMode: .common)
        }
    }
    func artifactTaskKey(model: AIModel, artifact: ArtifactType) -> String { DownloadTask(model: model, artifact: artifact).storageID }
    @discardableResult
    func registerActiveTaskIfAbsent(_ task: DownloadTask) -> Bool {
        guard activeTasks[task.storageID] == nil else { return false }
        activeTasks[task.storageID] = task
        return true
    }
    func hasActiveDownload(model: AIModel, artifact: ArtifactType) -> Bool {
        activeTasks[artifactTaskKey(model: model, artifact: artifact)] != nil
    }
    func reconcileBackgroundTasks() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        getSession().getAllTasks { [weak self] systemTasks in
            Task { @MainActor [weak self] in
                self?.reconcileBackgroundTasks(systemTasks)
            }
        }
    }
    /// Reconnect restored metadata to the system-owned background tasks. Kept
    /// separate from URLSession enumeration so the active-task/no-staging
    /// relaunch seam can be exercised without network I/O.
    func reconcileBackgroundTasks(_ systemTasks: [URLSessionTask]) {
        var reconciledKeys = Set<String>()
        for systemTask in systemTasks {
                    guard let key = systemTask.taskDescription, !key.isEmpty,
                          let downloadTask = systemTask as? URLSessionDownloadTask else {
                        // No stable identity to anchor — discard.
                        systemTask.cancel()
                        continue
                    }

                    // Already connected — duplicate.
                    if let existing = activeTasks[key], existing.task != nil {
                        systemTask.cancel()
                        continue
                    }

                    // Reconnect to a restored durable entry.
                    if let existing = activeTasks[key] {
                        existing.task = downloadTask
                        existing.isPaused = false
                        existing.awaitingBackgroundTaskReconciliation = false
                        existing.state = .downloading(progress: existing.progress)
                        reconciledKeys.insert(key)
                        updateStatus(model: existing.model)
                        continue
                    }

                    // No durable entry yet — try to rebuild from durable metadata
                    // or the model registry with staging evidence.
                    guard let resolved = DownloadManager.resolveStorageID(key) else {
                        // During a locked/background wake, protected imported
                        // registries are unavailable rather than empty. Leave
                        // system-owned tasks running until protected data returns.
                        if ModelRegistry.importedRegistriesAvailable {
                            systemTask.cancel()
                        }
                        continue
                    }

                    let hasMetadata = fileManager.fileExists(atPath: resolved.metadataURL.path)
                    let hasStaging = fileManager.fileExists(atPath: resolved.stagingURL.path)

                    if hasMetadata {
                        // Re-run the per-task restore path; it will populate activeTasks.
                        restoreSingleDurableTransfer(resolved)
                        if let restored = activeTasks[key] {
                            restored.task = downloadTask
                            restored.isPaused = false
                            restored.awaitingBackgroundTaskReconciliation = false
                            restored.state = .downloading(progress: restored.progress)
                            reconciledKeys.insert(key)
                            updateStatus(model: restored.model)
                            continue
                        }
                    }

                    if hasStaging {
                        // We have partial bytes but no metadata. Reconstruct
                        // progress from staging size and reconnect.
                        let staged = (try? fileManager.attributesOfItem(
                            atPath: resolved.stagingURL.path
                        )[.size] as? NSNumber)?.int64Value ?? 0
                        if staged > 0 {
                            resolved.progress = min(
                                Double(staged) / Double(max(resolved.expectedBytes, 1)),
                                1.0
                            )
                            resolved.state = .resuming(progress: resolved.progress)
                            _ = registerActiveTaskIfAbsent(resolved)
                            resolved.task = downloadTask
                            resolved.isPaused = false
                            resolved.state = .downloading(progress: resolved.progress)
                            reconciledKeys.insert(key)
                            persistDurableState(for: resolved)
                            updateStatus(model: resolved.model)
                            continue
                        }
                    }

                    // Nothing to anchor to — discard the system task.
                    systemTask.cancel()
        }

        // Metadata that claimed a live background task is only provisional.
        // Once URLSession enumeration completes, an unmatched entry has no
        // resumable bytes and must fail closed rather than remain a fake pause.
        let unmatched = activeTasks.filter {
            $0.value.awaitingBackgroundTaskReconciliation && !reconciledKeys.contains($0.key)
        }
        for (key, task) in unmatched {
            task.awaitingBackgroundTaskReconciliation = false
            task.state = .failed(error: .networkError)
            removeDurableState(for: task, discardStaging: false)
            activeTasks.removeValue(forKey: key)
            updateStatus(model: task.model)
        }
    }

    /// Restore durable state for a single transfer. Used by the bulk restore
    /// path and by background-task reconciliation when a system task needs a
    /// matching durable entry.
    @discardableResult
    func restoreSingleDurableTransfer(_ task: DownloadTask) -> Bool {
        guard fileManager.fileExists(atPath: task.metadataURL.path),
              let data = try? Data(contentsOf: task.metadataURL) else {
            return false
        }
        guard let snapshot = try? JSONDecoder().decode(DurableTransferSnapshot.self, from: data) else {
            // Corrupt artifact-scoped metadata cannot safely resume for any owner.
            // Remove its opaque bytes so every referring model can start cleanly.
            try? fileManager.removeItem(at: task.metadataURL)
            try? fileManager.removeItem(at: task.resumeDataURL)
            try? fileManager.removeItem(at: task.stagingURL)
            return false
        }
        guard (1...DurableTransferSnapshot.currentVersion).contains(snapshot.version),
              snapshot.artifact == (task.artifact == .base ? "base" : "mmproj"),
              snapshot.expectedBytes == task.expectedBytes,
              snapshot.expectedSHA256.map({ $0 == task.expectedSHA256 }) ?? true,
              snapshot.progress >= 0,
              snapshot.progress <= 1 else {
            // Another model can reference the same digest-addressed storage ID.
            // A mismatch is not proof that the artifact-scoped snapshot is stale.
            return false
        }

        let hasResume = fileManager.fileExists(atPath: task.resumeDataURL.path)
        let hasStaging = fileManager.fileExists(atPath: task.stagingURL.path)
        let hasResumableBytes = snapshot.resumeAvailable && (hasResume || hasStaging)
        guard hasResumableBytes || snapshot.activeBackgroundTask else {
            removeDurableState(for: task, discardStaging: false)
            return false
        }

        task.progress = snapshot.progress
        task.awaitingBackgroundTaskReconciliation = snapshot.activeBackgroundTask && !hasResumableBytes
        task.isPaused = !snapshot.failed && !task.awaitingBackgroundTaskReconciliation
        task.isChunked = hasStaging && shouldUseChunkedTransfer(for: task)
        if task.isChunked {
            task.totalChunks = Self.chunkCount(for: task.expectedBytes)
        }
        task.state = snapshot.failed
            ? .failed(error: .networkError)
            : task.awaitingBackgroundTaskReconciliation
                ? .resuming(progress: snapshot.progress)
                : .paused(progress: snapshot.progress)
        activeTasks[task.storageID] = task
        updateStatus(model: task.model)
        return true
    }
    func startArtifactDownload(
        model: AIModel,
        artifact: ArtifactType,
        skipCDNResolution: Bool = false
    ) {
        let task = DownloadTask(model: model, artifact: artifact)
        let key = task.storageID
        guard registerActiveTaskIfAbsent(task) else {
            updateStatus(model: model)
            return
        }
        noteTransferProgress(key)
        persistDurableState(for: task)
        let transferCID = DownloadDiagnosticRecorder.transferCorrelationID(modelID: model.id, artifact: artifact.label)
        DownloadDiagnosticRecorder.shared.record(
            event: .downloadStart,
            correlationID: transferCID,
            modelID: model.id,
            artifact: artifact.label,
            state: "downloading",
            expectedBytes: task.expectedBytes
        )
        if skipCDNResolution {
            transfer(task: task, key: key, downloadURL: task.sourceURL)
            return
        }
        task.resolutionTask = resolveCDNURL(
            task.sourceURL,
            modelID: model.id,
            artifact: artifact.label
        ) { [weak self, weak task] resolvedURL in
            guard let self, let task,
                  self.activeTasks[key] === task,
                  !task.isCancelled,
                  !task.isPaused else { return }
            task.resolutionTask = nil
            self.transfer(task: task, key: key, downloadURL: resolvedURL ?? task.sourceURL)
        }
    }

    /// Starts the actual byte transfer after CDN resolution (if any).
    func transfer(task: DownloadTask, key: String, downloadURL: URL) {
        guard activeTasks[key] === task, !task.isCancelled else { return }
        task.downloadURL = downloadURL
        if shouldUseChunkedTransfer(for: task) {
            // Background-session resume data belongs to the pre-chunk path and
            // cannot describe the bounded range protocol entered here.
            try? fileManager.removeItem(at: task.resumeDataURL)
            task.resumeData = nil
            task.isChunked = true
            task.totalChunks = Self.chunkCount(for: task.expectedBytes)
            self.chunkedDownload(task: task, key: key)
            return
        }
        if let resumeData = try? Data(contentsOf: task.resumeDataURL) {
            task.resumeData = resumeData
            task.task = self.getSession().downloadTask(withResumeData: resumeData)
        } else {
            task.task = self.getSession().downloadTask(with: downloadURL)
        }
        task.state = .downloading(progress: 0.0)
        self.updateStatus(model: task.model)
        task.task?.taskDescription = key
        persistDurableState(for: task)
        task.task?.resume()
    }
    func shouldUseChunkedTransfer(for task: DownloadTask) -> Bool {
        task.expectedBytes > Self.chunkedDownloadThreshold
    }

    @discardableResult
    func resolveCDNURL(
        _ url: URL,
        modelID: String,
        artifact: String,
        completion: @escaping (URL?) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        let resolutionTask = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               let location = httpResponse.value(forHTTPHeaderField: "Location"),
               let cdnURL = URL(string: location) {
                DownloadDiagnosticRecorder.shared.record(
                    event: .cdnRedirect,
                    correlationID: DownloadDiagnosticRecorder.transferCorrelationID(
                        modelID: modelID,
                        artifact: artifact
                    ),
                    modelID: modelID,
                    artifact: artifact
                )
                DispatchQueue.main.async { completion(cdnURL) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
        resolutionTask.resume()
        return resolutionTask
    }
}

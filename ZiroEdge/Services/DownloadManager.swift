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
    /// R6 pause-before-start intents keyed by artifact storage ID. See
    /// DownloadManager+ResumePolicy for the consume path.
    var pendingPauseRequests = Set<String>()
    /// In-flight tap-to-download verifications (Harden: main-thread hash).
    /// Prevents double-tap from hashing the same multi-GB artifacts twice;
    /// the first task owns the authoritative decision.
    private var pendingStartVerifications = Set<String>()
    /// P0 lint: 4-member start-verify tuple exceeded `large_tuple` (max 2).
    /// Struct is behavior-identical with the same member names so call sites read unchanged.
    private struct StartVerification: Sendable {
        let status: ModelDownloadStatus
        let baseDownloaded: Bool
        let mmprojDownloaded: Bool
        let required: Int64
    }
    /// Testing seam: forces the production async tap-verify path even under
    /// XCTest (where startDownload is otherwise synchronous for determinism).
    /// Behavior-identical in production (default false).
    var forceAsyncStartVerificationForTesting = false
    /// Whether a tap-triggered verification is currently in flight for `modelID`.
    /// Reads the double-tap dedup set; used to prove a failed/interrupted
    /// verify cannot leave a stale entry that dedupes-away a later tap.
    func isVerifyingStart(for modelID: String) -> Bool {
        pendingStartVerifications.contains(modelID)
    }
    // BATCH-05: cached storage breakdown — invalidated only on completion/promotion/quarantine/removal, computed off-main
    @Published var cachedStorageBreakdown: ManagedStorageBreakdown = ManagedStorageBreakdown(installedBytes: 0, stagingBytes: 0, resumeBytes: 0, quarantineBytes: 0)
    var storageBreakdownTask: Task<Void, Never>?
    var storageBreakdownComputeCount: Int = 0
    var lastStorageBreakdownWasOffMain: Bool?
    func resetStorageBreakdownComputeCountForTests() { storageBreakdownComputeCount = 0; lastStorageBreakdownWasOffMain = nil }
    // P3: off-main verify flag for updateStatus async refresh.
    var lastStatusRefreshWasOffMain: Bool?
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
        restoreDurableTransfers()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // Tests: historical synchronous behavior (full verification on-main).
            updateStatusesFromDisk()
            // BATCH-05: seed cache synchronously once at startup to avoid initial 0 flash; subsequent refreshes are off-main and coalesced
            cachedStorageBreakdown = managedStorageBreakdown()
            storageBreakdownComputeCount = 1
            lastStorageBreakdownWasOffMain = false
        } else {
            // Cold launch: seed from the hash-free fast path and defer every
            // heavy pass (digest verification, storage enumeration, orphan
            // reclamation, background-task reconciliation) until after first
            // frame via refreshStatusesFromDisk (driven by AppRuntime).
            seedStatusesFromDiskQuick()
            cachedStorageBreakdown = ManagedStorageBreakdown(installedBytes: 0, stagingBytes: 0, resumeBytes: 0, quarantineBytes: 0)
            storageBreakdownComputeCount = 0
            lastStorageBreakdownWasOffMain = nil
            scheduleStorageBreakdownRefresh()
        }
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
    // MARK: - Status seed/refresh moved to DownloadManager+StatusBookkeeping (P0-1 cached-status)

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
    /// Hash-free storage estimate for the tap fast-path. Mirrors
    /// `requiredDownloadBytes` but uses `isArtifactPresent` (exists + size)
    /// instead of full SHA-256 verification so the synchronous storage gate
    /// never blocks the main thread. The async verification re-checks with
    /// authoritative byte counts before starting any transfer.
    private func quickRequiredDownloadBytes(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) -> Int64 {
        func remaining(expectedBytes: Int64, stagingURL: URL, installed: Bool) -> Int64 {
            guard !installed else { return 0 }
            let staged = ((try? fileManager.attributesOfItem(atPath: stagingURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return max(0, expectedBytes - min(staged, expectedBytes))
        }
        let baseTask = DownloadTask(model: model, artifact: .base)
        var required = remaining(
            expectedBytes: baseTask.expectedBytes,
            stagingURL: baseTask.stagingURL,
            installed: ModelManagerService.isArtifactPresent(model, artifact: .base)
        )
        if model.requiresMMProj && (!model.allowsTextOnlyCapability || includeOptionalProjector) {
            let projTask = DownloadTask(model: model, artifact: .mmproj)
            let projector = remaining(
                expectedBytes: projTask.expectedBytes,
                stagingURL: projTask.stagingURL,
                installed: ModelManagerService.isArtifactPresent(model, artifact: .mmproj)
            )
            let (sum, overflow) = required.addingReportingOverflow(projector)
            if overflow { return .max }
            required = sum
        }
        guard required > 0 else { return 0 }
        let (withMargin, overflow) = required.addingReportingOverflow(storageSafetyMargin(for: required))
        return overflow ? .max : withMargin
    }

    /// Merge a hash-free disk probe with live transfer states so the tap
    /// fast-path never clobbers downloading/verifying UI with stale disk truth.
    func quickStatusMergingActiveTasks(
        for model: AIModel,
        quick: ModelDownloadStatus
    ) -> ModelDownloadStatus {
        let baseKey = artifactTaskKey(model: model, artifact: .base)
        let mmprojKey = artifactTaskKey(model: model, artifact: .mmproj)
        let baseState = activeTasks[baseKey]?.state ?? quick.baseState
        let mmprojState: DownloadState? = model.requiresMMProj
            ? (activeTasks[mmprojKey]?.state ?? quick.mmprojState)
            : nil
        return ModelDownloadStatus(
            modelID: model.id,
            baseState: baseState,
            mmprojState: mmprojState,
            baseExpectedBytes: model.baseFileSizeBytes,
            mmprojExpectedBytes: model.mmprojFileSizeBytes,
            allowsTextOnly: model.allowsTextOnlyCapability
        )
    }

    /// Synchronous legacy path for XCTest determinism. Fixtures are byte-scale
    /// so on-main SHA-256 is negligible; production uses the quick + async
    /// verify path below to keep multi-GB hashing off the main thread.
    private func startDownloadSynchronousForTests(
        for model: AIModel,
        includeOptionalProjector: Bool
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
        logger.info("Start requested: \(model.id, privacy: .public)")
        logger.info("Start scope: includeProjector=\(includeOptionalProjector, privacy: .public) requiredBytes=\(required, privacy: .public)")
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

    func startDownload(
        for model: AIModel,
        includeOptionalProjector: Bool = true
    ) {
        // Catalog gate is cheap (no I/O) — fail fast on main in all environments.
        guard model.catalogUnavailableReason == nil,
              ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels) == nil else {
            // Preserve test-observable failure shape for the invalid-catalog path.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
               !forceAsyncStartVerificationForTesting {
                startDownloadSynchronousForTests(for: model, includeOptionalProjector: includeOptionalProjector)
                return
            }
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .invalidCatalogMetadata),
                mmprojState: model.requiresMMProj ? .failed(error: .invalidCatalogMetadata) : nil
            )
            logger.error("Refusing download with invalid integrity metadata: \(model.id, privacy: .public)")
            return
        }
        // Tests: historical synchronous behavior (full verification on-main)
        // so assertions immediately after startDownload observe final truth.
        // forceAsyncStartVerificationForTesting opts back into the production
        // async path to exercise the tap-verify bookkeeping under test.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           !forceAsyncStartVerificationForTesting {
            startDownloadSynchronousForTests(for: model, includeOptionalProjector: includeOptionalProjector)
            return
        }
        // Tap fast-path: hash-free storage gate so a tap on a complete
        // multi-GB artifact never hashes on the main thread. The async phase
        // re-checks with authoritative bytes (a same-size SHA mismatch looks
        // installed to this probe but needs full bytes).
        let quickRequired = quickRequiredDownloadBytes(for: model, includeOptionalProjector: includeOptionalProjector)
        let available = availableDiskSpace
        if quickRequired >= Int64.max || available < quickRequired {
            let formattedRequired = StorageByteFormatter.string(fromByteCount: quickRequired)
            let formattedAvailable = StorageByteFormatter.string(fromByteCount: available)
            let message = "Not enough disk space: \(formattedRequired) needed, but only \(formattedAvailable) is available."
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .diskSpaceInsufficient),
                mmprojState: model.requiresMMProj ? .failed(error: .diskSpaceInsufficient) : nil
            )
            logger.error("Refusing download without sufficient free storage: \(model.id, privacy: .public) — \(message, privacy: .public)")
            DownloadDiagnosticRecorder.shared.record(
                event: .storageInsufficient,
                correlationID: DownloadDiagnosticRecorder.freshCorrelationID(),
                modelID: model.id,
                artifact: "base",
                availableStorageBytes: available,
                requiredStorageBytes: quickRequired
            )
            return
        }
        let storageCID = DownloadDiagnosticRecorder.freshCorrelationID()
        // Log the user's intent: text-only E2B requests complete with the base
        // alone, while vision requests need the pair. The pair-level observer
        // distinguishes them via isReady vs isVisionReady — never infer intent
        // from displayState alone.
        logger.info("Start requested: \(model.id, privacy: .public)")
        logger.info("Start scope: includeProjector=\(includeOptionalProjector, privacy: .public) requiredBytes=\(quickRequired, privacy: .public)")
        DownloadDiagnosticRecorder.shared.record(
            event: .storageCheck,
            correlationID: storageCID,
            modelID: model.id,
            artifact: "base",
            availableStorageBytes: available,
            requiredStorageBytes: quickRequired
        )
        startStuckWatchdog()
        // Fast-path publish: hash-free quick status merged with live transfers.
        // Matches the launch-defer pattern (seedStatusesFromDiskQuick): instant
        // UI, authoritative truth arrives async and corrects any optimistic
        // `.downloaded` (hash mismatch surfaces as repair there).
        let quick = Self.quickDiskStatus(for: model)
        downloadStatuses[model.id] = quickStatusMergingActiveTasks(for: model, quick: quick)
        // Dedupe double-tap: the first verification owns the decision.
        guard pendingStartVerifications.insert(model.id).inserted else { return }
        launchAsyncStartVerification(for: model, includeOptionalProjector: includeOptionalProjector, storageCID: storageCID, available: available)
    }

    /// Async authoritative verification off-main (extracted to keep `startDownload` within limits).
    private func launchAsyncStartVerification(
        for model: AIModel,
        includeOptionalProjector: Bool,
        storageCID: String,
        available: Int64
    ) {
        // Authoritative SHA-256 off-main; every UI publish hops back to main.
        // Mirrors refreshStatusesFromDisk: detached utility work, MainActor publish.
        Task { [weak self, model, includeOptionalProjector, storageCID, available] in
            let verified = await Task.detached(priority: .utility) { () -> StartVerification in
                let status = DownloadManager.diskStatus(for: model)
                // Share the mtime+size digest cache with the status above, so
                // these are cache hits — not second hashes — while still
                // applying quarantine side effects for corrupt artifacts.
                let baseDownloaded = ModelManagerService.isBaseDownloaded(model)
                let mmprojDownloaded = ModelManagerService.isMMProjDownloaded(model)
                func remaining(expected: Int64, staging: URL, installed: Bool) -> Int64 {
                    guard !installed else { return 0 }
                    let staged = ((try? FileManager.default.attributesOfItem(atPath: staging.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    return max(0, expected - min(staged, expected))
                }
                let baseTask = DownloadTask(model: model, artifact: .base)
                var req = remaining(expected: baseTask.expectedBytes, staging: baseTask.stagingURL, installed: baseDownloaded)
                if model.requiresMMProj && (!model.allowsTextOnlyCapability || includeOptionalProjector) {
                    let projTask = DownloadTask(model: model, artifact: .mmproj)
                    let proj = remaining(expected: projTask.expectedBytes, staging: projTask.stagingURL, installed: mmprojDownloaded)
                    let (sum, overflow) = req.addingReportingOverflow(proj)
                    req = overflow ? .max : sum
                }
                if req > 0 {
                    let margin = max(req / 20, DownloadManager.storageSafetyMarginBytes)
                    let (withMargin, overflow) = req.addingReportingOverflow(margin)
                    req = overflow ? .max : withMargin
                }
                return StartVerification(status: status, baseDownloaded: baseDownloaded, mmprojDownloaded: mmprojDownloaded, required: req)
            }.value
            guard let self else {
                // Owner deallocated mid-verify: the dedup set dies with the
                // instance, so no stale entry can outlive self to block a
                // later tap on a fresh manager.
                return
            }
            // Single cleanup point for every exit below (storage refusal,
            // already-ready, already-downloading, success). A stale entry
            // would permanently dedupe later taps for this artifact, so the
            // removal must not sit ahead of — or behind — any early return.
            // Defer also runs it after the final publish, so observers never
            // see "not verifying" before the verified status lands.
            defer { self.pendingStartVerifications.remove(model.id) }
            // Authoritative storage re-check: the quick gate is optimistic.
            if verified.required >= Int64.max || available < verified.required {
                let formattedRequired = StorageByteFormatter.string(fromByteCount: verified.required)
                let formattedAvailable = StorageByteFormatter.string(fromByteCount: available)
                let message = "Not enough disk space: \(formattedRequired) needed, but only \(formattedAvailable) is available."
                let baseKey = self.artifactTaskKey(model: model, artifact: .base)
                let mmprojKey = self.artifactTaskKey(model: model, artifact: .mmproj)
                if self.activeTasks[baseKey] == nil && self.activeTasks[mmprojKey] == nil {
                    self.downloadStatuses[model.id] = ModelDownloadStatus(
                        modelID: model.id,
                        baseState: .failed(error: .diskSpaceInsufficient),
                        mmprojState: model.requiresMMProj ? .failed(error: .diskSpaceInsufficient) : nil
                    )
                }
                self.logger.error("Refusing download without sufficient free storage: \(model.id, privacy: .public) — \(message, privacy: .public)")
                DownloadDiagnosticRecorder.shared.record(
                    event: .storageInsufficient,
                    correlationID: storageCID,
                    modelID: model.id,
                    artifact: "base",
                    availableStorageBytes: available,
                    requiredStorageBytes: verified.required
                )
                return
            }
            // Publish verified truth merged with any transfers that started
            // in the race window; complete vs partial drives identical starts.
            let merged = self.quickStatusMergingActiveTasks(for: model, quick: verified.status)
            self.downloadStatuses[model.id] = merged
            let requestedCapabilityReady = model.allowsTextOnlyCapability && includeOptionalProjector
                ? merged.isVisionReady
                : merged.isReady
            guard !requestedCapabilityReady, !merged.isDownloading else { return }
            ModelManagerService.ensureModelsDirectory()
            if !verified.baseDownloaded {
                self.startArtifactDownload(model: model, artifact: .base)
            }
            if model.requiresMMProj,
               (!model.allowsTextOnlyCapability || includeOptionalProjector),
               !verified.mmprojDownloaded {
                self.startArtifactDownload(model: model, artifact: .mmproj)
            }
        }
    }

    // MARK: - Pause/Resume/Retry moved to DownloadManager+StatusBookkeeping (file-length)
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
                // S1+S2+S3+S5: candidacy (chunked included, resuming and
                // CDN-resolution included, missing heartbeat trips) lives in
                // stuckTransferKeys so the timer body cannot diverge from tests.
                for key in self.stuckTransferKeys(now: now) {
                    guard let task = self.activeTasks[key] else { continue }
                    let elapsed = now.timeIntervalSince(self.watchdogHeartbeat(forKey: key))
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
    /// Stops the stuck-transfer watchdog once nothing needs it. Without
    /// this the repeating timer fires every 30 s for the rest of the app's
    /// lifetime after the last transfer ends. No-op while watchdog candidates
    /// (downloading/resuming/resolving) remain — paused entries alone must
    /// not pin the timer. Safe to call from every task-completion path.
    func stopStuckWatchdogIfIdle() {
        guard !hasWatchdogCandidates else { return }
        stuckTimer?.invalidate()
        stuckTimer = nil
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
        stopStuckWatchdogIfIdle()
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
        logger.info("Starting artifact: \(key, privacy: .public) expectedBytes=\(task.expectedBytes)")
        DownloadDiagnosticRecorder.shared.record(
            event: .downloadStart,
            correlationID: transferCID,
            modelID: model.id,
            artifact: artifact.label,
            state: "downloading",
            expectedBytes: task.expectedBytes
        )
        let canonicalURL: URL
        do {
            canonicalURL = try task.trySourceURL()
        } catch {
            task.state = .failed(error: .missingMmprojURL(modelID: model.id))
            updateStatus(model: model)
            activeTasks.removeValue(forKey: key)
            logger.error("Missing mmproj URL for model: \(model.id, privacy: .public)")
            return
        }
        if skipCDNResolution {
            transfer(task: task, key: key, downloadURL: canonicalURL)
            return
        }
        task.resolutionTask = resolveCDNURL(
            canonicalURL,
            modelID: model.id,
            artifact: artifact.label
        ) { [weak self, weak task] resolvedURL in
            guard let self, let task,
                  self.activeTasks[key] === task,
                  !task.isCancelled,
                  !task.isPaused else { return }
            task.resolutionTask = nil
            self.transfer(task: task, key: key, downloadURL: resolvedURL ?? canonicalURL)
        }
    }

    /// Starts the actual byte transfer after CDN resolution (if any).
    func transfer(task: DownloadTask, key: String, downloadURL: URL) {
        guard activeTasks[key] === task, !task.isCancelled else { return }
        // R6: a pause that arrived before this transfer existed wins over bytes.
        if consumePendingPause(key: key) {
            task.isPaused = true
            task.state = .paused(progress: task.progress)
            persistDurableState(for: task)
            updateStatus(model: task.model)
            return
        }
        // R5: never send bytes to a non-allowlisted host; fail closed to
        // the canonical catalog URL instead of following it.
        let gatedURL = Self.isAllowedDownloadURL(downloadURL) ? downloadURL : task.sourceURL
        task.downloadURL = gatedURL
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
        if let resumeData = loadFreshResumeData(for: task) {
            // R1+R2: only fresh, non-empty blobs resume; stale/corrupt ones
            // were already discarded inside loadFreshResumeData.
            task.resumeData = resumeData
            task.task = self.getSession().downloadTask(withResumeData: resumeData)
            // Best-effort resume point from cumulative progress. The exact
            // server-side start is unknowable from opaque resume data, so
            // transport validation only requires a COMPLETE body here and the
            // artifact SHA-256 gate enforces integrity afterwards.
            task.transferStartOffset = Int64((task.progress * Double(task.expectedBytes)).rounded())
            // R3: keep the resume point visible — resetting to 0 flashes the
            // progress UI back to empty on every resume.
            task.state = .downloading(progress: task.progress)
        } else {
            task.resumeData = nil
            task.transferStartOffset = 0
            task.task = self.getSession().downloadTask(with: gatedURL)
            task.state = .downloading(progress: 0.0)
        }
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

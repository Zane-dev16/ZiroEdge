// DownloadManager.swift
// ZiroEdge — Privacy-first local AI assistant
//
// URLSession-based download manager with pause/resume, progress tracking,
// cellular data detection, storage checking, and partial file cleanup.
import Foundation
import Network
import CryptoKit
import os
// MARK: - Download Task Wrapper
/// Internal wrapper tracking a single artifact download.
final class DownloadTask {
    let model: AIModel
    let artifact: ArtifactType
    var task: URLSessionDownloadTask?
    var chunkTask: URLSessionDataTask?
    var resumeData: Data?
    var progress: Double = 0.0
    var state: DownloadState = .notDownloaded
    // Chunked downloads use a staging file so partially written bytes can be
    // resumed without ever exposing an unverified model as installed.
    var isChunked = false
    var currentChunkOffset: Int64 = 0
    var currentChunkIndex: Int64 = 0
    var totalChunks: Int64 = 0
    var chunkRetryCount = 0
    var downloadURL: URL?
    var isPaused = false
    var isCancelled = false
    var chunkFileHandle: FileHandle?
    var currentChunkEnd: Int64 = 0
    var chunkBytesReceived: Int64 = 0
    var chunkResponseValidated = false
    var chunkFailureReason: String?
    init(model: AIModel, artifact: ArtifactType) {
        self.model = model
        self.artifact = artifact
    }
    var destinationURL: URL {
        switch artifact {
        case .base:
            return ModelManagerService.baseModelPath(for: model)
        case .mmproj:
            return ModelManagerService.mmprojModelPath(for: model)
        }
    }
    var sourceURL: URL {
        switch artifact {
        case .base:
            return model.baseURL
        case .mmproj:
            guard let url = model.mmprojURL else {
                fatalError("DownloadTask .mmproj for model '\(model.id)' with no mmprojURL")
            }
            return url
        }
    }
    var expectedSHA256: String {
        switch artifact {
        case .base:
            return model.baseSHA256
        case .mmproj:
            return model.mmprojSHA256 ?? ""
        }
    }
    var expectedBytes: Int64 {
        switch artifact {
        case .base:
            return model.baseFileSizeBytes
        case .mmproj:
            return model.mmprojFileSizeBytes ?? 0
        }
    }
    /// Canonical identity for the physical artifact. Catalog variants that share
    /// a base model must coordinate through the same task, staging, and resume keys.
    var storageID: String {
        switch artifact {
        case .base:
            return "base-\(model.baseArtifactStorageID)"
        case .mmproj:
            if let digest = model.mmprojSHA256 { return "mmproj-hf-\(digest.prefix(24))" }
            return "mmproj-\(model.id)"
        }
    }
    /// Resume data file path for persistence across app restarts.
    var resumeDataURL: URL {
        ModelManagerService.modelsDirectory
            .appendingPathComponent("\(storageID)-resume.dat")
    }
    /// In-progress bytes are kept separate from the installed artifact.
    var stagingURL: URL {
        destinationURL.appendingPathExtension("tmp")
    }
}
// MARK: - Network Monitor
/// Simple cellular data detector using NWPathMonitor.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnCellular = false
    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.zanish-labs.ziroedge.network-monitor")
    init(startMonitoring: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.isOnCellular = path.usesInterfaceType(.cellular)
            }
        }
        monitor.start(queue: queue)
    }
    deinit {
        monitor.cancel()
    }
}
// MARK: - Download Manager
/// Manages model file downloads with progress, pause/resume, and verification.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    // MARK: - Published State
    /// Download statuses keyed by model ID.
    @Published private(set) var downloadStatuses: [String: ModelDownloadStatus] = [:]
    /// Active downloads keyed by canonical physical-artifact identity, never catalog model ID.
    private var activeTasks: [String: DownloadTask] = [:]
    /// Network connectivity monitor.
    let networkMonitor = NetworkMonitor()
    // MARK: - Private
    private var _urlSession: URLSession?
    private func getSession() -> URLSession {
        if let existing = _urlSession { return existing }
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        _urlSession = session
        return session
    }
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "download")
    private let fileManager = FileManager.default
    private let availableDiskSpaceProvider: @MainActor () -> Int64
    private static let chunkSize: Int64 = 100 * 1_024 * 1_024
    private static let chunkedDownloadThreshold: Int64 = 2_147_483_648
    private static let maximumChunkRetries = 3
    // MARK: - Initialization
    override convenience init() {
        self.init(availableDiskSpaceProvider: nil)
    }

    init(availableDiskSpaceProvider: (@MainActor () -> Int64)?) {
        self.availableDiskSpaceProvider = availableDiskSpaceProvider ?? {
            guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return 0 }
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        }
        super.init()
        ModelManagerService.ensureModelsDirectory()
        updateStatusesFromDisk()
    }
    deinit {
        MainActor.assumeIsolated {
            _urlSession?.invalidateAndCancel()
            stuckTimer?.invalidate()
        }
    }
    // MARK: - Status Queries
    /// Get download status for a model. Falls back to disk check when
    /// no cached download task exists.
    func status(for model: AIModel) -> ModelDownloadStatus {
        if let cached = downloadStatuses[model.id] { return cached }
        return authoritativeDiskStatus(for: model)
    }
    /// Check disk and update statuses for all registered models.
    func updateStatusesFromDisk() {
        for model in ModelRegistry.libraryModels {
            downloadStatuses[model.id] = authoritativeDiskStatus(for: model)
        }
    }
    private func authoritativeDiskStatus(for model: AIModel) -> ModelDownloadStatus {
        switch ModelManagerService.availability(for: model) {
        case .ready:
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .downloaded,
                mmprojState: model.requiresMMProj ? .downloaded : nil
            )
        case .unavailable:
            let baseTask = DownloadTask(model: model, artifact: .base)
            let baseState = recoveredState(for: baseTask)
            let projectorState = model.requiresMMProj
                ? recoveredState(for: DownloadTask(model: model, artifact: .mmproj))
                : nil
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: baseState,
                mmprojState: projectorState
            )
        case .repairNeeded:
            // Preserve verified counterparts while also recovering durable staging
            // and resume state for missing or invalid artifacts.
            let baseTask = DownloadTask(model: model, artifact: .base)
            let baseState: DownloadState = ModelManagerService.isBaseDownloaded(model)
                ? .downloaded
                : recoveredState(for: baseTask)
            let projectorState: DownloadState? = model.requiresMMProj
                ? (ModelManagerService.isMMProjDownloaded(model)
                    ? .downloaded
                    : recoveredState(for: DownloadTask(model: model, artifact: .mmproj)))
                : nil
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: baseState,
                mmprojState: projectorState
            )
        }
    }
    // MARK: - Storage Check
    /// Available disk space in bytes.
    var availableDiskSpace: Int64 { availableDiskSpaceProvider() }

    func storageSafetyMargin(for requiredBytes: Int64) -> Int64 {
        max(requiredBytes / 20, 500_000_000)
    }
    /// Whether the device has enough space for the artifacts that are still missing.
    /// Installed verified artifacts are reused and are never staged a second time.
    func hasSufficientStorage(for model: AIModel) -> Bool {
        let required = requiredDownloadBytes(for: model)
        guard required >= 0, required < Int64.max else { return false }
        let (total, overflow) = required.addingReportingOverflow(storageSafetyMargin(for: required))
        return !overflow && availableDiskSpace >= total
    }
    func requiredDownloadBytes(for model: AIModel) -> Int64 {
        // These checks include the catalog SHA-256. A same-size GGUF with the
        // wrong digest needs a complete replacement and therefore full staging space.
        let required: Int64 = ModelManagerService.isBaseDownloaded(model)
            ? 0 : model.baseFileSizeBytes
        if model.requiresMMProj, !ModelManagerService.isMMProjDownloaded(model) {
            let (sum, overflow) = required.addingReportingOverflow(model.mmprojFileSizeBytes ?? 0)
            return overflow ? .max : sum
        }
        return required
    }
    /// Formatted available disk space without shared formatter state.
    func formattedAvailableSpace() -> String {
        let bytes = max(availableDiskSpace, 0)
        let units: [(threshold: Int64, suffix: String)] = [
            (1_000_000_000, "GB"),
            (1_000_000, "MB"),
            (1_000, "KB")
        ]
        guard let unit = units.first(where: { bytes >= $0.threshold }) else {
            return "\(bytes) bytes"
        }
        let value = Double(bytes) / Double(unit.threshold)
        return String(format: "%.1f %@", value, unit.suffix)
    }
    private func recoveredState(for task: DownloadTask) -> DownloadState {
        guard fileManager.fileExists(atPath: task.stagingURL.path) || fileManager.fileExists(atPath: task.resumeDataURL.path) else {
            return .notDownloaded
        }
        let size = ((try? fileManager.attributesOfItem(atPath: task.stagingURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let progress = task.expectedBytes > 0 ? min(Double(size) / Double(task.expectedBytes), 1) : 0
        return .paused(progress: progress)
    }

    // MARK: - Download Actions

    /// Start downloading a model. Shows cellular warning if needed.
    func startDownload(for model: AIModel) {
        guard hasSufficientStorage(for: model) else {
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .diskSpaceInsufficient),
                mmprojState: model.requiresMMProj ? .failed(error: .diskSpaceInsufficient) : nil
            )
            logger.error("Refusing download without sufficient free storage: \(model.id, privacy: .public)")
            return
        }
        guard ModelManagerService.isValidSHA256(model.baseSHA256),
              !model.requiresMMProj || model.mmprojSHA256.map(ModelManagerService.isValidSHA256) == true else {
            downloadStatuses[model.id] = ModelDownloadStatus(
                modelID: model.id,
                baseState: .failed(error: .invalidCatalogMetadata),
                mmprojState: model.requiresMMProj ? .failed(error: .invalidCatalogMetadata) : nil
            )
            logger.error("Refusing download with invalid integrity metadata: \(model.id, privacy: .public)")
            return
        }
        print("[DL-START] startDownload: \(model.id) url=\(model.baseURL.absoluteString)")
        ZiroEdgeApp.diagnosticLog("[DL-START] startDownload: \(model.id) url=\(model.baseURL.absoluteString)")
        startStuckWatchdog()
        let currentStatus = authoritativeDiskStatus(for: model)
        downloadStatuses[model.id] = currentStatus
        print("[DL-START] \(model.id): isReady=\(currentStatus.isReady) isDownloading=\(currentStatus.isDownloading)")
        guard !currentStatus.isReady, !currentStatus.isDownloading else { return }

        ModelManagerService.ensureModelsDirectory()

        if !ModelManagerService.isBaseDownloaded(model) {
            print("[DL-START] \(model.id): starting base download")
            startArtifactDownload(model: model, artifact: .base)
        }

        if model.requiresMMProj, !ModelManagerService.isMMProjDownloaded(model) {
            print("[DL-START] \(model.id): starting mmproj download")
            startArtifactDownload(model: model, artifact: .mmproj)
        }
    }

    /// Pause an active download.
    func pauseDownload(for model: AIModel) {
        pauseArtifactDownload(model: model, artifact: .base)
        if model.requiresMMProj {
            pauseArtifactDownload(model: model, artifact: .mmproj)
        }
        updateStatus(model: model)
    }

    private func pauseArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let downloadTask = activeTasks[key], downloadTask.model.id == model.id else { return }

        downloadTask.isPaused = true
        downloadTask.state = .paused(progress: downloadTask.progress)

        if downloadTask.isChunked {
            downloadTask.chunkTask?.cancel()
            downloadTask.chunkTask = nil
            closeChunkFile(for: downloadTask)
            print("[DL-CHUNK] \(key): paused at offset \(downloadTask.currentChunkOffset)")
            return
        }

        downloadTask.task?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, let pausedTask = self.activeTasks[key], pausedTask.isPaused else { return }
                pausedTask.resumeData = data
                if let data { try? data.write(to: pausedTask.resumeDataURL) }
                pausedTask.state = .paused(progress: pausedTask.progress)
                self.updateStatus(model: model)
            }
        })
    }

    /// Resume a paused download.
    func resumeDownload(for model: AIModel) {
        resumeArtifactDownload(model: model, artifact: .base)
        if model.requiresMMProj {
            resumeArtifactDownload(model: model, artifact: .mmproj)
        }
    }

    /// Cancel and clean up a download.
    func cancelDownload(for model: AIModel) {
        cancelArtifactDownload(model: model, artifact: .base)
        if model.requiresMMProj {
            cancelArtifactDownload(model: model, artifact: .mmproj)
        }
        updateStatus(model: model)
    }

    /// Delete a downloaded model and clean up.
    func deleteModel(_ model: AIModel) {
        cancelDownload(for: model)
        ModelManagerService.deleteModel(model)

        // Shared resume state belongs to the physical base, not either catalog entry.
        if !ModelManagerService.isBaseArtifactShared(model) {
            try? fileManager.removeItem(at: DownloadTask(model: model, artifact: .base).resumeDataURL)
        }
        if model.requiresMMProj {
            try? fileManager.removeItem(at: DownloadTask(model: model, artifact: .mmproj).resumeDataURL)
        }

        // Recompute every library entry because another entry may share an artifact.
        updateStatusesFromDisk()
        downloadStatuses[model.id] = authoritativeDiskStatus(for: model)
    }

    // MARK: - Repair

    /// Repair a partially downloaded or corrupt model by downloading only the
    /// missing or invalid artifacts. Preserves the verified counterpart so a
    /// vision model with only a broken projector downloads just the projector.
    func repairDownload(for model: AIModel) {
        let availability = ModelManagerService.availability(for: model)
        guard case .repairNeeded(let issues) = availability else {
            logger.info("repairDownload: model \(model.id) does not need repair")
            return
        }

        logger.info("repairDownload: repairing \(model.id) with issues: \(issues.map { String(describing: $0) }.joined(separator: ", "))")

        let baseNeedsRepair = issues.contains { issue in
            switch issue {
            case .missing(artifact: .base), .sha256Mismatch, .sizeMismatch, .missingGGUFHeader, .fileNotFound:
                return true
            case .missing(artifact: .mmproj), .unknown:
                return false
            }
        }
        let hasBaseFile = FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path)

        // Only re-download base if it's missing or failed validation.
        // A verified counterpart is preserved.
        if baseNeedsRepair || (!hasBaseFile && !ModelManagerService.isBaseDownloaded(model)) {
            // Remove the corrupt base before re-downloading.
            if hasBaseFile {
                try? fileManager.removeItem(at: ModelManagerService.baseModelPath(for: model))
            }
            startArtifactDownload(model: model, artifact: .base)
        }

        // For vision models, also check the projector.
        if model.requiresMMProj {
            let mmprojNeedsRepair = issues.contains { issue in
                switch issue {
                case .missing(artifact: .mmproj), .sha256Mismatch, .sizeMismatch, .missingGGUFHeader, .fileNotFound:
                    return true
                case .missing(artifact: .base), .unknown:
                    return false
                }
            }
            let hasMMProjFile = FileManager.default.fileExists(atPath: ModelManagerService.mmprojModelPath(for: model).path)
            if mmprojNeedsRepair || (!hasMMProjFile && !ModelManagerService.isMMProjDownloaded(model)) {
                if hasMMProjFile {
                    try? fileManager.removeItem(at: ModelManagerService.mmprojModelPath(for: model))
                }
                startArtifactDownload(model: model, artifact: .mmproj)
            }
        }
    }

    // MARK: - Atomic Paired Vision Update

    /// Stage a paired vision-model update. Both the new base and new projector
    /// download to staging paths that do not collide with the installed pair.
    /// The installed pair remains usable until both staged artifacts pass all
    /// checks and are promoted together.
    func startPairedUpdate(for stagedModel: AIModel) {
        guard stagedModel.requiresMMProj else {
            // Text-only models use the standard download path.
            startDownload(for: stagedModel)
            return
        }

        // Verify both artifacts have valid integrity metadata.
        guard ModelManagerService.isValidSHA256(stagedModel.baseSHA256),
              let mmprojSHA = stagedModel.mmprojSHA256,
              ModelManagerService.isValidSHA256(mmprojSHA) else {
            downloadStatuses[stagedModel.id] = ModelDownloadStatus(
                modelID: stagedModel.id,
                baseState: .failed(error: .invalidCatalogMetadata),
                mmprojState: .failed(error: .invalidCatalogMetadata)
            )
            return
        }

        // Check storage for both artifacts simultaneously.
        let requiredBytes = stagedModel.baseFileSizeBytes + (stagedModel.mmprojFileSizeBytes ?? 0)
        let safetyMargin = storageSafetyMargin(for: requiredBytes)
        let totalNeeded = requiredBytes + safetyMargin
        guard availableDiskSpace >= totalNeeded else {
            downloadStatuses[stagedModel.id] = ModelDownloadStatus(
                modelID: stagedModel.id,
                baseState: .failed(error: .diskSpaceInsufficient),
                mmprojState: .failed(error: .diskSpaceInsufficient)
            )
            logger.error("Refusing paired update without sufficient storage for both artifacts: \(stagedModel.id)")
            return
        }

        print("[DL-PAIRED] startPairedUpdate: \(stagedModel.id)")
        startStuckWatchdog()
        ModelManagerService.ensureModelsDirectory()

        // Start both downloads. The staging paths are digest-addressed and
        // do not collide with the currently installed pair.
        startArtifactDownload(model: stagedModel, artifact: .base)
        startArtifactDownload(model: stagedModel, artifact: .mmproj)
    }

    /// Check if a paired vision update has both artifacts fully verified.
    /// Returns true only when both base and projector pass all checks.
    func isPairedUpdateReady(_ model: AIModel) -> Bool {
        guard model.requiresMMProj else {
            return ModelManagerService.isBaseDownloaded(model)
        }
        return ModelManagerService.isBaseDownloaded(model)
            && ModelManagerService.isMMProjDownloaded(model)
    }

    // MARK: - Private Helpers

    /// Tracks last progress time per task for stuck-download detection.
    private var lastProgressTime: [String: Date] = [:]
    private var stuckTimer: Timer?

    /// Start a watchdog that detects stuck downloads (no progress for 60s).
    private func startStuckWatchdog() {
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
                        print("[DL-STUCK] \(key): no progress for \(Int(elapsed))s, cancelling and retrying")
                        self.lastProgressTime.removeValue(forKey: key)
                        task.task?.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            print("[DL-STUCK] \(key): retrying download")
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

    private func artifactTaskKey(model: AIModel, artifact: ArtifactType) -> String {
        DownloadTask(model: model, artifact: artifact).storageID
    }

    /// Atomically claims a physical artifact for one writer. Kept internal so
    /// regression tests can prove shared catalog variants cannot create two writers.
    @discardableResult
    func registerActiveTaskIfAbsent(_ task: DownloadTask) -> Bool {
        guard activeTasks[task.storageID] == nil else { return false }
        activeTasks[task.storageID] = task
        return true
    }

    func hasActiveDownload(model: AIModel, artifact: ArtifactType) -> Bool {
        activeTasks[artifactTaskKey(model: model, artifact: artifact)] != nil
    }

    private func startArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let task = DownloadTask(model: model, artifact: artifact)
        let key = task.storageID
        guard registerActiveTaskIfAbsent(task) else {
            // Another catalog entry already owns this physical artifact. Its
            // state is visible through the shared key; never race its .tmp file.
            updateStatus(model: model)
            return
        }
        lastProgressTime[key] = Date()
        print("[DL-START] \(key): url=\(task.sourceURL.absoluteString) expectedBytes=\(task.expectedBytes)")
        ZiroEdgeApp.diagnosticLog("[DL-START] \(key): expectedBytes=\(task.expectedBytes)")

        // Resolve the CDN URL to bypass the302 redirect. Large file downloads
        // can hang when URLSession follows the redirect on iOS.
        resolveCDNURL(task.sourceURL) { [weak self] resolvedURL in
            guard let self else { return }
            let downloadURL = resolvedURL ?? task.sourceURL
            print("[DL-START] \(key): resolvedURL=\(downloadURL.absoluteString.prefix(80))")

            task.downloadURL = downloadURL

            if task.expectedBytes > Self.chunkedDownloadThreshold {
                task.isChunked = true
                task.totalChunks = (task.expectedBytes + Self.chunkSize - 1) / Self.chunkSize
                print("[DL-CHUNK] \(key): using \(task.totalChunks) chunks of \(Self.chunkSize) bytes")
                self.chunkedDownload(task: task, key: key)
                return
            }

            // Check for resume data for the existing regular download path.
            if let resumeData = try? Data(contentsOf: task.resumeDataURL) {
                task.resumeData = resumeData
                task.task = self.getSession().downloadTask(withResumeData: resumeData)
                print("[DL-START] \(key): resuming from resume data")
            } else {
                task.task = self.getSession().downloadTask(with: downloadURL)
                print("[DL-START] \(key): fresh download")
            }

            task.state = .downloading(progress: 0.0)
            self.updateStatus(model: model)

            task.task?.taskDescription = key
            task.task?.resume()
            print("[DL-START] \(key): task resumed")
        }
    }

    /// Resolve a Hugging Face URL to its CDN URL to bypass the 302 redirect.
    /// This prevents large file downloads from hanging on iOS.
    private func resolveCDNURL(_ url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse,
               let location = httpResponse.value(forHTTPHeaderField: "Location"),
               let cdnURL = URL(string: location) {
                print("[DL-RESOLVE] CDN URL: \(cdnURL.absoluteString.prefix(80))")
                DispatchQueue.main.async { completion(cdnURL) }
            } else {
                print("[DL-RESOLVE] No redirect, using original URL")
                if let error {
                    print("[DL-RESOLVE] Error: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }

}

// MARK: - Chunked Download Helpers

extension DownloadManager {

    /// Download the next 100 MB range, resuming from complete chunks already
    /// present in the staging file.
    private func chunkedDownload(task: DownloadTask, key: String) {
        guard activeTasks[key] === task,
              !task.isPaused,
              !task.isCancelled,
              task.chunkTask == nil else { return }

        do {
            let stagedBytes = try resumableChunkOffset(for: task)
            task.currentChunkOffset = stagedBytes
            task.currentChunkIndex = stagedBytes / Self.chunkSize

            if stagedBytes == task.expectedBytes {
                print("[DL-CHUNK] \(key): all bytes already staged; verifying")
                finishChunkedDownload(task: task, key: key)
                return
            }

            guard stagedBytes < task.expectedBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let end = min(stagedBytes + Self.chunkSize - 1, task.expectedBytes - 1)
            var request = URLRequest(url: task.downloadURL ?? task.sourceURL)
            request.setValue("bytes=\(stagedBytes)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 300

            task.state = .downloading(progress: Double(stagedBytes) / Double(task.expectedBytes))
            task.progress = Double(stagedBytes) / Double(task.expectedBytes)
            updateStatus(model: task.model)
            lastProgressTime[key] = Date()

            print("[DL-CHUNK] \(key): starting chunk \(task.currentChunkIndex + 1)/\(task.totalChunks), bytes=\(stagedBytes)-\(end), retry=\(task.chunkRetryCount)")

            let handle = try FileHandle(forWritingTo: task.stagingURL)
            try handle.seek(toOffset: UInt64(stagedBytes))
            task.chunkFileHandle = handle
            task.currentChunkEnd = end
            task.chunkBytesReceived = 0
            task.chunkResponseValidated = false
            task.chunkFailureReason = nil

            let dataTask = getSession().dataTask(with: request)
            task.chunkTask = dataTask
            dataTask.taskDescription = key
            dataTask.resume()
        } catch {
            failChunkedDownload(task: task, key: key, error: error)
        }
    }

    /// Return the last complete chunk boundary. A crash during a write can
    /// leave a partial chunk, which is truncated and fetched again.
    private func resumableChunkOffset(for task: DownloadTask) throws -> Int64 {
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
            print("[DL-CHUNK] truncated partial staging data from \(size) to \(validSize) bytes")
        }
        return validSize
    }

    private func closeChunkFile(for task: DownloadTask, synchronize: Bool = false) {
        guard let handle = task.chunkFileHandle else { return }
        if synchronize {
            try? handle.synchronize()
        }
        try? handle.close()
        task.chunkFileHandle = nil
    }

    private func completeChunk(task: DownloadTask, key: String) {
        let completedBytes = task.currentChunkEnd + 1
        task.currentChunkOffset = completedBytes
        task.currentChunkIndex = (completedBytes + Self.chunkSize - 1) / Self.chunkSize
        task.chunkRetryCount = 0
        task.progress = Double(completedBytes) / Double(task.expectedBytes)
        task.state = .downloading(progress: task.progress)
        lastProgressTime[key] = Date()
        updateStatus(model: task.model)
        print("[DL-CHUNK] \(key): completed chunk \(task.currentChunkIndex)/\(task.totalChunks), overall=\(Int(task.progress * 100))%")

        if completedBytes == task.expectedBytes {
            finishChunkedDownload(task: task, key: key)
        } else {
            chunkedDownload(task: task, key: key)
        }
    }

    private func contentRange(
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

    private func retryChunk(task: DownloadTask, key: String, reason: String) {
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
        print("[DL-CHUNK] \(key): chunk \(task.currentChunkIndex + 1) failed: \(reason); retry \(task.chunkRetryCount)/\(Self.maximumChunkRetries) in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak task] in
            guard let self, let task else { return }
            self.chunkedDownload(task: task, key: key)
        }
    }

    private func finishChunkedDownload(task: DownloadTask, key: String) {
        closeChunkFile(for: task, synchronize: true)
        print("[DL-CHUNK] \(key): all \(task.totalChunks) chunks complete; verifying SHA-256")
        _ = verifyAndPromote(task: task)
        updateStatus(model: task.model)
        activeTasks.removeValue(forKey: key)
        lastProgressTime.removeValue(forKey: key)
    }

    private func failChunkedDownload(task: DownloadTask, key: String, error: Error) {
        guard activeTasks[key] === task else { return }
        closeChunkFile(for: task)
        task.chunkTask = nil
        task.state = .failed(error: .networkError)
        print("[DL-CHUNK] \(key): failed; staged bytes retained for resume: \(error.localizedDescription)")
        updateStatus(model: task.model)
        activeTasks.removeValue(forKey: key)
        lastProgressTime.removeValue(forKey: key)
    }

    private func resumeArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        guard let task = activeTasks[key] else {
            startArtifactDownload(model: model, artifact: artifact)
            return
        }
        guard task.model.id == model.id else { return }

        task.isPaused = false
        task.isCancelled = false

        if task.isChunked {
            task.state = .downloading(progress: task.progress)
            updateStatus(model: model)
            print("[DL-CHUNK] \(key): resuming chunked download")
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

    private func cancelArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = artifactTaskKey(model: model, artifact: artifact)
        let diskTask = DownloadTask(model: model, artifact: artifact)

        // A sibling catalog entry may observe a shared active download, but only
        // the entry that claimed the writer may cancel and discard its state.
        if let task = activeTasks[key] {
            guard task.model.id == model.id else { return }
            task.isCancelled = true
            task.task?.cancel()
            task.chunkTask?.cancel()
            closeChunkFile(for: task)
            task.state = .cancelled
            activeTasks.removeValue(forKey: key)
        }

        // Cancellation also cleans durable state recovered after relaunch, when
        // there is no in-memory active task to cancel.
        try? fileManager.removeItem(at: diskTask.stagingURL)
        try? fileManager.removeItem(at: diskTask.resumeDataURL)
        logger.info("Cancelled download: \(key, privacy: .public)")
    }

    /// Verify staged bytes before promoting them to the installed path.
    @discardableResult
    func verifyAndPromote(task: DownloadTask) -> Result<Void, DownloadError> {
        task.state = .verifying
        updateStatus(model: task.model)

        do {
            let attributes = try fileManager.attributesOfItem(atPath: task.stagingURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard task.expectedBytes <= 0 || actualBytes == task.expectedBytes else {
                print("[DL-CHUNK] verification failed: size \(actualBytes), expected \(task.expectedBytes)")
                task.state = .failed(error: .fileCorrupted)
                try? fileManager.removeItem(at: task.stagingURL)
                return .failure(.fileCorrupted)
            }

            guard ModelManagerService.verifyGGUFHeader(fileURL: task.stagingURL) else {
                task.state = .failed(error: .structureInvalid(reason: "missing GGUF magic or unsupported version"))
                try? fileManager.removeItem(at: task.stagingURL)
                return .failure(.structureInvalid(reason: "missing GGUF magic or unsupported version"))
            }

            guard ModelManagerService.isValidSHA256(task.expectedSHA256) else {
                task.state = .failed(error: .invalidCatalogMetadata)
                try? fileManager.removeItem(at: task.stagingURL)
                return .failure(.invalidCatalogMetadata)
            }
            let verified = ModelManagerService.verifySHA256(
                fileURL: task.stagingURL,
                expected: task.expectedSHA256
            )
            guard verified else {
                print("[DL-CHUNK] verification failed: SHA-256 mismatch")
                task.state = .failed(error: .sha256Mismatch)
                try? fileManager.removeItem(at: task.stagingURL)
                return .failure(.sha256Mismatch)
            }

            if fileManager.fileExists(atPath: task.destinationURL.path) {
                try fileManager.removeItem(at: task.destinationURL)
            }
            try fileManager.moveItem(at: task.stagingURL, to: task.destinationURL)
            try? fileManager.removeItem(at: task.resumeDataURL)
            task.progress = 1.0
            task.state = .downloaded
            logger.info("Download verified and promoted: \(task.model.id, privacy: .public)-\(String(describing: task.artifact), privacy: .public)")
            return .success(())
        } catch {
            print("[DL-CHUNK] verification/promotion failed: \(error.localizedDescription)")
            task.state = .failed(error: .fileCorrupted)
            try? fileManager.removeItem(at: task.stagingURL)
            return .failure(.fileCorrupted)
        }
    }

    private func updateStatus(model: AIModel) {
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
                mmprojState: mmprojState
            )
        }
    }
    /// Clean up partial files for failed downloads that cannot be resumed.
    func cleanupPartialFiles(for model: AIModel) {
        let basePath = ModelManagerService.baseModelPath(for: model)
        let tmpPath = basePath.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: tmpPath.path) {
            try? fileManager.removeItem(at: tmpPath)
            logger.info("Cleaned up partial file: \(tmpPath.lastPathComponent, privacy: .public)")
        }
        if model.requiresMMProj {
            let mmprojPath = ModelManagerService.mmprojModelPath(for: model)
            let mmprojTmpPath = mmprojPath.appendingPathExtension("tmp")
            if fileManager.fileExists(atPath: mmprojTmpPath.path) {
                try? fileManager.removeItem(at: mmprojTmpPath)
            }
        }
    }
}
// MARK: - URLSessionDownloadDelegate
extension DownloadManager: URLSessionDownloadDelegate, URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let key = dataTask.taskDescription,
                  let task = activeTasks[key],
                  task.isChunked,
                  task.chunkTask === dataTask,
                  let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            let start = task.currentChunkOffset
            let end = task.currentChunkEnd
            guard response.statusCode == 206,
                  contentRange(response, matchesStart: start, end: end, total: task.expectedBytes) else {
                let contentRangeValue = response.value(forHTTPHeaderField: "Content-Range") ?? "missing"
                task.chunkFailureReason = "invalid range response (HTTP \(response.statusCode), Content-Range=\(contentRangeValue))"
                print("[DL-CHUNK] \(key): \(task.chunkFailureReason!)")
                completionHandler(.cancel)
                return
            }
            task.chunkResponseValidated = true
            completionHandler(.allow)
        }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let key = dataTask.taskDescription,
                  let task = activeTasks[key],
                  task.isChunked,
                  task.chunkTask === dataTask,
                  task.chunkResponseValidated,
                  task.chunkFailureReason == nil else { return }
            let expectedCount = task.currentChunkEnd - task.currentChunkOffset + 1
            guard task.chunkBytesReceived + Int64(data.count) <= expectedCount else {
                task.chunkFailureReason = "range body exceeded expected \(expectedCount) bytes"
                dataTask.cancel()
                return
            }
            do {
                guard let handle = task.chunkFileHandle else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try handle.write(contentsOf: data)
                task.chunkBytesReceived += Int64(data.count)
                let totalWritten = task.currentChunkOffset + task.chunkBytesReceived
                task.progress = Double(totalWritten) / Double(task.expectedBytes)
                task.state = .downloading(progress: task.progress)
                lastProgressTime[key] = Date()
                updateStatus(model: task.model)
            } catch {
                task.chunkFailureReason = "file write failed: \(error.localizedDescription)"
                dataTask.cancel()
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let key = downloadTask.taskDescription,
                  let task = activeTasks[key] else { return }
            let response = downloadTask.response as? HTTPURLResponse
            let statusCode = response?.statusCode ?? -1
            print("[DL-DONE] \(key): didFinishDownloadingTo, HTTP \(statusCode), location=\(location.path)")
            ZiroEdgeApp.diagnosticLog("[DL-DONE] \(key): HTTP \(statusCode)")
            // Transport validation: check for error pages before processing
            if !(200...299).contains(statusCode) {
                print("[DL-DONE] \(key): HTTP error \(statusCode)")
                task.state = .failed(error: .networkError)
                cleanupPartialFiles(for: task.model)
                updateStatus(model: task.model)
                activeTasks.removeValue(forKey: key)
                return
            }
            // Check if the response is a textual error page
            if let contentType = response?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               contentType.hasPrefix("text/") || contentType.contains("html") || contentType.contains("json") {
                print("[DL-DONE] \(key): textual response (\(contentType)), likely error page")
                task.state = .failed(error: .networkError)
                cleanupPartialFiles(for: task.model)
                updateStatus(model: task.model)
                activeTasks.removeValue(forKey: key)
                return
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: location.path)
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                print("[DL-DONE] \(key): file size=\(fileSize) bytes")
                // Check if the downloaded file is actually a textual error page.
                if fileSize < 10_000,
                   let data = try? Data(contentsOf: location, options: .mappedIfSafe),
                   let text = String(data: data.prefix(512), encoding: .utf8) {
                    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower.hasPrefix("<") || lower.hasPrefix("{") || lower.contains("invalid")
                        || lower.contains("error") || lower.contains("unauthorized") {
                        print("[DL-DONE] \(key): ERROR PAGE detected: \(text.prefix(200))")
                        task.state = .failed(error: .networkError)
                        updateStatus(model: task.model)
                        activeTasks.removeValue(forKey: key)
                        return
                    }
                }
                if fileManager.fileExists(atPath: task.stagingURL.path) {
                    try fileManager.removeItem(at: task.stagingURL)
                }
                try fileManager.moveItem(at: location, to: task.stagingURL)
                _ = verifyAndPromote(task: task)
            } catch {
                task.state = .failed(error: .fileCorrupted)
                cleanupPartialFiles(for: task.model)
                logger.error("Download staging failed: \(error.localizedDescription, privacy: .public)")
            }
            updateStatus(model: task.model)
            activeTasks.removeValue(forKey: key)
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let key = downloadTask.taskDescription,
                  let task = activeTasks[key] else { return }
            let progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0.0
            task.progress = progress
            task.state = .downloading(progress: progress)
            updateStatus(model: task.model)
            let pct = Int(progress * 100)
            if pct % 5 == 0 {
                print("[DL-PROG] \(key): \(pct)% (written=\(totalBytesWritten) expected=\(totalBytesExpectedToWrite)")
            }
            lastProgressTime[key] = Date()
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let key = task.taskDescription,
                  let downloadTask = activeTasks[key] else { return }
            if downloadTask.isChunked {
                guard let dataTask = task as? URLSessionDataTask,
                      downloadTask.chunkTask === dataTask else { return }
                downloadTask.chunkTask = nil
                let expectedCount = downloadTask.currentChunkEnd - downloadTask.currentChunkOffset + 1
                let failureReason = downloadTask.chunkFailureReason
                let responseWasValid = downloadTask.chunkResponseValidated
                closeChunkFile(for: downloadTask, synchronize: error == nil && failureReason == nil)
                guard !downloadTask.isPaused, !downloadTask.isCancelled else { return }
                if let failureReason {
                    retryChunk(task: downloadTask, key: key, reason: failureReason)
                } else if let error {
                    retryChunk(task: downloadTask, key: key, reason: error.localizedDescription)
                } else if !responseWasValid || downloadTask.chunkBytesReceived != expectedCount {
                    retryChunk(
                        task: downloadTask,
                        key: key,
                        reason: "incomplete range body (received=\(downloadTask.chunkBytesReceived), expected=\(expectedCount))"
                    )
                } else {
                    completeChunk(task: downloadTask, key: key)
                }
                return
            }
            let nsError = error as NSError?
            print("[DL-COMP] \(key): didCompleteWithError=\(error?.localizedDescription ?? "nil")")
            ZiroEdgeApp.diagnosticLog("[DL-COMP] \(key): error=\(error?.localizedDescription ?? "nil")")
            if let nsError {
                print("[DL-COMP] \(key): NSError domain=\(nsError.domain) code=\(nsError.code)")
            }
            if let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                downloadTask.resumeData = resumeData
                try? resumeData.write(to: downloadTask.resumeDataURL)
            }
            if downloadTask.isPaused {
                downloadTask.state = .paused(progress: downloadTask.progress)
                print("[DL-COMP] \(key): paused at \(Int(downloadTask.progress * 100))%")
                updateStatus(model: downloadTask.model)
                return
            } else if error != nil {
                downloadTask.state = .failed(error: .networkError)
                cleanupPartialFiles(for: downloadTask.model)
                print("[DL-COMP] \(key): FAILED - \(error!.localizedDescription)")
            } else {
                print("[DL-COMP] \(key): completed successfully")
            }
            updateStatus(model: downloadTask.model)
            activeTasks.removeValue(forKey: key)
        }
    }
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        MainActor.assumeIsolated {
            let key = task.taskDescription ?? "unknown"
            let from = response.url?.absoluteString ?? "nil"
            let to = request.url?.absoluteString ?? "nil"
            print("[DL-REDIRECT] \(key): HTTP \(response.statusCode)")
            print("[DL-REDIRECT] \(key): from=\(from)")
            print("[DL-REDIRECT] \(key): to=\(to.prefix(120))")
            var redirectedRequest = request
            if let downloadTask = activeTasks[key], downloadTask.isChunked {
                let start = downloadTask.currentChunkOffset
                let end = min(start + Self.chunkSize - 1, downloadTask.expectedBytes - 1)
                redirectedRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                print("[DL-CHUNK] \(key): preserved Range header across redirect")
            }
            completionHandler(redirectedRequest)
        }
    }
}

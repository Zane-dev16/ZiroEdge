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
            return model.mmprojURL!
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

    /// Resume data file path for persistence across app restarts.
    var resumeDataURL: URL {
        ModelManagerService.modelsDirectory
            .appendingPathComponent("\(model.id)-\(artifact)-resume.dat")
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

    init() {
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
final class DownloadManager: NSObject, ObservableObject {

    // MARK: - Published State

    /// Download statuses keyed by model ID.
    @Published private(set) var downloadStatuses: [String: ModelDownloadStatus] = [:]

    /// Active download tasks keyed by model ID.
    private var activeTasks: [String: DownloadTask] = [:]

    /// Network connectivity monitor.
    let networkMonitor = NetworkMonitor()

    // MARK: - Private

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "download")
    private let fileManager = FileManager.default

    private static let chunkSize: Int64 = 100 * 1_024 * 1_024
    private static let chunkedDownloadThreshold: Int64 = 2_147_483_648
    private static let maximumChunkRetries = 3

    // MARK: - Initialization

    override init() {
        super.init()
        ModelManagerService.ensureModelsDirectory()
        updateStatusesFromDisk()
    }

    // MARK: - Status Queries

    /// Get download status for a model. Falls back to disk check when
    /// no cached download task exists.
    func status(for model: AIModel) -> ModelDownloadStatus {
        if let cached = downloadStatuses[model.id] { return cached }
        let baseState: DownloadState = ModelManagerService.isBaseDownloaded(model) ? .downloaded : .notDownloaded
        let mmprojState: DownloadState? = model.requiresMMProj
            ? (ModelManagerService.isMMProjDownloaded(model) ? .downloaded : .notDownloaded)
            : nil
        return ModelDownloadStatus(modelID: model.id, baseState: baseState, mmprojState: mmprojState)
    }

    /// Check disk and update statuses for all registered models.
    func updateStatusesFromDisk() {
        for model in ModelRegistry.allModels {
            let baseState: DownloadState = ModelManagerService.isBaseDownloaded(model) ? .downloaded : .notDownloaded
            let mmprojState: DownloadState? = model.requiresMMProj ? (ModelManagerService.isMMProjDownloaded(model) ? .downloaded : .notDownloaded) : nil
            downloadStatuses[model.id] = ModelDownloadStatus(modelID: model.id, baseState: baseState, mmprojState: mmprojState)
        }
    }

    // MARK: - Storage Check

    /// Available disk space in bytes.
    var availableDiskSpace: Int64 {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return 0 }
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Whether the device has enough space for a model download.
    func hasSufficientStorage(for model: AIModel) -> Bool {
        availableDiskSpace >= model.totalFileSizeBytes
    }

    /// Formatted available disk space.
    func formattedAvailableSpace() -> String {
        ByteCountFormatter.string(fromByteCount: availableDiskSpace, countStyle: .file)
    }

    // MARK: - Download Actions

    /// Start downloading a model. Shows cellular warning if needed.
    func startDownload(for model: AIModel) {
        print("[DL-START] startDownload: \(model.id) url=\(model.baseURL.absoluteString)")
        ZiroEdgeApp.diagnosticLog("[DL-START] startDownload: \(model.id) url=\(model.baseURL.absoluteString)")
        startStuckWatchdog()
        let currentStatus = status(for: model)
        print("[DL-START] \(model.id): isReady=\(currentStatus.isReady) isDownloading=\(currentStatus.isDownloading)")
        guard !currentStatus.isReady, !currentStatus.isDownloading else { return }

        ModelManagerService.ensureModelsDirectory()

        print("[DL-START] \(model.id): starting base download")
        startArtifactDownload(model: model, artifact: .base)

        if model.requiresMMProj {
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
        let key = "\(model.id)-\(artifact)"
        guard let downloadTask = activeTasks[key] else { return }

        if downloadTask.isChunked {
            downloadTask.isPaused = true
            downloadTask.chunkTask?.cancel()
            downloadTask.chunkTask = nil
            closeChunkFile(for: downloadTask)
            downloadTask.state = .notDownloaded
            print("[DL-CHUNK] \(key): paused at offset \(downloadTask.currentChunkOffset)")
            return
        }

        downloadTask.task?.cancel(byProducingResumeData: { data in
            downloadTask.resumeData = data
            if let data {
                try? data.write(to: downloadTask.resumeDataURL)
            }
            downloadTask.state = .notDownloaded
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
        cancelArtifactDownload(model: model, artifact: .mmproj)
        updateStatus(model: model)
    }

    /// Delete a downloaded model and clean up.
    func deleteModel(_ model: AIModel) {
        cancelDownload(for: model)
        ModelManagerService.deleteModel(model)

        // Clean up resume data
        try? fileManager.removeItem(at: DownloadTask(model: model, artifact: .base).resumeDataURL)
        if model.requiresMMProj {
            try? fileManager.removeItem(at: DownloadTask(model: model, artifact: .mmproj).resumeDataURL)
        }

        updateStatusesFromDisk()
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
            let now = Date()
            for (key, task) in self.activeTasks {
                guard case .downloading = task.state else { continue }
                // A completion-handler data task reports progress once per
                // chunk. Its request timeout and per-chunk retry policy are a
                // better signal than this regular-download watchdog.
                guard !task.isChunked else { continue }
                let lastProgress = self.lastProgressTime[key] ?? Date()
                let elapsed = now.timeIntervalSince(lastProgress)
                if elapsed > 120 {
                    print("[DL-STUCK] \(key): no progress for \(Int(elapsed))s, cancelling and retrying")
                    self.lastProgressTime.removeValue(forKey: key)
                    task.task?.cancel()
                    // Retry after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        print("[DL-STUCK] \(key): retrying download")
                        self.startArtifactDownload(model: task.model, artifact: task.artifact)
                    }
                }
            }
        }
    }

    private func startArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let task = DownloadTask(model: model, artifact: artifact)
        let key = "\(model.id)-\(artifact)"
        activeTasks[key] = task
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
                task.task = self.urlSession.downloadTask(withResumeData: resumeData)
                print("[DL-START] \(key): resuming from resume data")
            } else {
                task.task = self.urlSession.downloadTask(with: downloadURL)
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

            let dataTask = urlSession.dataTask(with: request)
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
        let key = "\(model.id)-\(artifact)"
        guard let task = activeTasks[key] else {
            startArtifactDownload(model: model, artifact: artifact)
            return
        }

        if task.isChunked {
            task.isPaused = false
            task.isCancelled = false
            task.state = .downloading(progress: task.progress)
            updateStatus(model: model)
            print("[DL-CHUNK] \(key): resuming chunked download")
            chunkedDownload(task: task, key: key)
            return
        }

        if let resumeData = task.resumeData ?? (try? Data(contentsOf: task.resumeDataURL)) {
            task.task = urlSession.downloadTask(withResumeData: resumeData)
        } else {
            task.task = urlSession.downloadTask(with: task.downloadURL ?? task.sourceURL)
        }

        task.state = .downloading(progress: task.progress)
        updateStatus(model: model)

        task.task?.taskDescription = key
        task.task?.resume()
        logger.info("Resumed download: \(key, privacy: .public)")
    }

    private func cancelArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = "\(model.id)-\(artifact)"
        guard let task = activeTasks[key] else { return }

        task.isCancelled = true
        task.task?.cancel()
        task.chunkTask?.cancel()
        closeChunkFile(for: task)
        task.state = .cancelled

        // Explicit cancellation discards both regular and chunked staging data.
        try? fileManager.removeItem(at: task.stagingURL)

        // Clean up resume data
        try? fileManager.removeItem(at: task.resumeDataURL)

        activeTasks.removeValue(forKey: key)
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

            if !task.expectedSHA256.isEmpty {
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
        let baseKey = "\(model.id)-base"
        let mmprojKey = "\(model.id)-mmproj"

        let baseState = activeTasks[baseKey]?.state
            ?? (ModelManagerService.isBaseDownloaded(model) ? .downloaded : .notDownloaded)
        let mmprojState: DownloadState? = model.requiresMMProj
            ? (activeTasks[mmprojKey]?.state
                ?? (ModelManagerService.isMMProjDownloaded(model) ? .downloaded : .notDownloaded))
            : nil

        downloadStatuses[model.id] = ModelDownloadStatus(modelID: model.id, baseState: baseState, mmprojState: mmprojState)
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
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

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
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
            downloadTask.state = .notDownloaded
            print("[DL-COMP] \(key): paused with resume data (\(resumeData.count) bytes)")
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
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

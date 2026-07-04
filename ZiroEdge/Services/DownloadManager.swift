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
    var resumeData: Data?
    var progress: Double = 0.0
    var state: DownloadState = .notDownloaded

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
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "download")
    private let fileManager = FileManager.default

    // MARK: - Initialization

    override init() {
        super.init()
        ModelManagerService.ensureModelsDirectory()
        updateStatusesFromDisk()
    }

    // MARK: - Status Queries

    /// Get download status for a model.
    func status(for model: AIModel) -> ModelDownloadStatus {
        downloadStatuses[model.id] ?? ModelDownloadStatus(baseState: .notDownloaded, mmprojState: model.requiresMMProj ? .notDownloaded : nil)
    }

    /// Check disk and update statuses for all registered models.
    func updateStatusesFromDisk() {
        for model in ModelRegistry.allModels {
            let baseState: DownloadState = ModelManagerService.isBaseDownloaded(model) ? .downloaded : .notDownloaded
            let mmprojState: DownloadState? = model.requiresMMProj ? (ModelManagerService.isMMProjDownloaded(model) ? .downloaded : .notDownloaded) : nil
            downloadStatuses[model.id] = ModelDownloadStatus(baseState: baseState, mmprojState: mmprojState)
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
        let currentStatus = status(for: model)
        guard !currentStatus.isReady, !currentStatus.isDownloading else { return }

        ModelManagerService.ensureModelsDirectory()

        // Start base download
        startArtifactDownload(model: model, artifact: .base)

        // Start mmproj download if needed
        if model.requiresMMProj {
            startArtifactDownload(model: model, artifact: .mmproj)
        }
    }

    /// Pause an active download.
    func pauseDownload(for model: AIModel) {
        guard let baseTask = activeTasks["\(model.id)-base"] else { return }
        baseTask.task?.cancel(byProducingResumeData: { data in
            baseTask.resumeData = data
            if let data = data {
                try? data.write(to: baseTask.resumeDataURL)
            }
            baseTask.state = .notDownloaded
        })

        if model.requiresMMProj, let mmprojTask = activeTasks["\(model.id)-mmproj"] {
            mmprojTask.task?.cancel(byProducingResumeData: { data in
                mmprojTask.resumeData = data
                if let data = data {
                    try? data.write(to: mmprojTask.resumeDataURL)
                }
            })
        }
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

    private func startArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let task = DownloadTask(model: model, artifact: artifact)
        let key = "\(model.id)-\(artifact)"
        activeTasks[key] = task

        // Check for resume data
        if let resumeData = try? Data(contentsOf: task.resumeDataURL) {
            task.resumeData = resumeData
            task.task = urlSession.downloadTask(withResumeData: resumeData)
        } else {
            task.task = urlSession.downloadTask(with: task.sourceURL)
        }

        task.state = .downloading(progress: 0.0)
        updateStatus(model: model)

        task.task?.taskDescription = key
        task.task?.resume()
        logger.info("Started download: \(key, privacy: .public)")
    }

    private func resumeArtifactDownload(model: AIModel, artifact: ArtifactType) {
        let key = "\(model.id)-\(artifact)"
        guard let task = activeTasks[key] else {
            startArtifactDownload(model: model, artifact: artifact)
            return
        }

        if let resumeData = task.resumeData ?? (try? Data(contentsOf: task.resumeDataURL)) {
            task.task = urlSession.downloadTask(withResumeData: resumeData)
        } else {
            task.task = urlSession.downloadTask(with: task.sourceURL)
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

        task.task?.cancel()
        task.state = .cancelled

        // Clean up partial file if it's not a resume-capable state
        let tempFile = task.destinationURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: tempFile)

        // Clean up resume data
        try? fileManager.removeItem(at: task.resumeDataURL)

        activeTasks.removeValue(forKey: key)
        logger.info("Cancelled download: \(key, privacy: .public)")
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

        downloadStatuses[model.id] = ModelDownloadStatus(baseState: baseState, mmprojState: mmprojState)
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

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription,
              let task = activeTasks[key] else { return }

        do {
            // Move downloaded file to destination
            if fileManager.fileExists(atPath: task.destinationURL.path) {
                try fileManager.removeItem(at: task.destinationURL)
            }
            try fileManager.moveItem(at: location, to: task.destinationURL)

            // Verify SHA-256 if hash is available
            if !task.expectedSHA256.isEmpty {
                task.state = .verifying
                updateStatus(model: task.model)

                let verified = ModelManagerService.verifySHA256(
                    fileURL: task.destinationURL,
                    expected: task.expectedSHA256
                )
                if verified {
                    task.state = .downloaded
                    // Clean up resume data
                    try? fileManager.removeItem(at: task.resumeDataURL)
                    logger.info("Download verified: \(key, privacy: .public)")
                } else {
                    task.state = .failed(error: .sha256Mismatch)
                    cleanupPartialFiles(for: task.model)
                    logger.error("SHA-256 mismatch: \(key, privacy: .public)")
                }
            } else {
                // No hash to verify — trust the download
                task.state = .downloaded
                try? fileManager.removeItem(at: task.resumeDataURL)
                logger.info("Download complete (no hash to verify): \(key, privacy: .public)")
            }
        } catch {
            task.state = .failed(error: .fileCorrupted)
            cleanupPartialFiles(for: task.model)
            logger.error("Download move failed: \(error.localizedDescription, privacy: .public)")
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
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let key = task.taskDescription,
              let downloadTask = activeTasks[key] else { return }

        let nsError = error as NSError?

        // Check for cancellation with resume data
        if let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            downloadTask.resumeData = resumeData
            try? resumeData.write(to: downloadTask.resumeDataURL)
            downloadTask.state = .notDownloaded
            logger.info("Download paused with resume data: \(key, privacy: .public)")
        } else if error != nil {
            downloadTask.state = .failed(error: .networkError)
            cleanupPartialFiles(for: downloadTask.model)
            logger.error("Download failed: \(key, privacy: .public) - \(error!.localizedDescription, privacy: .public)")
        }

        updateStatus(model: downloadTask.model)
        activeTasks.removeValue(forKey: key)
    }
}

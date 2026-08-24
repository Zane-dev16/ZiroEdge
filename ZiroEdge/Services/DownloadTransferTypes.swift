import Combine
import Foundation
import Network

/// Per-artifact transfer state machine. One instance tracks a single
/// model artifact (base weights or mmproj projector) from CDN resolution
/// through chunked/plain transfer into verification and promotion.
final class DownloadTask {
    let model: AIModel
    let artifact: ArtifactType
    var task: URLSessionDownloadTask?
    var chunkTask: URLSessionDataTask?
    var resolutionTask: URLSessionDataTask?
    var resumeData: Data?
    /// Byte offset the CURRENT URLSessionDownloadTask starts from: zero for
    /// fresh transfers, the estimated received count when created from resume
    /// data. Lets transport validation distinguish fresh vs resumed flows.
    var transferStartOffset: Int64 = 0
    var progress: Double = 0.0
    var state: DownloadState = .notDownloaded
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
    var canonicalRetryAttempted = false
    var awaitingBackgroundTaskReconciliation = false
    var verificationTask: Task<Void, Never>?
    init(model: AIModel, artifact: ArtifactType) { self.model = model; self.artifact = artifact }
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
    var storageID: String {
        switch artifact {
        case .base:
            return "base-\(model.baseArtifactStorageID)"
        case .mmproj:
            if model.isImported, let digest = model.mmprojSHA256 {
                return "mmproj-hf-\(digest.prefix(24))"
            }
            return "mmproj-\(model.id)"
        }
    }
    var resumeDataURL: URL { ModelManagerService.resumeDirectory.appendingPathComponent("\(storageID).resume") }
    var metadataURL: URL { ModelManagerService.resumeDirectory.appendingPathComponent("\(storageID).json") }
    var stagingURL: URL { ModelManagerService.stagingDirectory.appendingPathComponent("\(storageID).partial") }
}

/// Publishes network reachability and interface class so downloads can
/// surface connectivity state without polling.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnCellular = false
    @Published private(set) var isConnected = true
    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "com.zanish-labs.ziroedge.network-monitor")
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
    deinit { monitor.cancel() }
}

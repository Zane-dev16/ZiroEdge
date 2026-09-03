import Foundation
import os

// Chunked (HTTP range) transfer orchestration for oversized artifacts.
// Protocol rules live in ChunkedTransport; this file sequences chunks,
// retries, and hands completed transfers to verification.
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
            let end = ChunkedTransport.rangeEnd(offset: stagedBytes, totalBytes: task.expectedBytes)
            var request = URLRequest(url: task.downloadURL ?? task.sourceURL)
            request.setValue("bytes=\(stagedBytes)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 300
            task.state = .downloading(progress: Double(stagedBytes) / Double(task.expectedBytes))
            task.progress = Double(stagedBytes) / Double(task.expectedBytes)
            updateStatus(model: task.model)
            noteTransferProgress(key)
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
        noteTransferProgress(key)
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
        ChunkedTransport.contentRange(response, matchesStart: start, end: end, total: total)
    }
    func isValidChunkResponse(
        _ response: HTTPURLResponse,
        start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        ChunkedTransport.isValidChunkResponse(response, start: start, end: end, total: total)
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
        // Classify by cause: local filesystem failures (disk full, permissions)
        // are not network problems — reporting them as such sends users into
        // pointless retries.
        let downloadError: DownloadError
        if let cocoa = error as? CocoaError, cocoa.isFileError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                downloadError = .diskSpaceInsufficient
            default:
                downloadError = .fileCorrupted
            }
        } else {
            downloadError = .networkError
        }
        task.state = .failed(error: downloadError)
        persistDurableState(for: task, failed: true)
        DownloadDiagnosticRecorder.shared.record(
            event: .chunkFailed,
            correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
            modelID: task.model.id,
            artifact: task.artifact.label,
            failureCategory: DownloadFailureCategory.from(downloadError),
            failureSummary: error.localizedDescription
        )
        updateStatus(model: task.model)
        activeTasks.removeValue(forKey: key)
        clearTransferProgress(key)
        stopStuckWatchdogIfIdle()
    }
}

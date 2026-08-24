// DownloadManager+URLSessionDelegate.swift
// ZiroEdge — Privacy-first local AI assistant
//
// URLSession delegate plumbing for artifact transfers: chunked data-task
// events, download-task completion/staging, progress writes, resume-data
// capture, and redirect handling. Split from DownloadManager.swift.

import Foundation
import os

extension DownloadManager: URLSessionDownloadDelegate, URLSessionDataDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            BackgroundDownloadCompletionStore.drain(identifier: identifier)
        }
    }
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
            guard isValidChunkResponse(
                response,
                start: start,
                end: end,
                total: task.expectedBytes
            ) else {
                let isStaleAuth = response.statusCode == 401 || response.statusCode == 403
                let hadSignedURL = task.downloadURL != task.sourceURL
                let hadResumeData = fileManager.fileExists(atPath: task.resumeDataURL.path)
                if isStaleAuth, hadSignedURL || hadResumeData {
                    closeChunkFile(for: task)
                    task.chunkTask = nil
                    _ = retryOnceFromCanonicalURL(task, key: key)
                    completionHandler(.cancel)
                    return
                }
                let contentRangeValue = response.value(forHTTPHeaderField: "Content-Range") ?? "missing"
                task.chunkFailureReason = "invalid range response (HTTP \(response.statusCode), Content-Range=\(contentRangeValue))"
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
                noteTransferProgress(key)
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
                  let task = activeTasks[key],
                  task.task === downloadTask else { return }
            let response = downloadTask.response as? HTTPURLResponse
            let artifactLabel = task.artifact.label
            let transferCID = DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: artifactLabel)
            DownloadDiagnosticRecorder.shared.record(
                event: .downloadComplete,
                correlationID: transferCID,
                modelID: task.model.id,
                artifact: artifactLabel,
                state: "received",
                expectedBytes: task.expectedBytes
            )
            if let failure = DownloadTransportValidator.failure(
                response: response,
                bodyURL: location,
                expectedBytes: task.expectedBytes,
                expectedOffset: task.transferStartOffset
            ) {
                let shouldFallback: Bool
                switch failure {
                case .authorizationRequired, .rangeMismatch, .contentRejected:
                    shouldFallback = task.downloadURL != task.sourceURL
                        || task.resumeData != nil
                        || fileManager.fileExists(atPath: task.resumeDataURL.path)
                default:
                    shouldFallback = false
                }
                if shouldFallback, retryOnceFromCanonicalURL(task, key: key) { return }
                task.state = .failed(error: failure)
                persistDurableState(for: task, failed: true)
                updateStatus(model: task.model)
                activeTasks.removeValue(forKey: key)
                return
            }
            do {
                if fileManager.fileExists(atPath: task.stagingURL.path) {
                    try fileManager.removeItem(at: task.stagingURL)
                }
                try fileManager.moveItem(at: location, to: task.stagingURL)
                verifyAndPromoteOffMain(task: task, key: key)
                return
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
            let priorPct = Int(task.progress * 100)
            task.progress = progress
            task.state = .downloading(progress: progress)
            updateStatus(model: task.model)
            let pct = Int(progress * 100)
            if pct % 5 == 0 {
                DownloadDiagnosticRecorder.shared.record(
                    event: .downloadProgress,
                    correlationID: DownloadDiagnosticRecorder.transferCorrelationID(modelID: task.model.id, artifact: task.artifact.label),
                    modelID: task.model.id,
                    artifact: task.artifact.label,
                    expectedBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                    actualBytes: totalBytesWritten,
                    progress: progress
                )
            }
            // Persist durable state at 10 % milestones so a relaunch can
            // restore progress even without an explicit pause.
            if pct % 10 == 0 && priorPct / 10 != pct / 10 {
                persistDurableState(for: task)
            }
            noteTransferProgress(key)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let key = task.taskDescription,
                  let downloadTask = activeTasks[key] else { return }
            if !downloadTask.isChunked,
               let currentTask = task as? URLSessionDownloadTask,
               downloadTask.task !== currentTask { return }
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
                    let isStaleHint = failureReason.contains("401") || failureReason.contains("403")
                        || failureReason.contains("invalid range")
                    let hadSignedURL = downloadTask.downloadURL != downloadTask.sourceURL
                    let hadResumeData = fileManager.fileExists(atPath: downloadTask.resumeDataURL.path)
                    if isStaleHint, hadSignedURL || hadResumeData,
                       retryOnceFromCanonicalURL(downloadTask, key: key) { return }
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
            let artifactLabel = downloadTask.artifact.label
            let transferCID = DownloadDiagnosticRecorder.transferCorrelationID(modelID: downloadTask.model.id, artifact: artifactLabel)
            if let error = error {
                let category = DownloadFailureCategory.from(.networkError)
                DownloadDiagnosticRecorder.shared.record(
                    event: .downloadComplete,
                    correlationID: transferCID,
                    modelID: downloadTask.model.id,
                    artifact: artifactLabel,
                    state: "failed",
                    failureCategory: category,
                    failureSummary: error.localizedDescription
                )
            }
            if let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                downloadTask.resumeData = resumeData
                // Atomic write to match the pause path: a torn resume blob that
                // persisted metadata still advertises would fail resume later.
                if (try? resumeData.write(to: downloadTask.resumeDataURL, options: .atomic)) == nil {
                    try? fileManager.removeItem(at: downloadTask.resumeDataURL)
                }
            }
            if downloadTask.isPaused {
                downloadTask.state = .paused(progress: downloadTask.progress)
                updateStatus(model: downloadTask.model)
                return
            } else if error != nil {
                let hadSignedURL = downloadTask.downloadURL != downloadTask.sourceURL
                let hadResumeData = fileManager.fileExists(atPath: downloadTask.resumeDataURL.path)
                if hadSignedURL || hadResumeData,
                   retryOnceFromCanonicalURL(downloadTask, key: key) {
                    return
                }
                downloadTask.state = .failed(error: .networkError)
                persistDurableState(for: downloadTask, failed: true)
            }
            if case .verifying = downloadTask.state,
               downloadTask.verificationTask != nil {
                // didFinishDownloadingTo already handed staging to
                // verifyAndPromoteOffMain; its completion block owns this key's
                // cleanup (it guards on activeTasks[key] === task). Removing the
                // entry here would strand a fully verified artifact in staging.
                updateStatus(model: downloadTask.model)
                return
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
            var redirectedRequest = request
            if let downloadTask = activeTasks[key], downloadTask.isChunked {
                let start = downloadTask.currentChunkOffset
                let end = ChunkedTransport.rangeEnd(offset: start, totalBytes: downloadTask.expectedBytes)
                redirectedRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
            completionHandler(redirectedRequest)
        }
    }
}

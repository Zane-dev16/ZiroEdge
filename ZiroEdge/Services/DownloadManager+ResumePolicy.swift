// DownloadManager+ResumePolicy.swift
// ZiroEdge — Privacy-first local AI assistant
//
// P2 resume/watchdog policy: one home for the R1-R7 resume rules and the
// S1-S5 stuck-watchdog candidacy rules so transfer paths cannot diverge.
// Pure helpers (no I/O beyond attribute reads); every rule is unit tested
// in P2BatchTests. Logging uses Logger fault-level for corrupt/stale
// invariants: model IDs log public, digests never log.

import Foundation
import os

extension DownloadManager {
    /// R1: resume blobs older than this are stale (signed-URL era) and must
    /// be discarded so the transfer restarts from the canonical catalog URL.
    static let resumeDataFreshnessInterval: TimeInterval = 7 * 24 * 3_600

    /// R5: hosts a byte transfer may touch. Catalog hosts are always allowed;
    /// the Hugging Face CDN hosts below are the only redirect targets.
    /// Anything else fails closed to the canonical catalog URL.
    static var allowedDownloadHosts: Set<String> {
        var hosts = Set(ModelRegistry.allModels.compactMap { $0.baseURL.host?.lowercased() })
        for extra in [
            "cdn-lfs.huggingface.co", "cdn-lfs.hf.co",
            "huggingface.co", "hf.co",
            "catalog.ziroedge.app",
        ] { hosts.insert(extra) }
        return hosts
    }

    /// R5: whether a transfer URL is allowed to carry bytes.
    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if allowedDownloadHosts.contains(host) { return true }
        return allowedDownloadHosts.contains(where: { host.hasSuffix("." + $0) })
    }

    /// R1: freshness probe for a resume blob on disk.
    func isResumeDataFresh(at url: URL, now: Date = Date()) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) <= Self.resumeDataFreshnessInterval
    }

    /// R1+R2: load a usable resume blob, or nil when the transfer must start
    /// fresh. Stale (R1) and empty/corrupt (R2) blobs are removed so later
    /// taps see no phantom resumable state. Corrupt/stale hits log at fault
    /// level with the storage ID public (digests never log).
    /// R2 validates the plist shape before returning: URLSession traps on
    /// non-plist bytes passed to `downloadTask(withResumeData:)`, so only
    /// blobs that deserialize as a dictionary ever resume.
    func loadFreshResumeData(for task: DownloadTask, now: Date = Date()) -> Data? {
        let url = task.resumeDataURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isResumeDataFresh(at: url, now: now) else {
            try? fileManager.removeItem(at: url)
            logger.fault("Discarding stale resume blob: \(task.storageID, privacy: .public)")
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) is [String: Any] else {
            try? fileManager.removeItem(at: url)
            logger.fault("Discarding corrupt resume blob: \(task.storageID, privacy: .public)")
            return nil
        }
        return data
    }

    /// R4: bytes already on disk that the resume storage gate may credit.
    /// Staging size wins; when staging is missing, the in-memory progress
    /// estimate stands in so a resume is not refused for bytes it holds.
    func creditedResumeBytes(for task: DownloadTask) -> Int64 {
        let staged = ((try? fileManager.attributesOfItem(atPath: task.stagingURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if staged > 0 { return min(staged, task.expectedBytes) }
        let estimated = Int64((task.progress * Double(task.expectedBytes)).rounded())
        return min(max(0, estimated), task.expectedBytes)
    }

    /// R4: remaining bytes for the resume storage gate after crediting
    /// resumable bytes, plus the safety margin when anything remains.
    func resumeRemainingBytes(for task: DownloadTask) -> Int64 {
        let remaining = max(0, task.expectedBytes - creditedResumeBytes(for: task))
        guard remaining > 0 else { return 0 }
        let (withMargin, overflow) = remaining.addingReportingOverflow(Self.storageSafetyMarginBytes)
        return overflow ? .max : withMargin
    }

    /// R7 (canonical): the single stale-credential fallback. Callers never
    /// hand-roll resume/staging removal — they funnel here so the one-shot
    /// guard, blob clearing, and canonical restart stay identical.
    /// (Implementation lives in DownloadManager+ArtifactLifecycle.)
    static let canonicalRetryDoc = "retryOnceFromCanonicalURL is the canonical stale-credential fallback"

    // MARK: - R6 pause-before-start

    /// R6: pause intents that arrive before any transfer exists (during CDN
    /// resolution or before the first tap-verify lands). Consumed by
    /// startArtifactDownload, which parks instead of starting bytes.
    /// Storage lives on the main declaration (extensions cannot add it).
    func notePendingPause(key: String) { pendingPauseRequests.insert(key) }
    func consumePendingPause(key: String) -> Bool { pendingPauseRequests.remove(key) != nil }

    // MARK: - S1-S5 stuck-watchdog candidacy

    /// S1+S2+S5: whether the watchdog owns this task. Downloading and
    /// resuming transfers (chunked or plain) plus tasks stuck inside CDN
    /// resolution are candidates; verifying/paused/done tasks are not.
    func isWatchdogCandidate(_ task: DownloadTask) -> Bool {
        if task.isCancelled || task.isPaused { return false }
        if task.resolutionTask != nil { return true }
        switch task.state {
        case .downloading, .resuming: return true
        default: return false
        }
    }

    /// S3: heartbeat for a task, or distantPast when none was ever recorded
    /// so a transfer that never progressed still trips the watchdog.
    func watchdogHeartbeat(forKey key: String) -> Date {
        lastProgressTime[key] ?? .distantPast
    }

    /// S1-S3+S5: keys whose watchdog elapsed time exceeds `timeout`.
    func stuckTransferKeys(now: Date = Date(), timeout: TimeInterval = 120) -> [String] {
        activeTasks.compactMap { (key, task) in
            guard isWatchdogCandidate(task) else { return nil }
            return now.timeIntervalSince(watchdogHeartbeat(forKey: key)) > timeout ? key : nil
        }
    }

    /// S4: whether any task currently needs the watchdog timer.
    var hasWatchdogCandidates: Bool {
        activeTasks.values.contains(where: { isWatchdogCandidate($0) })
    }
}

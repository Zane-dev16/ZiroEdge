// DownloadDiagnostics.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Privacy-preserving structured diagnostic recorder for model downloads.
// Every event carries a transfer correlation ID that survives retry and
// relaunch so operators can correlate the lifecycle of a single transfer.
//
// Redaction: signed URLs, authorization headers, resume payloads, and
// filesystem paths are stripped before any event touches the log file.

import CryptoKit
import Foundation
import os

// MARK: - Diagnostic Event Types

enum DownloadDiagnosticEvent: String, Codable, Sendable {
    case downloadStart       = "download_start"
    case downloadProgress    = "download_progress"
    case downloadComplete    = "download_complete"
    case downloadResume      = "download_resume"
    case downloadPause       = "download_pause"
    case downloadCancel      = "download_cancel"
    case validationStart     = "validation_start"
    case validationComplete  = "validation_complete"
    case validationFailed    = "validation_failed"
    case storageCheck        = "storage_check"
    case storageInsufficient = "storage_insufficient"
    case reconciliationStart = "reconciliation_start"
    case reconciliationDone  = "reconciliation_done"
    case chunkReceived       = "chunk_received"
    case chunkRetry          = "chunk_retry"
    case chunkFailed         = "chunk_failed"
    case promotionAttempt    = "promotion_attempt"
    case promotionSuccess    = "promotion_success"
    case promotionFailed     = "promotion_failed"
    case durableStateWritten = "durable_state_written"
    case durableStateWriteFailed = "durable_state_write_failed"
    case durableStateCleared = "durable_state_cleared"
    case stuckWatchdogFired  = "stuck_watchdog_fired"
    case cdnRedirect         = "cdn_redirect"
}

enum DownloadFailureCategory: String, Codable, Sendable {
    case network
    case storage
    case verification
    case structure
    case authorization
    case catalog
    case cancelled
    case unknown

    /// Map a DownloadError to a sanitized category.
    static func from(_ error: DownloadError) -> DownloadFailureCategory {
        switch error {
        case .networkError:
            return .network
        case .diskSpaceInsufficient:
            return .storage
        case .sha256Mismatch, .sizeMismatch, .fileCorrupted:
            return .verification
        case .contentRejected, .structureInvalid:
            return .structure
        case .authorizationRequired:
            return .authorization
        case .httpStatus, .rangeMismatch:
            return .network
        case .invalidCatalogMetadata:
            return .catalog
        case .promotionFailed:
            return .storage
        case .cancelled:
            return .cancelled
        case .unknown:
            return .unknown
        }
    }

    static func from(validationIssues: [ArtifactIssue]) -> DownloadFailureCategory {
        if validationIssues.contains(where: { if case .sha256Mismatch = $0 { true } else { false } }) {
            return .verification
        }
        if validationIssues.contains(where: { if case .sizeMismatch = $0 { true } else { false } }) {
            return .verification
        }
        if validationIssues.contains(where: { if case .missingGGUFHeader = $0 { true } else { false } }) {
            return .structure
        }
        return .verification
    }
}

// MARK: - Diagnostic Payload

/// A single structured diagnostic record. Fields that could contain secrets
/// are excluded from the schema entirely; the encoder only writes safe keys.
struct DownloadDiagnosticPayload: Codable, Sendable {
    let event: DownloadDiagnosticEvent
    let correlationID: String
    let timestamp: Date
    let modelID: String
    let artifact: String
    let state: String?
    let expectedBytes: Int64?
    let actualBytes: Int64?
    let progress: Double?
    let failureCategory: String?
    let failureSummary: String?
    let chunkIndex: Int64?
    let chunkRetryCount: Int?
    let availableStorageBytes: Int64?
    let requiredStorageBytes: Int64?
    let appVersion: String
    let catalogVersion: String?
    let durationMs: UInt64?
}

// MARK: - Sanitized Export Summary

/// A human-readable, share-safe summary produced on demand.
struct DownloadDiagnosticSummary: Codable, Sendable {
    let exportedAt: Date
    let appVersion: String
    let catalogVersion: String?
    let totalEvents: Int
    let correlationIDs: [String]
    let artifactStates: [DiagnosticArtifactState]
    let recentFailures: [DiagnosticFailureRecord]
    let storageChecks: [DiagnosticStorageRecord]

    struct DiagnosticArtifactState: Codable, Sendable {
        let modelID: String
        let artifact: String
        let expectedBytes: Int64?
        let actualBytes: Int64?
        let verified: Bool
        let lastEvent: String
        let lastEventTime: Date
    }

    struct DiagnosticFailureRecord: Codable, Sendable {
        let modelID: String
        let artifact: String
        let category: String
        let summary: String
        let timestamp: Date
        let correlationID: String
    }

    struct DiagnosticStorageRecord: Codable, Sendable {
        let modelID: String
        let availableBytes: Int64
        let requiredBytes: Int64
        let sufficient: Bool
        let timestamp: Date
        let correlationID: String
    }
}

// MARK: - Redaction

enum DownloadDiagnosticRedactor {
    /// Patterns that must never appear in diagnostic output.
    /// Each matched substring is replaced with `<redacted>`.
    private static let sensitivePatterns: [(String, String)] = [
        (#"https?://[^\s]+"#, "<redacted URL>"),
        (#"file://[^\s]+"#, "<redacted file URL>"),
        (#"/(?:private/)?var/(?:mobile|folders)/[^\s]+"#, "<redacted filesystem path>"),
        (#"(?i)x-(?:amz|goog)-[^\s:]+\s*:\s*[^\r\n]+"#, "<redacted header>"),
        (#"(?i)authorization\s*:\s*[^\r\n]+"#, "<redacted authorization>"),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "<redacted bearer token>"),
        (#"(?i)(?:token|signature|credential|api[_-]?key|secret|password)\s*[:=]\s*[^\s,;&]+"#, "<redacted credential>"),
        (#"(?i)expires\s*=\s*\d+"#, "<redacted expiry>"),
    ]

    static func sanitize(_ value: String) -> String {
        var result = value
        for (pattern, replacement) in sensitivePatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    /// Redact a URL to its scheme + host only.
    static func sanitizedHost(_ url: URL) -> String {
        guard let host = url.host else { return "<redacted URL>" }
        return "\(url.scheme ?? "https")://\(host)"
    }
}

// MARK: - Recorder

/// Thread-safe JSONL recorder for download diagnostics. Writes one JSON
/// line per event. Exports a sanitized summary with no raw URLs, paths,
/// or credentials.
///
/// Sendable safety: mutable file I/O and encoder/decoder access are serialized
/// by `lock`; bundle-derived enablement/version values are immutable at runtime.
/// Callers receive value-type payloads and never access recorder storage.
final class DownloadDiagnosticRecorder: @unchecked Sendable {
    static let shared = DownloadDiagnosticRecorder()

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "download-diagnostics")

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Resolved catalog version provenance.
    struct CatalogVersionProvenance: Sendable {
        let value: String
        let sourceIsPlist: Bool
    }

    /// Resolve the catalog version, preferring the generated Info.plist key.
    /// Returns `nil` when neither the plist nor the compiled fallback is available.
    static func resolvedCatalogVersion(bundle: Bundle = .main) -> CatalogVersionProvenance {
        if let plistValue = bundle.infoDictionary?["ModelCatalogVersion"] as? String,
           !plistValue.isEmpty {
            return CatalogVersionProvenance(value: plistValue, sourceIsPlist: true)
        }
        return CatalogVersionProvenance(
            value: ModelCatalogValidator.catalogVersion,
            sourceIsPlist: false
        )
    }

    private var catalogVersion: String {
        Self.resolvedCatalogVersion().value
    }

    var isEnabled: Bool {
#if DEBUG
        CommandLine.arguments.contains("--download-diagnostic")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#else
        true  // always enabled in release for privacy-preserving telemetry
#endif
    }

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Recording

    @discardableResult
    func record(
        event: DownloadDiagnosticEvent,
        correlationID: String,
        modelID: String,
        artifact: String,
        state: String? = nil,
        expectedBytes: Int64? = nil,
        actualBytes: Int64? = nil,
        progress: Double? = nil,
        failureCategory: DownloadFailureCategory? = nil,
        failureSummary: String? = nil,
        chunkIndex: Int64? = nil,
        chunkRetryCount: Int? = nil,
        availableStorageBytes: Int64? = nil,
        requiredStorageBytes: Int64? = nil,
        durationMs: UInt64? = nil
    ) -> DownloadDiagnosticPayload? {
        guard isEnabled else { return nil }

        let sanitizedSummary = failureSummary.map { DownloadDiagnosticRedactor.sanitize($0) }
        let payload = DownloadDiagnosticPayload(
            event: event,
            correlationID: correlationID,
            timestamp: Date(),
            modelID: modelID,
            artifact: artifact,
            state: state,
            expectedBytes: expectedBytes,
            actualBytes: actualBytes,
            progress: progress,
            failureCategory: failureCategory?.rawValue,
            failureSummary: sanitizedSummary,
            chunkIndex: chunkIndex,
            chunkRetryCount: chunkRetryCount,
            availableStorageBytes: availableStorageBytes,
            requiredStorageBytes: requiredStorageBytes,
            appVersion: appVersion,
            catalogVersion: catalogVersion,
            durationMs: durationMs
        )
        persist(payload)
        return payload
    }

    /// Generate a new transfer correlation ID that survives retry/relaunch
    /// because it is derived from the artifact identity, not a transient task.
    static func transferCorrelationID(modelID: String, artifact: String) -> String {
        // Use a stable, collision-resistant hash of the model + artifact
        // so the same transfer always gets the same correlation ID
        let seed = "ziro-edge.download.\(modelID).\(artifact)"
        let digest = CryptoKit.SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Return a fresh correlation ID for one-off operations.
    static func freshCorrelationID() -> String {
        UUID().uuidString
    }

    // MARK: - Persistence

    private func persist(_ payload: DownloadDiagnosticPayload) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try encoder.encode(payload)
            guard let line = String(data: data, encoding: .utf8) else {
                logger.error("Failed to encode download diagnostic as UTF-8")
                return
            }
            let url = Self.logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                try handle.synchronize()
            } else {
                try Data((line + "\n").utf8).write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Failed to persist download diagnostic: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Export

    var exportURL: URL? {
        Self.logURLIfPresent
    }

    /// Produce a sanitized summary: app/catalog version, artifact states,
    /// expected/actual sizes, verification outcomes, and recent failures.
    /// No raw URLs, paths, credentials, or conversation data is included.
    func exportSummary() -> DownloadDiagnosticSummary? {
        lock.lock()
        defer { lock.unlock() }

        guard let url = Self.logURLIfPresent,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        var payloads: [DownloadDiagnosticPayload] = []
        for line in lines.suffix(5000) { // last 5000 events
            if let payload = try? decoder.decode(DownloadDiagnosticPayload.self, from: Data(line.utf8)) {
                payloads.append(payload)
            }
        }

        // Deduplicate correlation IDs
        var correlationIDs = Set<String>()
        for payload in payloads {
            correlationIDs.insert(payload.correlationID)
        }

        // Aggregate artifact states (latest event per correlation ID)
        var latestByCorrelation: [String: DownloadDiagnosticPayload] = [:]
        for payload in payloads {
            if let existing = latestByCorrelation[payload.correlationID] {
                if payload.timestamp >= existing.timestamp {
                    latestByCorrelation[payload.correlationID] = payload
                }
            } else {
                latestByCorrelation[payload.correlationID] = payload
            }
        }

        let artifactStates: [DownloadDiagnosticSummary.DiagnosticArtifactState] = latestByCorrelation
            .values
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(100)
            .map { payload in
                DownloadDiagnosticSummary.DiagnosticArtifactState(
                    modelID: payload.modelID,
                    artifact: payload.artifact,
                    expectedBytes: payload.expectedBytes,
                    actualBytes: payload.actualBytes,
                    verified: payload.event == .downloadComplete || payload.event == .validationComplete,
                    lastEvent: payload.event.rawValue,
                    lastEventTime: payload.timestamp
                )
            }

        // Recent failures (last 50)
        let recentFailures: [DownloadDiagnosticSummary.DiagnosticFailureRecord] = payloads
            .filter { $0.failureCategory != nil }
            .suffix(50)
            .map { payload in
                DownloadDiagnosticSummary.DiagnosticFailureRecord(
                    modelID: payload.modelID,
                    artifact: payload.artifact,
                    category: payload.failureCategory ?? "unknown",
                    summary: payload.failureSummary ?? "",
                    timestamp: payload.timestamp,
                    correlationID: payload.correlationID
                )
            }

        // Storage checks (last 20)
        let storageChecks: [DownloadDiagnosticSummary.DiagnosticStorageRecord] = payloads
            .filter { $0.event == .storageCheck || $0.event == .storageInsufficient }
            .suffix(20)
            .map { payload in
                DownloadDiagnosticSummary.DiagnosticStorageRecord(
                    modelID: payload.modelID,
                    availableBytes: payload.availableStorageBytes ?? 0,
                    requiredBytes: payload.requiredStorageBytes ?? 0,
                    sufficient: payload.event == .storageCheck,
                    timestamp: payload.timestamp,
                    correlationID: payload.correlationID
                )
            }

        return DownloadDiagnosticSummary(
            exportedAt: Date(),
            appVersion: appVersion,
            catalogVersion: catalogVersion,
            totalEvents: payloads.count,
            correlationIDs: Array(correlationIDs).sorted().prefix(200).map { $0 },
            artifactStates: artifactStates,
            recentFailures: recentFailures,
            storageChecks: storageChecks
        )
    }

    /// Write the sanitized summary to a JSON file and return its URL.
    func writeSummary() -> URL? {
        guard let summary = exportSummary() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encoder.encode(summary)
            try data.write(to: Self.summaryURL, options: .atomic)
            return Self.summaryURL
        } catch {
            logger.error("Failed to write summary: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func resetLog() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: Self.logURL)
        try? FileManager.default.removeItem(at: Self.summaryURL)
    }

    // MARK: - File URLs

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-diagnostics.jsonl")
    }

    static var logURLIfPresent: URL? {
        FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
    }

    static var summaryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-diagnostics-summary.json")
    }
}

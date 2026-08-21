// OfflineAvailabilityGuard.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Guard that verifies every installed model at launch without touching the network.
// Produces a typed report so the UI can reflect verified local state and never
// present partial, corrupt, staged, or resumable artifacts as offline-ready.

import Foundation
import os

// MARK: - Offline Readiness

/// Readiness verdict for a single model artifact pair.
enum OfflineModelReadiness: Sendable, Equatable {
    /// Both required artifacts are verified and ready for offline use.
    case ready(textOnly: Bool)

    /// At least one artifact exists on disk but fails catalog validation.
    case repairNeeded(issues: [ArtifactIssue])

    /// No verified artifacts exist. Nothing to load.
    case unavailable
}

/// Aggregate report produced after a launch-time offline sweep.
struct OfflineAvailabilityReport: Sendable {
    /// Timestamp of the sweep.
    let timestamp: Date

    /// Per-model readiness verdicts keyed by model ID.
    let models: [String: OfflineModelReadiness]

    /// Diagnoses for tracing, stripped of absolute paths.
    let diagnostics: [String]

    /// True when at least one model is ready for offline use.
    var hasReadyModel: Bool {
        models.values.contains { if case .ready = $0 { true } else { false } }
    }

    /// IDs of models whose artifacts exist on disk but fail validation.
    var repairNeededModelIDs: [String] {
        models.compactMap { id, readiness -> String? in
            if case .repairNeeded = readiness { return id }
            return nil
        }
    }

    /// IDs of ready models, ordered by catalog position.
    var readyModelIDs: [String] {
        ModelRegistry.allModels.compactMap { model in
            if case .ready = models[model.id] { return model.id }
            return nil
        }
    }
}

// MARK: - Offline Availability Guard

/// Runs a targeted launch-time sweep that enforces the offline-proof contract:
/// no network, no URLSession, only FileManager + CryptoKit.
enum OfflineAvailabilityGuard {
    private static let logger = Logger(
        subsystem: "com.zanish-labs.ziroedge",
        category: "offline-guard"
    )

    // MARK: - Public API

    // BATCH-03: mtime+size cache + off-main execution
    static var lastSweepWasOffMain: Bool?

    private static func makeReport(extraModels: [AIModel]) -> OfflineAvailabilityReport {
        let all = ModelRegistry.allModels + extraModels
        var models: [String: OfflineModelReadiness] = [:]
        var diagnostics: [String] = []
        for model in all {
            let availability = ModelManagerService.availability(for: model)
            switch availability {
            case .ready:
                let textOnly = model.allowsTextOnlyCapability
                    && !(ModelManagerService.isMMProjDownloaded(model))
                models[model.id] = .ready(textOnly: textOnly)
                diagnostics.append(
                    "[offline-guard] \(model.id): verified — ready for offline use\(textOnly ? " (text-only)" : "")"
                )
            case .repairNeeded(let issues):
                models[model.id] = .repairNeeded(issues: issues)
                let issueDescriptions = issues.map { issue -> String in
                    switch issue {
                    case .sha256Mismatch: "SHA-256 mismatch"
                    case .sizeMismatch: "size mismatch"
                    case .missingGGUFHeader: "missing GGUF header"
                    case .fileNotFound: "file not found"
                    case .missing(let artifact): "missing \(artifact == .base ? "base" : "mmproj") artifact"
                    case .unknown(let detail): "unknown: \(detail)"
                    }
                }
                diagnostics.append(
                    "[offline-guard] \(model.id): repair needed — \(issueDescriptions.joined(separator: ", "))"
                )
            case .unavailable:
                models[model.id] = .unavailable
                diagnostics.append("[offline-guard] \(model.id): unavailable")
            }
        }
        logger.info("Offline sweep complete: \(self.modelsSummary(models), privacy: .public)")
        return OfflineAvailabilityReport(
            timestamp: Date(),
            models: models,
            diagnostics: diagnostics
        )
    }

    /// Sweep every catalog model and return a typed verdict for each one.
    /// - Parameter extraModels: Optional additional models to verify (e.g. calibration-only).
    /// - Returns: A report ready for UI consumption.
    /// Runs off the main actor when awaited; the synchronous overload is retained for legacy tests.
    static func sweep(extraModels: [AIModel] = []) async -> OfflineAvailabilityReport {
        let report = await Task.detached(priority: .utility) {
            lastSweepWasOffMain = !Thread.isMainThread
            return makeReport(extraModels: extraModels)
        }.value
        return report
    }

    /// Synchronous sweep retained for legacy callers and tests.
    /// For startup, prefer `await sweep(extraModels:)` which runs on a background task.
    static func sweep(extraModels: [AIModel] = []) -> OfflineAvailabilityReport {
        // If already off-main, just run; if on main, still run but record metric
        lastSweepWasOffMain = !Thread.isMainThread
        return makeReport(extraModels: extraModels)
    }

    /// Lightweight check: run the sweep and return true when at least one model is offline-ready.
    /// Does NOT initiate any network activity.
    static func hasAnyOfflineReadyModel(extraModels: [AIModel] = []) -> Bool {
        for model in ModelRegistry.allModels + extraModels {
            if case .ready = ModelManagerService.availability(for: model) {
                return true
            }
        }
        return false
    }

    /// Async variant that performs availability checks off the main actor.
    static func hasAnyOfflineReadyModel(extraModels: [AIModel] = []) async -> Bool {
        await Task.detached(priority: .utility) {
            for model in ModelRegistry.allModels + extraModels {
                if case .ready = ModelManagerService.availability(for: model) {
                    return true
                }
            }
            return false
        }.value
    }

    /// Verify that no model with a resumable download or staged artifact is
    /// mistakenly treated as offline-ready. Returns the IDs of any model whose
    /// download state is paused/resuming/staged but whose `availability` is also `.ready`
    /// (which would be a defect — the model should only be ready after promotion).
    @MainActor
    static func detectStalePromotions(downloadManager: DownloadManager) -> [String] {
        var stale: [String] = []
        for model in ModelRegistry.allModels {
            let status = downloadManager.status(for: model)
            // A model whose download state is paused/resuming/verifying should
            // not also claim `.ready` from the file system.
            if case .ready = ModelManagerService.availability(for: model) {
                switch status.displayState {
                case .paused, .pausing, .resuming, .verifying, .downloading:
                    // This is a stale state — the staged file may have been
                    // promoted outside the download manager lifecycle.
                    stale.append(model.id)
                case .downloaded, .notDownloaded, .cancelled, .failed:
                    break
                }
            }
        }
        return stale
    }

    // MARK: - Helpers

    private static func modelsSummary(_ models: [String: OfflineModelReadiness]) -> String {
        let ready = models.values.filter { if case .ready = $0 { true } else { false } }.count
        let repair = models.values.filter { if case .repairNeeded = $0 { true } else { false } }.count
        let unavailable = models.values.filter { $0 == .unavailable }.count
        return "\(ready) ready, \(repair) repair-needed, \(unavailable) unavailable"
    }
}

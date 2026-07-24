// DownloadState.swift
// ZiroEdge — Privacy-first local AI assistant
//
// State machine for model downloads. Tracks progress per artifact
// (base .gguf and optional mmproj.gguf).

import Foundation

// MARK: - Artifact Type

/// Which file in a paired download this state refers to.
enum ArtifactType: Sendable, Hashable {
    case base           // The main .gguf model file
    case mmproj         // The multimodal projector (vision models only)
}

// MARK: - Download State

/// State machine for a single artifact download.
enum DownloadState: Sendable, Hashable {
    case notDownloaded
    case downloading(progress: Double)      // 0.0 ... 1.0
    case verifying                          // SHA-256 check in progress
    case downloaded                         // Verified and ready
    case failed(error: DownloadError)       // Download or verification failed
    case cancelled                          // User cancelled

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .downloading, .verifying:
            return true
        default:
            return false
        }
    }
}

// MARK: - Download Error

/// Errors that can occur during model download or verification.
enum DownloadError: Sendable, Error, Hashable {
    case networkError
    case diskSpaceInsufficient
    case sha256Mismatch
    case fileCorrupted
    case invalidCatalogMetadata
    case cancelled
    case unknown

    // Transport-layer validation failures (DownloadTransportValidator).
    case contentRejected(reason: String)
    case authorizationRequired(statusCode: Int)
    case httpStatus(code: Int)
    case rangeMismatch(expectedOffset: Int64, actualOffset: Int64?)
    case sizeMismatch(expected: Int64, actual: Int64)
    case structureInvalid(reason: String)

    var localizedDescription: String {
        switch self {
        case .networkError:
            return "Network connection failed"
        case .diskSpaceInsufficient:
            return "Not enough disk space"
        case .sha256Mismatch:
            return "File integrity check failed"
        case .fileCorrupted:
            return "Downloaded file is corrupted"
        case .invalidCatalogMetadata:
            return "Model catalog integrity metadata is invalid"
        case .cancelled:
            return "Download was cancelled"
        case .unknown:
            return "An unknown error occurred"
        case .contentRejected(let reason):
            return "Content rejected: \(reason)"
        case .authorizationRequired(let statusCode):
            return "Authorization required (HTTP \(statusCode))"
        case .httpStatus(let code):
            return "HTTP error \(code)"
        case .rangeMismatch(let expected, let actual):
            if let actual {
                return "Range mismatch: expected offset \(expected), got \(actual)"
            }
            return "Range mismatch: expected offset \(expected), no Content-Range header"
        case .sizeMismatch(let expected, let actual):
            return "Size mismatch: expected \(expected) bytes, got \(actual) bytes"
        case .structureInvalid(let reason):
            return "Invalid file structure: \(reason)"
        }
    }
}

// MARK: - Model Download Status

/// An artifact-level validation issue found during availability checks.
enum ArtifactIssue: Sendable, Hashable {
    case sha256Mismatch
    case sizeMismatch
    case missingGGUFHeader
    case fileNotFound
    case missing(artifact: ArtifactType)
    case unknown(String)
}

/// Overall model availability after validation.
enum ModelAvailability: Sendable, Hashable {
    case ready
    case repairNeeded(issues: [ArtifactIssue])
    case unavailable
}

/// Aggregated download status for a model (combines base + mmproj states).
struct ModelDownloadStatus: Sendable, Hashable {
    let modelID: String
    let baseState: DownloadState
    let mmprojState: DownloadState?     // nil for text-only models

    init(modelID: String = "", baseState: DownloadState, mmprojState: DownloadState?) {
        self.modelID = modelID
        self.baseState = baseState
        self.mmprojState = mmprojState
    }

    /// Whether the model is fully downloaded and verified.
    var isReady: Bool {
        guard baseState.isDownloaded else { return false }
        if let mmproj = mmprojState {
            return mmproj.isDownloaded
        }
        return true
    }

    /// Whether files exist on disk but failed basic validation (GGUF header, SHA, size)
    /// or a required artifact is missing while another is present.
    var isRepairNeeded: Bool {
        // If the model is fully ready, no repair needed.
        if isReady { return false }
        // If any artifact is downloaded or partially present, repair may be needed.
        let hasAnyFile = baseState.isDownloaded
            || (mmprojState?.isDownloaded ?? false)
            || baseState.isDownloading
            || (mmprojState?.isDownloading ?? false)
        // Also check if base was previously downloaded but now fails validation.
        if baseState == .notDownloaded, !modelID.isEmpty {
            // Could have files on disk that fail validation — check via availability.
            if case .repairNeeded = ModelManagerService.availability(for: modelID) {
                return true
            }
        }
        return hasAnyFile && !isReady
    }

    /// Whether any download is currently in progress.
    var isDownloading: Bool {
        baseState.isDownloading || (mmprojState?.isDownloading ?? false)
    }

    /// Overall progress (0.0 ... 1.0). Averages base and mmproj if both present.
    var overallProgress: Double {
        let baseProgress: Double
        switch baseState {
        case .downloading(let progress): baseProgress = progress
        case .downloaded: baseProgress = 1.0
        default: baseProgress = 0.0
        }

        guard let mmproj = mmprojState else {
            return baseProgress
        }

        let mmprojProgress: Double
        switch mmproj {
        case .downloading(let progress): mmprojProgress = progress
        case .downloaded: mmprojProgress = 1.0
        default: mmprojProgress = 0.0
        }

        return (baseProgress + mmprojProgress) / 2.0
    }

    /// Default: nothing downloaded.
    static let empty = ModelDownloadStatus(modelID: "", baseState: .notDownloaded, mmprojState: nil)
}

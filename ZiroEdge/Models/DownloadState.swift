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

    var label: String {
        switch self {
        case .base: return "base"
        case .mmproj: return "mmproj"
        }
    }
}

// MARK: - Download State

/// State machine for a single artifact download.
enum DownloadState: Sendable, Hashable {
    case notDownloaded
    case downloading(progress: Double)      // 0.0 ... 1.0
    case pausing(progress: Double)           // waiting for durable resume state
    case paused(progress: Double)            // usable resume state is persisted
    case resuming(progress: Double)          // exactly one transfer is being restored
    case verifying                           // structural and SHA-256 checks in progress
    case downloaded                         // Verified and ready
    case failed(error: DownloadError)       // Download or verification failed
    case cancelled                          // User cancelled

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var isDownloading: Bool {
        switch self {
        case .downloading, .pausing, .resuming: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .downloading, .pausing, .resuming, .verifying:
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
    /// Verified bytes could not be moved into the installed directory
    /// (transient filesystem failure). Staging is preserved for retry.
    case promotionFailed(underlying: String)

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
        case .promotionFailed(let underlying):
            return "Could not install downloaded files: \(underlying)"
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
    let baseExpectedBytes: Int64
    let mmprojExpectedBytes: Int64?
    let allowsTextOnly: Bool

    init(
        modelID: String = "",
        baseState: DownloadState,
        mmprojState: DownloadState?,
        baseExpectedBytes: Int64 = 0,
        mmprojExpectedBytes: Int64? = nil,
        allowsTextOnly: Bool = false
    ) {
        self.modelID = modelID
        self.baseState = baseState
        self.mmprojState = mmprojState
        self.baseExpectedBytes = baseExpectedBytes
        self.mmprojExpectedBytes = mmprojExpectedBytes
        self.allowsTextOnly = allowsTextOnly
    }

    /// Whether text inference can run with the currently verified artifacts.
    var isReady: Bool {
        guard baseState.isDownloaded else { return false }
        guard let mmproj = mmprojState else { return true }
        return allowsTextOnly || mmproj.isDownloaded
    }

    var isVisionReady: Bool {
        guard baseState.isDownloaded, let mmprojState else { return false }
        return mmprojState.isDownloaded
    }

    /// Summaries for partial outcomes such as valid base + failed projector.
    enum PartialOutcome: Sendable, Hashable {
        case baseDownloaded
        case baseFailed(DownloadError)
        case baseDownloading(progress: Double)
        case basePaused(progress: Double)
        case projectorDownloaded
        case projectorFailed(DownloadError)
        case projectorDownloading(progress: Double)
        case projectorPaused(progress: Double)

        var isBase: Bool {
            switch self {
            case .baseDownloaded, .baseFailed, .baseDownloading, .basePaused: true
            default: false
            }
        }
    }

    /// Expose independent artifact states so UI can surface mixed outcomes.
    var partialOutcomes: [PartialOutcome] {
        var results: [PartialOutcome] = []
        switch baseState {
        case .downloaded: results.append(.baseDownloaded)
        case .failed(let error): results.append(.baseFailed(error))
        case .downloading(let progress), .resuming(let progress): results.append(.baseDownloading(progress: progress))
        case .paused(let progress), .pausing(let progress): results.append(.basePaused(progress: progress))
        default: break
        }
        if let mmproj = mmprojState {
            switch mmproj {
            case .downloaded: results.append(.projectorDownloaded)
            case .failed(let error): results.append(.projectorFailed(error))
            case .downloading(let progress), .resuming(let progress): results.append(.projectorDownloading(progress: progress))
            case .paused(let progress), .pausing(let progress): results.append(.projectorPaused(progress: progress))
            default: break
            }
        }
        return results
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

    /// A single state for catalog/detail presentation of paired artifacts.
    var displayState: DownloadState {
        let states = [baseState, mmprojState].compactMap { $0 }
        if isReady { return .downloaded }
        if states.contains(where: { if case .pausing = $0 { true } else { false } }) {
            return .pausing(progress: overallProgress)
        }
        if states.contains(where: { if case .resuming = $0 { true } else { false } }) {
            return .resuming(progress: overallProgress)
        }
        if isDownloading { return .downloading(progress: overallProgress) }
        if states.contains(where: { if case .paused = $0 { true } else { false } }) {
            return .paused(progress: overallProgress)
        }
        if states.contains(.verifying) { return .verifying }
        // Expose a failure when any artifact has failed, even if another is valid.
        if let failure = states.compactMap({ state -> DownloadError? in
            if case .failed(let error) = state { return error }
            return nil
        }).first {
            return .failed(error: failure)
        }
        if states.contains(.cancelled) { return .cancelled }
        // When base is downloaded but vision model projector is not yet started.
        if let mmprojState, baseState.isDownloaded, mmprojState == .notDownloaded, !isReady {
            return .downloaded
        }
        return .notDownloaded
    }

    /// Overall progress (0.0 ... 1.0), weighted by artifact byte length.
    var overallProgress: Double {
        let baseProgress: Double
        switch baseState {
        case .downloading(let progress), .pausing(let progress), .paused(let progress), .resuming(let progress):
            baseProgress = progress
        case .downloaded: baseProgress = 1.0
        default: baseProgress = 0.0
        }

        guard let mmproj = mmprojState else {
            return baseProgress
        }

        let mmprojProgress: Double
        switch mmproj {
        case .downloading(let progress), .pausing(let progress), .paused(let progress), .resuming(let progress):
            mmprojProgress = progress
        case .downloaded: mmprojProgress = 1.0
        default: mmprojProgress = 0.0
        }

        let baseWeight = max(baseExpectedBytes, 0)
        let projectorWeight = max(mmprojExpectedBytes ?? 0, 0)
        let totalWeight = baseWeight + projectorWeight
        guard totalWeight > 0 else { return (baseProgress + mmprojProgress) / 2.0 }
        return (baseProgress * Double(baseWeight) + mmprojProgress * Double(projectorWeight))
            / Double(totalWeight)
    }

    /// Default: nothing downloaded.
    static let empty = ModelDownloadStatus(modelID: "", baseState: .notDownloaded, mmprojState: nil)
}

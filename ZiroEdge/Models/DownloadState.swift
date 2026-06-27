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
enum DownloadError: String, Sendable, Error, Hashable {
    case networkError           = "Network connection failed"
    case diskSpaceInsufficient  = "Not enough disk space"
    case sha256Mismatch         = "File integrity check failed"
    case fileCorrupted          = "Downloaded file is corrupted"
    case cancelled              = "Download was cancelled"
    case unknown                = "An unknown error occurred"

    var localizedDescription: String {
        rawValue
    }
}

// MARK: - Model Download Status

/// Aggregated download status for a model (combines base + mmproj states).
struct ModelDownloadStatus: Sendable, Hashable {
    let baseState: DownloadState
    let mmprojState: DownloadState?     // nil for text-only models

    /// Whether the model is fully downloaded and verified.
    var isReady: Bool {
        guard baseState.isDownloaded else { return false }
        if let mmproj = mmprojState {
            return mmproj.isDownloaded
        }
        return true
    }

    /// Whether any download is currently in progress.
    var isDownloading: Bool {
        baseState.isDownloading || (mmprojState?.isDownloading ?? false)
    }

    /// Overall progress (0.0 ... 1.0). Averages base and mmproj if both present.
    var overallProgress: Double {
        let baseProgress: Double
        switch baseState {
        case .downloading(let p): baseProgress = p
        case .downloaded: baseProgress = 1.0
        default: baseProgress = 0.0
        }

        guard let mmproj = mmprojState else {
            return baseProgress
        }

        let mmprojProgress: Double
        switch mmproj {
        case .downloading(let p): mmprojProgress = p
        case .downloaded: mmprojProgress = 1.0
        default: mmprojProgress = 0.0
        }

        return (baseProgress + mmprojProgress) / 2.0
    }

    /// Default: nothing downloaded.
    static let empty = ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
}

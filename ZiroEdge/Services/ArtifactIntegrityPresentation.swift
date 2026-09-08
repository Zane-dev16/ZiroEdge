// ArtifactIntegrityPresentation.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single source of truth for artifact-integrity copy: the catalog row
// subtitle, the detail repair banner, and the row accessibility label all
// project these strings. Modal (detail) and inline (catalog row) surfaces
// previously worded the same repair state three different ways; one edit
// here keeps them aligned.

import Foundation

/// Canonical user-facing copy for integrity/repair states. File-level truth
/// stays in `ModelManagerService.availability` / `ArtifactValidationOutcome`;
/// this type owns only the words every surface speaks.
enum ArtifactIntegrityPresentation {
    /// Inline catalog subtitle fragment for a post-sweep unverified model.
    static let needsRepairSubtitle = "Needs repair"
    /// Spoken row state for a repair-needed model.
    static let needsRepairSpoken = "needs repair"
    /// Detail repair banner: title + body shown inline (never a modal).
    static let repairBannerMessage =
        "This model needs repair. Downloading again will replace damaged files."
    /// User sentence for a single artifact issue (detail diagnostics).
    static func message(for issue: ArtifactIssue) -> String {
        switch issue {
        case .sha256Mismatch:
            return "The downloaded file failed its integrity check."
        case .sizeMismatch:
            return "The downloaded file has an unexpected size."
        case .missingGGUFHeader:
            return "The downloaded file is not a valid model file."
        case .fileNotFound, .missing:
            return "A required model file is missing."
        case .unknown(let detail):
            return detail.isEmpty ? "The model could not be verified." : detail
        }
    }
}

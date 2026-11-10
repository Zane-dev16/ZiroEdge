// ArtifactIntegrityPresentation.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single source of truth for what ZiroEdge says about files that did not
// survive verification: the catalog row's status chip, the detail page banner,
// and the row accessibility label all project these strings.
//
// Two rules, both learned from shipping the wrong thing:
//
// 1. "Repair" is not a word a user should ever read. It names a maintenance
//    operation the user cannot perform and cannot evaluate. The only remedy
//    the app actually offers is downloading the files again, so that is what
//    the copy says.
// 2. Absence is not damage. A model with nothing on disk is simply not
//    downloaded; only files that exist and fail verification are described
//    here. `ModelAvailability.notDownloaded` exists to keep the two apart.

import Foundation

/// Canonical user-facing copy for damaged or incomplete downloads. File-level
/// truth stays in `ModelManagerService.availability` / `ArtifactValidationOutcome`;
/// this type owns only the words every surface speaks.
enum ArtifactIntegrityPresentation {
    /// Inline catalog row chip for files that must be fetched again.
    static let needsRedownloadSubtitle = "Download again"
    /// Spoken row state for the same condition.
    static let needsRedownloadSpoken = "needs downloading again"
    /// Detail banner: title + body, shown inline (never a modal).
    static let damagedBannerMessage =
        "Some files for this model didn't download properly. Download it again "
        + "to replace them — nothing else on your iPhone is affected."

    /// One plain sentence per verification failure, for the detail page.
    /// Written for someone deciding what to do next, not for someone debugging.
    static func message(for issue: ArtifactIssue) -> String {
        switch issue {
        case .sha256Mismatch:
            return "Part of the download is damaged, so it can't be used."
        case .sizeMismatch:
            return "The download is the wrong size, so it is probably incomplete."
        case .missingGGUFHeader:
            return "The downloaded file isn't a model file ZiroEdge can read."
        case .fileNotFound, .missing:
            return "A file this model needs isn't on your iPhone."
        case .unknown:
            return "ZiroEdge couldn't check this model's files."
        }
    }
}

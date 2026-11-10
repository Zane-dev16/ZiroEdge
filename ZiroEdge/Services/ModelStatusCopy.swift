// ModelStatusCopy.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single source of truth for what ZiroEdge says about a model's runtime state
// and a refused load. Every alert, banner, row subtitle, and accessibility
// label projects these strings.
//
// The rule this file exists to enforce: a sentence a user reads must be
// understandable without knowing how the app is built. Internal vocabulary —
// calibration, evidence, profile, headroom, jetsam, artifact, projector,
// GGUF, SHA-256, integrity, admission, runtime — is forbidden here. Those
// facts live in `ModelTechnicalDetailsPage`, one tap deeper, for the people
// who actually want them.
//
// `ModelStatusCopyTests` fails the build if a forbidden word reappears in
// user-facing output. That is deliberate: the previous load-failure alert
// read "No safe runtime-memory evidence exists for this configuration yet.
// You can download it now, but ZiroEdge will not load it until calibration
// provides evidence." — true, and useless to the person reading it.

import Foundation

// MARK: - Runtime eligibility

/// What a model's runtime state means, said two ways: once for everyone, once
/// for the reader who opened Technical Details on purpose.
enum RuntimeEligibilityCopy {
    /// Short state word for a row or a status line.
    static func label(for eligibility: RuntimeEligibility) -> String {
        eligibility.label
    }

    /// The plain sentence shown on a model's page. Leads with whether the
    /// model will run, because that is the only thing most readers want.
    static func detail(for eligibility: RuntimeEligibility) -> String {
        switch eligibility {
        case .validated:
            return "Tested on a real iPhone and ready to use. ZiroEdge checks "
                + "how much memory is free before it loads."
        case .estimated:
            return "Ready to use. ZiroEdge works out how much memory this model "
                + "needs and checks your iPhone has room before it loads."
        case .experimental:
            return "Ready to use after you confirm. ZiroEdge has measured how "
                + "much memory this model needs, but it has not finished testing it."
        case .unavailable:
            // Defensive only: the catalog gate refuses to ship a row that lands
            // here, so no shipped model can reach this sentence.
            return "This model can't run in this version of ZiroEdge."
        }
    }

    /// Technical-details wording: precise, and deliberately not on the surface.
    static func technicalDetail(for eligibility: RuntimeEligibility) -> String {
        switch eligibility {
        case .validated:
            return "Validated. Full physical workload accepted on a retained device; "
                + "admission uses the retained full-workload peak."
        case .experimental:
            return "Experimental. Measured load delta only; the full workload has not "
                + "been accepted. Explicit consent is required before a load."
        case .estimated:
            return "Estimated. No device measurement for this shape; admission uses the "
                + "conservative static footprint (artifact bytes and configured context)."
        case .unavailable:
            return "Unavailable. No runtime memory shape is registered for this model."
        }
    }
}

// MARK: - Refused loads

/// Everything a user can be told when a model does not start. Each case exists
/// because a distinct real cause reaches it; none of them reuse another's
/// sentence, so the copy can never claim a cause the app did not observe.
enum ModelLoadCopy {
    /// One short line naming the model and what to do about it.
    static func storageIncomplete(modelName: String) -> String {
        "\(modelName) isn't fully downloaded yet. ZiroEdge needs the whole file "
            + "before it can start — download it again."
    }

    /// Files are on the iPhone but could not be read or did not verify.
    static func damagedFiles(modelName: String) -> String {
        "Some of \(modelName)'s files on this iPhone are damaged or incomplete. "
            + "Download it again to replace them."
    }

    /// The base model file is gone (deleted outside the app, or a failed move).
    static func missingModelFile(modelName: String) -> String {
        "\(modelName)'s model file is missing from this iPhone. Download it again."
    }

    /// The image-support file for a vision model is gone.
    static func missingImageFile(modelName: String) -> String {
        "\(modelName) is missing the file it uses to read images. Download it again "
            + "to add image support."
    }

    /// Headroom shortfall with a measured or estimated requirement. `requiredBytes`
    /// is nil only when no number exists for the shape — the sentence then names
    /// no figure rather than inventing one.
    static func notEnoughMemory(
        modelName: String,
        requiredBytes: UInt64?,
        availableBytes: UInt64
    ) -> String {
        if availableBytes == 0 {
            // A zero sample means the read failed or the device is mid-pressure.
            // Never print "0 bytes available": it reads as a broken app.
            return "\(modelName) needs more free memory than your iPhone can spare "
                + "right now. Close other apps and try again, or pick a smaller model."
        }
        let available = byteLabel(availableBytes)
        guard let requiredBytes, requiredBytes > 0 else {
            return "\(modelName) needs more free memory than the \(available) your iPhone "
                + "can spare right now. Close other apps and try again, or pick a smaller model."
        }
        return "\(modelName) needs about \(byteLabel(requiredBytes)) of free memory, and "
            + "your iPhone can spare about \(available) right now. Close other apps and "
            + "try again, or pick a smaller model."
    }

    /// The model already loaded has no size ZiroEdge can account for, so closing
    /// it out first is the only reliable way to make room.
    static func unloadFirst(priorName: String, modelName: String) -> String {
        "Unload \(priorName) first, then try \(modelName) again."
    }

    /// The device can never host this model, with nothing else running.
    static func tooLargeForDevice(modelName: String) -> String {
        "\(modelName) needs more memory than this iPhone has, even with every other "
            + "app closed. Pick a smaller model."
    }

    /// The memory read failed. Say so instead of inventing a shortfall.
    static func memoryCheckUnavailable(modelName: String) -> String {
        "ZiroEdge couldn't check how much memory is free, so it didn't start "
            + "\(modelName). This is usually temporary — try again in a moment."
    }

    /// Loading would strand too little for iOS to keep the app responsive.
    static func wouldStarveDevice(modelName: String) -> String {
        "Starting \(modelName) would leave your iPhone too little memory to keep "
            + "ZiroEdge running smoothly, so it wasn't started."
    }

    /// The app was backgrounded or iOS raised memory pressure mid-load.
    static func interruptedBySystem() -> String {
        "Loading stopped because ZiroEdge left the foreground or your iPhone was "
            + "short on memory. Try again."
    }

    /// Two unclean attempts on this exact setup; loading is paused on purpose.
    /// Points at the page that actually hosts the reset control — Safety &
    /// Runtime, not Technical Details, which is read-only by design.
    static func pausedAfterRepeatedStops(modelName: String) -> String {
        "\(modelName) stopped twice while starting, so ZiroEdge paused it to protect "
            + "your iPhone. Open Safety & Runtime on this model if you want to clear "
            + "that and try again."
    }

    /// The model is measured and fits, but the user has not agreed to the
    /// experimental runtime. Nothing is wrong with the model.
    static func experimentalConsentRequired(modelName: String) -> String {
        "\(modelName) needs your permission before ZiroEdge can start it. Open the "
            + "model and allow experimental use, then try again."
    }

    /// The native engine failed to map or construct the model.
    static func engineCouldNotStart(modelName: String) -> String {
        "\(modelName) couldn't start. Try again, or choose a different model."
    }

    /// Distinct per-cause sentences for native load failures.
    ///
    /// These stay different from one another on purpose: three unrelated faults
    /// that all read "couldn't start" give a user nothing to act on and a
    /// supporter nothing to work from. Each sentence says what part failed in
    /// words that describe the app, not the engine.
    static func unreadableModelFile(modelName: String) -> String {
        "ZiroEdge couldn't read \(modelName)'s file from this iPhone. "
            + "Download it again to replace it."
    }

    /// The working-memory reservation for the run failed (context creation).
    static func couldNotReserveWorkingMemory(modelName: String) -> String {
        "ZiroEdge couldn't set up enough working memory to start \(modelName). "
            + "Close other apps and try again, or pick a smaller model."
    }

    /// The image-reading half of the runtime failed to initialize.
    static func couldNotStartImageSupport(modelName: String) -> String {
        "The part of \(modelName) that reads images didn't start. "
            + "Try again, or use a text-only model."
    }

    /// A conversation referenced a model that no longer exists.
    static func modelNoLongerAvailable() -> String {
        "The model this conversation used isn't on this iPhone anymore. Choose a "
            + "model to continue."
    }

    /// Generic fallback. Never names a cause the app did not observe.
    static func genericFailure(modelName: String) -> String {
        "\(modelName) couldn't start. Try again, or choose a different model."
    }

    /// Sentence shown under a disabled retry control.
    static func retryUnavailable(reason: String) -> String {
        reason
    }

    /// Shared memory-size formatting. `.memory` counts decimal GB, matching
    /// the numbers iOS itself reports.
    static func byteLabel(_ bytes: UInt64) -> String {
        StorageByteFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }
}

// MARK: - Wording fence

/// The vocabulary this file forbids, kept next to the copy it governs so a new
/// sentence is checked the moment it lands.
enum ModelCopyPolicy {
    /// Words that describe how ZiroEdge is built, not what the user sees.
    static let forbiddenInUserCopy = [
        "calibration",
        "evidence",
        "runtime profile",
        "profile",
        "headroom",
        "jetsam",
        "artifact",
        "projector",
        "mmproj",
        "gguf",
        "sha-256",
        "sha256",
        "integrity",
        "admission",
        "resident",
        "evict",
        "quarantine",
        "mmap",
        "logits",
    ]

    /// Returns the forbidden terms found in `text`, lowercased. Empty is good.
    static func violations(in text: String) -> [String] {
        let lowered = text.lowercased()
        return forbiddenInUserCopy.filter { lowered.contains($0) }
    }
}

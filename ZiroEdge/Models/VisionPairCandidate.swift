// VisionPairCandidate.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Deterministic vision pair candidate with confidence scoring.
// A pair is a base GGUF artifact and a compatible mmproj projector
// from the same pinned Hugging Face repository revision.

import Foundation

// MARK: - Vision Pair Confidence

/// Deterministic confidence level for a vision (base + projector) pair.
/// Scored from repository metadata only — no network round-trips needed.
enum VisionPairConfidence: String, Codable, Sendable, Comparable {
    /// Same architecture, matching quantization tier (e.g. Q4_K_M base + Q8_0 projector for Gemma).
    case high

    /// Compatible architecture but the quantization pairing is not from a known pattern.
    case medium

    /// Architecture match only; the projector filename, size, or quantization tier
    /// does not align with the base. May load but inference quality is uncertain.
    case low

    static func < (lhs: VisionPairConfidence, rhs: VisionPairConfidence) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ c: VisionPairConfidence) -> Int {
        switch c {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }

    var label: String {
        switch self {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        }
    }
}

// MARK: - Vision Pair Candidate

/// A base + projector artifact pair from a Hugging Face repository review.
/// Each candidate carries a deterministic confidence score so the user
/// can make an informed import decision.
struct VisionPairCandidate: Identifiable, Hashable, Sendable {
    /// Deterministic identity from the base artifact id and projector artifact id.
    var id: String { "\(base.id)+\(projector.id)" }

    /// The base GGUF model artifact.
    let base: HFArtifact

    /// The mmproj projector artifact.
    let projector: HFArtifact

    /// Deterministic confidence score.
    let confidence: VisionPairConfidence

    /// Combined download size in bytes.
    var combinedSizeBytes: Int64 { SaturatedArithmetic.add(base.size, projector.size) }

    /// Human-readable combined size.
    var formattedCombinedSize: String {
        StorageByteFormatter.string(fromByteCount: combinedSizeBytes)
    }

    /// Explanation of why this confidence level was assigned.
    var confidenceExplanation: String {
        switch confidence {
        case .high:
            "The base model and projector have matching architectures and aligned quantization tiers — this is the recommended pairing."
        case .medium:
            "The architectures are compatible, but the quantization tiers do not follow a known pairing pattern. The model should load, but verify the projector matches the base quantization."
        case .low:
            "Only architecture compatibility was verified. The projector may not be designed for this base model. Import is allowed but unsupported."
        }
    }

    /// Whether the projector is required for this architecture family.
    /// Some architectures (e.g. Gemma) require a CLIP projector for vision;
    /// others (e.g. LLaVA-style) embed the projector.
    var projectorArchitectureNote: String? {
        let arch = base.architecture.lowercased()
        if arch.contains("gemma") {
            return "Gemma vision models require a CLIP projector (mmproj). Without it, vision inference is not possible."
        }
        if arch.contains("qwen") && arch.contains("vl") {
            return "Qwen2.5-VL requires an mmproj for vision. The base GGUF alone provides text-only inference."
        }
        return nil
    }
}

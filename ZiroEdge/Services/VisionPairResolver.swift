// VisionPairResolver.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Resolves compatible vision (base + mmproj) pairs from a Hugging Face
// repository review with deterministic confidence scoring. No network
// access required — all scoring is derived from artifact metadata.

import Foundation

// MARK: - Vision Pair Resolver

/// Deterministic resolver for vision model artifact pairs.
/// Examines artifact filenames, sizes, architectures, and quantization
/// tiers to produce ranked pair candidates with confidence scores.
struct VisionPairResolver: Sendable {

    // MARK: - Known Pairing Patterns

    /// Known quantization tier pairings: base tier → expected projector tier.
    /// For many vision architectures (Gemma, LLaVA), the projector uses a
    /// higher-precision quantization than the base model because it is
    /// smaller and precision matters more for vision features.
    private static let quantizationPairs: [(base: String, projector: String, confidence: VisionPairConfidence)] = [
        // Gemma family: Q4_K_M base → Q8_0 projector (most common)
        ("Q4_K_M", "Q8_0", .high),
        ("Q4_K_S", "Q8_0", .high),
        ("Q4_0", "Q8_0", .medium),
        ("Q5_K_M", "Q8_0", .high),
        ("Q5_K_S", "Q8_0", .high),
        ("Q6_K", "Q8_0", .medium),
        ("Q8_0", "Q8_0", .medium),
        ("Q8_0", "F16", .high),
        ("Q4_K_M", "F16", .medium),
        ("Q5_K_M", "F16", .medium),
        // Generic: same tier → medium
        ("Q4_K_M", "Q4_K_M", .medium),
        ("Q4_K_S", "Q4_K_S", .medium),
        ("Q5_K_M", "Q5_K_M", .medium),
        ("Q6_K", "Q6_K", .medium),
    ]

    // MARK: - Public API

    /// Resolve all possible vision pairs from a repository review, ranked by
    /// confidence (highest first), with ties broken by total download size.
    func resolvePairs(from review: HFRepositoryReview) -> [VisionPairCandidate] {
        let bases = review.baseArtifacts
        let projectors = review.projectorArtifacts

        guard !bases.isEmpty, !projectors.isEmpty else { return [] }

        var candidates: [VisionPairCandidate] = []
        for base in bases {
            for projector in projectors {
                guard isArchitectureCompatible(base: base, projector: projector) else { continue }
                let confidence = scoreConfidence(base: base, projector: projector)
                candidates.append(VisionPairCandidate(
                    base: base,
                    projector: projector,
                    confidence: confidence
                ))
            }
        }

        // Sort: highest confidence first, then smaller combined size
        candidates.sort { a, b in
            if a.confidence != b.confidence { return a.confidence < b.confidence }
            return a.combinedSizeBytes < b.combinedSizeBytes
        }
        return candidates
    }

    /// Find the best vision pair for a specific base artifact. Returns nil when
    /// no compatible projector exists or multiple projectors have equal best
    /// confidence, because file size is not compatibility evidence.
    func bestPair(for base: HFArtifact, in review: HFRepositoryReview) -> VisionPairCandidate? {
        let pairs = resolvePairs(from: review).filter { $0.base.id == base.id }
        guard let best = pairs.first else { return nil }
        guard pairs.dropFirst().first(where: { $0.confidence == best.confidence }) == nil else {
            return nil
        }
        return best
    }

    /// Suggest the single recommended pair from a review.
    /// Returns nil when the repository has no compatible vision pair,
    /// or when the top candidate has low confidence and there are
    /// ambiguous alternatives (multiple projectors at the same level).
    func suggestedPair(from review: HFRepositoryReview) -> VisionPairCandidate? {
        let pairs = resolvePairs(from: review)
        guard let best = pairs.first else { return nil }

        // Reject equally ranked alternatives rather than using file size as a
        // compatibility tie-breaker.
        if pairs.dropFirst().contains(where: { $0.confidence == best.confidence }) {
            return nil
        }
        return best
    }

    /// Whether a review contains at least one viable vision pair.
    func hasViableVisionPair(_ review: HFRepositoryReview) -> Bool {
        suggestedPair(from: review) != nil
    }

    /// Human-readable explanation for why no vision pair was found.
    func noVisionPairReason(for review: HFRepositoryReview) -> String? {
        if review.projectorArtifacts.isEmpty {
            return "No vision projector (mmproj) file was found in this repository at this revision. Only text-only import is available."
        }
        if review.baseArtifacts.isEmpty {
            return "No compatible base GGUF model was found."
        }
        let pairs = resolvePairs(from: review)
        if pairs.isEmpty {
            return "No projector in this repository is architecture-compatible with any base model. The projectors may target a different model family."
        }
        if let best = pairs.first,
           pairs.dropFirst().contains(where: { $0.confidence == best.confidence }) {
            return "Multiple projector candidates have equal compatibility evidence. ZiroEdge will not guess between them."
        }
        return nil
    }

    // MARK: - Scoring

    /// Check architecture compatibility between base and projector.
    private func isArchitectureCompatible(base: HFArtifact, projector: HFArtifact) -> Bool {
        // Projectors for vision models are typically "clip" architecture.
        if projector.architecture == "clip" { return true }
        // Direct architecture match.
        if projector.architecture == base.architecture { return true }
        // Gemma models accept "gemma" or "gemma2"/"gemma3" architecture projectors.
        let baseArch = base.architecture.lowercased()
        let projectorArch = projector.architecture.lowercased()
        if (baseArch.hasPrefix("gemma") || baseArch == "clip") &&
           (projectorArch.hasPrefix("gemma") || projectorArch == "clip") {
            return true
        }
        return false
    }

    /// Score confidence for a base + projector pair.
    private func scoreConfidence(base: HFArtifact, projector: HFArtifact) -> VisionPairConfidence {
        // 1. Check known quantization pairings.
        if let match = Self.quantizationPairs.first(where: {
            base.quantization == $0.base && projector.quantization == $0.projector
        }) {
            return match.confidence
        }

        // 2. Check naming conventions for embedded hints.
        let baseName = base.filename.lowercased()
        let projName = projector.filename.lowercased()

        // Extract model family from filenames.
        let baseFamily = baseModelFamily(baseName)
        let projFamily = baseModelFamily(projName)

        // Same model family with mmproj in name → medium confidence.
        if baseFamily == projFamily && projName.contains("mmproj") {
            return .medium
        }

        // Same quantization tier → medium confidence.
        let baseQuant = base.quantization
        let projQuant = projector.quantization
        if baseQuant == projQuant {
            return .medium
        }

        // Projector filename contains the base quantization hint.
        if projName.contains(baseQuant.lowercased()) {
            return .medium
        }

        // Architecture match only → low confidence.
        return .low
    }

    /// Extract a model family hint from an artifact filename.
    private func baseModelFamily(_ filename: String) -> String? {
        let families = ["gemma", "qwen", "llama", "phi", "mistral", "smolvlm"]
        return families.first { filename.contains($0) }
    }
}

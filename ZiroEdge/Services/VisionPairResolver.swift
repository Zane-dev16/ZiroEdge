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
                guard Self.isArchitectureCompatible(base: base, projector: projector) else { continue }
                let confidence = scoreConfidence(base: base, projector: projector)
                candidates.append(VisionPairCandidate(
                    base: base,
                    projector: projector,
                    confidence: confidence
                ))
            }
        }

        // Sort: highest confidence first, then smaller combined size
        candidates.sort { firstCandidate, secondCandidate in
            if firstCandidate.confidence != secondCandidate.confidence {
                return firstCandidate.confidence < secondCandidate.confidence
            }
            return firstCandidate.combinedSizeBytes < secondCandidate.combinedSizeBytes
        }
        return candidates
    }

    /// Find the best vision pair for a specific base artifact. Returns nil when
    /// no compatible projector exists or multiple projectors have equal best
    /// confidence, because file size is not compatibility evidence.
    func bestPair(for base: HFArtifact, in review: HFRepositoryReview) -> VisionPairCandidate? {
        let pairs = resolvePairs(from: review).filter { $0.base.id == base.id }
        guard let best = pairs.first, best.confidence == .high else { return nil }
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
        guard let best = pairs.first, best.confidence == .high else { return nil }

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
        if pairs.first?.confidence != .high {
            return "No projector has high-confidence compatibility evidence for the selected base model."
        }
        return nil
    }

    // MARK: - Scoring

    /// Check architecture compatibility between base and projector.
    static func isArchitectureCompatible(base: HFArtifact, projector: HFArtifact) -> Bool {
        let baseArch = base.architecture.lowercased()
        let projectorArch = projector.architecture.lowercased()
        // Projectors for vision models are typically "clip" architecture.
        if projectorArch == "clip" { return true }
        // Direct architecture match.
        if projectorArch == baseArch { return true }
        // Gemma models accept "gemma" or "gemma2"/"gemma3" architecture projectors.
        return baseArch.hasPrefix("gemma") && projectorArch.hasPrefix("gemma")
    }

    /// Score confidence for a base + projector pair. Quantization is never
    /// compatibility evidence by itself: an unrelated generic CLIP projector
    /// can use the same common tier. A high-confidence pair must first establish
    /// a deterministic model identity through filenames or per-artifact metadata.
    private func scoreConfidence(base: HFArtifact, projector: HFArtifact) -> VisionPairConfidence {
        guard hasDeterministicPairingEvidence(base: base, projector: projector) else {
            return .low
        }

        if let match = Self.quantizationPairs.first(where: {
            base.quantization == $0.base && projector.quantization == $0.projector
        }) {
            return match.confidence
        }
        return .medium
    }

    private func hasDeterministicPairingEvidence(base: HFArtifact, projector: HFArtifact) -> Bool {
        let baseIdentity = filenameIdentity(base.filename)
        let projectorIdentity = filenameIdentity(projector.filename)
        if let baseIdentity, baseIdentity == projectorIdentity { return true }

        let baseMetadata = metadataIdentity(base.metadata.modelName)
        let projectorMetadata = metadataIdentity(projector.metadata.modelName)
        return baseMetadata != nil && baseMetadata == projectorMetadata
    }

    private func filenameIdentity(_ filename: String) -> String? {
        let quantizations = [
            "q2-k", "q3-k-s", "q3-k-m", "q3-k-l", "q4-0", "q4-k-s",
            "q4-k-m", "q5-0", "q5-k-s", "q5-k-m", "q6-k", "q8-0", "f16", "bf16"
        ]
        var value = filename.lowercased()
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "mmproj", with: "")
        for quantization in quantizations {
            value = value.replacingOccurrences(of: quantization, with: "")
            value = value.replacingOccurrences(of: quantization.replacingOccurrences(of: "-", with: "_"), with: "")
        }
        let tokens = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let generic = Set(["model", "base", "projector", "vision", "gguf"])
        let meaningful = tokens.filter { !generic.contains($0) }
        guard !meaningful.isEmpty else { return nil }
        return meaningful.joined(separator: "-")
    }

    private func metadataIdentity(_ name: String?) -> String? {
        guard let name else { return nil }
        let tokens = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let generic = Set(["model", "base", "projector", "vision", "fixture", "test", "unknown"])
        let meaningful = tokens.filter { !generic.contains($0) }
        guard !meaningful.isEmpty else { return nil }
        return meaningful.joined(separator: "-")
    }
}

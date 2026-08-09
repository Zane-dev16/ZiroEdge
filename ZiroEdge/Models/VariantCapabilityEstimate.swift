import Foundation

/// Conservative comparison derived only from artifact metadata and device RAM.
struct VariantCapabilityEstimate: Equatable, Sendable {
    enum Footprint: Equatable, Sendable {
        case smallest(total: Int)
        case intermediate(total: Int)
        case largest(total: Int)

        var caption: String {
            switch self {
            case .smallest(let total): "smallest of \(total) variants"
            case .intermediate(let total): "intermediate of \(total) variants"
            case .largest(let total): "largest of \(total) variants"
            }
        }
    }

    enum MemoryFit: String, Equatable, Sendable {
        case likelyFits = "likely fits device memory"
        case mayExceed = "may exceed device memory"
    }

    let precisionBits: Int?
    let footprint: Footprint?
    let memoryFit: MemoryFit?

    init(
        artifact: HFArtifact,
        candidates: [HFArtifact],
        physicalRAM: UInt64?,
        contextLength: Int
    ) {
        precisionBits = Self.precisionBits(for: artifact.quantization)
        footprint = Self.footprint(for: artifact, among: candidates)
        if let physicalRAM, physicalRAM > 0 {
            let estimate = ImportRAMAssessment.estimatedBytes(
                artifactBytes: artifact.size,
                contextLength: contextLength
            )
            memoryFit = estimate < physicalRAM ? .likelyFits : .mayExceed
        } else {
            memoryFit = nil
        }
    }

    var caption: String? {
        let components = [
            precisionBits.map { "\($0)-bit precision" },
            footprint?.caption,
            memoryFit?.rawValue,
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    static func precisionBits(for quantization: String) -> Int? {
        let canonical = quantization.uppercased()
        if canonical == "F16" || canonical == "BF16" { return 16 }
        for bits in 2...8 where canonical.hasPrefix("Q\(bits)") { return bits }
        return nil
    }

    private static func footprint(for artifact: HFArtifact, among candidates: [HFArtifact]) -> Footprint? {
        guard candidates.count > 1,
              let minimum = candidates.map(\.size).min(),
              let maximum = candidates.map(\.size).max() else { return nil }
        let total = candidates.count
        guard minimum != maximum else { return .intermediate(total: total) }
        if artifact.size == minimum,
           candidates.filter({ $0.size == minimum }).count == 1 {
            return .smallest(total: total)
        }
        if artifact.size == maximum,
           candidates.filter({ $0.size == maximum }).count == 1 {
            return .largest(total: total)
        }
        return .intermediate(total: total)
    }
}

// AIModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Model registry for curated on-device models.
// Each model carries paired artifact metadata (base .gguf + optional mmproj.gguf).

import Foundation

#if DEBUG
enum HermeticUITestRuntime {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--uitesting-hermetic-model")
    }
}
#endif

// MARK: - Model Type

/// Whether a model supports vision (requires mmproj) or text-only.
enum ModelType: String, Sendable, CaseIterable {
    case vision    // requires paired mmproj.gguf
    case text      // base .gguf only
}

// MARK: - License Info

/// Per-model license attribution. Displayed in Settings → Licenses.
struct LicenseInfo: Sendable, Hashable {
    let name: String           // e.g. "Apache 2.0", "Meta Llama Community License"
    let url: URL               // Full license text URL
    let copyright: String      // e.g. "Copyright 2024 Meta Platforms, Inc."
}

// MARK: - AI Model

/// A curated model entry in the ZiroEdge registry.
/// This is the single source of truth for all model metadata.
struct AIModel: Identifiable, Hashable, Sendable {
    let id: String                  // e.g. "llama3.2-3b-q4"
    let displayName: String         // e.g. "Llama 3.2 3B"
    let description: String         // Human-readable capability description
    let modelType: ModelType        // .vision or .text
    let baseURL: URL                // .gguf download URL
    let mmprojURL: URL?             // nil for text-only models
    let baseFileSizeBytes: Int64    // Expected size of base .gguf
    let mmprojFileSizeBytes: Int64? // Expected size of mmproj.gguf (nil for text-only)
    let baseSHA256: String          // Expected SHA-256 of base .gguf
    let mmprojSHA256: String?       // Expected SHA-256 of mmproj.gguf (nil for text-only)
    let quantization: String        // e.g. "Q4_K_M"
    let config: ModelConfiguration  // Per-model presets (prompt format, sampling, etc.)
    let license: LicenseInfo

    // MARK: Computed

    /// Total download size (base + mmproj if present).
    var totalFileSizeBytes: Int64 {
        baseFileSizeBytes + (mmprojFileSizeBytes ?? 0)
    }

    /// Installed base-artifact key. Calibration may reuse a registered artifact without copying it.
    var baseArtifactStorageID: String {
        if id == "gemma-4-e4b-q4-text" { return "gemma-4-e4b-q4" }
#if DEBUG
        if id == "gemma-4-e4b-q4-text-calibration" { return "gemma-4-e4b-q4" }
#endif
        return id
    }

    /// Whether this model requires a paired mmproj download.
    var requiresMMProj: Bool {
        modelType == .vision && mmprojURL != nil
    }

    var runtimeEligibility: RuntimeEligibility {
        MemoryProfileRegistry.profile(for: id)?.runtimeEligibility ?? .unavailable
    }

    var runtimeEligibilityExplanation: String {
        switch runtimeEligibility {
        case .validated:
            "Passed the retained full-workload physical-device acceptance policy."
        case .experimental:
            "Measured load evidence provides a conservative admission floor, but the full workload is not yet validated. Explicit consent is required."
        case .unavailable:
            "No safe runtime-memory evidence exists for this configuration yet. You can download it now, but ZiroEdge will not load it until calibration provides evidence."
        }
    }

    /// Human-readable file size (e.g. "2.1 GB").
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalFileSizeBytes, countStyle: .file)
    }
}

// MARK: - Model Registry

/// The complete ZiroEdge model catalog.
/// Phase 1 ships with text-only. Phase 2 adds vision models.
// Existing catalog symbols retain their public names for compatibility.
// swiftlint:disable identifier_name

enum ModelRegistry {

    // MARK: - Phase 1: Text-Only

    static let llama32_3B = AIModel(
        id: "llama3.2-3b-q4",
        displayName: "Llama 3.2 3B",
        description: "Fast general-purpose text chat. No vision.",
        modelType: .text,
        baseURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        mmprojURL: nil,
        baseFileSizeBytes: 2_019_377_696,
        mmprojFileSizeBytes: nil,
        baseSHA256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
        mmprojSHA256: nil,
        quantization: "Q4_K_M",
        config: .llama32,
        license: LicenseInfo(
            name: "Meta Llama Community License",
            url: URL(string: "https://raw.githubusercontent.com/meta-llama/llama-models/main/LICENSE")!,
            copyright: "Copyright 2024 Meta Platforms, Inc."
        )
    )

    // MARK: - Phase 2: Vision Models

    static let gemma4_e2b = AIModel(
        id: "gemma-4-e2b-q4",
        displayName: "Gemma 4 E2B",
        description: "Compact vision model. Understands images and text. Runs on most devices.",
        modelType: .vision,
        baseURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e2b-q4km-gguf/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e2b-q4km-gguf/resolve/main/mmproj-gemma-4-E2B-it-Q8_0.gguf")!,
        baseFileSizeBytes: 3_427_861_088,  // 3.19 GB
        mmprojFileSizeBytes: 557_367_776,  // 532 MB
        baseSHA256: "8580ede90c6a7fdd5bfee2c016b3a7601d471895b192a0fddaf655d577b12e3b",
        mmprojSHA256: "8a82e0fd831bb7cb5c8898b86393eb14042986b950a60e1034bf21d061aac8a8",
        quantization: "Q4_K_M",
        config: .gemma4,
        license: LicenseInfo(
            name: "Gemma Terms of Use",
            url: URL(string: "https://ai.google.dev/gemma/terms")!,
            copyright: "Copyright 2024 Google LLC"
        )
    )

    static let gemma4_e4b = AIModel(
        id: "gemma-4-e4b-q4",
        displayName: "Gemma 4 E4B",
        description: "Higher-quality vision model. Better accuracy on complex images.",
        modelType: .vision,
        baseURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e4b-q4km-gguf/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e4b-q4km-gguf/resolve/main/mmproj-gemma-4-E4B-it-Q8_0.gguf")!,
        baseFileSizeBytes: 5_335_273_056,  // 4.97 GB
        mmprojFileSizeBytes: 559_874_528,  // 534 MB
        baseSHA256: "9d23b7b4cd3c6c6c9ffadd7a9b1e16448621005b80a803e85afa3ca2c48714e3",
        mmprojSHA256: "51d4b7fd825e4569f746b200fccc5332bf914e8ef7cbe447272ce4fec6df3db6",
        quantization: "Q4_K_M",
        config: .gemma4,
        license: LicenseInfo(
            name: "Gemma Terms of Use",
            url: URL(string: "https://ai.google.dev/gemma/terms")!,
            copyright: "Copyright 2024 Google LLC"
        )
    )

    static let gemma4_e4b_text = AIModel(
        id: "gemma-4-e4b-q4-text",
        displayName: "Gemma 4 E4B Text",
        description: "Higher-quality text chat using the E4B base model without the vision projector.",
        modelType: .text,
        baseURL: gemma4_e4b.baseURL,
        mmprojURL: nil,
        baseFileSizeBytes: gemma4_e4b.baseFileSizeBytes,
        mmprojFileSizeBytes: nil,
        baseSHA256: gemma4_e4b.baseSHA256,
        mmprojSHA256: nil,
        quantization: gemma4_e4b.quantization,
        config: .gemma4E4BText,
        license: gemma4_e4b.license
    )

#if DEBUG
    /// DEBUG calibration identity. Reuses the registered E4B base artifact and never requests a projector.
    static let gemma4E4BTextCalibration = AIModel(
        id: "gemma-4-e4b-q4-text-calibration",
        displayName: "Gemma 4 E4B Text Calibration",
        description: "Calibration-only text runtime. Not available for normal conversations.",
        modelType: .text,
        baseURL: gemma4_e4b.baseURL,
        mmprojURL: nil,
        baseFileSizeBytes: gemma4_e4b.baseFileSizeBytes,
        mmprojFileSizeBytes: nil,
        baseSHA256: gemma4_e4b.baseSHA256,
        mmprojSHA256: nil,
        quantization: gemma4_e4b.quantization,
        config: .gemma4E4BTextCalibration,
        license: gemma4_e4b.license
    )
#endif

    /* Reference: SmolVLM and Qwen2.5-VL (commented out)
    static let smolVLM_500M = AIModel(
        id: "smolvlm-500m-q4",
        displayName: "SmolVLM 500M",
        description: "Lightweight vision model. Runs on all iOS 18 devices.",
        modelType: .vision,
        baseURL: URL(string: "https://huggingface.co/zanish-labs/SmolVLM-500M-Q4_K_M-gguf/resolve/main/SmolVLM-500M-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/SmolVLM-500M-Q4_K_M-gguf/resolve/main/mmproj-SmolVLM-500M-f16.gguf")!,
        baseFileSizeBytes: 400_000_000,
        mmprojFileSizeBytes: 150_000_000,
        baseSHA256: "",
        mmprojSHA256: "",
        quantization: "Q4_K_M",
        config: .smolVLM,
        license: LicenseInfo(
            name: "Apache 2.0",
            url: URL(string: "https://huggingface.co/HuggingFaceTB/SmolVLM-Instruct/blob/main/LICENSE")!,
            copyright: "Copyright 2024 Hugging Face"
        )
    )

    static let qwen25VL_3B = AIModel(
        id: "qwen2.5-vl-3b-q4",
        displayName: "Qwen 2.5-VL 3B",
        description: "High-quality vision-language model. Requires 6 GB+ RAM.",
        modelType: .vision,
        baseURL: URL(string: "https://huggingface.co/zanish-labs/Qwen2.5-VL-3B-Q4_K_M-gguf/resolve/main/Qwen2.5-VL-3B-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/Qwen2.5-VL-3B-Q4_K_M-gguf/resolve/main/mmproj-Qwen2.5-VL-3B-f16.gguf")!,
        baseFileSizeBytes: 2_000_000_000,
        mmprojFileSizeBytes: 200_000_000,
        baseSHA256: "",
        mmprojSHA256: "",
        quantization: "Q4_K_M",
        config: .qwen25VL,
        license: LicenseInfo(
            name: "Apache 2.0",
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct/blob/main/LICENSE")!,
            copyright: "Copyright 2024 Alibaba Cloud"
        )
    )
    */

    // MARK: - Registry Access

    /// All available models for the current phase.
    static var allModels: [AIModel] {
        [
            llama32_3B,
            gemma4_e2b,
            gemma4_e4b_text,
            gemma4_e4b,
            // Reference: smolVLM_500M, qwen25VL_3B,
        ]
    }

    /// Calibration identities are deliberately absent from normal catalog UI and Release builds.
    static var calibrationModels: [AIModel] {
#if DEBUG
        [gemma4E4BTextCalibration]
#else
        []
#endif
    }

    /// Profiles promoted by retained full-workload physical acceptance.
    static var productionModels: [AIModel] {
        allModels.filter { $0.runtimeEligibility == .validated }
    }

    /// Models the current user may select for inference. Experimental profiles
    /// require explicit per-profile consent; unavailable profiles remain catalog-only.
    static var selectableModels: [AIModel] {
        allModels.filter {
            switch $0.runtimeEligibility {
            case .validated: true
            case .experimental: ExperimentalModelConsent.isGranted(for: $0)
            case .unavailable: false
            }
        }
    }

    static func availableModels(deviceRAM: Int64) -> [AIModel] {
        allModels.filter {
            guard let profile = MemoryProfileRegistry.profile(for: $0.id) else { return false }
            return profile.runtimeEligibility != .unavailable
                && UInt64(clamping: deviceRAM) >= profile.minimumPhysicalRAMBytes
        }
    }

    /// Look up normal catalog and calibration-only identities by ID.
    static func model(for id: String) -> AIModel? {
        (allModels + calibrationModels).first { $0.id == id }
    }
}

enum ExperimentalModelConsent {
    private static let prefix = "experimentalModelConsent."

    static func isGranted(for model: AIModel, defaults: UserDefaults = .standard) -> Bool {
        guard model.runtimeEligibility == .experimental,
              let profile = MemoryProfileRegistry.profile(for: model.id) else { return false }
        return defaults.bool(forKey: prefix + profile.id)
    }

    static func setGranted(_ granted: Bool, for model: AIModel, defaults: UserDefaults = .standard) {
        guard let profile = MemoryProfileRegistry.profile(for: model.id) else { return }
        defaults.set(granted, forKey: prefix + profile.id)
    }
}

// swiftlint:enable identifier_name

// AIModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Model registry for curated on-device models.
// Each model carries paired artifact metadata (base .gguf + optional mmproj.gguf).

import Foundation

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
    let minimumDeviceRAM: Int64     // Minimum device RAM in bytes. MemoryBudgeter enforces this.
    let license: LicenseInfo

    // MARK: Computed

    /// Total download size (base + mmproj if present).
    var totalFileSizeBytes: Int64 {
        baseFileSizeBytes + (mmprojFileSizeBytes ?? 0)
    }

    /// Whether this model requires a paired mmproj download.
    var requiresMMProj: Bool {
        modelType == .vision && mmprojURL != nil
    }

    /// Human-readable file size (e.g. "2.1 GB").
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalFileSizeBytes, countStyle: .file)
    }
}

// MARK: - Model Registry

/// The complete ZiroEdge model catalog.
/// Phase 1 ships with text-only. Phase 2 adds vision models.
enum ModelRegistry {

    // MARK: - Phase 1: Text-Only

    static let llama32_3B = AIModel(
        id: "llama3.2-3b-q4",
        displayName: "Llama 3.2 3B",
        description: "Fast general-purpose text chat. No vision.",
        modelType: .text,
        baseURL: URL(string: "https://huggingface.co/zanish-labs/llama-3.2-3b-q4km-gguf/resolve/main/llama-3.2-3b-Q4_K_M.gguf")!,
        mmprojURL: nil,
        baseFileSizeBytes: 2_100_000_000,  // ~2 GB
        mmprojFileSizeBytes: nil,
        baseSHA256: "",  // TODO: fill after upload
        mmprojSHA256: nil,
        quantization: "Q4_K_M",
        config: .llama32,
        minimumDeviceRAM: 3_500_000_000,  // 3.5 GB
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
        baseURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e2b-q4km-gguf/resolve/main/gemma-4-e2b-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e2b-q4km-gguf/resolve/main/mmproj-gemma-4-e2b-f16.gguf")!,
        baseFileSizeBytes: 1_500_000_000,  // ~1.5 GB
        mmprojFileSizeBytes: 200_000_000,  // ~200 MB
        baseSHA256: "",  // TODO: fill after upload
        mmprojSHA256: "",  // TODO: fill after upload
        quantization: "Q4_K_M",
        config: .gemma4,
        minimumDeviceRAM: 3_000_000_000,  // 3 GB
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
        baseURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e4b-q4km-gguf/resolve/main/gemma-4-e4b-Q4_K_M.gguf")!,
        mmprojURL: URL(string: "https://huggingface.co/zanish-labs/gemma-4-e4b-q4km-gguf/resolve/main/mmproj-gemma-4-e4b-f16.gguf")!,
        baseFileSizeBytes: 2_800_000_000,  // ~2.8 GB
        mmprojFileSizeBytes: 200_000_000,  // ~200 MB
        baseSHA256: "",  // TODO: fill after upload
        mmprojSHA256: "",  // TODO: fill after upload
        quantization: "Q4_K_M",
        config: .gemma4,
        minimumDeviceRAM: 5_000_000_000,  // 5 GB
        license: LicenseInfo(
            name: "Gemma Terms of Use",
            url: URL(string: "https://ai.google.dev/gemma/terms")!,
            copyright: "Copyright 2024 Google LLC"
        )
    )

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
        minimumDeviceRAM: 1_500_000_000,
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
        minimumDeviceRAM: 6_000_000_000,
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
            gemma4_e4b,
            // Reference: smolVLM_500M, qwen25VL_3B,
        ]
    }

    /// Models that can run on the current device (RAM-gated).
    static func availableModels(deviceRAM: Int64) -> [AIModel] {
        allModels.filter { $0.minimumDeviceRAM <= deviceRAM }
    }

    /// Look up a model by ID.
    static func model(for id: String) -> AIModel? {
        allModels.first { $0.id == id }
    }
}

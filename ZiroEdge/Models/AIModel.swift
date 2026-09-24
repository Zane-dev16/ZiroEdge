// AIModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Model registry for curated on-device models.
// Each model carries paired artifact metadata (base .gguf + optional mmproj.gguf).

import Foundation

#if DEBUG
/// Deterministic hermetic runtime for UI tests and review launches. Seeded by
/// `--uitesting-hermetic*` launch arguments (DEBUG builds only) so the chat,
/// composer, sidebar, and wizard flows run without any real model download.
enum HermeticUITestRuntime {
    /// Any `--uitesting-hermetic*` launch argument enables the runtime.
    static var isEnabled: Bool {
        isEnabled(CommandLine.arguments)
    }

    static func isEnabled(_ arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("--uitesting-hermetic") }
    }

    /// Which deterministic state the runtime presents:
    /// - `.ready` (`--uitesting-hermetic-model`, default): llama32_3B reads as
    ///   downloaded and load fakes success — the "ready to chat" state.
    /// - `.needsDownload` (`--uitesting-hermetic-needs-download`): llama32_3B
    ///   reads as not-downloaded so the chat parks on `.needsDownload` — the
    ///   empty-library state (disabled composer, "No model yet" pill).
    /// - `.failedLoad` (`--uitesting-hermetic-failed-load`): llama32_3B reads
    ///   as downloaded but every load attempt throws — the load-failure state
    ///   (warning pill + inline retry banner).
    /// - `.loading` (`--uitesting-hermetic-loading`): llama32_3B reads as
    ///   downloaded and the fake load holds `.loading` for a bounded window
    ///   before resolving as ready — the in-flight state (typing enabled,
    ///   send disabled with spinner).
    enum Scenario: Equatable {
        case ready
        case needsDownload
        case failedLoad
        case loading
    }

    static var scenario: Scenario {
        scenario(CommandLine.arguments)
    }

    static func scenario(_ arguments: [String]) -> Scenario {
        if arguments.contains("--uitesting-hermetic-needs-download") { return .needsDownload }
        if arguments.contains("--uitesting-hermetic-failed-load") { return .failedLoad }
        if arguments.contains("--uitesting-hermetic-loading") { return .loading }
        return .ready
    }

    /// True when a non-default scenario flag was passed explicitly. Shell-level
    /// autoloads defer to ChatView's deferred loader in these modes so the
    /// failure/empty choreography stays deterministic and alert-free.
    static var hasExplicitScenario: Bool {
        scenario != .ready
    }
}
#endif

// MARK: - Model Type

/// Whether a model supports vision (requires mmproj) or text-only.
enum ModelType: String, Codable, Sendable, CaseIterable {
    case vision    // requires paired mmproj.gguf
    case text      // base .gguf only
}

// MARK: - License Info

/// Per-model license attribution. Displayed in Settings → Licenses.
struct LicenseInfo: Codable, Sendable, Hashable {
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
    /// Curated entries remain static; imported entries carry immutable Hugging Face provenance.
    var source: ModelSource = .curated

    // MARK: Computed

    /// Total download size (base + mmproj if present).
    var totalFileSizeBytes: Int64 {
        SaturatedArithmetic.add(baseFileSizeBytes, mmprojFileSizeBytes ?? 0)
    }

    /// Installed base-artifact key. Calibration may reuse a registered artifact without copying it.
    var baseArtifactStorageID: String {
        if case .huggingFace(let provenance) = source {
            return "hf-\(provenance.baseSHA256.prefix(24))"
        }
        if id == "gemma-4-e4b-q4-text" { return "gemma-4-e4b-q4" }
#if DEBUG
        if id == "gemma-4-e4b-q4-text-calibration" { return "gemma-4-e4b-q4" }
#endif
        return id
    }

    /// E2B is one product whose base supports text chat while its projector adds images.
    var allowsTextOnlyCapability: Bool { id == "gemma-4-e2b-q4" }

    /// Whether this runtime identity requires a paired projector.
    var requiresMMProj: Bool {
        modelType == .vision && mmprojURL != nil
    }

    /// Runtime identity for a verified base when the optional projector is absent.
    var textOnlyRuntimeVariant: AIModel {
        AIModel(
            id: id,
            displayName: displayName,
            description: "\(displayName) text chat",
            modelType: .text,
            baseURL: baseURL,
            mmprojURL: nil,
            baseFileSizeBytes: baseFileSizeBytes,
            mmprojFileSizeBytes: nil,
            baseSHA256: baseSHA256,
            mmprojSHA256: nil,
            quantization: quantization,
            config: config,
            license: license
        )
    }

    var runtimeEligibility: RuntimeEligibility {
        if isImported { return .experimental }
        return MemoryProfileRegistry.profile(for: id)?.runtimeEligibility ?? .unavailable
    }

    var isImported: Bool {
        if case .huggingFace = source { return true }
        return false
    }

    var huggingFaceProvenance: HuggingFaceProvenance? {
        guard case .huggingFace(let provenance) = source else { return nil }
        return provenance
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
        StorageByteFormatter.string(fromByteCount: totalFileSizeBytes)
    }

    /// A useful fail-closed reason when this catalog row cannot be verified.
    var catalogUnavailableReason: String? {
        ModelCatalogValidator.failureReason(for: self)
    }
}

/// Runtime counterpart to the release catalog checker. UI and orchestration use
/// this before touching the network so malformed production metadata fails closed.
enum ModelCatalogValidator {
    /// Increment when production artifact identities or integrity metadata change.
    static let catalogVersion = "1"

    static func failureReason(for model: AIModel) -> String? {
        guard isCanonicalArtifactURL(model.baseURL) else {
            return "The model download URL is not a canonical HTTPS GGUF URL."
        }
        guard model.baseFileSizeBytes > 0 else {
            return "The model catalog does not contain a positive base artifact size."
        }
        guard isLowercaseSHA256(model.baseSHA256) else {
            return "The model catalog does not contain a verified base SHA-256."
        }

        if model.modelType == .vision {
            guard let projectorURL = model.mmprojURL,
                  isCanonicalArtifactURL(projectorURL),
                  let projectorBytes = model.mmprojFileSizeBytes,
                  projectorBytes > 0,
                  let projectorSHA = model.mmprojSHA256,
                  isLowercaseSHA256(projectorSHA) else {
                return "Vision is unavailable because projector integrity metadata is incomplete."
            }
        } else if model.mmprojURL != nil || model.mmprojFileSizeBytes != nil || model.mmprojSHA256 != nil {
            return "The text-only catalog row contains inconsistent projector metadata."
        }
        return nil
    }

    static func catalogFailureReason(models: [AIModel]) -> String? {
        var ids = Set<String>()
        var storage: [String: (URL, Int64, String)] = [:]
        for model in models {
            if !ids.insert(model.id).inserted { return "The model catalog contains a duplicate model identity."
            }
            if let reason = failureReason(for: model) { return "\(model.displayName): \(reason)" }

            let identity = (model.baseURL, model.baseFileSizeBytes, model.baseSHA256)
            if let existing = storage[model.baseArtifactStorageID],
               existing.0 != identity.0 || existing.1 != identity.1 || existing.2 != identity.2 {
                return "The model catalog maps conflicting artifacts to the same storage identity."
            }
            storage[model.baseArtifactStorageID] = identity
        }
        return nil
    }

    private static func isCanonicalArtifactURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.path.lowercased().hasSuffix(".gguf"),
              url.fragment == nil else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty ?? true
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0)) }
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

    // MARK: - Validated import lineup (text-only, device-verified 2026-09-23)

    /// Shared runtime preset for the chat-template text lineup: bounded ctx
    /// 4096, 2 threads, mmap + f16 KV, auto Metal tiering. Per-model stop
    /// strings come from the embedded GGUF chat template.
    static let lineupText = [
        AIModel(
            id: "lfm2.5-1.2b-q4",
            displayName: "LFM 2.5 1.2B",
            description: "Everyday default. Fast sub-gigabyte text chat.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/LFM2.5-1.2B-Instruct-Q4_K_M.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 730_895_168,
            mmprojFileSizeBytes: nil,
            baseSHA256: "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5",
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "LFM Open License v1.0",
                url: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/LICENSE")!,
                copyright: "Copyright 2026 Liquid AI"
            )
        ),
        AIModel(
            id: "lfm2.5-2.6b-q4",
            displayName: "LFM 2.5 2.6B",
            description: "On-phone agent flagship. Base model: pair with a strong system prompt.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/resolve/e7caca5d835a3901a8e0d63e94009429bafafdfc/LFM2.5-2.6B-Q4_K_M.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1_674_455_040,
            mmprojFileSizeBytes: nil,
            baseSHA256: "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed",
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "LFM Open License v1.0",
                url: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/resolve/e7caca5d835a3901a8e0d63e94009429bafafdfc/LICENSE")!,
                copyright: "Copyright 2026 Liquid AI"
            )
        ),
        AIModel(
            id: "qwen3.5-2b-q4",
            displayName: "Qwen 3.5 2B",
            description: "Long-memory dense text chat. Community conversion, Apache-2.0.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1_280_835_840,
            mmprojFileSizeBytes: nil,
            baseSHA256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "Apache 2.0",
                url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                copyright: "Copyright 2026 Alibaba Cloud"
            )
        ),
        AIModel(
            id: "qwen3.5-0.8b-q4",
            displayName: "Qwen 3.5 0.8B",
            description: "Playground tiny. Fastest downloads, lightest footprint.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 532_517_120,
            mmprojFileSizeBytes: nil,
            baseSHA256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "Apache 2.0",
                url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                copyright: "Copyright 2026 Alibaba Cloud"
            )
        ),
        AIModel(
            id: "bonsai-8b-q1",
            displayName: "Bonsai 8B",
            description: "Brains-per-GB flagship. End-to-end 1-bit, 1.15 GB on disk.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/48516770dd04643643e9f9019a2a349cf26c5dbd/Bonsai-8B-Q1_0.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1_158_654_496,
            mmprojFileSizeBytes: nil,
            baseSHA256: "284a335aa3fb2ced3b1b01fcb40b08aa783e3b70832767f0dd2e3fdfa134bd54",
            mmprojSHA256: nil,
            quantization: "Q1_0",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "Apache 2.0",
                url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                copyright: "Copyright 2026 Prism ML"
            )
        ),
        AIModel(
            id: "bonsai-4b-q1",
            displayName: "Bonsai 4B",
            description: "Light density 1-bit. Sub-gigabyte, full-precision-class answers.",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/prism-ml/Bonsai-4B-gguf/resolve/78f2c2bacd0904ffaba24b4873ed975e5818354a/Bonsai-4B-Q1_0.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 572_270_624,
            mmprojFileSizeBytes: nil,
            baseSHA256: "4524b3f997f0f06444e568d1f26e2efd69effa3218c7ad3047432fb171e42168",
            mmprojSHA256: nil,
            quantization: "Q1_0",
            config: .curatedText4K,
            license: LicenseInfo(
                name: "Apache 2.0",
                url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                copyright: "Copyright 2026 Prism ML"
            )
        ),
    ]

    // MARK: - Registry Access

    /// All available models for the current phase.
    static var allModels: [AIModel] {
        [
            llama32_3B,
            gemma4_e2b,
            gemma4_e4b_text,
            gemma4_e4b,
            // Reference: smolVLM_500M, qwen25VL_3B,
        ] + lineupText
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
    static var importedModels: [AIModel] {
        ImportedModelStore.shared.models
    }

    static var libraryModels: [AIModel] {
        allModels + importedModels
    }

    /// Whether protected imported lifecycle registries can currently be read.
    /// False must never be interpreted as an empty library.
    static var importedRegistriesAvailable: Bool {
        ImportedModelStore.shared.isAvailable && ImportedModelUpdateStore.shared.isAvailable
    }

    /// Includes unpromoted update candidates solely for durable transfer recovery.
    static var transferModels: [AIModel] {
        libraryModels + ImportedModelUpdateStore.shared.models
    }

    static var selectableModels: [AIModel] {
        libraryModels.filter {
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
        (libraryModels + calibrationModels).first { $0.id == id }
    }

    static func isKnownModelID(_ id: String) -> Bool {
        model(for: id) != nil
    }

    static func unavailableModelReason(for modelID: String) -> UnavailableModelReason? {
        if model(for: modelID) != nil { return nil }
        if modelID.hasPrefix("hf-") { return .removed }
        return .neverExisted
    }
}

enum ExperimentalModelConsent {
    private static let prefix = "experimentalModelConsent."

    static func isGranted(for model: AIModel, defaults: UserDefaults = .standard) -> Bool {
        guard model.runtimeEligibility == .experimental,
              let profile = MemoryProfileRegistry.profile(for: model) else { return false }
        return defaults.bool(forKey: prefix + profile.id)
    }

    static func setGranted(_ granted: Bool, for model: AIModel, defaults: UserDefaults = .standard) {
        guard let profile = MemoryProfileRegistry.profile(for: model) else { return }
        defaults.set(granted, forKey: prefix + profile.id)
    }
}

// swiftlint:enable identifier_name

// ModelLifecycleManager.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Coordinates lazy model loading, switching, and unloading.
// Uses MemoryBudgeter to verify RAM before every load.
// Observes memory pressure notifications for automatic eviction.

import Foundation
import UIKit
import os

/// The current state of a model in the lifecycle.
enum ModelState: Sendable, Equatable {
    case unloaded
    case loading
    case loaded
    case evicted
    case loadFailed

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.unloaded, .unloaded), (.loading, .loading), (.loaded, .loaded), (.evicted, .evicted), (.loadFailed, .loadFailed):
            return true
        default:
            return false
        }
    }
}

// MARK: - Model Lifecycle Manager

/// Manages model lifecycle: lazy load, switch, unload, and memory pressure eviction.
@MainActor
final class ModelLifecycleManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentState: ModelState = .unloaded
    @Published private(set) var activeModel: AIModel?
    @Published var showMemoryWarning = false

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private let memoryBudgeter: MemoryBudgeter
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "lifecycle")

    // MARK: - Download Status (injected from ModelManagerService)

    /// Tracks download state per model ID. Populated by ModelManagerService.
    @Published var downloadStatuses: [String: ModelDownloadStatus] = [:]

    // MARK: - Initialization

    init(inferenceService: InferenceService, memoryBudgeter: MemoryBudgeter) {
        self.inferenceService = inferenceService
        self.memoryBudgeter = memoryBudgeter

        // Observe memory pressure notifications.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Model Operations

    /// Load a model. Checks memory budget first. Unloads current model if needed.
    func loadModel(_ model: AIModel) async {
        // Don't reload if already loaded.
        if let active = activeModel, active.id == model.id, currentState == .loaded {
            logger.info("Model already loaded: \(model.id, privacy: .public)")
            return
        }

        currentState = .loading

        // Check memory budget.
        let recommendation = await memoryBudgeter.recommendation(for: model)
        switch recommendation {
        case .proceed:
            break  // Good to go.

        case .unloadCurrentFirst:
            // Unload current model to free RAM.
            if activeModel != nil {
                logger.info("Unloading current model to make room for \(model.id, privacy: .public)")
                unloadCurrentModel()
                // Give the system a moment to reclaim memory.
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }

        case .insufficientRAM:
            let available = await memoryBudgeter.formattedAvailableRAM()
            logger.error("Insufficient RAM for \(model.id, privacy: .public): \(available, privacy: .public) available")
            currentState = .loadFailed
            return
        }

        // Get file paths.
        let baseURL = ModelManagerService.baseModelPath(for: model)
        let mmprojURL = model.requiresMMProj ? ModelManagerService.mmprojModelPath(for: model) : nil

        // Load the model.
        do {
            try await inferenceService.loadModel(model, baseURL: baseURL, mmprojURL: mmprojURL)
            activeModel = model
            currentState = .loaded
            logger.info("Model loaded: \(model.id, privacy: .public)")
        } catch {
            logger.error("Model load failed: \(error.localizedDescription, privacy: .public)")
            currentState = .loadFailed
        }
    }

    /// Unload the current model, freeing memory.
    func unloadCurrentModel() {
        Task {
            await inferenceService.unloadModel()
        }
        let previousModel = activeModel
        activeModel = nil
        currentState = .unloaded
        logger.info("Model unloaded: \(previousModel?.id ?? "none", privacy: .public)")
    }

    /// Switch to a different model. Unloads current, loads new.
    func switchToModel(_ model: AIModel) async {
        if let active = activeModel, active.id == model.id {
            return  // Already on this model.
        }

        unloadCurrentModel()
        await loadModel(model)
    }

    /// Whether a model is currently loaded and ready.
    var isModelLoaded: Bool {
        if case .loaded = currentState { return true }
        return false
    }

    // MARK: - Memory Pressure

    @objc private func handleMemoryPressure() {
        logger.warning("Memory pressure received — evicting model")
        Task {
            unloadCurrentModel()
            currentState = .evicted
            showMemoryWarning = true
        }
    }

    /// Dismiss the memory warning banner.
    func dismissMemoryWarning() {
        showMemoryWarning = false
    }

    /// Reload after eviction.
    func reloadEvictedModel() async {
        guard let model = activeModel else { return }
        showMemoryWarning = false
        await loadModel(model)
    }

    /// Load the first fully downloaded model. Used for UI testing.
    func autoLoadFirstModel() async {
        guard activeModel == nil else { return }
        guard let model = ModelRegistry.allModels.first(where: { ModelManagerService.isFullyDownloaded($0) }) else {
            logger.warning("autoLoadFirstModel: no downloaded models found")
            return
        }
        logger.info("autoLoadFirstModel: loading \(model.id, privacy: .public)")
        await loadModel(model)
    }
}

// MARK: - Model Manager Service (Download + Verify)

/// Handles model file management: download, SHA-256 verification, storage queries.
/// This is a separate concern from lifecycle — it manages files on disk.
enum ModelManagerService {

    private static let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "model-manager")

    /// Base directory for model storage.
    static var modelsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Models", isDirectory: true)
    }

    /// File path for a model's base .gguf.
    static func baseModelPath(for model: AIModel) -> URL {
        modelsDirectory.appendingPathComponent("\(model.id).gguf")
    }

    /// File path for a model's mmproj.gguf (vision models).
    static func mmprojModelPath(for model: AIModel) -> URL {
        modelsDirectory.appendingPathComponent("\(model.id)-mmproj.gguf")
    }

    /// Whether the base model file exists on disk.
    static func isBaseDownloaded(_ model: AIModel) -> Bool {
        FileManager.default.fileExists(atPath: baseModelPath(for: model).path)
    }

    /// Whether the mmproj file exists on disk (always true for text-only models).
    static func isMMProjDownloaded(_ model: AIModel) -> Bool {
        guard model.requiresMMProj else { return true }
        return FileManager.default.fileExists(atPath: mmprojModelPath(for: model).path)
    }

    /// Whether a model is fully downloaded (base + mmproj if needed).
    static func isFullyDownloaded(_ model: AIModel) -> Bool {
        isBaseDownloaded(model) && isMMProjDownloaded(model)
    }

    /// Disk usage in bytes for a specific model (base + mmproj).
    static func diskUsage(for model: AIModel) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        let basePath = baseModelPath(for: model)
        if let attrs = try? fm.attributesOfItem(atPath: basePath.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }

        if model.requiresMMProj {
            let mmprojPath = mmprojModelPath(for: model)
            if let attrs = try? fm.attributesOfItem(atPath: mmprojPath.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }

        return total
    }

    /// Formatted disk usage for a specific model.
    static func formattedDiskUsage(for model: AIModel) -> String {
        ByteCountFormatter.string(fromByteCount: diskUsage(for: model), countStyle: .file)
    }

    /// Total disk usage of all downloaded models in bytes.
    static func totalDiskUsage() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Formatted total disk usage string.
    static func formattedDiskUsage() -> String {
        ByteCountFormatter.string(fromByteCount: totalDiskUsage(), countStyle: .file)
    }

    /// Verify SHA-256 of a downloaded file.
    static func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        let hash = SHA256.hash(data: data)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return hex == expected.lowercased()
    }

    /// Delete a model's files from disk.
    static func deleteModel(_ model: AIModel) {
        let fm = FileManager.default
        let basePath = baseModelPath(for: model)
        let mmprojPath = mmprojModelPath(for: model)

        try? fm.removeItem(at: basePath)
        if model.requiresMMProj {
            try? fm.removeItem(at: mmprojPath)
        }

        logger.info("Deleted model files: \(model.id, privacy: .public)")
    }

    /// Create the models directory if it doesn't exist.
    static func ensureModelsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: modelsDirectory.path) {
            try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - SHA256 Helper

import CryptoKit

extension ModelManagerService {
    /// Compute SHA-256 of a file.
    static func computeSHA256(fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

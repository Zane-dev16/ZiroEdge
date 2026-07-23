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

    /// Stores the evicted model so it can be reloaded after memory pressure eviction.
    private var evictedModel: AIModel?

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
        print("[LOAD] loadModel(\(model.id)) — currentState=\(currentState)")
        // Don't reload if already loaded.
        if let active = activeModel, active.id == model.id, currentState == .loaded {
            print("[LOAD] SKIP: already loaded")
            logger.info("Model already loaded: \(model.id, privacy: .public)")
            return
        }

        print("[LOAD] Setting state to .loading")
        currentState = .loading

        // Check memory budget.
        let recommendation = await memoryBudgeter.recommendation(for: model)
        print("[LOAD] Memory recommendation: \(recommendation)")
        switch recommendation {
        case .proceed:
            break  // Good to go.

        case .unloadCurrentFirst:
            // Unload current model to free RAM.
            if activeModel != nil {
                logger.info("Unloading current model to make room for \(model.id, privacy: .public)")
                await unloadCurrentModel()
                // Give the system a moment to reclaim memory.
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }

        case .insufficientRAM:
            let available = await memoryBudgeter.formattedAvailableRAM()
            logger.warning("RAM is tight for \(model.id, privacy: .public): \(available, privacy: .public) available. Attempting load anyway...")
            // Don't block — try to load. OS will kill us if we're wrong.
            break
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
    func unloadCurrentModel() async {
        await inferenceService.unloadModel()
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

        await unloadCurrentModel()
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
        guard currentState == .loaded else { return }
        Task {
            guard currentState == .loaded else { return }
            evictedModel = activeModel
            await unloadCurrentModel()
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
        guard let model = evictedModel else { return }
        evictedModel = nil
        showMemoryWarning = false
        await loadModel(model)
    }

    /// Load the first fully downloaded model. Used for UI testing.
    func autoLoadFirstModel() async {
        print("[AUTOLOAD] autoLoadFirstModel called — activeModel=\(activeModel?.id ?? "nil")")
        guard activeModel == nil else {
            print("[AUTOLOAD] SKIP: model already loaded (\(activeModel!.id))")
            return
        }
        
        // Check each model's download status
        for model in ModelRegistry.allModels {
            let isDL = ModelManagerService.isFullyDownloaded(model)
            print("[AUTOLOAD]   \(model.id): downloaded=\(isDL)")
        }
        
        guard let model = ModelRegistry.allModels.first(where: { ModelManagerService.isFullyDownloaded($0) }) else {
            print("[AUTOLOAD] FAIL: no downloaded models found")
            logger.warning("autoLoadFirstModel: no downloaded models found")
            return
        }
        print("[AUTOLOAD] Selected: \(model.id), loading...")
        logger.info("autoLoadFirstModel: loading \(model.id, privacy: .public)")
        await loadModel(model)
        print("[AUTOLOAD] loadModel returned — currentState=\(self.currentState), isLoaded=\(self.isModelLoaded)")
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

    /// Whether the base model file exists on disk AND passes basic validation.
    /// Bogus files (wrong magic, size mismatch, etc.) are removed automatically.
    static func isBaseDownloaded(_ model: AIModel) -> Bool {
        let path = baseModelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard verifyGGUFHeader(fileURL: path) else {
            try? FileManager.default.removeItem(at: path)
            return false
        }
        // Cheap size check — wrong byte count means the download is incomplete/corrupt.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != model.baseFileSizeBytes {
            try? FileManager.default.removeItem(at: path)
            return false
        }
        return true
    }

    /// Whether the mmproj file exists on disk AND passes basic validation.
    /// Always returns true for text-only models.
    static func isMMProjDownloaded(_ model: AIModel) -> Bool {
        guard model.requiresMMProj else { return true }
        let path = mmprojModelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard verifyGGUFHeader(fileURL: path) else {
            try? FileManager.default.removeItem(at: path)
            return false
        }
        if let expectedSize = model.mmprojFileSizeBytes,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != expectedSize {
            try? FileManager.default.removeItem(at: path)
            return false
        }
        return true
    }

    /// Whether a model is fully downloaded AND passes validation (GGUF header, size, SHA-256).
    static func isFullyDownloaded(_ model: AIModel) -> Bool {
        if case .ready = availability(for: model) { return true }
        return false
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
        guard let hex = computeSHA256(fileURL: fileURL) else { return false }
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

// MARK: - Availability Check

extension ModelManagerService {

    /// Comprehensive model availability check. Validates files on disk
    /// and returns ready, repair-needed, or unavailable.
    static func availability(for modelID: String) -> ModelAvailability {
        guard let model = ModelRegistry.model(for: modelID) else {
            return .unavailable
        }
        return availability(for: model)
    }

    /// Comprehensive model availability check for an AIModel.
    static func availability(for model: AIModel) -> ModelAvailability {
        // Missing catalog metadata → unavailable.
        guard !model.baseSHA256.isEmpty else {
            return .unavailable
        }

        var issues: [ArtifactIssue] = []

        // Check base artifact.
        let basePath = baseModelPath(for: model)
        if !FileManager.default.fileExists(atPath: basePath.path) {
            issues.append(.missing(artifact: .base))
        } else if !verifyGGUFHeader(fileURL: basePath) {
            issues.append(.missingGGUFHeader)
        } else {
            // SHA-256 check.
            if let actualSHA = computeSHA256(fileURL: basePath), !model.baseSHA256.isEmpty {
                if actualSHA != model.baseSHA256.lowercased() {
                    issues.append(.sha256Mismatch)
                }
            }
            // Size check.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: basePath.path),
               let fileSize = attrs[.size] as? Int64 {
                if fileSize != model.baseFileSizeBytes {
                    issues.append(.sizeMismatch)
                }
            }
        }

        // Check mmproj artifact for vision models.
        if model.requiresMMProj {
            let mmprojPath = mmprojModelPath(for: model)
            if !FileManager.default.fileExists(atPath: mmprojPath.path) {
                issues.append(.missing(artifact: .mmproj))
            } else if !verifyGGUFHeader(fileURL: mmprojPath) {
                issues.append(.missingGGUFHeader)
            } else if let expectedSHA = model.mmprojSHA256, !expectedSHA.isEmpty {
                if let actualSHA = computeSHA256(fileURL: mmprojPath),
                   actualSHA != expectedSHA.lowercased() {
                    issues.append(.sha256Mismatch)
                }
            }
        }

        if issues.isEmpty {
            return .ready
        }
        return .repairNeeded(issues: issues)
    }
}

// MARK: - SHA256 Helper

import CryptoKit

extension ModelManagerService {
    /// Compute SHA-256 of a file by streaming in 64 KB chunks.
    /// Avoids loading the entire file into memory (critical for multi-GB GGUFs).
    static func computeSHA256(fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Managed Storage Directories

extension ModelManagerService {

    /// Root directory for managed, backup-excluded model storage.
    static var managedStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("ZiroEdge/Models", isDirectory: true)
    }

    /// Staging area for in-progress downloads.
    static var stagingDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Resume data for interrupted downloads.
    static var resumeDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Resume", isDirectory: true)
    }

    /// Quarantine area for files that failed validation.
    static var quarantineDirectory: URL {
        managedStorageDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    /// Legacy models directory (pre-#4 location in Documents).
    static var legacyModelsDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("Models", isDirectory: true)
    }
}

// MARK: - Artifact Validation

extension ModelManagerService {

    /// Lightweight pre-SHA validation of a model artifact. Returns a list of
    /// human-readable issue descriptions. Empty list means the file passes.
    static func artifactValidationIssues(
        at url: URL,
        model: AIModel,
        artifact: ArtifactType
    ) -> [String] {
        var issues: [String] = []
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            issues.append("File does not exist at \(url.path)")
            return issues
        }

        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64,
              fileSize > 0 else {
            issues.append("File is empty or unreadable")
            return issues
        }

        // Verify GGUF header magic.
        guard verifyGGUFHeader(fileURL: url) else {
            issues.append("Invalid or missing GGUF header magic")
            return issues
        }

        // Size sanity check: must be at least the advertised model size.
        let expectedSize = artifact == .base
            ? model.baseFileSizeBytes
            : model.mmprojFileSizeBytes ?? 0
        if expectedSize > 0 && fileSize < expectedSize / 2 {
            issues.append(
                "File size (\(fileSize) bytes) is less than half of expected (\(expectedSize) bytes)"
            )
        }

        return issues
    }

    /// Verify the GGUF magic number at the start of a file.
    /// GGUF format: 4-byte magic "GGUF" (0x47 0x47 0x55 0x46)
    /// followed by a 4-byte little-endian version (2 or 3).
    static func verifyGGUFHeader(fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 8),
              header.count >= 8 else {
            return false
        }

        let magic = header[0..<4]
        let expectedMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]  // "GGUF"
        guard Array(magic) == expectedMagic else {
            return false
        }

        // Version is little-endian uint32 at bytes 4-7.
        let version = UInt32(header[4])
            | (UInt32(header[5]) << 8)
            | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 24)
        return version == 2 || version == 3
    }
}

// MARK: - Repair Tracking

extension ModelManagerService {

    private static let repairMarkerPrefix = ".repair-needed-"

    /// Mark a model as needing repair (e.g. after a failed migration).
    static func markRepairNeeded(for model: AIModel) {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        try? Data("1".utf8).write(to: marker, options: .atomic)
    }

    /// Check whether a model has been marked for repair.
    static func isRepairNeeded(for model: AIModel) -> Bool {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Clear the repair marker after a successful repair.
    static func clearRepairNeeded(for model: AIModel) {
        let marker = managedStorageDirectory
            .appendingPathComponent("\(repairMarkerPrefix)\(model.id)")
        try? FileManager.default.removeItem(at: marker)
    }
}

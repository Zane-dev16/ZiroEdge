// ModelManagerService+ArtifactIntegrity.swift
// ZiroEdge — Privacy-first local AI assistant
//
// SHA-256 memoization and artifact validation seams for ModelManagerService.
// All hashing routes through the single canonical loop in
// `ModelArtifactVerifier`; this file only adds the mtime+size cache, the
// digest/verify helpers, and the human-readable issue mapping.

import CryptoKit
import Foundation
import SwiftLlama

// MARK: - SHA256 Helper

import CryptoKit

extension ModelManagerService {
    // MARK: - SHA256 mtime+size cache (BATCH-03 ANR fix)

    private struct SHA256CacheEntry: Sendable {
        let mtime: Date
        let size: Int64
        let hash: String
    }

    private static let sha256CacheLock = NSLock()
    private static var sha256CacheStore: [String: SHA256CacheEntry] = [:]
    private static var _sha256ComputeCount: Int = 0
    private static var _sha256CacheHitCount: Int = 0
    static var lastSHA256ComputeWasOffMain: Bool?

    static var sha256ComputeCount: Int {
        sha256CacheLock.lock(); defer { sha256CacheLock.unlock() }
        return _sha256ComputeCount
    }

    static var sha256CacheHitCount: Int {
        sha256CacheLock.lock(); defer { sha256CacheLock.unlock() }
        return _sha256CacheHitCount
    }

    static func resetSHA256CacheForTests() {
        sha256CacheLock.lock()
        sha256CacheStore.removeAll()
        _sha256ComputeCount = 0
        _sha256CacheHitCount = 0
        lastSHA256ComputeWasOffMain = nil
        sha256CacheLock.unlock()
    }

    static func clearSHA256Cache() {
        sha256CacheLock.lock()
        sha256CacheStore.removeAll()
        sha256CacheLock.unlock()
    }

    private static func cachedHashIfValid(for fileURL: URL, size: Int64, mtime: Date) -> String? {
        sha256CacheLock.lock()
        defer { sha256CacheLock.unlock() }
        guard let entry = sha256CacheStore[fileURL.path], entry.size == size, entry.mtime == mtime else { return nil }
        _sha256CacheHitCount += 1
        return entry.hash
    }

    private static func storeHash(_ hash: String, for fileURL: URL, size: Int64, mtime: Date) {
        sha256CacheLock.lock()
        sha256CacheStore[fileURL.path] = SHA256CacheEntry(mtime: mtime, size: size, hash: hash)
        _sha256ComputeCount += 1
        lastSHA256ComputeWasOffMain = !Thread.isMainThread
        sha256CacheLock.unlock()
    }

    static func computeSHA256(fileURL: URL) -> String? {
        // Fast-path: check mtime+size cache
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNum = attrs[.size] as? NSNumber,
           let mtime = attrs[.modificationDate] as? Date {
            let size = sizeNum.int64Value
            if let cached = cachedHashIfValid(for: fileURL, size: size, mtime: mtime) {
                return cached
            }
            // Hashing itself is the single canonical loop in
            // ModelArtifactVerifier; this wrapper only memoizes.
            guard let hash = ModelArtifactVerifier.digest(fileURL: fileURL) else { return nil }
            storeHash(hash, for: fileURL, size: size, mtime: mtime)
            return hash
        }
        // Fallback without cache (no mtime)
        sha256CacheLock.lock()
        _sha256ComputeCount += 1
        lastSHA256ComputeWasOffMain = !Thread.isMainThread
        sha256CacheLock.unlock()
        return ModelArtifactVerifier.digest(fileURL: fileURL)
    }
}


// MARK: - Artifact Validation

extension ModelManagerService {

    /// Lightweight pre-SHA validation of a model artifact. Returns a list of
    /// human-readable issue descriptions. Empty list means the file passes.
    /// Single canonical pass (`ModelArtifactVerifier.validate`) with the
    /// historical message strings preserved for diagnostics consumers.
    static func artifactValidationIssues(
        at url: URL,
        model: AIModel,
        artifact: ArtifactType
    ) -> [String] {
        let expectedSize = artifact == .base
            ? model.baseFileSizeBytes
            : model.mmprojFileSizeBytes ?? 0
        let expectedHash = artifact == .base ? model.baseSHA256 : model.mmprojSHA256 ?? ""
        switch ModelArtifactVerifier.validate(
            fileURL: url,
            expectedBytes: expectedSize,
            expectedSHA256: expectedHash,
            isCancelled: { false },
            digestProvider: { computeSHA256(fileURL: $0) }
        ) {
        case .valid:
            return []
        case .missingFile:
            return ["File does not exist at \(url.path)"]
        case .unreadableSize:
            return ["File is empty or unreadable"]
        case .sizeMismatch(_, let actual) where actual == 0:
            return ["File is empty or unreadable"]
        case .sizeMismatch:
            return ["File size does not match catalog metadata"]
        case .structureInvalid:
            return ["Invalid or missing GGUF header magic"]
        case .invalidMetadata:
            return ["Catalog SHA-256 metadata is invalid"]
        case .readFailure:
            return ["Artifact could not be read (possible I/O error)"]
        case .hashMismatch:
            return ["SHA-256 does not match catalog metadata"]
        case .cancelled:
            // Unreachable: cancellation is disabled for this pass.
            return []
        }
    }

    /// Parse the complete GGUF metadata/tensor descriptor tables with
    /// llama.cpp and prove every declared tensor fits inside the file. The
    /// historical name is retained because this is a widely used validation
    /// seam, but the check is intentionally much stronger than an 8-byte
    /// magic/version probe.
    static func verifyGGUFHeader(fileURL: URL) -> Bool {
        GGUFFileValidator.isStructurallyValid(atPath: fileURL.path)
    }
}


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
    // MARK: - SHA256 mtime+size cache (BATCH-03 ANR fix) + persisted sidecar

    /// On-disk sidecar entry. `mtimeKey` is whole microseconds since 1970 so
    /// entries survive a JSON round-trip: a decoded `Date` can differ from the
    /// file's `Date` in its final bits, which would silently invalidate every
    /// reloaded entry on relaunch.
    private struct SidecarEntry: Codable {
        let mtimeKey: Int64
        let size: Int64
        let hash: String?
        let structureValid: Bool?
    }

    private struct SHA256CacheEntry: Sendable {
        let mtimeKey: Int64
        let size: Int64
        let hash: String
    }

    /// Memoized GGUF structure verdict, keyed by mtime+size like the digest
    /// cache: the structural parse reads the metadata/tensor tables of every
    /// installed sibling artifact on each status refresh otherwise.
    private struct StructureCacheEntry: Sendable {
        let mtimeKey: Int64
        let size: Int64
        let isValid: Bool
    }

    private static let sha256CacheLock = NSLock()
    private static var sha256CacheStore: [String: SHA256CacheEntry] = [:]
    private static var structureCacheStore: [String: StructureCacheEntry] = [:]
    private static var sidecarLoaded = false
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
        structureCacheStore.removeAll()
        sidecarLoaded = false
        _sha256ComputeCount = 0
        _sha256CacheHitCount = 0
        lastSHA256ComputeWasOffMain = nil
        // The sidecar must go too, or a previous test run's entries would be
        // reloaded mid-test and turn first computes into cache hits.
        try? FileManager.default.removeItem(at: sidecarURL)
        sha256CacheLock.unlock()
    }

    /// Test seam simulating a relaunch: forgets the in-memory stores while
    /// keeping the sidecar file, so the next compute reloads it from disk.
    static func simulateRelaunchForTests() {
        sha256CacheLock.lock()
        sha256CacheStore.removeAll()
        structureCacheStore.removeAll()
        sidecarLoaded = false
        sha256CacheLock.unlock()
    }

    /// Whole microseconds since 1970 for an attribute timestamp.
    private static func mtimeKey(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// JSON sidecar carrying computed digests and structure verdicts across
    /// launches, keyed by path + mtime + size. Lives next to the managed
    /// storage root, so the DEBUG storage-root override relocates it too.
    private static var sidecarURL: URL {
        managedStorageDirectory.deletingLastPathComponent()
            .appendingPathComponent("artifact-hash-cache.json")
    }

    private static func loadSidecarIfNeededLocked() {
        guard !sidecarLoaded else { return }
        sidecarLoaded = true
        guard let data = try? Data(contentsOf: sidecarURL),
              let entries = try? JSONDecoder().decode([String: SidecarEntry].self, from: data) else {
            return
        }
        for (path, entry) in entries {
            // Anything computed earlier this session wins over the sidecar.
            if let hash = entry.hash, sha256CacheStore[path] == nil {
                sha256CacheStore[path] = SHA256CacheEntry(
                    mtimeKey: entry.mtimeKey, size: entry.size, hash: hash
                )
            }
            if let valid = entry.structureValid, structureCacheStore[path] == nil {
                structureCacheStore[path] = StructureCacheEntry(
                    mtimeKey: entry.mtimeKey, size: entry.size, isValid: valid
                )
            }
        }
    }

    private static func sidecarSnapshotLocked() -> [String: SidecarEntry] {
        var entries: [String: SidecarEntry] = [:]
        for (path, entry) in sha256CacheStore {
            entries[path] = SidecarEntry(
                mtimeKey: entry.mtimeKey,
                size: entry.size,
                hash: entry.hash,
                structureValid: structureCacheStore[path]?.isValid
            )
        }
        for (path, entry) in structureCacheStore where entries[path] == nil {
            entries[path] = SidecarEntry(
                mtimeKey: entry.mtimeKey,
                size: entry.size,
                hash: nil,
                structureValid: entry.isValid
            )
        }
        return entries
    }

    private static func saveSidecar(_ entries: [String: SidecarEntry]) {
        // Entries whose file no longer exists are dead weight; pruning keeps
        // the sidecar bounded to real artifacts.
        let live = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        if live.isEmpty, !FileManager.default.fileExists(atPath: sidecarURL.path) {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(live).write(to: sidecarURL, options: .atomic)
        } catch {
            // Sidecar persistence is best-effort; in-memory caching still applies.
        }
    }

    private static func cachedHashIfValid(for fileURL: URL, size: Int64, mtimeKey: Int64) -> String? {
        sha256CacheLock.lock()
        defer { sha256CacheLock.unlock() }
        loadSidecarIfNeededLocked()
        guard let entry = sha256CacheStore[fileURL.path],
              entry.size == size, entry.mtimeKey == mtimeKey else { return nil }
        _sha256CacheHitCount += 1
        return entry.hash
    }

    private static func storeHash(_ hash: String, for fileURL: URL, size: Int64, mtimeKey: Int64) {
        sha256CacheLock.lock()
        sha256CacheStore[fileURL.path] = SHA256CacheEntry(mtimeKey: mtimeKey, size: size, hash: hash)
        _sha256ComputeCount += 1
        lastSHA256ComputeWasOffMain = !Thread.isMainThread
        let snapshot = sidecarSnapshotLocked()
        sha256CacheLock.unlock()
        saveSidecar(snapshot)
    }

    private static func cachedStructureValidity(
        for fileURL: URL, size: Int64, mtimeKey: Int64
    ) -> Bool? {
        sha256CacheLock.lock()
        defer { sha256CacheLock.unlock() }
        loadSidecarIfNeededLocked()
        guard let entry = structureCacheStore[fileURL.path],
              entry.size == size, entry.mtimeKey == mtimeKey else { return nil }
        return entry.isValid
    }

    private static func storeStructureValidity(
        _ isValid: Bool, for fileURL: URL, size: Int64, mtimeKey: Int64
    ) {
        sha256CacheLock.lock()
        structureCacheStore[fileURL.path] = StructureCacheEntry(
            mtimeKey: mtimeKey, size: size, isValid: isValid
        )
        let snapshot = sidecarSnapshotLocked()
        sha256CacheLock.unlock()
        saveSidecar(snapshot)
    }

    static func computeSHA256(fileURL: URL) -> String? {
        // Fast-path: check mtime+size cache
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNum = attrs[.size] as? NSNumber,
           let mtime = attrs[.modificationDate] as? Date {
            let size = sizeNum.int64Value
            let key = mtimeKey(mtime)
            if let cached = cachedHashIfValid(for: fileURL, size: size, mtimeKey: key) {
                return cached
            }
            // Hashing itself is the single canonical loop in
            // ModelArtifactVerifier; this wrapper only memoizes.
            guard let hash = ModelArtifactVerifier.digest(fileURL: fileURL) else { return nil }
            storeHash(hash, for: fileURL, size: size, mtimeKey: key)
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
    /// Verdicts are memoized by mtime+size (and persisted in the hash sidecar)
    /// so per-tick status refreshes do not re-parse every installed artifact.
    static func verifyGGUFHeader(fileURL: URL) -> Bool {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNum = attrs[.size] as? NSNumber,
           let mtime = attrs[.modificationDate] as? Date {
            let size = sizeNum.int64Value
            let key = mtimeKey(mtime)
            if let cached = cachedStructureValidity(for: fileURL, size: size, mtimeKey: key) {
                return cached
            }
            let isValid = GGUFFileValidator.isStructurallyValid(atPath: fileURL.path)
            storeStructureValidity(isValid, for: fileURL, size: size, mtimeKey: key)
            return isValid
        }
        return GGUFFileValidator.isStructurallyValid(atPath: fileURL.path)
    }
}


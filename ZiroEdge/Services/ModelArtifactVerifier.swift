import CryptoKit
import Foundation

// MARK: - Verification Progress

/// Progress reported during a bounded-memory verification pass.
/// Delivered on a caller-chosen queue (typically a background serial queue).
struct VerificationProgress: Sendable {
    /// Bytes hashed so far.
    let bytesProcessed: Int64
    /// Total bytes expected (the artifact's catalog-advertised size).
    let totalBytes: Int64
    /// Fraction complete in 0.0...1.0.
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesProcessed) / Double(totalBytes)
    }
}

// MARK: - Verification Metrics

/// Performance evidence captured from a single verification run.
/// Does not require multi-gigabyte fixtures — measured with generated sparse files.
struct VerificationMetrics: Sendable {
    /// Wall-clock duration of the hashing loop (seconds).
    let durationSeconds: TimeInterval
    /// Peak resident memory delta observed during verification (bytes).
    /// Sampled via `task_info` / `rusage`; zero when unavailable.
    let peakMemoryDeltaBytes: Int64
    /// Whether the verification ran off the main actor.
    let ranOffMainActor: Bool
    /// Total bytes processed.
    let totalBytesProcessed: Int64
}

// MARK: - Canonical Validation Outcome

/// Outcome of the single canonical artifact validation pass.
/// Every hash + byte-size comparison in the app funnels through
/// `ModelArtifactVerifier.validate`, and callers map this outcome onto their
/// own externally observable error types (see `failure`,
/// `ModelManagerService.availability`, `isArtifactDownloaded`,
/// `artifactValidationIssues`).
enum ArtifactValidationOutcome: Sendable, Equatable {
    /// The artifact satisfies the full catalog contract.
    case valid
    /// Catalog metadata itself is unusable (non-positive bytes or malformed digest).
    case invalidMetadata
    /// No file exists at the validated path.
    case missingFile
    /// The file's byte size could not be read.
    case unreadableSize
    /// The file's byte size differs from the catalog-advertised size.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The GGUF metadata/tensor tables are structurally invalid.
    case structureInvalid
    /// The file could not be opened or read during hashing.
    case readFailure
    /// The streamed SHA-256 differs from the catalog digest.
    case hashMismatch
    /// Cooperative cancellation fired mid-pass.
    case cancelled
}

// MARK: - Verifier

/// Bounded-memory staged-file validation. Call from a detached task in production.
///
/// ## Buffer Bound
///
/// Every read uses at most `bufferSize` bytes (64 KiB). The in-memory
/// SHA-256 state (`CryptoKit.SHA256`) is ~208 bytes regardless of file
/// size. Peak process memory delta during verification is therefore
/// dominated by the single read buffer — there is no accumulating
/// allocation proportional to the artifact.
///
/// ## Cancellation
///
/// Cooperative cancellation is checked once per chunk. When cancelled,
/// the caller receives `.cancelled` and the staged file is left
/// untouched so the caller can decide whether to discard or resume.
///
/// ## Off-Main Guarantee
///
/// This function is synchronous and does not hop to the main actor.
/// Production callers wrap it in `Task.detached(priority: .utility)`.
/// The optional `onProgress` callback is invoked on an arbitrary
/// background thread — the callback is responsible for any needed
/// actor isolation.
enum ModelArtifactVerifier {

    /// Fixed buffer size for streaming reads: 64 KiB.
    /// This is the sole heap allocation that scales with a single
    /// read operation; the hasher state is constant-size.
    static let bufferSize = 65_536

    // MARK: - Canonical Hash Primitive

    /// Result of the single streaming hash pass.
    private enum StreamHashOutcome {
        case digest(String, streamedBytes: Int64)
        case openFailed
        case readFailed
        case cancelled
    }

    /// The sole streaming SHA-256 implementation in the app. Every hash
    /// computation (`validate`, `ModelManagerService.computeSHA256`) routes
    /// through this loop: one reused 64 KiB read buffer, constant-size hasher
    /// state, cooperative cancellation checked once per chunk.
    private static func streamHash(
        fileURL: URL,
        isCancelled: () -> Bool,
        onChunk: ((Int64) -> Void)?
    ) -> StreamHashOutcome {
        guard let inputStream = InputStream(url: fileURL) else {
            return .openFailed
        }
        inputStream.open()
        defer { inputStream.close() }

        var hasher = SHA256()
        var processed: Int64 = 0
        var buffer = Data(count: bufferSize)
        while true {
            if isCancelled() { return .cancelled }
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return inputStream.read(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    maxLength: bufferSize
                )
            }
            if bytesRead < 0 { return .readFailed }
            if bytesRead == 0 { break }
            processed += Int64(bytesRead)
            hasher.update(data: buffer.prefix(bytesRead))
            onChunk?(processed)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .digest(digest, streamedBytes: processed)
    }

    /// Compute the SHA-256 digest of a file. Returns `nil` when the file
    /// cannot be opened or read (or when `isCancelled` fires).
    /// Callers add any memoization they need (e.g. the mtime+size cache in
    /// `ModelManagerService.computeSHA256`).
    static func digest(fileURL: URL, isCancelled: () -> Bool = { false }) -> String? {
        switch streamHash(fileURL: fileURL, isCancelled: isCancelled, onChunk: nil) {
        case .digest(let digest, _): return digest
        case .openFailed, .readFailed, .cancelled: return nil
        }
    }

    // MARK: - Core Validation

    /// Validate an artifact file against catalog metadata.
    ///
    /// This is the single canonical hash + byte-size comparison path. All
    /// validators (download verification, availability sweeps, installed-
    /// artifact integrity, migration preflight) call it and map the outcome
    /// onto their own error types; quarantine decisions remain with callers.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the artifact file.
    ///   - expectedBytes: Catalog-advertised byte count.
    ///   - expectedSHA256: Catalog-advertised lowercase hex SHA-256.
    ///   - onProgress: Optional callback invoked after each chunk
    ///     (never on the main actor).
    ///   - isCancelled: Cooperative cancellation probe, consulted once per
    ///     chunk. Defaults to the surrounding task's cancellation state;
    ///     pass `{ false }` when the pass must run to completion.
    ///   - digestProvider: Optional replacement for the built-in streaming
    ///     hash (e.g. `ModelManagerService.computeSHA256` to reuse its
    ///     mtime+size memoization). Returning `nil` maps to `.readFailure`.
    /// - Returns: A typed `ArtifactValidationOutcome`.
    static func validate(
        fileURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        onProgress: ((VerificationProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { Task.isCancelled },
        digestProvider: ((URL) -> String?)? = nil
    ) -> ArtifactValidationOutcome {
        guard expectedBytes > 0,
              ModelManagerService.isValidSHA256(expectedSHA256) else {
            return .invalidMetadata
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missingFile
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let actualBytes = attributes[.size] as? Int64 else {
            return .unreadableSize
        }
        guard actualBytes == expectedBytes else {
            return .sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        guard ModelManagerService.verifyGGUFHeader(fileURL: fileURL) else {
            return .structureInvalid
        }
        let hashed: StreamHashOutcome
        if let digestProvider {
            // External (possibly memoized) digest source. The attribute read
            // above already pinned the byte count, so no post-stream re-check.
            hashed = digestProvider(fileURL).map {
                .digest($0, streamedBytes: actualBytes)
            } ?? .readFailed
        } else {
            hashed = streamHash(
                fileURL: fileURL,
                isCancelled: isCancelled,
                onChunk: onProgress.map { progress in
                    { processed in
                        progress(VerificationProgress(
                            bytesProcessed: processed,
                            totalBytes: expectedBytes
                        ))
                    }
                }
            )
        }
        switch hashed {
        case .digest(let actual, let streamedBytes):
            // Re-check size after streaming: catches truncation/mutation
            // between the attribute read above and the hashing pass.
            guard streamedBytes == expectedBytes else {
                return .sizeMismatch(expected: expectedBytes, actual: streamedBytes)
            }
            return actual == expectedSHA256 ? .valid : .hashMismatch
        case .openFailed:
            return .readFailure
        case .readFailed:
            return .readFailure
        case .cancelled:
            return .cancelled
        }
    }

    /// Post-stream byte-size re-check is folded into `validate`; this shim
    /// retains the historical `DownloadError` surface for download callers.
    static func failure(
        fileURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        onProgress: ((VerificationProgress) -> Void)? = nil
    ) -> DownloadError? {
        downloadError(from: validate(
            fileURL: fileURL,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            onProgress: onProgress
        ))
    }

    /// Map the canonical outcome onto the download-domain error type.
    static func downloadError(from outcome: ArtifactValidationOutcome) -> DownloadError? {
        switch outcome {
        case .valid:
            return nil
        case .invalidMetadata:
            return .invalidCatalogMetadata
        case .missingFile:
            return .contentRejected(reason: "the staged artifact does not exist")
        case .unreadableSize:
            return .contentRejected(reason: "the staged artifact size could not be read")
        case .sizeMismatch(let expected, let actual):
            return .sizeMismatch(expected: expected, actual: actual)
        case .structureInvalid:
            return .structureInvalid(reason: "the GGUF metadata or tensor tables are invalid")
        case .readFailure:
            return .contentRejected(reason: "the staged artifact could not be read")
        case .hashMismatch:
            return .sha256Mismatch
        case .cancelled:
            return .cancelled
        }
    }

    // MARK: - Measured Validation

    /// Validate with performance instrumentation.
    ///
    /// Captures wall-clock duration, peak memory delta, and off-main
    /// confirmation. Suitable for automated test evidence.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the staged file.
    ///   - expectedBytes: Catalog-advertised byte count.
    ///   - expectedSHA256: Catalog-advertised lowercase hex SHA-256.
    ///   - sampleIntervalBytes: Memory sampling granularity (default: every 64 MiB).
    /// - Returns: A tuple of the verification result and captured metrics.
    static func measureAndVerify(
        fileURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        sampleIntervalBytes: Int64 = 64 * 1_024 * 1_024
    ) -> (error: DownloadError?, metrics: VerificationMetrics) {
        let start = CFAbsoluteTimeGetCurrent()
        let startMemory = Self.residentMemoryBytes()
        var peakDelta: Int64 = 0
        var lastSampleBytes: Int64 = 0
        let ranOffMain = !Thread.isMainThread

        let error = failure(
            fileURL: fileURL,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            onProgress: { progress in
                let bytesSinceSample = progress.bytesProcessed - lastSampleBytes
                if bytesSinceSample >= sampleIntervalBytes || progress.bytesProcessed == progress.totalBytes {
                    let current = Self.residentMemoryBytes()
                    let delta = current - startMemory
                    if delta > peakDelta { peakDelta = delta }
                    lastSampleBytes = progress.bytesProcessed
                }
            }
        )

        let duration = CFAbsoluteTimeGetCurrent() - start
        let metrics = VerificationMetrics(
            durationSeconds: duration,
            peakMemoryDeltaBytes: max(peakDelta, 0),
            ranOffMainActor: ranOffMain,
            totalBytesProcessed: expectedBytes
        )
        return (error, metrics)
    }

    // MARK: - Memory Measurement

    /// Best-effort resident memory in bytes for the current process.
    /// Returns 0 when the kernel interface is unavailable (simulator
    /// or sandbox restrictions).
    static func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }
}

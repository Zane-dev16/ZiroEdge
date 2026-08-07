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

    // MARK: - Core Validation

    /// Validate a staged artifact file against catalog metadata.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the staged file.
    ///   - expectedBytes: Catalog-advertised byte count.
    ///   - expectedSHA256: Catalog-advertised lowercase hex SHA-256.
    ///   - onProgress: Optional callback invoked after each chunk
    ///     (never on the main actor).
    /// - Returns: `nil` when the file passes; a `DownloadError` otherwise.
    static func failure(
        fileURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        onProgress: ((VerificationProgress) -> Void)? = nil
    ) -> DownloadError? {
        guard expectedBytes > 0,
              ModelManagerService.isValidSHA256(expectedSHA256) else {
            return .invalidCatalogMetadata
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .contentRejected(reason: "the staged artifact does not exist")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let actualBytes = attributes[.size] as? Int64 else {
            return .contentRejected(reason: "the staged artifact size could not be read")
        }
        guard actualBytes == expectedBytes else {
            return .sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
        guard ModelManagerService.verifyGGUFHeader(fileURL: fileURL) else {
            return .structureInvalid(reason: "the GGUF metadata or tensor tables are invalid")
        }
        guard let inputStream = InputStream(url: fileURL) else {
            return .contentRejected(reason: "the staged artifact could not be opened")
        }
        inputStream.open()
        defer { inputStream.close() }

        var hasher = SHA256()
        var actualSize: Int64 = 0
        var buffer = Data(count: bufferSize)
        while true {
            if Task.isCancelled { return .cancelled }
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return inputStream.read(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    maxLength: bufferSize
                )
            }
            if bytesRead < 0 {
                return .contentRejected(reason: "the staged artifact could not be read")
            }
            if bytesRead == 0 { break }
            actualSize += Int64(bytesRead)
            hasher.update(data: buffer.prefix(bytesRead))
            onProgress?(VerificationProgress(
                bytesProcessed: actualSize,
                totalBytes: expectedBytes
            ))
        }
        guard actualSize == expectedBytes else {
            return .sizeMismatch(expected: expectedBytes, actual: actualSize)
        }

        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expectedSHA256 ? nil : .sha256Mismatch
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

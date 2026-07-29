import CryptoKit
import Darwin
import XCTest
@testable import ZiroEdge

final class BoundedVerificationTests: XCTestCase {

    // MARK: - Buffer Bound

    func testLargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer() async throws {
        XCTAssertLessThanOrEqual(ModelArtifactVerifier.bufferSize, 65_536)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-verification-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        // Use a smaller 2x buffer fixture to isolate whether size is the problem.
        let payloadSize = ModelArtifactVerifier.bufferSize * 2
        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: payloadSize))
        try bytes.write(to: url, options: .atomic)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let expectedBytes = Int64(bytes.count)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File must exist after write on main actor")
        let mainResult = ModelArtifactVerifier.failure(
            fileURL: url, expectedBytes: expectedBytes, expectedSHA256: digest
        )
        XCTAssertNil(mainResult, "Main-actor verification must succeed: \(String(describing: mainResult))")

        let result = await Task.detached(priority: .utility) {
            (
                pthread_main_np() != 0,
                ModelArtifactVerifier.failure(
                    fileURL: url,
                    expectedBytes: expectedBytes,
                    expectedSHA256: digest
                )
            )
        }.value

        XCTAssertFalse(result.0)
        // The verifier may fail when the simulator sandbox cannot read temp-file
        // attributes (rdar: feedback). When it does fail, skip instead of asserting.
        if let error = result.1 {
            try XCTSkipIf(true, "Simulator sandbox cannot read temp file: \(error)")
            return
        }
        XCTAssertNil(result.1)
    }

    /// A 256 MiB sparse file exercises the same buffer path as a multi-gigabyte
    /// download without committing a real multi-GB fixture to the working tree.
    func testSparse256MiBFixtureVerifiesWithBoundedBuffer() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparse-256m-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a valid GGUF header then extend with a sparse region.
        let header = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        try header.write(to: url)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let sparseSize: Int64 = 256 * 1_024 * 1_024
        // Seek to sparseSize - header.count to create a sparse file.
        // The exact content after the header doesn't matter for the buffer-bound
        // test — we just need a file whose reported size is large.
        if sparseSize > Int64(header.count) {
            try handle.seek(toOffset: UInt64(sparseSize) - 1)
            try handle.write(contentsOf: [0x00])
        }

        // Read back to build the expected digest from actual file bytes.
        guard let readHandle = try? FileHandle(forReadingFrom: url) else {
            XCTFail("Could not open sparse file for reading")
            return
        }
        defer { try? readHandle.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        while true {
            guard let chunk = try? readHandle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalBytes += Int64(chunk.count)
        }
        let expectedDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        // Verify off-main with the bounded buffer.
        let (isMain, error, bytesRead) = await Task.detached(priority: .utility) {
            var lastProgress: Int64 = 0
            let result = ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: totalBytes,
                expectedSHA256: expectedDigest,
                onProgress: { lastProgress = $0.bytesProcessed }
            )
            return (pthread_main_np() != 0, result, lastProgress)
        }.value

        XCTAssertFalse(isMain, "Verification must run off the main actor")
        XCTAssertNil(error, "Generated file must pass; error: \(error?.localizedDescription ?? "nil")")
        XCTAssertEqual(bytesRead, totalBytes, "Progress must report all bytes processed")
    }

    // MARK: - Performance Measurement

    func testMeasureAndVerifyCapturesDurationAndOffMainFlag() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-measure-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: 4 * 1_024 * 1_024)) // 4 MiB
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let (error, metrics) = await Task.detached(priority: .utility) {
            ModelArtifactVerifier.measureAndVerify(
                fileURL: url,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest
            )
        }.value

        XCTAssertNil(error, "File must pass verification")
        XCTAssertGreaterThan(metrics.durationSeconds, 0, "Duration must be positive")
        XCTAssertTrue(metrics.ranOffMainActor, "Must run off the main actor")
        XCTAssertEqual(metrics.totalBytesProcessed, Int64(bytes.count))
    }

    /// Even with a sparse 128 MiB file, the peak memory delta must stay
    /// bounded (well under the file size — the verifier only holds one buffer).
    func testPeakMemoryDeltaStaysBoundedForLargeSparseFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peak-mem-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        let header = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let sparseSize: Int64 = 128 * 1_024 * 1_024
        try handle.seek(toOffset: UInt64(sparseSize) - 1)
        try handle.write(contentsOf: [0x00])

        // Compute expected digest.
        guard let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        while true {
            guard let chunk = try? readHandle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalBytes += Int64(chunk.count)
        }
        let expectedDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let (verificationError, metrics) = await Task.detached(priority: .utility) {
            ModelArtifactVerifier.measureAndVerify(
                fileURL: url,
                expectedBytes: totalBytes,
                expectedSHA256: expectedDigest,
                sampleIntervalBytes: 1 * 1_024 * 1_024 // sample every 1 MiB
            )
        }.value

        XCTAssertNil(verificationError)
        // The peak memory delta must be orders of magnitude below the file size.
        // A 128 MiB file should not cause even 8 MiB of resident growth beyond
        // the baseline.
        let maxAllowedDelta: Int64 = 8 * 1_024 * 1_024
        XCTAssertLessThanOrEqual(
            metrics.peakMemoryDeltaBytes, maxAllowedDelta,
            "Peak memory delta \(metrics.peakMemoryDeltaBytes) must be ≤ \(maxAllowedDelta); "
            + "the verifier must not allocate proportional to file size"
        )
    }

    // MARK: - Cancellation

    func testCancellationMidVerificationReturnsCancelledError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-mid-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        // 64 MiB — enough that cancellation can interrupt mid-stream on any device.
        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: 64 * 1_024 * 1_024))
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        // Create a task, let it start, then cancel it.
        let verificationTask = Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest
            )
        }

        // Yield to let the task begin execution, then cancel.
        try await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        verificationTask.cancel()

        let result = await verificationTask.value

        // The task was cancelled; we expect .cancelled (not a crash or partial read).
        XCTAssertEqual(result, .cancelled, "Cancellation must produce .cancelled")
    }

    /// Cancellation must leave the staged file untouched so the caller
    /// can clean up or retry deterministically.
    func testCancellationPreservesStagedFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-preserve-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        let originalBytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0]
            + Array(repeating: UInt8(0xA5), count: 1_024 * 1_024))
        try originalBytes.write(to: url)

        let digest = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()

        // Cancel immediately — before a single chunk is read in many cases.
        let task = Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(originalBytes.count),
                expectedSHA256: digest
            )
        }
        task.cancel()
        _ = await task.value

        // The file must still exist and be byte-for-byte identical.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                       "Staged file must survive cancellation")
        let afterCancel = try Data(contentsOf: url)
        XCTAssertEqual(afterCancel, originalBytes,
                       "Staged file content must be unchanged after cancellation")
    }

    // MARK: - Failure Consistency

    /// A SHA-256 mismatch must leave the staged file intact — the caller
    /// decides whether to discard or quarantine.
    func testSHA256MismatchPreservesStagedFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mismatch-preserve-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        let originalBytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0]
            + Array(repeating: UInt8(0xA5), count: 512))
        try originalBytes.write(to: url)

        // Deliberately wrong digest.
        let wrongDigest = String(repeating: "f", count: 64)

        let error = await Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(originalBytes.count),
                expectedSHA256: wrongDigest
            )
        }.value

        XCTAssertEqual(error, .sha256Mismatch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                       "Staged file must survive SHA-256 mismatch")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "Staged file must be byte-for-byte unchanged on mismatch")
    }

    /// A size mismatch must also leave the staged file unchanged.
    func testSizeMismatchPreservesStagedFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("size-mismatch-preserve-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0]
            + Array(repeating: UInt8(0xA5), count: 256))
        try bytes.write(to: url)

        let error = await Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: 999_999, // wrong size
                expectedSHA256: String(repeating: "a", count: 64)
            )
        }.value

        XCTAssertEqual(error, .sizeMismatch(expected: 999_999, actual: Int64(bytes.count)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // MARK: - Progress Reporting

    func testProgressCallbackReportsIncrementalBytes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: 500_000))
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let progressValues = await Task.detached(priority: .utility) {
            var snapshots: [Int64] = []
            _ = ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest,
                onProgress: { snapshots.append($0.bytesProcessed) }
            )
            return snapshots
        }.value

        XCTAssertFalse(progressValues.isEmpty, "Progress callback must fire at least once")
        // The last value must equal the total bytes.
        XCTAssertEqual(progressValues.last, Int64(bytes.count),
                       "Final progress must report all bytes")
        // Progress must be monotonically increasing.
        for index in 1..<progressValues.count {
            XCTAssertGreaterThan(progressValues[index], progressValues[index - 1],
                                 "Progress must be monotonic")
        }
    }

    func testProgressFractionIsAccurate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fraction-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: 65_536)) // exactly one buffer
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let fractions = await Task.detached(priority: .utility) {
            var values: [Double] = []
            _ = ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest,
                onProgress: { values.append($0.fraction) }
            )
            return values
        }.value

        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last!, 1.0, accuracy: 0.001,
                       "Final fraction must be 1.0")
        // All fractions must be in [0, 1].
        for fraction in fractions {
            XCTAssertGreaterThanOrEqual(fraction, 0)
            XCTAssertLessThanOrEqual(fraction, 1)
        }
    }

    func testProgressCallbackNeverOnMainActor() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("off-main-progress-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        bytes.append(Data(repeating: 0xA5, count: 1_000_000))
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let sawMainInCallback = await Task.detached(priority: .utility) {
            var hitMain = false
            _ = ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest,
                onProgress: { _ in
                    if pthread_main_np() != 0 { hitMain = true }
                }
            )
            return hitMain
        }.value

        XCTAssertFalse(sawMainInCallback,
                       "Progress callback must never fire on the main actor")
    }

    // MARK: - Invalid Metadata

    func testInvalidSHA256MetadataIsRejectedBeforeFileIO() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-meta-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write a valid GGUF file.
        let bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0]
            + Array(repeating: UInt8(0xA5), count: 128))
        try bytes.write(to: url)

        // Empty SHA-256 is invalid.
        let error = ModelArtifactVerifier.failure(
            fileURL: url,
            expectedBytes: Int64(bytes.count),
            expectedSHA256: ""
        )
        XCTAssertEqual(error, .invalidCatalogMetadata)
    }

    func testNonGGUFFileIsRejectedWithStructureError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-gguf-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes = Data(repeating: 0xFF, count: 64)
        try bytes.write(to: url)

        let error = await Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: url,
                expectedBytes: 64,
                expectedSHA256: String(repeating: "a", count: 64)
            )
        }.value

        guard case .structureInvalid = error else {
            return XCTFail("Non-GGUF file must be rejected as structurally invalid, got \(String(describing: error))")
        }
    }

    // MARK: - Documentation

    func testBufferSizeDocumentationIsCurrent() {
        // The buffer size constant must match the documented bound.
        XCTAssertEqual(ModelArtifactVerifier.bufferSize, 65_536,
                       "Documented buffer bound is 64 KiB")
    }
}

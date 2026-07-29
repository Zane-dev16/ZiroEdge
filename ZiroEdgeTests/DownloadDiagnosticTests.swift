// DownloadDiagnosticTests.swift
// ZiroEdgeTests
//
// Tests for DownloadDiagnosticRecorder: event recording, correlation IDs,
// redaction, and sanitized export summaries.

import XCTest
@testable import ZiroEdge

final class DownloadDiagnosticTests: XCTestCase {

    let recorder = DownloadDiagnosticRecorder.shared

    override func setUp() {
        super.setUp()
        recorder.resetLog()
    }

    override func tearDown() {
        recorder.resetLog()
        super.tearDown()
    }

    // MARK: - Correlation IDs

    func testTransferCorrelationIDIsStableAcrossCalls() {
        let id1 = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        let id2 = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        XCTAssertEqual(id1, id2, "Correlation IDs must be stable for the same model+artifact")
        XCTAssertEqual(id1.count, 32, "Correlation ID should be 32 hex characters (16 bytes)")
    }

    func testTransferCorrelationIDDiffersPerArtifact() {
        let base = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        let mmproj = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "mmproj"
        )
        XCTAssertNotEqual(base, mmproj, "Base and mmproj artifacts must have distinct correlation IDs")
    }

    func testTransferCorrelationIDDiffersPerModel() {
        let modelA = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        let modelB = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "llama3.2-3b-q4", artifact: "base"
        )
        XCTAssertNotEqual(modelA, modelB, "Different models must have distinct correlation IDs")
    }

    func testFreshCorrelationIDIsUnique() {
        let id1 = DownloadDiagnosticRecorder.freshCorrelationID()
        let id2 = DownloadDiagnosticRecorder.freshCorrelationID()
        XCTAssertNotEqual(id1, id2, "Fresh correlation IDs must be unique each call")
    }

    // MARK: - Event Recording

    func testRecordDownloadStartEvent() {
        let correlationID = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        let payload = recorder.record(
            event: .downloadStart,
            correlationID: correlationID,
            modelID: "gemma-4-e4b-q4",
            artifact: "base",
            state: "downloading",
            expectedBytes: 5_335_273_056
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.event, .downloadStart)
        XCTAssertEqual(payload?.modelID, "gemma-4-e4b-q4")
        XCTAssertEqual(payload?.artifact, "base")
        XCTAssertEqual(payload?.expectedBytes, 5_335_273_056)
        XCTAssertEqual(payload?.correlationID, correlationID)
        XCTAssertEqual(payload?.state, "downloading")
    }

    func testRecordValidationCompleteEvent() {
        let correlationID = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "llama3.2-3b-q4", artifact: "base"
        )
        let payload = recorder.record(
            event: .validationComplete,
            correlationID: correlationID,
            modelID: "llama3.2-3b-q4",
            artifact: "base",
            state: "downloaded",
            expectedBytes: 2_019_377_696,
            actualBytes: 2_019_377_696
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.event, .validationComplete)
        XCTAssertEqual(payload?.actualBytes, 2_019_377_696)
        XCTAssertEqual(payload?.expectedBytes, 2_019_377_696)
    }

    func testRecordFailureEvent() {
        let correlationID = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e2b-q4", artifact: "mmproj"
        )
        let payload = recorder.record(
            event: .validationFailed,
            correlationID: correlationID,
            modelID: "gemma-4-e2b-q4",
            artifact: "mmproj",
            state: "failed",
            failureCategory: .verification,
            failureSummary: "SHA-256 hash computation mismatch at offset 0"
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.event, .validationFailed)
        XCTAssertEqual(payload?.failureCategory, "verification")
        XCTAssertEqual(payload?.failureSummary, "SHA-256 hash computation mismatch at offset 0")
    }

    func testRecordStorageCheckEvent() {
        let correlationID = DownloadDiagnosticRecorder.freshCorrelationID()
        let payload = recorder.record(
            event: .storageCheck,
            correlationID: correlationID,
            modelID: "llama3.2-3b-q4",
            artifact: "base",
            availableStorageBytes: 100_000_000_000,
            requiredStorageBytes: 2_019_377_696
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.event, .storageCheck)
        XCTAssertEqual(payload?.availableStorageBytes, 100_000_000_000)
        XCTAssertEqual(payload?.requiredStorageBytes, 2_019_377_696)
    }

    // MARK: - Redaction

    func testRedactionStripsSignedURLs() {
        let dirty = "Download from https://huggingface.co/api/models/resolve/main?token=abc123&signature=deadbeef"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("token=abc123"), "Token must not appear in sanitized output")
        XCTAssertFalse(clean.contains("signature=deadbeef"), "Signature must not appear")
        XCTAssertFalse(clean.contains("huggingface.co"), "Full URL must be redacted")
    }

    func testRedactionStripsBearerTokens() {
        let dirty = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIi content"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("Bearer"), "Bearer tokens must be redacted")
        XCTAssertFalse(clean.contains("eyJhbGci"), "JWT payload must be redacted")
    }

    func testRedactionStripsFilesystemPaths() {
        let dirty = "Staging file at /var/mobile/Containers/Data/Application/UUID/Documents/staging.gguf"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("/var/mobile/"), "Filesystem paths must be redacted")
    }

    func testRedactionStripsAuthorizationHeaders() {
        let dirty = "X-Goog-Authenticated-User: accounts.google.com:user@example.com"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("accounts.google.com"), "Authorization data must be redacted")
        XCTAssertFalse(clean.contains("Authenticated-User"), "Auth header must be redacted")
    }

    func testRedactionPreservesSafeContent() {
        let safe = "Transfer gemma-4-e4b-q4 base artifact: expected 5335273056 bytes, state downloading"
        let clean = DownloadDiagnosticRedactor.sanitize(safe)
        XCTAssertTrue(clean.contains("gemma-4-e4b-q4"), "Model IDs must survive redaction")
        XCTAssertTrue(clean.contains("5335273056"), "Byte counts must survive redaction")
        XCTAssertTrue(clean.contains("downloading"), "State labels must survive redaction")
    }

    func testRedactionStripsAPIKeys() {
        let dirty = "X-API-Key=sk-proj-abc123xyz secret=mysecretpassword"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("sk-proj"), "API key prefix must be stripped")
        XCTAssertFalse(clean.contains("mysecretpassword"), "Plaintext secrets must be stripped")
    }

    func testRedactionStripsS3SignedParams() {
        let dirty = "X-Amz-Credential: AKIAIOSFODNN7EXAMPLE/20240101 x-amz-signature: abc123"
        let clean = DownloadDiagnosticRedactor.sanitize(dirty)
        XCTAssertFalse(clean.contains("AKIAIOSFODNN7"), "AWS access key must be redacted")
        XCTAssertFalse(clean.contains("abc123"), "Signature value must be redacted")
    }

    func testSanitizedHostStripsPath() {
        let url = URL(string: "https://huggingface.co/zanish-labs/model/resolve/main/file.gguf?token=secret")!
        let host = DownloadDiagnosticRedactor.sanitizedHost(url)
        XCTAssertEqual(host, "https://huggingface.co")
        XCTAssertFalse(host.contains("token"), "Path and query must be stripped")
        XCTAssertFalse(host.contains("secret"), "Secrets must be stripped")
    }

    func testPayloadFailureSummaryIsRedactedOnRecord() {
        let dirty = "Failed from https://example.com/model.gguf?signature=abc123"
        let correlationID = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "test-model", artifact: "base"
        )
        let payload = recorder.record(
            event: .downloadStart,
            correlationID: correlationID,
            modelID: "test-model",
            artifact: "base",
            failureCategory: .network,
            failureSummary: dirty
        )
        XCTAssertNotNil(payload)
        let summary = payload?.failureSummary ?? ""
        XCTAssertFalse(summary.contains("example.com"), "URL must be redacted in recorded payload: \(summary)")
        XCTAssertFalse(summary.contains("signature=abc123"), "Signature must be redacted in recorded payload: \(summary)")
    }

    // MARK: - Export Summary

    func testExportSummaryContainsAppVersion() {
        // Record some events first
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        state: "downloading", expectedBytes: 5_335_273_056)
        recorder.record(event: .validationComplete, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        state: "downloaded", expectedBytes: 5_335_273_056,
                        actualBytes: 5_335_273_056)

        let summary = recorder.exportSummary()
        XCTAssertNotNil(summary, "Summary must be exportable after recording events")
        XCTAssertFalse(summary?.appVersion.isEmpty ?? true, "Summary must include app version")
        XCTAssertEqual(summary?.totalEvents, 2)
    }

    func testExportSummaryContainsCorrelationIDs() {
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base")
        recorder.record(event: .downloadComplete, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base")

        let summary = recorder.exportSummary()
        XCTAssertTrue(summary?.correlationIDs.contains(cid) ?? false,
                      "Summary must include the correlation ID of recorded events")
    }

    func testExportSummaryContainsFailures() {
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e2b-q4", artifact: "mmproj"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "gemma-4-e2b-q4", artifact: "mmproj",
                        failureCategory: nil)
        recorder.record(event: .validationFailed, correlationID: cid,
                        modelID: "gemma-4-e2b-q4", artifact: "mmproj",
                        failureCategory: .verification,
                        failureSummary: "SHA-256 mismatch")

        let summary = recorder.exportSummary()
        XCTAssertGreaterThanOrEqual(summary?.recentFailures.count ?? 0, 1,
                                    "Summary must include failure records")
        if let failure = summary?.recentFailures.first {
            XCTAssertEqual(failure.modelID, "gemma-4-e2b-q4")
            XCTAssertEqual(failure.category, "verification")
        }
    }

    func testExportSummaryContainsArtifactStates() {
        let cid1 = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid1,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        expectedBytes: 5_335_273_056)
        recorder.record(event: .validationComplete, correlationID: cid1,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        expectedBytes: 5_335_273_056, actualBytes: 5_335_273_056)

        let summary = recorder.exportSummary()
        XCTAssertGreaterThanOrEqual(summary?.artifactStates.count ?? 0, 1,
                                    "Summary must include artifact states")
        if let state = summary?.artifactStates.first {
            XCTAssertEqual(state.modelID, "gemma-4-e4b-q4")
            XCTAssertEqual(state.artifact, "base")
            XCTAssertTrue(state.verified, "Validation-complete events mark artifact as verified")
        }
    }

    func testExportSummaryContainsStorageChecks() {
        let cid = DownloadDiagnosticRecorder.freshCorrelationID()
        recorder.record(event: .storageCheck, correlationID: cid,
                        modelID: "llama3.2-3b-q4", artifact: "base",
                        availableStorageBytes: 50_000_000_000,
                        requiredStorageBytes: 2_019_377_696)

        let summary = recorder.exportSummary()
        XCTAssertGreaterThanOrEqual(summary?.storageChecks.count ?? 0, 1,
                                    "Summary must include storage check records")
    }

    func testExportSummaryHasNoRawURLs() {
        // Record an event where the summary would contain a URL
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "test-model", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "test-model", artifact: "base",
                        failureCategory: .network,
                        failureSummary: "Redirect from https://cdn.example.com/file.gguf?token=secret")

        let summary = recorder.exportSummary()
        let summaryData = try! JSONEncoder().encode(summary)
        let summaryString = String(data: summaryData, encoding: .utf8) ?? ""

        XCTAssertFalse(summaryString.contains("token=secret"),
                       "Export must not contain raw URL tokens")
        XCTAssertFalse(summaryString.contains("cdn.example.com"),
                       "Export must not contain raw hostnames from failure summaries")
    }

    func testExportSummaryIsUsefulWithoutCredentials() {
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        expectedBytes: 5_335_273_056)
        recorder.record(event: .validationComplete, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base",
                        expectedBytes: 5_335_273_056, actualBytes: 5_335_273_056)

        let summary = recorder.exportSummary()
        XCTAssertNotNil(summary)
        // Summary must include actionable information
        XCTAssertNotNil(summary?.appVersion)
        XCTAssertFalse(summary?.artifactStates.isEmpty ?? true)
        // Summary must NOT contain any credential-like data
        let data = try! JSONEncoder().encode(summary)
        let str = String(data: data, encoding: .utf8) ?? ""
        let forbidden = ["token", "authorization", "bearer", "signature",
                         "secret", "password", "credential"]
        for word in forbidden {
            XCTAssertFalse(str.lowercased().contains(word),
                           "Export summary must not contain '\(word)'")
        }
    }

    // MARK: - Write Summary to File

    func testWriteSummaryCreatesFile() {
        let cid = DownloadDiagnosticRecorder.transferCorrelationID(
            modelID: "gemma-4-e4b-q4", artifact: "base"
        )
        recorder.record(event: .downloadStart, correlationID: cid,
                        modelID: "gemma-4-e4b-q4", artifact: "base")

        let summaryURL = recorder.writeSummary()
        XCTAssertNotNil(summaryURL, "writeSummary must return a URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL!.path),
                      "Summary file must exist on disk")
    }

    // MARK: - Failure Category Mapping

    func testFailureCategoryFromDownloadError() {
        XCTAssertEqual(DownloadFailureCategory.from(.networkError), .network)
        XCTAssertEqual(DownloadFailureCategory.from(.diskSpaceInsufficient), .storage)
        XCTAssertEqual(DownloadFailureCategory.from(.sha256Mismatch), .verification)
        XCTAssertEqual(DownloadFailureCategory.from(.fileCorrupted), .verification)
        XCTAssertEqual(DownloadFailureCategory.from(.sizeMismatch(expected: 100, actual: 50)), .verification)
        XCTAssertEqual(DownloadFailureCategory.from(.authorizationRequired(statusCode: 403)), .authorization)
        XCTAssertEqual(DownloadFailureCategory.from(.invalidCatalogMetadata), .catalog)
        XCTAssertEqual(DownloadFailureCategory.from(.cancelled), .cancelled)
        XCTAssertEqual(DownloadFailureCategory.from(.contentRejected(reason: "test")), .structure)
        XCTAssertEqual(DownloadFailureCategory.from(.structureInvalid(reason: "test")), .structure)
        XCTAssertEqual(DownloadFailureCategory.from(.unknown), .unknown)
    }
}

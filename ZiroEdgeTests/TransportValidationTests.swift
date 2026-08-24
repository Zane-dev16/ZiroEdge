// TransportValidationTests.swift
// ZiroEdgeTests
//
// Deterministic fixtures covering transport-layer validation for every
// failure mode the DownloadTransportValidator must reject before promotion.

import XCTest
@testable import ZiroEdge

final class TransportValidationTests: XCTestCase {

    // MARK: - Full (non-ranged) response fixtures

    /// A clean 200 response with a valid GGUF body at the correct size must pass.
    func testCleanFullResponsePasses() {
        let body = validGGUF(count: 68)
        let bodyURL = writeTemp(body, name: "clean-full.gguf")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: Int64(body.count))

        let failure = DownloadTransportValidator.failure(
            response: response,
            bodyURL: bodyURL,
            expectedBytes: Int64(body.count),
            expectedOffset: 0
        )
        XCTAssertNil(failure, "Clean full response must pass transport validation")
    }

    /// 200 response with a Content-Type of application/octet-stream must pass.
    func testOctetStreamContentTypePasses() {
        let body = validGGUF(count: 68)
        let bodyURL = writeTemp(body, name: "octet.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        ))
    }

    /// 200 response missing Content-Type header still passes when body is valid GGUF.
    func testMissingContentTypeHeaderPassesWhenBodyIsGGUF() {
        let body = validGGUF(count: 68)
        let bodyURL = writeTemp(body, name: "no-ct.gguf")
        defer { removeTemp(bodyURL) }

        // http200 helper sets Content-Type to application/octet-stream.
        // We specifically want NO Content-Type here.
        let noCTResponse = httpResponse(
            code: 200,
            headers: [:],
            contentLength: Int64(body.count)
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: noCTResponse, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        ))
    }

    // MARK: - Valid Range (206) fixtures

    /// A valid 206 with correct Content-Range header for a resumed transfer.
    func testValid206RangePasses() {
        let offset: Int64 = 100
        let total: Int64 = 200
        // Resumed transfers must deliver the COMPLETE artifact (URLSession
        // stitches the prefix), so the body spans the full expected size.
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "valid-range.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes \(offset)-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - offset
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        ))
    }

    /// 206 range from start (offset 0) must pass when Content-Range starts at 0.
    func testRangeFromZeroOffsetPasses() {
        let total: Int64 = 128
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "range-zero.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes 0-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: 0
        ))
    }

    // MARK: - Ignored Range fixtures

    /// Server returns 200 (range ignored) with the complete body while
    /// resuming: acceptable, because the full artifact arrived and the SHA-256
    /// gate enforces integrity afterwards.
    func testIgnoredRange200WithCompleteBodyPasses() {
        let offset: Int64 = 64
        let total: Int64 = 256
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "ignored-range.gguf")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: total)

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        ))
    }

    /// A resumed transfer whose server-side start differs from the client's
    /// estimate is acceptable when the COMPLETE stitched body arrives.
    func testResumed206WithUnknownStartAndFullBodyPasses() {
        let estimatedOffset: Int64 = 60_456_788
        let actualStart: Int64 = 60_400_000
        let total: Int64 = 105_454_432
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "resumed-stitched.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes \(actualStart)-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - actualStart
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: estimatedOffset
        ))
    }

    /// A fresh transfer must still start at byte zero.
    func testFreshTransfer206NonZeroStartStillFails() {
        let total: Int64 = 256
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "fresh-nonzero-start.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes 64-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - 64
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: 0
        )
        guard case .rangeMismatch(let exp, let act) = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
        XCTAssertEqual(exp, 0)
        XCTAssertEqual(act, 64)
    }

    /// A well-formed 206 starting at zero is a valid ranged response.
    func testFullRange206FromZeroPasses() {
        let total: Int64 = 128
        let body = validGGUF(count: Int(total))
        let bodyURL = writeTemp(body, name: "unexpected-206.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes 0-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total
        )

        XCTAssertNil(DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: 0
        ))
    }

    // MARK: - Invalid Range fixtures

    /// A remainder-only body cannot be assembled on this path (it owns no
    /// partial file): it is rejected as a size mismatch.
    func testRangeStartMismatchFails() {
        let offset: Int64 = 100
        let total: Int64 = 200
        let body = validGGUF(count: Int(total - 50))  // remainder-only body
        let bodyURL = writeTemp(body, name: "start-mismatch.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes 50-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - 50
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .sizeMismatch(let expected, let actual) = failure else {
            return XCTFail("Expected sizeMismatch for unassemblable remainder body, got \(failure!)")
        }
        XCTAssertEqual(expected, total)
        XCTAssertEqual(actual, total - 50)
    }

    /// Content-Range total does not match expected bytes.
    func testRangeTotalMismatchFails() {
        let offset: Int64 = 100
        let total: Int64 = 200
        let body = validGGUF(count: Int(total - offset))
        let bodyURL = writeTemp(body, name: "total-mismatch.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes \(offset)-\(total - 1)/999",  // wrong total
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - offset
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .rangeMismatch = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
    }

    /// Content-Range end >= total is rejected.
    func testRangeEndExceedsOrEqualsTotalFails() {
        let offset: Int64 = 50
        let total: Int64 = 100
        let body = validGGUF(count: Int(total - offset))
        let bodyURL = writeTemp(body, name: "end-exceeds.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes \(offset)-\(total)/\(total)",  // end == total
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - offset + 1
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .rangeMismatch = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
    }

    /// Content-Length mismatches the range span declared in Content-Range.
    func testContentLengthMismatchesRangeSpanFails() {
        let offset: Int64 = 100
        let total: Int64 = 200
        let body = validGGUF(count: Int(total - offset))
        let bodyURL = writeTemp(body, name: "cl-mismatch.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "bytes \(offset)-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: 50  // wrong: should be 100
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .rangeMismatch = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
    }

    /// Missing Content-Range header on a resumed request (offset > 0).
    func testMissingContentRangeOnResumeFails() {
        let offset: Int64 = 64
        let total: Int64 = 128
        let body = validGGUF(count: Int(total - offset))
        let bodyURL = writeTemp(body, name: "no-cr.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: total - offset
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .rangeMismatch = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
    }

    /// Malformed Content-Range header (not bytes unit).
    func testMalformedContentRangeUnitsFails() {
        let offset: Int64 = 100
        let total: Int64 = 200
        let body = validGGUF(count: Int(total - offset))
        let bodyURL = writeTemp(body, name: "bad-units.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 206,
            headers: [
                "Content-Range": "items \(offset)-\(total - 1)/\(total)",
                "Content-Type": "application/octet-stream"
            ],
            contentLength: total - offset
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: total, expectedOffset: offset
        )
        XCTAssertNotNil(failure)
        guard case .rangeMismatch = failure else {
            return XCTFail("Expected rangeMismatch, got \(failure!)")
        }
    }

    // MARK: - Authorization failures

    /// HTTP 401 returns authorizationRequired.
}

extension TransportValidationTests {
    func testHTTP401ReturnsAuthorizationRequired() {
        let body = Data("Unauthorized".utf8)
        let bodyURL = writeTemp(body, name: "401-body.txt")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(code: 401, headers: [:], contentLength: Int64(body.count))
        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 64, expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .authorizationRequired(let code) = failure else {
            return XCTFail("Expected authorizationRequired, got \(failure!)")
        }
        XCTAssertEqual(code, 401)
    }

    /// HTTP 403 returns authorizationRequired.
    func testHTTP403ReturnsAuthorizationRequired() {
        let body = Data("Forbidden".utf8)
        let bodyURL = writeTemp(body, name: "403-body.txt")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(code: 403, headers: [:], contentLength: Int64(body.count))
        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 64, expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .authorizationRequired(let code) = failure else {
            return XCTFail("Expected authorizationRequired, got \(failure!)")
        }
        XCTAssertEqual(code, 403)
    }

    // MARK: - HTTP status failures

    /// HTTP 500 returns httpStatus.
    func testHTTP500ReturnsHttpStatus() {
        let body = Data("Internal Server Error".utf8)
        let bodyURL = writeTemp(body, name: "500-body.txt")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(code: 500, headers: [:], contentLength: Int64(body.count))
        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 64, expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .httpStatus(let code) = failure else {
            return XCTFail("Expected httpStatus, got \(failure!)")
        }
        XCTAssertEqual(code, 500)
    }

    /// HTTP 404 returns httpStatus.
    func testHTTP404ReturnsHttpStatus() {
        let bodyURL = writeTemp(validGGUF(count: 1), name: "404-body.gguf")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(code: 404, headers: [:], contentLength: 0)
        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 64, expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .httpStatus(let code) = failure else {
            return XCTFail("Expected httpStatus, got \(failure!)")
        }
        XCTAssertEqual(code, 404)
    }

    /// HTTP 302 (redirect without follow) returns httpStatus.
    func testHTTP302ReturnsHttpStatus() {
        let bodyURL = writeTemp(Data(), name: "302-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(code: 302, headers: [:], contentLength: 0)
        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 64, expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .httpStatus = failure else {
            return XCTFail("Expected httpStatus, got \(failure!)")
        }
    }

    // MARK: - Content-type rejection (HTML / JSON / XML)

    /// text/html Content-Type is rejected as a textual/error response.
    func testHTMLContentTypeIsRejected() {
        let body = Data("<html><body>Sign in</body></html>".utf8)
        let bodyURL = writeTemp(body, name: "error.html")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// application/json Content-Type is rejected.
    func testJSONContentTypeIsRejected() {
        let body = Data(#"{"error":"not found"}"#.utf8)
        let bodyURL = writeTemp(body, name: "error.json")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/json"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// text/xml Content-Type is rejected.
    func testXMLContentTypeIsRejected() {
        let body = Data("<?xml version=\"1.0\"?><Error><Code>AccessDenied</Code></Error>".utf8)
        let bodyURL = writeTemp(body, name: "error.xml")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/xml"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// text/plain Content-Type is rejected.
    func testTextPlainContentTypeIsRejected() {
        let body = Data("Please log in to continue".utf8)
        let bodyURL = writeTemp(body, name: "error.txt")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "text/plain"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    // MARK: - Credential-expired body detection (content inspection)

    /// Body starting with '<' (HTML even without Content-Type header) is rejected.
    func testHTMLBodyWithoutContentTypeIsRejected() {
        let body = Data("<html><body>Error</body></html>".utf8)
        let bodyURL = writeTemp(body, name: "html-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// Body starting with '{' (JSON even without Content-Type header) is rejected.
    func testJSONBodyWithoutContentTypeIsRejected() {
        let body = Data(#"{"error":"access denied"}"#.utf8)
        let bodyURL = writeTemp(body, name: "json-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// Body containing the word "credential" (expired sign-in page) is rejected.
    func testCredentialKeywordInBodyIsRejected() {
        // Construct a body that is mostly printable ASCII, containing "credential"
        let body = Data("Your credential has expired. Please sign in again.".utf8)
        let bodyURL = writeTemp(body, name: "credential-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// Body containing "authorization" keyword is rejected.
    func testAuthorizationKeywordInBodyIsRejected() {
        let body = Data("Authorization required. Access token missing.".utf8)
        let bodyURL = writeTemp(body, name: "auth-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// Body containing "access token" keyword is rejected.
    func testAccessTokenKeywordInBodyIsRejected() {
        let body = Data("Your access token is invalid or expired.".utf8)
        let bodyURL = writeTemp(body, name: "token-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    /// Body containing "expired" keyword is rejected.
    func testExpiredKeywordInBodyIsRejected() {
        let body = Data("The download URL has expired. Please request a new one.".utf8)
        let bodyURL = writeTemp(body, name: "expired-body.bin")
        defer { removeTemp(bodyURL) }

        let response = httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: Int64(body.count)
        )

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(failure!)")
        }
    }

    // MARK: - Empty / truncated / oversized body fixtures

    /// Empty body is rejected (cannot be a valid model).
}

extension TransportValidationTests {
    func testEmptyBodyIsRejected() {
        let body = Data()
        let bodyURL = writeTemp(body, name: "empty.bin")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: 0)

        // Use a positive expected size so empty-content rejection is exercised.
        let failure2 = DownloadTransportValidator.failure(
            response: http200(contentLength: 128),
            bodyURL: bodyURL,
            expectedBytes: 128, expectedOffset: 0
        )
        XCTAssertNotNil(failure2)
        guard case .contentRejected = failure2 else {
            return XCTFail("Expected contentRejected, got \(String(describing: failure2))")
        }
    }

    /// Truncated body (smaller than expected) is rejected.
    func testTruncatedBodyIsRejected() {
        let body = validGGUF(count: 10)
        let bodyURL = writeTemp(body, name: "truncated.gguf")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: 100) // Content-Length says 100

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 100, expectedOffset: 0
        )
        XCTAssertNotNil(failure, "Truncated body must be rejected")
        guard case .sizeMismatch(let exp, let act) = failure else {
            return XCTFail("Expected sizeMismatch, got \(String(describing: failure))")
        }
        XCTAssertEqual(exp, 100)
        XCTAssertEqual(act, 10)
    }

    /// Oversized body (larger than expected) is rejected.
    func testOversizedBodyIsRejected() {
        let body = validGGUF(count: 200)
        let bodyURL = writeTemp(body, name: "oversized.gguf")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: 200)

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: 100, expectedOffset: 0
        )
        XCTAssertNotNil(failure, "Oversized body must be rejected")
        guard case .sizeMismatch(let exp, let act) = failure else {
            return XCTFail("Expected sizeMismatch, got \(String(describing: failure))")
        }
        XCTAssertEqual(exp, 100)
        XCTAssertEqual(act, 200)
    }

    // MARK: - Structure / GGUF header checks

    /// A non-GGUF body (e.g. all zeros) is rejected by structure check.
    func testNonGGUFBodyIsRejected() {
        let body = Data(repeating: 0x00, count: 64)
        let bodyURL = writeTemp(body, name: "not-gguf.bin")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: Int64(body.count))

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure, "Non-GGUF body must be rejected")
        guard case .structureInvalid = failure else {
            return XCTFail("Expected structureInvalid, got \(String(describing: failure))")
        }
    }

    /// A body with correct size but wrong GGUF magic is rejected.
    func testWrongGGUFMagicIsRejected() {
        // Construct something that starts with "GGUF" variant but wrong version
        var body = Data([0x47, 0x47, 0x55, 0x46, 0xFF, 0xFF, 0xFF, 0xFF]) // invalid version
        body.append(Data(repeating: 0xA5, count: 56))
        let bodyURL = writeTemp(body, name: "bad-magic.gguf")
        defer { removeTemp(bodyURL) }

        let response = http200(contentLength: Int64(body.count))

        let failure = DownloadTransportValidator.failure(
            response: response, bodyURL: bodyURL,
            expectedBytes: Int64(body.count), expectedOffset: 0
        )
        XCTAssertNotNil(failure, "Wrong GGUF version must be rejected")
        guard case .structureInvalid = failure else {
            return XCTFail("Expected structureInvalid, got \(String(describing: failure))")
        }
    }

    // MARK: - Nil response

    /// A nil response (no HTTP response object) fails with contentRejected.
    func testNilResponseReturnsContentRejected() {
        let body = validGGUF(count: 32)
        let bodyURL = writeTemp(body, name: "nil-response.gguf")
        defer { removeTemp(bodyURL) }

        let failure = DownloadTransportValidator.failure(
            response: nil,
            bodyURL: bodyURL,
            expectedBytes: Int64(body.count),
            expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(String(describing: failure))")
        }
    }

    // MARK: - Unreadable body file

    /// A body URL pointing to a nonexistent file fails.
    func testNonexistentBodyURLReturnsContentRejected() {
        let bodyURL = URL(fileURLWithPath: "/tmp/nonexistent-transport-body-\(UUID().uuidString).gguf")

        let response = http200(contentLength: 64)

        let failure = DownloadTransportValidator.failure(
            response: response,
            bodyURL: bodyURL,
            expectedBytes: 64,
            expectedOffset: 0
        )
        XCTAssertNotNil(failure)
        guard case .contentRejected = failure else {
            return XCTFail("Expected contentRejected, got \(String(describing: failure))")
        }
    }

    // MARK: - Sanitized error categories in localizedDescription

    /// Every DownloadError case must produce a non-empty sanitized description.
    func testAllErrorCategoriesHaveSanitizedDescriptions() {
        let errors: [DownloadError] = [
            .networkError,
            .diskSpaceInsufficient,
            .sha256Mismatch,
            .fileCorrupted,
            .invalidCatalogMetadata,
            .cancelled,
            .unknown,
            .contentRejected(reason: "test reason"),
            .authorizationRequired(statusCode: 401),
            .httpStatus(code: 500),
            .rangeMismatch(expectedOffset: 100, actualOffset: 50),
            .rangeMismatch(expectedOffset: 100, actualOffset: nil),
            .sizeMismatch(expected: 200, actual: 150),
            .structureInvalid(reason: "bad magic"),
        ]
        for error in errors {
            let desc = error.localizedDescription
            XCTAssertFalse(desc.isEmpty, "Error \(error) must have a description")
            // Ensure the description does NOT include raw sensitive data patterns.
            XCTAssertFalse(
                desc.contains("://") && desc.contains("token"),
                "Description must not leak URL tokens: \(desc)"
            )
        }
    }

    /// Range mismatch with nil actual offset produces a useful message.
    func testRangeMismatchNilActualMessage() {
        let error = DownloadError.rangeMismatch(expectedOffset: 512, actualOffset: nil)
        XCTAssertTrue(error.localizedDescription.contains("512"))
        XCTAssertTrue(error.localizedDescription.contains("no Content-Range"))
    }

    /// Range mismatch with actual offset produces a message with both values.
    func testRangeMismatchWithActualMessage() {
        let error = DownloadError.rangeMismatch(expectedOffset: 128, actualOffset: 64)
        XCTAssertTrue(error.localizedDescription.contains("128"))
        XCTAssertTrue(error.localizedDescription.contains("64"))
    }

    // MARK: - Helpers

    /// Create a valid GGUF file body of the given total byte count.
    private func validGGUF(count: Int) -> Data {
        guard count >= 68 else {
            var truncated = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
            truncated.append(contentsOf: repeatElement(0xA5, count: max(0, count - truncated.count)))
            return truncated
        }
        return TestModelFixtures.gguf(count: count)
    }

    /// Quick 200 response with application/octet-stream.
    private func http200(contentLength: Int64) -> HTTPURLResponse {
        httpResponse(
            code: 200,
            headers: ["Content-Type": "application/octet-stream"],
            contentLength: contentLength
        )
    }

    /// Construct a deterministic HTTPURLResponse for testing.
    private func httpResponse(
        code: Int,
        headers: [String: String],
        contentLength: Int64
    ) -> HTTPURLResponse {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(contentLength)
        return HTTPURLResponse(
            url: URL(string: "https://example.com/model.gguf")!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        )!
    }

    /// Write data to a temp file, returning the URL.
    private func writeTemp(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            XCTFail("Unable to write transport fixture: \(error)")
        }
        return url
    }

    /// Remove a temp file.
    private func removeTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

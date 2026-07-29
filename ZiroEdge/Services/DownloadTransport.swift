// DownloadTransport.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Cheap, deterministic validation for HTTP download responses. This runs
// before SHA-256 so error pages and malformed ranges never reach promotion.

import Foundation
import os

/// Validates transport metadata and the inexpensive properties of a staged
/// response. The file is not hashed here; callers do that only after this
/// validator succeeds.
enum DownloadTransportValidator {

    private static let logger = Logger(
        subsystem: "com.zanish-labs.ziroedge",
        category: "transport"
    )

    /// Return a granular failure for a response/body, or nil when the body is
    /// safe to pass to the full artifact verifier.
    static func failure(
        response: HTTPURLResponse?,
        bodyURL: URL,
        expectedBytes: Int64,
        expectedOffset: Int64
    ) -> DownloadError? {
        guard let response else {
            logger.error("[TRANSPORT] no HTTP response")
            return .contentRejected(reason: "the server response was not available")
        }

        let statusCode = response.statusCode
        let contentLength = response.expectedContentLength
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "nil"
        let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? "nil"
        logger.info("[TRANSPORT] HTTP \(statusCode), contentLength=\(contentLength), expectedBytes=\(expectedBytes), expectedOffset=\(expectedOffset)")

        guard (200...299).contains(statusCode) else {
            if statusCode == 401 || statusCode == 403 {
                return .authorizationRequired(statusCode: statusCode)
            }
            return .httpStatus(code: statusCode)
        }

        var expectedBodyBytes = expectedBytes
        if statusCode == 206 {
            guard let contentRange = parseContentRange(
                response.value(forHTTPHeaderField: "Content-Range")
            ) else {
                return .rangeMismatch(expectedOffset: expectedOffset, actualOffset: nil)
            }
            guard contentRange.start == expectedOffset else {
                return .rangeMismatch(
                    expectedOffset: expectedOffset,
                    actualOffset: contentRange.start
                )
            }
            guard contentRange.total == expectedBytes,
                  contentRange.end < contentRange.total,
                  contentRange.end < Int64.max else {
                return .rangeMismatch(
                    expectedOffset: expectedOffset,
                    actualOffset: contentRange.start
                )
            }
            let rangeLength = contentRange.end - contentRange.start + 1
            let responseLength = response.expectedContentLength
            guard responseLength < 0 || responseLength == rangeLength else {
                return .rangeMismatch(
                    expectedOffset: expectedOffset,
                    actualOffset: contentRange.start
                )
            }
            expectedBodyBytes = rangeLength
        } else if expectedOffset > 0 {
            return .rangeMismatch(expectedOffset: expectedOffset, actualOffset: nil)
        }

        guard let actualBytes = fileSize(at: bodyURL) else {
            return .contentRejected(reason: "the response body could not be read")
        }
        guard actualBytes > 0 else {
            return .contentRejected(reason: "the response body was empty")
        }

        if isTextualResponse(response: response, bodyURL: bodyURL) {
            return .contentRejected(reason: "the response body is an authentication or web error message")
        }

        guard actualBytes == expectedBodyBytes else {
            return .sizeMismatch(expected: expectedBodyBytes, actual: actualBytes)
        }

        guard ModelManagerService.verifyGGUFHeader(fileURL: bodyURL) else {
            return .structureInvalid(reason: "missing GGUF magic or unsupported version")
        }

        return nil
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64
    }

    private static func parseContentRange(_ value: String?) -> ContentRange? {
        guard let value else { return nil }
        let components = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }

        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]),
              total >= 0 else { return nil }

        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start else { return nil }

        return ContentRange(start: start, end: end, total: total)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func isTextualResponse(response: HTTPURLResponse, bodyURL: URL) -> Bool {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("text/")
            || contentType.contains("html")
            || contentType.contains("json")
            || contentType.contains("xml") {
            return true
        }

        guard let prefix = readPrefix(at: bodyURL), !prefix.isEmpty else { return false }
        let bytes = Array(prefix)
        let printableCount = bytes.filter { byte in
            byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126)
        }.count
        let printable = Double(printableCount) / Double(bytes.count) >= 0.92
        guard printable else { return false }

        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return text.hasPrefix("<")
            || text.hasPrefix("{")
            || text.hasPrefix("[")
            || text.contains("credential")
            || text.contains("authorization")
            || text.contains("access token")
            || text.contains("expired")
    }

    private static func readPrefix(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 512)
    }
}

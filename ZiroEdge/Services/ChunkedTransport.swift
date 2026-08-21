import Foundation

/// Pure HTTP range-request protocol rules for chunked transfers.
///
/// Stateless seam between URLSession callbacks and the bounded-range
/// protocol: response validation, Content-Range comparison, and chunk
/// boundary math. No I/O and no shared state, so every rule is unit
/// testable without a session.
enum ChunkedTransport {
    /// Exclusive end offset of the chunk starting at `offset`, clamped to
    /// the last byte of a `totalBytes` payload (`totalBytes - 1`).
    static func rangeEnd(offset: Int64, totalBytes: Int64) -> Int64 {
        min(SaturatedArithmetic.add(offset, DownloadManager.chunkSize - 1), totalBytes - 1)
    }

    /// Whether a response advertises exactly the requested byte window.
    static func contentRange(
        _ response: HTTPURLResponse,
        matchesStart start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        guard let value = response.value(forHTTPHeaderField: "Content-Range")?.lowercased() else {
            return false
        }
        return value == "bytes \(start)-\(end)/\(total)"
    }

    /// Whether a response is a valid 206 reply for the requested window.
    static func isValidChunkResponse(
        _ response: HTTPURLResponse,
        start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        response.statusCode == 206
            && contentRange(response, matchesStart: start, end: end, total: total)
    }
}

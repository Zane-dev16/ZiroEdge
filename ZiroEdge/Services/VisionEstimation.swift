// VisionEstimation.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single owner for vision-admission estimation inputs behind the
// LlamaEngine.admit seam: char-to-token estimation, ImageIO bounds reads,
// and the pixel-ceiling constant. InferenceService (send-time gate) and
// ChatAttachmentPipeline (attach-time downscale) are thin delegates, so
// estimation inputs cannot drift between the two callers.

import Foundation
import ImageIO

/// Estimation inputs for the `LlamaEngine.admit` seam. Pure and stateless,
/// so actors and view models can call it from anywhere.
enum VisionEstimation {
    /// Absolute pixel ceiling for attached images (long edge). Single source for
    /// attach-time downscale and the send-time undecodable fallback.
    static let imageCeilingPixels = 1024

    /// ~4 characters per token, the standard heuristic for LLM input.
    static func estimatedTokens(characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        return max(1, characterCount / 4)
    }

    /// Sibling-split inputs for one admit decision: raw history tokens plus
    /// the context/generation budget and the image count (including the
    /// candidate). Struct (not a tuple) so attach-time params stay lint-clean.
    struct Budget {
        let promptTokens: Int
        let contextLength: Int
        let maxTokens: Int
        let imageCount: Int
    }

    /// Pixel width/height from image metadata without decoding the bitmap.
    /// Nil when the bytes are not a readable image.
    static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

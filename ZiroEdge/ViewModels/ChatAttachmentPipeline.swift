// ChatAttachmentPipeline.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Image-attachment ingestion for ChatViewModel: clipboard and photo-picker
// bytes are validated, capped, and downsampled entirely off the main actor
// via ImageIO so multi-megabyte photos never block the UI. Extracted from
// ChatViewModel.swift to keep the send/streaming core focused (no behavior
// change — the pipeline is byte-for-byte identical).

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ChatViewModel {
    // MARK: - Image Attachment

    /// Maximum image dimension (width or height) in pixels.
    nonisolated static let maxImageDimension: CGFloat = 1024
    /// Maximum raw image data size before forced downsample (10 MB).
    private nonisolated static let maxImageBytes = 10 * 1024 * 1024

    /// Outcome of attachment preprocessing (legacy validation semantics).
    enum AttachmentPreparation: Equatable {
        /// Final bytes to attach (downsampled JPEG or pass-through original).
        case ready(Data)
        /// Oversize payload that could not be read as an image.
        case unreadable
        /// Oversize payload that was readable but could not be re-encoded.
        case downsampleFailed
        /// Small payload over the pixel budget whose re-encode failed; dropped silently.
        case dropped
    }

    /// Result of running the attachment pipeline, including the executor it ran on.
    struct AttachmentPipelineOutput {
        let preparation: AttachmentPreparation
        /// True iff preprocessing executed on the main thread. Must always be false;
        /// exposed for tests and diagnostics.
        let ranOnMainThread: Bool
    }

    /// Add an image to the pending attachments. Validates size and downsamples if needed.
    /// Decoding/downsampling runs off the main actor via ImageIO, so multi-megabyte
    /// photos never freeze the UI.
    func addImage(_ data: Data) async {
        let output = await Self.prepareAttachment(data)
        switch output.preparation {
        case .ready(let bytes):
            pendingImages.append(bytes)
            visionWarning = nil
        case .unreadable:
            visionWarning = "Could not read image data."
        case .downsampleFailed:
            visionWarning = "Image is too large and could not be resized."
        case .dropped:
            break // Legacy behavior: silently drop.
        }
    }

    /// Decode, validate, and downsample attachment data using ImageIO.
    ///
    /// Nonisolated async functions execute on the cooperative thread pool, never on
    /// the main thread, so full-resolution bitmaps are never materialized for the UI.
    nonisolated static func prepareAttachment(_ data: Data) async -> AttachmentPipelineOutput {
        let startedOnMainThread = isExecutingOnMainThread

        // Read pixel bounds without decoding the bitmap.
        let dimensions = Self.pixelDimensions(of: data)
        let exceedsPixelBudget = dimensions.map {
            $0.width > Int(Self.maxImageDimension) || $0.height > Int(Self.maxImageDimension)
        } ?? false

        let preparation: AttachmentPreparation
        if !exceedsPixelBudget && data.count <= Self.maxImageBytes {
            // Small enough already: attach as-is (matches legacy pass-through,
            // including undecodable payloads, which report no dimensions).
            preparation = .ready(data)
        } else if let cgImage = Self.downsampledCGImage(from: data, maxPixelSize: Int(Self.maxImageDimension)),
                  let jpeg = Self.jpegData(from: cgImage, quality: 0.8) {
            preparation = .ready(jpeg)
        } else if data.count > Self.maxImageBytes {
            preparation = dimensions == nil ? .unreadable : .downsampleFailed
        } else {
            preparation = .dropped
        }

        return AttachmentPipelineOutput(preparation: preparation, ranOnMainThread: startedOnMainThread)
    }

    /// Synchronous accessor avoids the async-context availability warning on
    /// `Thread.isMainThread` while still reporting the actually-executing thread.
    private nonisolated static var isExecutingOnMainThread: Bool { Thread.isMainThread }

    /// Create a thumbnail bounded by `maxPixelSize` on the long edge, preserving
    /// aspect ratio and baking in EXIF orientation. Returns nil when undecodable.
    private nonisolated static func downsampledCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Read pixel width/height from image metadata without decoding the bitmap.
    private nonisolated static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Encode a CGImage as JPEG entirely in CoreGraphics (no UIKit round-trip).
    private nonisolated static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Remove an image at the specified index.
    func removeImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    /// Clear all pending images.
    func clearImages() {
        pendingImages.removeAll()
        visionWarning = nil
    }

    /// Attempt to paste an image from the clipboard.
    /// Returns true if an image was found and added.
    @discardableResult
    func pasteImage() async -> Bool {
        guard UIPasteboard.general.hasImages,
              let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            return false
        }
        await addImage(data)
        return true
    }

    /// Whether the currently selected model supports vision.
    var isVisionModel: Bool {
        selectedModel?.modelType == .vision
    }
}

// Batch23ImagePipelineTests.swift
// BATCH-23: attachment image pipeline (ImageIO downsample off the main thread)
//
// Verifies that attaching photos:
//  - downsamples oversized images to ≤ maxImageDimension on the long edge,
//  - produces valid JPEG output,
//  - never decodes/resizes on the main thread,
//  - preserves legacy validation semantics (pass-through, warnings, drops).

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZiroEdge

@MainActor
final class Batch23ImagePipelineTests: XCTestCase {

    // MARK: - Helpers

    /// Generate solid-color encoded image data of arbitrary pixel size via CGContext.
    private func makeSolidImageData(width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "Batch23", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create CGContext"])
        }
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Batch23", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not make CGImage"])
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "Batch23", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Batch23", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode image"])
        }
        return output as Data
    }

    private func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private func assertJPEG(_ data: Data, _ message: String) throws {
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8, 0xFF]), "\(message): missing JPEG SOI marker")
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil), "\(message): undecodable")
    }

    // MARK: - Downsample Pipeline

    /// A large 4000×3000 image must come out at most maxImageDimension on the long
    /// edge, aspect ratio preserved, as valid JPEG.
    func testLargeImageDownsamplesToMaxDimension() async throws {
        let input = try makeSolidImageData(width: 4000, height: 3000)
        XCTAssertEqual(pixelDimensions(of: input)?.width, 4000, "Fixture must be full-size")

        let output = await ChatViewModel.prepareAttachment(input)

        guard case let .ready(jpeg) = output.preparation else {
            return XCTFail("Expected .ready, got \(output.preparation)")
        }
        XCTAssertNotEqual(jpeg, input, "Oversize image must be re-encoded")
        try assertJPEG(jpeg, "Output should be valid JPEG")

        let dims = try XCTUnwrap(pixelDimensions(of: jpeg), "Output must decode")
        let maxSide = Int(ChatViewModel.maxImageDimension)
        XCTAssertLessThanOrEqual(max(dims.width, dims.height), maxSide)
        // 4000×3000 → 1024×768 (aspect preserved).
        XCTAssertEqual(dims.width, 1024)
        XCTAssertEqual(dims.height, 768)
    }

    /// The decode/downsample work must run off the main thread.
    func testPipelineRunsOffMainThread() async throws {
        let input = try makeSolidImageData(width: 2000, height: 1500)

        let output = await ChatViewModel.prepareAttachment(input)

        XCTAssertFalse(
            output.ranOnMainThread,
            "Image decoding/downsampling blocked the main thread"
        )
        guard case .ready = output.preparation else {
            return XCTFail("Expected .ready, got \(output.preparation)")
        }
    }

    /// Images already within budget pass through byte-for-byte (no recompression).
    func testSmallImagePassesThroughUnchanged() async throws {
        let input = try makeSolidImageData(width: 64, height: 48)

        let output = await ChatViewModel.prepareAttachment(input)

        guard case let .ready(bytes) = output.preparation else {
            return XCTFail("Expected .ready, got \(output.preparation)")
        }
        XCTAssertEqual(bytes, input, "In-budget images must not be re-encoded")
    }

    /// Undecodable small payloads pass through untouched (legacy semantics).
    func testUnreadableSmallDataPassesThrough() async {
        let junk = Data(repeating: 0x01, count: 512)

        let output = await ChatViewModel.prepareAttachment(junk)

        guard case let .ready(bytes) = output.preparation else {
            return XCTFail("Expected .ready, got \(output.preparation)")
        }
        XCTAssertEqual(bytes, junk)
    }

    /// Oversize undecodable payload reports .unreadable (drives legacy warning).
    func testUnreadableLargePayloadReportsUnreadable() async {
        let junk = Data(repeating: 0xAB, count: 11 * 1024 * 1024)

        let output = await ChatViewModel.prepareAttachment(junk)

        XCTAssertEqual(output.preparation, .unreadable)
    }

    // MARK: - ViewModel Integration

    private func makeViewModel() -> ChatViewModel {
        let persistence = PersistenceController(inMemory: true)
        let inferenceService = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycleManager = ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter
        )
        let sessionActor = ChatSessionActor(
            inferenceService: inferenceService,
            persistence: persistence
        )
        return ChatViewModel(
            persistence: persistence,
            inferenceService: inferenceService,
            sessionActor: sessionActor,
            lifecycleManager: lifecycleManager,
            downloadStatusProvider: MockDownloadStatusProvider()
        )
    }

    private final class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        func status(for model: AIModel) -> ModelDownloadStatus {
            ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
    }

    /// End-to-end: addImage appends downsampled JPEG and clears any warning.
    func testAddImageAppendsDownsampledOutput() async throws {
        let viewModel = makeViewModel()
        viewModel.visionWarning = "Stale warning"

        await viewModel.addImage(try makeSolidImageData(width: 4000, height: 3000))

        XCTAssertEqual(viewModel.pendingImages.count, 1)
        XCTAssertNil(viewModel.visionWarning)
        let dims = try XCTUnwrap(pixelDimensions(of: viewModel.pendingImages[0]))
        XCTAssertLessThanOrEqual(max(dims.width, dims.height), Int(ChatViewModel.maxImageDimension))
        try assertJPEG(viewModel.pendingImages[0], "Attached bytes should be JPEG")
    }
}

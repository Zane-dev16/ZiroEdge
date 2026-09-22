// Batch24VisionBudgetTests.swift
// BATCH-24: conservative vision gate (pre-decode context guard)
//
// The fitted census math (441 positions fits a 512 allowance) APPROVED a
// 1024px image that then SIGABRTd in eval on device, so
// positions-predict-safety is falsified. These tests pin the conservative
// replacement: every image is capped to `visionSafeMaxPixels` on the long
// edge (oversize downscales TO safe, never refused when downscalable),
// only an unfixable history refuses, and send re-gates and throws
// `contextWindowExceeded` instead of reaching eval. The engine
// `visionPrefixFits` preflight stays the final backstop.

import ImageIO
import SwiftLlama
import UniformTypeIdentifiers
import XCTest
@testable import ZiroEdge

@MainActor
final class Batch24VisionBudgetTests: XCTestCase {

    private let contextLength = 4096
    private let maxTokens = 2048

    private func target(
        _ width: Int, _ height: Int, promptTokens: Int = 0
    ) -> (width: Int, height: Int)? {
        LlamaEngine.visionTargetSize(
            imageWidth: width, imageHeight: height,
            promptTokens: promptTokens,
            contextLength: contextLength, maxTokens: maxTokens
        )
    }

    private func gate(
        _ width: Int, _ height: Int, promptTokens: Int = 0
    ) -> LlamaEngine.VisionGateResult {
        LlamaEngine.visionGate(
            imageWidth: width, imageHeight: height,
            promptTokens: promptTokens,
            contextLength: contextLength, maxTokens: maxTokens
        )
    }

    // MARK: - Conservative gate

    /// Safe constant: 512 (512px fixtures pass; 1024px aborts on device).
    func testSafeConstant() {
        XCTAssertEqual(LlamaEngine.visionSafeMaxPixels, 512)
    }

    /// Tiny images fit as-is: never upscale, return source.
    func testTinyImageFits() {
        XCTAssertEqual(gate(1, 1), .fits)
        XCTAssertEqual(target(1, 1)?.width, 1)
        XCTAssertEqual(target(1, 1)?.height, 1)
        XCTAssertEqual(gate(10, 10), .fits)
    }

    /// Safe-size image with empty history fits: target == source.
    func testSafeSizeFitsEmptyHistory() {
        XCTAssertEqual(gate(512, 512), .fits)
        let result = target(512, 512)
        XCTAssertEqual(result?.width, 512)
        XCTAssertEqual(result?.height, 512)
    }

    /// Oversize image downscales TO safe, never refused when downscalable.
    func testOversizeDownscalesToSafe() {
        XCTAssertEqual(gate(1024, 1024), .downscaledTo(width: 512, height: 512))
        let result = target(1024, 1024)
        XCTAssertEqual(result?.width, 512)
        XCTAssertEqual(result?.height, 512)
    }

    /// Panorama downscales aspect-preserved to the safe long edge.
    func testPanoramaDownscalesAspectPreserved() {
        XCTAssertEqual(gate(4000, 3000), .downscaledTo(width: 512, height: 384))
        let result = target(4000, 3000)
        XCTAssertEqual(result?.width, 512)
        XCTAssertEqual(result?.height, 384)
    }

    /// History that fills the window alone refuses (no downscale can fix it).
    func testHeavyHistoryRefused() {
        XCTAssertEqual(gate(1024, 1024, promptTokens: 3000), .refused(reason: .historyTooHeavy))
        XCTAssertNil(target(1024, 1024, promptTokens: 3000))
        // Even a safe-size image is refused under such history.
        XCTAssertEqual(gate(512, 512, promptTokens: 3000), .refused(reason: .historyTooHeavy))
    }

    /// Refusal boundary: remaining > 3 marker tokens fits, == 3 refuses
    /// (4096 - 1979 - 2048 - 1 - 64 = 4 fits; prompt 1980 leaves exactly 3).
    func testRefusalBoundary() {
        XCTAssertNotNil(target(1024, 1024, promptTokens: 1979))
        XCTAssertNil(target(1024, 1024, promptTokens: 1980))
    }

    /// Invalid dims refuse outright (nothing to downscale).
    func testInvalidDimensionsRefused() {
        XCTAssertEqual(gate(0, 0), .refused(reason: .invalidDimensions))
        XCTAssertNil(target(0, 0))
    }

    /// Gate output never exceeds the source dims.
    func testNeverUpscaleAcrossBudgets() {
        for prompt in stride(from: 0, through: 1000, by: 250) {
            guard let result = target(512, 512, promptTokens: prompt) else {
                return XCTFail("Unexpected nil at promptTokens=\(prompt)")
            }
            XCTAssertLessThanOrEqual(result.width, 512, "promptTokens=\(prompt)")
            XCTAssertLessThanOrEqual(result.height, 512, "promptTokens=\(prompt)")
            guard let small = target(64, 48, promptTokens: prompt) else {
                return XCTFail("Unexpected nil at promptTokens=\(prompt)")
            }
            XCTAssertEqual(small.width, 64, "promptTokens=\(prompt)")
            XCTAssertEqual(small.height, 48, "promptTokens=\(prompt)")
        }
    }

    /// Margin is a named constant (64), overridable per call in tests only.
    func testMarginConstant() {
        XCTAssertEqual(LlamaEngine.visionTokenMargin, 64)
    }

    /// Engine pre-decode backstop is intact (unchanged by the gate swap).
    func testBackstopIntact() {
        XCTAssertTrue(LlamaEngine.visionPrefixFits(chunkPositions: 100, contextLength: contextLength, maxTokens: maxTokens))
        XCTAssertFalse(LlamaEngine.visionPrefixFits(chunkPositions: 5000, contextLength: contextLength, maxTokens: maxTokens))
    }

    // MARK: - Send-time regression (throws pre-decode, never reaches eval)

    private func makeSolidImageData(width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "Batch24", code: 1, userInfo: nil)
        }
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Batch24", code: 2, userInfo: nil)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "Batch24", code: 3, userInfo: nil)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Batch24", code: 4, userInfo: nil)
        }
        return output as Data
    }

    private func userMessages(chars: Int) -> [(role: String, content: String)] {
        [(role: "user", content: String(repeating: "a", count: chars))]
    }

    /// Image with history grown heavy since attach must throw
    /// contextWindowExceeded instead of reaching eval/decode.
    func testSendBudgetThrowsOnHeavyHistory() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertThrowsError(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 3000 * 4),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens
        )) { error in
            guard case LlamaError.contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        }
    }

    /// Over-threshold image with light history still throws: attach already
    /// downscaled anything over-safe, so one here bypassed attach and must
    /// never reach eval (no path reaches eval with an over-threshold image).
    func testSendBudgetThrowsOnOverThresholdImage() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertThrowsError(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 100),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens
        )) { error in
            guard case LlamaError.contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        }
    }

    /// Probe bypass OFF (prod path) refuses over-threshold probes: pins the
    /// default so the flag cannot silently become the prod behavior.
    func testSendBudgetProbeBypassOffRefusesOverThreshold() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertThrowsError(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 100),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens,
            probeBypass: false
        )) { error in
            guard case LlamaError.contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        }
    }

    /// Probe bypass ON lets an over-threshold probe reach the engine
    /// eval-preflight (`visionPrefixFits` stays the backstop, where
    /// n_pos/peak/console logging happens) instead of refusing at the gate.
    func testSendBudgetProbeBypassOnPassesOverThreshold() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertNoThrow(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 100),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens,
            probeBypass: true
        ))
    }

    /// Probe bypass is size-only: unfixable history still refuses even with
    /// the flag, so measurement probes (empty chat) pass while heavy-history
    /// sends stay fail-closed.
    func testSendBudgetProbeBypassOnStillRefusesHeavyHistory() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertThrowsError(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 3000 * 4),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens,
            probeBypass: true
        )) { error in
            guard case LlamaError.contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        }
    }

    /// Runner parses `--vision-probe-bypass` like `--vision-force-cpu`.
    func testProbeBypassFlagParsing() {
        XCTAssertTrue(VisionBudgetRunner.isProbeBypass(arguments: ["--vision-probe-bypass"]))
        XCTAssertTrue(VisionBudgetRunner.isProbeBypass(arguments: ["--vision-threshold-size", "768", "--vision-probe-bypass"]))
        XCTAssertFalse(VisionBudgetRunner.isProbeBypass(arguments: []))
        XCTAssertFalse(VisionBudgetRunner.isProbeBypass(arguments: ["--vision-force-cpu"]))
    }

    /// Safe-size image with light history passes (the fits path is untouched).
    func testSendBudgetPassesSafeImageLightHistory() throws {
        let image = try makeSolidImageData(width: 512, height: 512)
        XCTAssertNoThrow(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 100),
            images: [image],
            contextLength: contextLength, maxTokens: maxTokens
        ))
    }

    /// Multi-image split: two images share the budget; heavy history throws.
    func testSendBudgetMultiImageHeavyHistoryThrows() throws {
        let image = try makeSolidImageData(width: 1024, height: 1024)
        XCTAssertThrowsError(try InferenceService.throwIfVisionExceedsBudget(
            messages: userMessages(chars: 3000 * 4),
            images: [image, image],
            contextLength: contextLength, maxTokens: maxTokens
        )) { error in
            guard case LlamaError.contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        }
    }

    // MARK: - Attach-time (downscale when possible, refuse only when unfixable)

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

    /// Attach with history too heavy to fix by downscaling: refused surfaces
    /// a choice (nothing attached, offer pending) — never the original.
    func testAddImageRefusesWhenOverBudget() async throws {
        let viewModel = makeViewModel()
        viewModel.inputText = String(repeating: "a", count: 8000)

        await viewModel.addImage(try makeSolidImageData(width: 1024, height: 1024))

        XCTAssertTrue(viewModel.pendingImages.isEmpty)
        let offer = try XCTUnwrap(viewModel.visionDownscaleOffer)
        XCTAssertLessThanOrEqual(max(offer.width, offer.height), LlamaEngine.visionSafeMaxPixels)
    }

    /// Tiny downscale result (panorama sliver) offers a choice instead of
    /// silently degrading: nothing attached until the user decides.
    func testAddImageTinyDownscaleOffersChoice() async throws {
        let viewModel = makeViewModel()

        await viewModel.addImage(try makeSolidImageData(width: 2000, height: 200))

        XCTAssertTrue(viewModel.pendingImages.isEmpty)
        let offer = try XCTUnwrap(viewModel.visionDownscaleOffer)
        XCTAssertLessThanOrEqual(max(offer.width, offer.height), LlamaEngine.visionSafeMaxPixels)
        XCTAssertLessThan(min(offer.width, offer.height), LlamaEngine.visionUsefulMinPixels)
    }

    /// Confirm attaches the safe downscale (stored dims <= safe) and clears
    /// the offer. Silent-path images stay silent (no offer).
    func testVisionChoiceConfirmAttachesSafeSize() async throws {
        let viewModel = makeViewModel()
        viewModel.inputText = String(repeating: "a", count: 8000)
        await viewModel.addImage(try makeSolidImageData(width: 1024, height: 1024))
        XCTAssertNotNil(viewModel.visionDownscaleOffer)

        await viewModel.confirmVisionDownscale()

        XCTAssertNil(viewModel.visionDownscaleOffer)
        XCTAssertEqual(viewModel.pendingImages.count, 1)
        let dims = ChatViewModel.pixelDimensions(of: try XCTUnwrap(viewModel.pendingImages.first))
        XCTAssertLessThanOrEqual(max(dims?.width ?? 0, dims?.height ?? 0), LlamaEngine.visionSafeMaxPixels)
    }

    /// Cancel attaches nothing and clears the offer.
    func testVisionChoiceCancelAttachesNothing() async throws {
        let viewModel = makeViewModel()
        viewModel.inputText = String(repeating: "a", count: 8000)
        await viewModel.addImage(try makeSolidImageData(width: 1024, height: 1024))
        XCTAssertNotNil(viewModel.visionDownscaleOffer)

        viewModel.cancelVisionDownscale()

        XCTAssertNil(viewModel.visionDownscaleOffer)
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
    }

    /// Silent floor: downscales at/above the useful minimum attach without
    /// asking (1024 square -> 512 square stays silent).
    func testUsefulMinConstant() {
        XCTAssertEqual(LlamaEngine.visionUsefulMinPixels, 256)
    }

    /// Safe-downscale helper: aspect-preserved fit to safe, never upscales.
    func testSafeDownscaleHelper() {
        let pano = LlamaEngine.visionSafeDownscale(imageWidth: 4000, imageHeight: 3000)
        XCTAssertEqual(pano.width, 512)
        XCTAssertEqual(pano.height, 384)
        let small = LlamaEngine.visionSafeDownscale(imageWidth: 100, imageHeight: 80)
        XCTAssertEqual(small.width, 100)
        XCTAssertEqual(small.height, 80)
    }

    /// Alert routing: consent > delete > vision choice; vision copy is plain
    /// and honest with exactly the two safe options (no proceed-with-original).
    func testChatQueueVisionChoice() {
        XCTAssertEqual(
            ZiroAlert.chatQueue(experimentalConsent: true, deleteConversation: false, visionChoiceModelName: "M"),
            .experimentalConsent
        )
        XCTAssertEqual(
            ZiroAlert.chatQueue(experimentalConsent: false, deleteConversation: true, visionChoiceModelName: "M"),
            .deleteConversation
        )
        XCTAssertEqual(
            ZiroAlert.chatQueue(experimentalConsent: false, deleteConversation: false, visionChoiceModelName: "Gemma E2B"),
            .visionDownscale(modelName: "Gemma E2B")
        )
        XCTAssertNil(ZiroAlert.chatQueue(experimentalConsent: false, deleteConversation: false))
        let alert = ZiroAlert.visionDownscale(modelName: "Gemma E2B")
        XCTAssertEqual(alert.title, "Photo Too Detailed")
        XCTAssertTrue(alert.message.contains("too detailed for Gemma E2B on this iPhone"))
        XCTAssertTrue(alert.message.contains("smaller version"))
        XCTAssertFalse(alert.message.lowercased().contains("original"))
    }

    /// Attach with empty history: 1024px image is downscaled TO safe and
    /// attaches with no warning (never refused outright when downscalable).
    func testAddImageDownscalesOversizeWhenFitting() async throws {
        let viewModel = makeViewModel()

        await viewModel.addImage(try makeSolidImageData(width: 1024, height: 1024))

        XCTAssertEqual(viewModel.pendingImages.count, 1)
        XCTAssertNil(viewModel.visionWarning)
        let dims = ChatViewModel.pixelDimensions(of: try XCTUnwrap(viewModel.pendingImages.first))
        XCTAssertLessThanOrEqual(max(dims?.width ?? 0, dims?.height ?? 0), LlamaEngine.visionSafeMaxPixels)
    }
}

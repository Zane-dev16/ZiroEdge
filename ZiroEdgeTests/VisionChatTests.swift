// VisionChatTests.swift
// ZiroEdgeTests
//
// Tests for vision chat features: image attachment, removal, paste,
// vision model gating, message composition with images, and graceful degradation.

import XCTest
@testable import ZiroEdge

@MainActor
final class VisionChatTests: XCTestCase {

    // MARK: - Test Helpers

    private class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        var readyModelIDs: Set<String> = []

        func status(for model: AIModel) -> ModelDownloadStatus {
            if readyModelIDs.contains(model.id) {
                return ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
            }
            return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
    }

    private func makeViewModel(
        provider: MockDownloadStatusProvider = MockDownloadStatusProvider()
    ) -> ChatViewModel {
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
            downloadStatusProvider: provider
        )
    }

    /// Create a small PNG image data for testing.
    private func makeImageData(byte: UInt8 = 0xFF) -> Data {
        // 1x1 red PNG
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return image.pngData() ?? Data(repeating: byte, count: 100)
    }

    // MARK: - Image Attachment Tests

    /// Adding an image appends to pendingImages.
    func testAddImageAppendsToPendingImages() throws {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.pendingImages.isEmpty)

        let data1 = makeImageData(byte: 0x01)
        viewModel.addImage(data1)

        XCTAssertEqual(viewModel.pendingImages.count, 1)
        XCTAssertEqual(viewModel.pendingImages.first, data1)
    }

    /// Adding multiple images accumulates.
    func testAddMultipleImages() throws {
        let viewModel = makeViewModel()
        let data1 = makeImageData(byte: 0x01)
        let data2 = makeImageData(byte: 0x02)
        let data3 = makeImageData(byte: 0x03)

        viewModel.addImage(data1)
        viewModel.addImage(data2)
        viewModel.addImage(data3)

        XCTAssertEqual(viewModel.pendingImages.count, 3)
    }

    /// Adding an image clears the vision warning.
    func testAddImageClearsVisionWarning() throws {
        let viewModel = makeViewModel()
        viewModel.visionWarning = "Some warning"

        viewModel.addImage(makeImageData())

        XCTAssertNil(viewModel.visionWarning)
    }

    // MARK: - Image Removal Tests

    /// Removing at valid index removes the correct image.
    func testRemoveImageAtIndex() throws {
        let viewModel = makeViewModel()
        let data1 = makeImageData(byte: 0x01)
        let data2 = makeImageData(byte: 0x02)
        viewModel.addImage(data1)
        viewModel.addImage(data2)

        viewModel.removeImage(at: 0)

        XCTAssertEqual(viewModel.pendingImages.count, 1)
        XCTAssertEqual(viewModel.pendingImages.first, data2)
    }

    /// Removing at out-of-bounds index is a no-op.
    func testRemoveImageOutOfBounds() throws {
        let viewModel = makeViewModel()
        viewModel.addImage(makeImageData())

        viewModel.removeImage(at: 5) // Should not crash

        XCTAssertEqual(viewModel.pendingImages.count, 1)
    }

    /// Removing last image leaves empty array.
    func testRemoveLastImage() throws {
        let viewModel = makeViewModel()
        viewModel.addImage(makeImageData())

        viewModel.removeImage(at: 0)

        XCTAssertTrue(viewModel.pendingImages.isEmpty)
    }

    // MARK: - Clear Images Tests

    /// clearImages removes all pending images.
    func testClearImagesRemovesAll() throws {
        let viewModel = makeViewModel()
        viewModel.addImage(makeImageData(byte: 0x01))
        viewModel.addImage(makeImageData(byte: 0x02))
        viewModel.addImage(makeImageData(byte: 0x03))

        viewModel.clearImages()

        XCTAssertTrue(viewModel.pendingImages.isEmpty)
    }

    /// clearImages also clears the vision warning.
    func testClearImagesClearsVisionWarning() throws {
        let viewModel = makeViewModel()
        viewModel.visionWarning = "Some warning"

        viewModel.clearImages()

        XCTAssertNil(viewModel.visionWarning)
    }

    // MARK: - Vision Model Detection Tests

    /// isVisionModel returns true for vision models.
    func testIsVisionModelTrueForVisionModel() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.gemma4_e2b.id]
        let viewModel = makeViewModel(provider: provider)

        viewModel.selectedModel = ModelRegistry.gemma4_e2b

        XCTAssertTrue(viewModel.isVisionModel)
    }

    /// isVisionModel returns false for text-only models.
    func testIsVisionModelFalseForTextModel() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.llama32_3B.id]
        let viewModel = makeViewModel(provider: provider)

        viewModel.selectedModel = ModelRegistry.llama32_3B

        XCTAssertFalse(viewModel.isVisionModel)
    }

    /// isVisionModel returns false when no model selected.
    func testIsVisionModelFalseWhenNoModel() throws {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.isVisionModel)
    }

    // MARK: - Graceful Degradation Tests

    /// Sending with images and text-only model sets vision warning.
    func testSendImagesWithTextModelSetsWarning() async throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.llama32_3B.id]
        let viewModel = makeViewModel(provider: provider)
        viewModel.selectedModel = ModelRegistry.llama32_3B
        viewModel.addImage(makeImageData())

        await viewModel.sendMessage()

        XCTAssertNotNil(viewModel.visionWarning)
        XCTAssertTrue(viewModel.visionWarning!.contains("text-only"))
        // Images should NOT be cleared (message was rejected).
        XCTAssertEqual(viewModel.pendingImages.count, 1)
    }

    /// Sending with no images and no text is a no-op (no warning).
    func testSendEmptyNoWarning() async throws {
        let viewModel = makeViewModel()

        await viewModel.sendMessage()

        XCTAssertNil(viewModel.visionWarning)
    }

    // MARK: - Message Composition Tests

    /// pendingImages starts empty.
    func testPendingImagesStartsEmpty() throws {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
    }

    /// visionWarning starts nil.
    func testVisionWarningStartsNil() throws {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.visionWarning)
    }

    /// pasteImage returns false when clipboard has no images.
    func testPasteImageReturnsFalseWhenClipboardEmpty() throws {
        let viewModel = makeViewModel()
        // Clear clipboard first.
        UIPasteboard.general.items = []

        let result = viewModel.pasteImage()

        XCTAssertFalse(result)
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")
    }
}

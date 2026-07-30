import XCTest
@testable import ZiroEdge

final class InferenceFailureTests: XCTestCase {
    func testMissingArtifactDescriptionDoesNotExposeSensitivePath() {
        let sensitivePath = "/private/var/mobile/Containers/Data/Application/secret/model.gguf"
        let error = InferenceError.modelFileNotFound(path: sensitivePath)

        XCTAssertFalse(error.localizedDescription.contains(sensitivePath))
        XCTAssertEqual(error.sanitizedDiagnostic, "model-artifact-missing")
    }

    func testGemmaPromptUsesDeterministicTurnsAndPlacesImagesInFirstUserTurn() {
        let prompt = InferenceService.formatGemmaPrompt(
            messages: [
                ChatMessagePayload(role: .user, content: "Describe it."),
                ChatMessagePayload(role: .assistant, content: "It is red."),
                ChatMessagePayload(role: .user, content: "One word?")
            ],
            systemPrompt: "Be concise.",
            imageMarkers: "<__media__>"
        )

        XCTAssertEqual(
            prompt,
            "<start_of_turn>user\nBe concise.\n<__media__>\nDescribe it.<end_of_turn>\n"
                + "<start_of_turn>model\nIt is red.<end_of_turn>\n"
                + "<start_of_turn>user\nOne word?<end_of_turn>\n"
                + "<start_of_turn>model\n"
        )
    }

    func testGemmaPromptCompactionDropsOldestCompleteExchangesAndPreservesShortHistory() async throws {
        let longHistory = [
            ChatMessagePayload(
                role: .user,
                content: "Old question " + String(repeating: "detail ", count: 30)
            ),
            ChatMessagePayload(
                role: .assistant,
                content: "Old answer " + String(repeating: "detail ", count: 30)
            ),
            ChatMessagePayload(role: .user, content: "Recent question."),
            ChatMessagePayload(role: .assistant, content: "Recent answer."),
            ChatMessagePayload(role: .user, content: "Newest prompt must survive.")
        ]
        let shortHistory = Array(longHistory.suffix(3))
        let tokenCount: (String) async throws -> Int = { $0.utf8.count }
        let shortPrompt = InferenceService.formatGemmaPrompt(
            messages: shortHistory,
            systemPrompt: nil
        )

        let compacted = try await InferenceService.compactGemmaPrompt(
            messages: longHistory,
            systemPrompt: nil,
            maximumPromptTokens: 512 - 64,
            tokenCount: tokenCount
        )
        let unchanged = try await InferenceService.compactGemmaPrompt(
            messages: shortHistory,
            systemPrompt: nil,
            maximumPromptTokens: 512 - 64,
            tokenCount: tokenCount
        )

        XCTAssertEqual(compacted, shortPrompt)
        XCTAssertEqual(unchanged, shortPrompt)
        XCTAssertFalse(compacted.contains("Old question"))
        XCTAssertFalse(compacted.contains("Old answer"))
        XCTAssertTrue(compacted.contains("Newest prompt must survive."))
        XCTAssertLessThanOrEqual(compacted.utf8.count + 64, 512)
        XCTAssertTrue(compacted.hasSuffix("<start_of_turn>model\n"))
        XCTAssertEqual(
            compacted.components(separatedBy: "<start_of_turn>").count - 1,
            compacted.components(separatedBy: "<end_of_turn>").count
        )
    }

    func testNativeFailuresRetainDistinctSanitizedCategories() {
        let categories: [NativeFailureKind] = [
            .modelMapping,
            .contextCreation,
            .projectorInitialization,
            .inference,
            .memoryPressure,
            .suspectedJetsam
        ]

        XCTAssertEqual(Set(categories.map(\.rawValue)).count, 6)
        for category in categories {
            let error = InferenceError.nativeFailure(kind: category, diagnostic: "native-code-1")
            XCTAssertTrue(error.sanitizedDiagnostic.contains("native-code-1"))
            XCTAssertFalse(error.localizedDescription.contains("native-code-1"))
        }
    }
}

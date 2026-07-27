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

import XCTest
@testable import ZiroEdge
import SwiftLlama

final class InferenceFailureTests: XCTestCase {
    func testMissingArtifactDescriptionDoesNotExposeSensitivePath() {
        let sensitivePath = "/private/var/mobile/Containers/Data/Application/secret/model.gguf"
        let error = InferenceError.modelFileNotFound(path: sensitivePath)

        XCTAssertFalse(error.localizedDescription.contains(sensitivePath))
        XCTAssertEqual(error.sanitizedDiagnostic, "model-artifact-missing")
    }

    func testLegacyPromptPathsDecodeToTheEmbeddedTemplateRoute() throws {
        // Conversations and imported records persisted `.gemma` / `.raw` before
        // the hand formatters were removed. Decoding must migrate them, not fail.
        for legacy in ["gemma", "raw", "chatTemplate"] {
            let decoded = try JSONDecoder().decode(
                PromptPath.self,
                from: Data("\"\(legacy)\"".utf8)
            )
            XCTAssertEqual(decoded, .chatTemplate, "legacy value \(legacy)")
        }
    }

    func testGemmaPresetRoutesThroughTheEmbeddedTemplate() {
        // Gemma keeps BOS and its end-of-turn stop string; only the hand-built
        // turn renderer is gone. The runtime's template emits the same turns.
        XCTAssertEqual(ModelConfiguration.gemma4.promptPath, .chatTemplate)
        XCTAssertEqual(ModelConfiguration.gemma4.addBos, true)
        XCTAssertEqual(ModelConfiguration.gemma4.stopStrings, ["<end_of_turn>"])
    }

    func testGemmaDeclaresTheBuiltInTemplateBecauseItsGGUFCarriesNone() throws {
        // The Gemma 4 E2B GGUF has no `tokenizer.chat_template`. The catalog row
        // declares the runtime's built-in `gemma` template instead; the runtime
        // still renders every turn. Other rows keep the embedded template.
        let gemma = try XCTUnwrap(ModelRegistry.model(for: "gemma-4-e2b-q4"))
        XCTAssertEqual(gemma.chatTemplateName, "gemma")
        XCTAssertEqual(gemma.textOnlyRuntimeVariant.chatTemplateName, "gemma")
        for model in ModelRegistry.allModels where model.id != gemma.id {
            XCTAssertNil(model.chatTemplateName, model.id)
        }
        let config = LlamaConfigSwift(modelPath: "/tmp/model.gguf", chatTemplateName: "gemma")
        XCTAssertEqual(config.cpuFallback.chatTemplateName, "gemma")
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

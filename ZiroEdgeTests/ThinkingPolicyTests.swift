// ThinkingPolicyTests.swift
// ZiroEdgeTests
//
// The thinking switch and the reasoning split are runtime capabilities, so the
// parts that can be proven without native construction are proven here: the
// policy's own contract, the catalogue's declared state, stop merging, and the
// load-time refusal.

import XCTest
@testable import ZiroEdge
@testable import SwiftLlama
// The native sentinel lives in the runtime header; assert against it directly so
// a mismatch fails here instead of turning into reasoning nobody asked for.
import llama

final class ThinkingPolicyTests: XCTestCase {

    // MARK: - Policy contract

    func testOnlyDefaultPolicySkipsTemplateSupport() {
        XCTAssertFalse(ChatThinkingPolicy.templateDefault.requiresTemplateSupport)
        XCTAssertTrue(ChatThinkingPolicy.disabled.requiresTemplateSupport)
        XCTAssertTrue(ChatThinkingPolicy.enabled.requiresTemplateSupport)
    }

    func testNativeTriStateMatchesTheHeaderContract() {
        // -1 is the header's "leave the template default alone" sentinel; the
        // explicit policies must be 0 and 1 so a mix-up cannot silently enable
        // reasoning a row asked to suppress.
        XCTAssertEqual(ChatThinkingPolicy.templateDefault.nativeValue, ZIRO_CHAT_THINKING_DEFAULT)
        XCTAssertEqual(ChatThinkingPolicy.disabled.nativeValue, 0)
        XCTAssertEqual(ChatThinkingPolicy.enabled.nativeValue, 1)
    }

    func testPolicyRoundTripsThroughItsRawValue() {
        for policy in ChatThinkingPolicy.allCases {
            XCTAssertEqual(ChatThinkingPolicy(rawValue: policy.rawValue), policy)
        }
    }

    // MARK: - Catalogue declaration

    func testEveryCatalogRowDeclaresItsThinkingPolicyExplicitly() {
        // A row that reasons and cannot be switched is a blocked row. The shipped
        // catalogue has no blocked rows, so every row must resolve to a policy
        // rather than relying on a nil/absent value.
        for model in ModelRegistry.allModels {
            XCTAssertTrue(
                ChatThinkingPolicy.allCases.contains(model.thinking),
                "\(model.id) has no declared thinking policy"
            )
        }
    }

    func testThinkingPolicySurvivesTheTextOnlyRuntimeVariant() {
        let model = ModelRegistry.allModels.first { $0.thinking != .templateDefault }
            ?? ModelRegistry.allModels[0]
        let variant = model.textOnlyRuntimeVariant
        XCTAssertEqual(variant.thinking, model.thinking)
    }

    // MARK: - Stops

    func testTemplateStopsAreAddedWithoutDuplicatingCallerStops() {
        let merged = LlamaEngine.merging(["<|im_end|>"], with: ["<|im_end|>", "<|end|>", ""])
        XCTAssertEqual(merged, ["<|im_end|>", "<|end|>"])
    }

    func testCallerStopsSurviveAnEmptyTemplateList() {
        XCTAssertEqual(LlamaEngine.merging(["A", "B"], with: []), ["A", "B"])
    }

    func testMergingKeepsCallerOrderFirst() {
        // Which stop matches first is a behaviour difference, so the order the
        // caller declared must not be reshuffled by the template's list.
        let merged = LlamaEngine.merging(["first", "second"], with: ["third"])
        XCTAssertEqual(merged.prefix(2), ["first", "second"])
        XCTAssertEqual(merged.last, "third")
    }

    // MARK: - Gate

    func testGateDiagnosticsAreDistinct() {
        // The lifecycle copy keys on these strings; two refusals that read the
        // same would give the user the wrong sentence.
        XCTAssertEqual(InferenceService.diagnostic(for: .missing), "chat-template-missing")
        XCTAssertEqual(
            InferenceService.diagnostic(for: .thinkingUnsupported),
            "chat-template-thinking-unsupported"
        )
        XCTAssertEqual(InferenceService.diagnostic(for: .ready), "chat-template-ready")
    }

    func testThinkingRefusalCopyNamesTheThinkingStepNotTheFile() {
        let copy = ModelLoadCopy.reasoningCannotBeDisabled(modelName: "Bonsai 8B")
        XCTAssertTrue(copy.contains("Bonsai 8B"), copy)
        XCTAssertTrue(copy.lowercased().contains("thinking"), copy)
        // The generic format refusal would send the user looking for a corrupt
        // file, which is the wrong action for a model that simply reasons.
        XCTAssertFalse(copy.contains("format"), copy)
    }
}

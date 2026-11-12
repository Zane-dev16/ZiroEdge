// ModelStatusCopyTests.swift
// ZiroEdge — Privacy-first local AI assistant
//
// The wording fence. Every sentence this file covers is one a user reads cold,
// usually at the worst moment: a model did not start, or its files are broken.
// The previous copy in exactly these places read:
//
//   "No safe runtime-memory evidence exists for this configuration yet. You can
//    download it now, but ZiroEdge will not load it until calibration provides
//    evidence."
//
// and
//
//   "This model needs repair. Downloading again will replace damaged files."
//
// Both were true and both were useless: they name machinery the user cannot see
// or act on. These tests fail the build if that vocabulary comes back, so the
// plain surface cannot silently rot when someone adds a new failure.

import XCTest
@testable import ZiroEdge

final class ModelStatusCopyTests: XCTestCase {

    private let modelName = "LFM 2.5 1.2B"

    /// Every sentence a refused load can produce.
    private func allLoadSentences() -> [String] {
        [
            ModelLoadCopy.storageIncomplete(modelName: modelName),
            ModelLoadCopy.damagedFiles(modelName: modelName),
            ModelLoadCopy.missingModelFile(modelName: modelName),
            ModelLoadCopy.missingImageFile(modelName: modelName),
            ModelLoadCopy.notEnoughMemory(
                modelName: modelName, requiredBytes: 2_000_000_000, availableBytes: 1_500_000_000
            ),
            ModelLoadCopy.notEnoughMemory(
                modelName: modelName, requiredBytes: 2_000_000_000, availableBytes: 0
            ),
            ModelLoadCopy.notEnoughMemory(modelName: modelName, requiredBytes: nil, availableBytes: 900_000_000),
            ModelLoadCopy.tooLargeForDevice(modelName: modelName),
            ModelLoadCopy.moreThanThisAppCanUse(
                modelName: modelName, requiredBytes: 4_550_000_000, limitBytes: 3_540_000_000
            ),
            ModelLoadCopy.moreThanThisAppCanUse(
                modelName: modelName, requiredBytes: nil, limitBytes: 3_540_000_000
            ),
            ModelLoadCopy.cannotRunHereFlag(modelName: modelName),
            ModelLoadCopy.memoryCheckUnavailable(modelName: modelName),
            ModelLoadCopy.wouldStarveDevice(modelName: modelName),
            ModelLoadCopy.interruptedBySystem(),
            ModelLoadCopy.pausedAfterRepeatedStops(modelName: modelName),
            ModelLoadCopy.experimentalConsentRequired(modelName: modelName),
            ModelLoadCopy.engineCouldNotStart(modelName: modelName),
            ModelLoadCopy.unreadableModelFile(modelName: modelName),
            ModelLoadCopy.couldNotReserveWorkingMemory(modelName: modelName),
            ModelLoadCopy.couldNotStartImageSupport(modelName: modelName),
            ModelLoadCopy.modelNoLongerAvailable(),
            ModelLoadCopy.genericFailure(modelName: modelName),
            ModelLoadCopy.unloadFirst(priorName: "Gemma 4 E2B", modelName: modelName),
        ]
    }

    /// Every sentence a runtime-eligibility surface can produce.
    private func allEligibilitySentences() -> [String] {
        let cases: [RuntimeEligibility] = [.validated, .estimated, .experimental, .unavailable]
        return cases.map { RuntimeEligibilityCopy.detail(for: $0) }
            + cases.map { RuntimeEligibilityCopy.label(for: $0) }
            + [RuntimeEligibilityCopy.refusedLabel]
    }

    /// Every sentence the damaged-download surface can produce.
    private func allDownloadSentences() -> [String] {
        [
            ArtifactIntegrityPresentation.needsRedownloadSubtitle,
            ArtifactIntegrityPresentation.needsRedownloadSpoken,
            ArtifactIntegrityPresentation.damagedBannerMessage,
            ArtifactIntegrityPresentation.message(for: .sha256Mismatch),
            ArtifactIntegrityPresentation.message(for: .sizeMismatch),
            ArtifactIntegrityPresentation.message(for: .missingGGUFHeader),
            ArtifactIntegrityPresentation.message(for: .fileNotFound),
            ArtifactIntegrityPresentation.message(for: .missing(artifact: .base)),
            ArtifactIntegrityPresentation.message(for: .missing(artifact: .mmproj)),
            ArtifactIntegrityPresentation.message(for: .unknown("")),
        ]
    }

    // MARK: - The vocabulary fence

    func testNoLoadSentenceUsesInternalVocabulary() {
        for sentence in allLoadSentences() {
            XCTAssertTrue(
                ModelCopyPolicy.violations(in: sentence).isEmpty,
                "internal vocabulary \(ModelCopyPolicy.violations(in: sentence)) in: \(sentence)"
            )
        }
    }

    func testNoEligibilitySentenceUsesInternalVocabulary() {
        for sentence in allEligibilitySentences() {
            XCTAssertTrue(
                ModelCopyPolicy.violations(in: sentence).isEmpty,
                "internal vocabulary \(ModelCopyPolicy.violations(in: sentence)) in: \(sentence)"
            )
        }
    }

    func testNoDownloadSentenceUsesInternalVocabulary() {
        for sentence in allDownloadSentences() {
            XCTAssertTrue(
                ModelCopyPolicy.violations(in: sentence).isEmpty,
                "internal vocabulary \(ModelCopyPolicy.violations(in: sentence)) in: \(sentence)"
            )
        }
    }

    // MARK: - The word that must never ship

    func testRepairNeverAppearsInUserCopy() {
        let everySurface = allLoadSentences() + allEligibilitySentences() + allDownloadSentences()
        for sentence in everySurface {
            XCTAssertFalse(
                sentence.lowercased().contains("repair"),
                "\"repair\" names a maintenance operation the user cannot perform: \(sentence)"
            )
        }
    }

    // MARK: - Actionability

    func testEveryLoadSentenceNamesTheModel() {
        // Except the system-interruption and no-model sentences, which are
        // about the app's state rather than a specific model.
        let named = allLoadSentences().filter {
            $0 != ModelLoadCopy.interruptedBySystem() && $0 != ModelLoadCopy.modelNoLongerAvailable()
        }
        for sentence in named {
            XCTAssertTrue(sentence.contains(modelName), "sentence must name the model: \(sentence)")
        }
    }

    func testHeadroomSentenceCarriesNumbersAndARemedy() {
        let sentence = ModelLoadCopy.notEnoughMemory(
            modelName: modelName, requiredBytes: 2_400_000_000, availableBytes: 1_800_000_000
        )
        // Format through the same formatter the copy uses: `.memory` counts
        // binary gigabytes, so 2_400_000_000 B renders as 2.24 GB.
        XCTAssertTrue(
            sentence.contains(ModelLoadCopy.byteLabel(2_400_000_000)), sentence
        )
        XCTAssertTrue(
            sentence.contains(ModelLoadCopy.byteLabel(1_800_000_000)), sentence
        )
        XCTAssertTrue(sentence.contains("Close other apps"), sentence)
    }

    func testZeroHeadroomSampleNeverPrintsZeroBytes() {
        // A zero sample means the read failed or the device is mid-pressure.
        // "needs more than the 0 bytes available" reads as a broken app.
        let sentence = ModelLoadCopy.notEnoughMemory(
            modelName: modelName, requiredBytes: 2_000_000_000, availableBytes: 0
        )
        XCTAssertFalse(sentence.contains("0 bytes"), sentence)
        XCTAssertFalse(sentence.contains(" 0 B"), sentence)
    }

    func testSentencesAreDistinctPerCause() {
        // Three unrelated faults that all read "couldn't start" give the user
        // nothing to act on.
        let distinct = [
            ModelLoadCopy.couldNotReserveWorkingMemory(modelName: modelName),
            ModelLoadCopy.couldNotStartImageSupport(modelName: modelName),
            ModelLoadCopy.unreadableModelFile(modelName: modelName),
            ModelLoadCopy.memoryCheckUnavailable(modelName: modelName),
            ModelLoadCopy.tooLargeForDevice(modelName: modelName),
            ModelLoadCopy.moreThanThisAppCanUse(
                modelName: modelName, requiredBytes: 4_550_000_000, limitBytes: 3_540_000_000
            ),
        ]
        XCTAssertEqual(Set(distinct).count, distinct.count, "each cause needs its own sentence")
    }

    // MARK: - The policy itself

    func testPolicyCatchesTheShippedJargon() {
        // The exact sentence from the shipped alert must trip the fence.
        let shipped = "No safe runtime-memory evidence exists for this configuration yet. "
            + "You can download it now, but ZiroEdge will not load it until calibration provides evidence."
        let violations = ModelCopyPolicy.violations(in: shipped)
        XCTAssertTrue(violations.contains("calibration"), "the fence must catch calibration")
        XCTAssertTrue(violations.contains("evidence"), "the fence must catch evidence")
        XCTAssertTrue(
            ModelCopyPolicy.violations(in: "Close other apps and try again.").isEmpty,
            "the fence must not flag ordinary English"
        )
    }
}

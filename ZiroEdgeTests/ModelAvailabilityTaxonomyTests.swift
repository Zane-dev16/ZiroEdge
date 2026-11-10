// ModelAvailabilityTaxonomyTests.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Locks in the two defects that shipped together and read to a user as a
// broken app:
//
// 1. `ModelManagerService.availability` reported `.repairNeeded` for a model
//    with no files at all, so a fresh install painted an orange "Repair" chip
//    on every catalog row for files the user had never downloaded. Absence is
//    not damage: `.notDownloaded` now exists to say so.
//
// 2. Nine of ten catalog rows resolved `RuntimeEligibility.unavailable` —
//    either no memory profile at all (the six lineup models) or a profile with
//    no measurement that could never admit. Every load attempt was refused
//    with a sentence about calibration. `.estimated` is the tier that makes a
//    shipped model loadable without a DEBUG calibration run.
//
// Each test below fails against the old behavior.

import XCTest
@testable import ZiroEdge

final class ModelAvailabilityTaxonomyTests: XCTestCase {

    // MARK: - Absence is not damage

    func testNeverDownloadedCatalogRowReadsAsNotDownloaded() {
        // A real catalog row, never downloaded: nothing on disk.
        for model in ModelRegistry.allModels where model.id != ModelRegistry.gemma4_e2b.id {
            let availability = ModelManagerService.availability(for: model)
            guard case .notDownloaded = availability else {
                // A developer machine may genuinely hold a verified install;
                // `.ready` is then correct. Anything else is the bug.
                if case .ready = availability { continue }
                return XCTFail("\(model.id) must read as not downloaded, got \(availability)")
            }
        }
    }

    @MainActor
    func testNeverDownloadedRowNeverAsksToDownloadAgain() {
        // The row's visible chip is driven by `needsRedownload`; false here is
        // the difference between a calm catalog and every row reading "Repair"
        // on first launch.
        let model = ModelRegistry.llama32_3B
        let status = DownloadManager().status(for: model)
        XCTAssertFalse(
            status.needsRedownload(for: model),
            "a model that was never downloaded must not present as damaged"
        )
    }

    @MainActor
    func testDamagedFilesAskToDownloadAgain() throws {
        let data = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(id: "damaged-\(UUID().uuidString.lowercased())", data: data)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(data, for: model)

        // Same size, different bytes: passes a size probe, fails the digest.
        try TestModelFixtures.install(TestModelFixtures.gguf(fill: 0x5A, count: 128), for: model)

        guard case .damaged = ModelManagerService.availability(for: model) else {
            return XCTFail("corrupt bytes with the right length must classify as damaged")
        }
        XCTAssertTrue(DownloadManager().status(for: model).needsRedownload(for: model))
    }

    func testMissingCatalogMetadataIsAConfigurationErrorNotDamage() {
        // A catalog row whose integrity metadata is absent cannot be judged at
        // all; saying "damaged" would accuse the user's files of a fault that
        // lives in the catalog.
        let invalid = AIModel(
            id: "bad-metadata-\(UUID().uuidString.lowercased())",
            displayName: "Bad Metadata",
            description: "Fixture",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 128,
            mmprojFileSizeBytes: nil,
            baseSHA256: "",  // missing
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(
                name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test"
            )
        )
        guard case .configurationError = ModelManagerService.availability(for: invalid) else {
            return XCTFail("missing catalog metadata must be a configuration error")
        }
    }

    // MARK: - The catalog/runtime fence

    func testEveryShippedModelResolvesALoadableRuntimeShape() {
        for model in ModelRegistry.allModels {
            let profile = MemoryProfileRegistry.profile(for: model)
            XCTAssertNotNil(profile, "\(model.id) must resolve a runtime shape")
            XCTAssertNotEqual(
                model.runtimeEligibility, .unavailable,
                "\(model.id) is listed in the catalog, so ZiroEdge must be able to load it"
            )
        }
    }

    func testCatalogValidatorRefusesARowWithNoRuntimeShape() {
        // The fence itself. A catalog row the runtime cannot size is the exact
        // shape of the shipped bug, so `catalogFailureReason` must reject it
        // before it can ever reach a user.
        let orphan = AIModel(
            id: "no-runtime-shape",
            displayName: "Orphan",
            description: "Fixture",
            modelType: .text,
            baseURL: URL(string: "https://example.com/orphan.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 128,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(
                name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test"
            )
        )
        XCTAssertNil(ModelCatalogValidator.failureReason(for: orphan), "a single row is fine on its own")
        let catalogReason = ModelCatalogValidator.catalogFailureReason(
            models: ModelRegistry.allModels + [orphan]
        )
        XCTAssertNotNil(catalogReason, "the catalog must refuse a row with no runtime shape")
        XCTAssertTrue(catalogReason?.contains("Orphan") == true, catalogReason ?? "nil")
    }

    func testCuratedShapeIDsAreUniqueAcrossTheWholeRegistry() {
        // Profile id keys experimental consent AND load-safety history: a
        // duplicate would let one shape inherit another's disabled state.
        // Asserted over the registry itself, not over served shapes — serving
        // the same validated shape for both GPU preferences is intended.
        var seen = Set<String>()
        for shape in MemoryProfileRegistry.all {
            XCTAssertTrue(
                seen.insert(shape.id).inserted,
                "duplicate shape id \(shape.id) — consent and load-safety state would collide"
            )
        }
        // And every shipped model still resolves a shape for either preference.
        for model in ModelRegistry.allModels {
            for usesGPU in [false, true] {
                XCTAssertNotNil(
                    MemoryProfileRegistry.profile(for: model.id, usesGPU: usesGPU),
                    "\(model.id) missing a shape (usesGPU: \(usesGPU))"
                )
            }
        }
    }

    // MARK: - The estimate tier admits

    func testEstimatedShapeProceedsWithHeadroom() async throws {
        let model = ModelRegistry.llama32_3B   // estimated, no measurement
        XCTAssertEqual(model.runtimeEligibility, .estimated)
        let profile = try XCTUnwrap(MemoryProfileRegistry.profile(for: model))
        let required = try profile.estimatedRequiredProcessHeadroomBytes()

        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: required, total: profile.minimumPhysicalRAMBytes
        )).decision(for: model)

        XCTAssertEqual(decision.recommendation, .proceed)
        XCTAssertNil(decision.reason)
        XCTAssertEqual(decision.requiredBytes, required)
    }

    func testEstimatedShapeRefusesWhenTheDeviceIsShort() async throws {
        let model = try XCTUnwrap(ModelRegistry.model(for: "bonsai-4b-q1"))
        let profile = try XCTUnwrap(MemoryProfileRegistry.profile(for: model))
        let required = try profile.estimatedRequiredProcessHeadroomBytes()

        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: required - 100_000_000,
            total: profile.minimumPhysicalRAMBytes
        )).decision(for: model)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .insufficientProcessHeadroom)
        XCTAssertEqual(decision.requiredBytes, required)
        // The sentence names a real number and a real remedy.
        let message = decision.alertMessage(modelName: model.displayName)
        XCTAssertTrue(message.contains("free memory"), message)
        XCTAssertTrue(ModelCopyPolicy.violations(in: message).isEmpty, message)
    }

    func testEstimatedShapeRefusesBelowItsPhysicalFloor() async throws {
        // Hardware, not transient pressure: nothing else running would help.
        let model = ModelRegistry.llama32_3B
        let profile = try XCTUnwrap(MemoryProfileRegistry.profile(for: model))
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 16_000_000_000,
            total: profile.minimumPhysicalRAMBytes - 1
        )).decision(for: model)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .physicalRAMBelowMinimum)
        XCTAssertFalse(decision.alertMessage(modelName: "M").contains("Close other apps"))
    }

    // MARK: - Estimation never overrides evidence

    func testValidatedShapeKeepsItsMeasuredFloor() throws {
        let profile = try XCTUnwrap(MemoryProfileRegistry.profile(
            for: ModelRegistry.gemma4_e2b.id, usesGPU: false
        ))
        XCTAssertEqual(profile.runtimeEligibility, .validated)
        XCTAssertNotNil(profile.measuredFullWorkloadPeakDeltaBytes)
        // A validated profile may never fall back to the estimate path.
        XCTAssertThrowsError(try profile.estimatedRequiredProcessHeadroomBytes())
    }

    func testCalibrationIdentityCarriesNoEstimate() throws {
        // It exists to gather the first measurement; an estimate would make the
        // measurement run pointless and re-open the artifact-size loophole the
        // admission policy closed.
        let profile = MemoryProfileRegistry.e4bTextCalibration
        XCTAssertNil(profile.estimatedLoadDeltaBytes)
        XCTAssertNil(profile.measuredLoadDeltaBytes)
        XCTAssertNil(try? profile.estimatedRequiredProcessHeadroomBytes())
    }
}

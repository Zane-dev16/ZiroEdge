// ModelMigrationTests.swift
// ZiroEdgeTests
//
// Regression coverage for the versioned legacy-to-managed model migration.

import XCTest
import CryptoKit
@testable import ZiroEdge

final class ModelMigrationTests: XCTestCase {

    private struct MigrationFixture {
        let model: AIModel
        let base: Data
        let projector: Data?
    }

    private var model: AIModel?
    private var cleanupURLs: [URL] = []
    private var storageRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZiroEdge-ModelMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storageRoot = root
        ModelManagerService.storageRootOverride = root
        ModelMigrationService.resetForTesting()
    }

    override func tearDownWithError() throws {
        if let model {
            ModelManagerService.deleteModel(model)
        }
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        ModelMigrationService.resetForTesting()
        if let storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
        storageRoot = nil
        ModelManagerService.storageRootOverride = nil
        try super.tearDownWithError()
    }

    func testValidLegacyPairMovesIntoManagedInstalledLibrary() throws {
        let fixture = makeVisionModel()
        let model = fixture.model
        let base = fixture.base
        let projector = try XCTUnwrap(fixture.projector)
        prepare(model)

        let baseSource = legacyURL(for: model, artifact: .base)
        let projectorSource = legacyURL(for: model, artifact: .mmproj)
        try installLegacyAlias()
        try write(base, to: baseSource)
        try write(projector, to: projectorSource)
        try assertSweepObservesAlias(
            planURLs: [baseSource, projectorSource],
            expectedBytes: [base, projector]
        )

        let result = ModelMigrationService.migrateIfNeeded(models: [model])

        XCTAssertEqual(result, .migrated(entryCount: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectorSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelManagerService.mmprojModelPath(for: model).path))
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        XCTAssertEqual(ModelMigrationService.migrateIfNeeded(models: [model]), .alreadyCurrent)
    }

    func testMixedValidityPairInstallsOnlyValidArtifactAndMarksRepair() throws {
        let fixture = makeVisionModel()
        let model = fixture.model
        let base = fixture.base
        prepare(model)

        let baseSource = legacyURL(for: model, artifact: .base)
        let projectorSource = legacyURL(for: model, artifact: .mmproj)
        let invalidProjector = gguf(fill: 0xCC)
        try installLegacyAlias()
        try write(base, to: baseSource)
        try write(invalidProjector, to: projectorSource)
        try assertSweepObservesAlias(
            planURLs: [baseSource, projectorSource],
            expectedBytes: [base, invalidProjector]
        )

        let result = ModelMigrationService.migrateIfNeeded(models: [model])

        XCTAssertEqual(result, .migrated(entryCount: 2))
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        guard case .repairNeeded(let issues) = ModelManagerService.availability(for: model) else {
            return XCTFail("A mixed-validity pair must remain repairable")
        }
        XCTAssertTrue(issues.contains { issue in
            if case .missing(artifact: .mmproj) = issue { return true }
            return false
        })
        XCTAssertTrue(quarantineContains(modelID: model.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectorSource.path))
    }

    func testResumeOnlyLegacyStateMovesToResumeLocation() throws {
        let model = makeTextModel()
        prepare(model)

        let source = ModelManagerService.legacyModelsDirectory
            .appendingPathComponent("resume-\(model.id)-base.dat")
        try write(Data("opaque resume data".utf8), to: source)

        let result = ModelMigrationService.migrateIfNeeded(models: [model])

        XCTAssertEqual(result, .migrated(entryCount: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(directoryContains(ModelManagerService.resumeDirectory, named: source.lastPathComponent))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
    }

    func testOrphanedStagingDataMovesToManagedStagingLocation() throws {
        let model = makeTextModel()
        prepare(model)

        let legacyStaging = ModelManagerService.legacyModelsDirectory
            .appendingPathComponent("staging", isDirectory: true)
        let source = legacyStaging.appendingPathComponent("\(model.id).part")
        try write(Data("partial bytes".utf8), to: source)

        let result = ModelMigrationService.migrateIfNeeded(models: [model])

        XCTAssertEqual(result, .migrated(entryCount: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(directoryContains(ModelManagerService.stagingDirectory, named: "staging-\(model.id).part"))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
    }

    func testAbsentLegacyStorageCreatesCurrentMarkerAndIsIdempotent() throws {
        let model = makeTextModel()
        prepare(model)

        let legacyRoot = ModelManagerService.legacyModelsDirectory
        if FileManager.default.fileExists(atPath: legacyRoot.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: legacyRoot.path)
            guard contents.isEmpty else {
                throw XCTSkip("Legacy storage contains unrelated files")
            }
            try FileManager.default.removeItem(at: legacyRoot)
        }

        XCTAssertEqual(ModelMigrationService.migrateIfNeeded(models: [model]), .migrated(entryCount: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelMigrationService.migrationVersionMarkerURL.path))
        XCTAssertEqual(ModelMigrationService.migrateIfNeeded(models: [model]), .alreadyCurrent)
    }

    func testInterruptedMigrationRecoversAfterPriorMoveCompleted() throws {
        let fixture = makeTextModelWithData()
        let model = fixture.model
        let base = fixture.base
        prepare(model)

        let destination = ModelManagerService.baseModelPath(for: model)
        try write(base, to: destination)
        let source = ModelManagerService.legacyModelsDirectory.appendingPathComponent("\(model.id).gguf")
        let entryID = "\(source.path)->\(destination.path)"
        let journal = """
        {
          "version": 1,
          "entries": [{
            "id": "\(entryID)",
            "source": "\(source.path)",
            "destination": "\(destination.path)",
            "kind": "installed",
            "modelID": "\(model.id)",
            "artifact": "base"
          }],
          "completed": [],
          "repairModelIDs": []
        }
        """
        try write(Data(journal.utf8), to: ModelMigrationService.migrationJournalFileURL)

        let result = ModelMigrationService.migrateIfNeeded(models: [model])

        XCTAssertEqual(result, .migrated(entryCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelMigrationService.migrationJournalFileURL.path))
        XCTAssertEqual(ModelMigrationService.migrateIfNeeded(models: [model]), .alreadyCurrent)
    }

    func testManagedLocationsAreDistinctAndBackupExcluded() throws {
        let model = makeTextModel()
        prepare(model)
        ModelMigrationService.ensureManagedDirectories()

        let locations = [
            ModelManagerService.modelsDirectory,
            ModelManagerService.stagingDirectory,
            ModelManagerService.resumeDirectory,
            ModelManagerService.quarantineDirectory
        ]
        XCTAssertEqual(Set(locations.map(\.path)).count, locations.count)
        for location in locations {
            let values = try location.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(
                values.isExcludedFromBackup,
                true,
                "Managed location should be backup excluded: \(location.path)"
            )
        }
    }

    // MARK: - Helpers

    private func prepare(_ model: AIModel) {
        self.model = model
        ModelManagerService.deleteModel(model)
        let legacyRoot = ModelManagerService.legacyModelsDirectory
        cleanupURLs += [
            legacyURL(for: model, artifact: .base),
            legacyURL(for: model, artifact: .mmproj),
            legacyRoot.appendingPathComponent("resume-\(model.id)-base.dat"),
            legacyRoot.appendingPathComponent("staging/\(model.id).part"),
            legacyRoot.appendingPathComponent("staging", isDirectory: true),
            legacyRoot
        ]
    }

    private func makeVisionModel() -> MigrationFixture {
        let id = "migration-vision-\(UUID().uuidString.lowercased())"
        let base = gguf(fill: 0xA5)
        let projector = gguf(fill: 0x5A)
        let model = AIModel(
            id: id,
            displayName: "Migration Vision",
            description: "Test model",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: URL(string: "https://example.com/\(id)-mmproj.gguf")!,
            baseFileSizeBytes: Int64(base.count),
            mmprojFileSizeBytes: Int64(projector.count),
            baseSHA256: sha256(base),
            mmprojSHA256: sha256(projector),
            quantization: "Q4_K_M",
            config: .llama32,
            license: testLicense
        )
        return MigrationFixture(model: model, base: base, projector: projector)
    }

    private func makeTextModel() -> AIModel {
        makeTextModelWithData().model
    }

    private func makeTextModelWithData() -> MigrationFixture {
        let id = "migration-text-\(UUID().uuidString.lowercased())"
        let base = gguf(fill: 0xA5)
        let model = AIModel(
            id: id,
            displayName: "Migration Text",
            description: "Test model",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(base.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(base),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: testLicense
        )
        return MigrationFixture(model: model, base: base, projector: nil)
    }

    private var testLicense: LicenseInfo {
        LicenseInfo(
            name: "Test",
            url: URL(string: "https://example.com/license")!,
            copyright: "Test"
        )
    }

    private func legacyURL(for model: AIModel, artifact: ArtifactType) -> URL {
        let name = artifact == .base ? "\(model.id).gguf" : "\(model.id)-mmproj.gguf"
        return ModelManagerService.legacyModelsDirectory.appendingPathComponent(name)
    }

    /// Makes planned legacy URLs traverse a test-owned alias while the legacy
    /// sweep reports the canonical backing-directory spelling.
    private func installLegacyAlias() throws {
        let root = try XCTUnwrap(storageRoot)
        let realLegacy = root.appendingPathComponent("_legacyReal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realLegacy.appendingPathComponent("Models", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Legacy", isDirectory: true),
            withDestinationURL: realLegacy
        )
    }

    /// Fails closed unless every planned source has a distinct sweep spelling
    /// that resolves to the same file identity and bytes.
    private func assertSweepObservesAlias(planURLs: [URL], expectedBytes: [Data]) throws {
        XCTAssertEqual(planURLs.count, expectedBytes.count)
        let fileManager = FileManager.default
        let legacyRoot = ModelManagerService.legacyModelsDirectory
        let enumerator = try XCTUnwrap(fileManager.enumerator(
            at: legacyRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileResourceIdentifierKey]
        ))
        let sweepURLs = enumerator.compactMap { element -> URL? in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        XCTAssertEqual(sweepURLs.count, planURLs.count, "Fixture sweep must observe every planned source")

        let identityKeys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        for (planURL, expectedData) in zip(planURLs, expectedBytes) {
            let canonicalPlan = planURL.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertNotEqual(
                planURL.path,
                canonicalPlan.path,
                "Planned source must retain the aliased path spelling"
            )
            let sweepURL = try XCTUnwrap(sweepURLs.first {
                $0.resolvingSymlinksInPath().standardizedFileURL.path == canonicalPlan.path
            }, "Legacy sweep must report the same resource through its canonical spelling")
            XCTAssertNotEqual(
                planURL.path,
                sweepURL.path,
                "Manifest planning and sweeping must use distinct raw path spellings"
            )

            let planIdentity = try XCTUnwrap(
                try planURL.resourceValues(forKeys: identityKeys).fileResourceIdentifier as? AnyHashable
            )
            let sweepIdentity = try XCTUnwrap(
                try sweepURL.resourceValues(forKeys: identityKeys).fileResourceIdentifier as? AnyHashable
            )
            XCTAssertEqual(planIdentity, sweepIdentity, "Alias spellings must identify the same file resource")
            XCTAssertEqual(try Data(contentsOf: planURL), expectedData)
            XCTAssertEqual(try Data(contentsOf: sweepURL), expectedData)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        cleanupURLs.append(url)
    }

    private func gguf(fill: UInt8) -> Data {
        TestModelFixtures.gguf(fill: fill)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func directoryContains(_ directory: URL, named name: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains(name) == true
    }

    private func quarantineContains(modelID: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: ModelManagerService.quarantineDirectory.path))?.contains {
            $0.hasPrefix("\(modelID)-")
        } == true
    }
}

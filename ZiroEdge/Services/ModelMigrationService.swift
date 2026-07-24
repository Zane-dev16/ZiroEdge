// ModelMigrationService.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Migrates pre-#4 model files out of Documents into managed, backup-excluded
// application storage. The journal makes each move resumable after interruption.

import Foundation

/// The outcome of one versioned model-storage reconciliation.
enum ModelMigrationResult: Sendable, Equatable {
    case alreadyCurrent
    case migrated(entryCount: Int)
    case failed(remainingEntries: Int)
}

/// Owns the one-time migration from the legacy Documents/Models directory.
enum ModelMigrationService {

    static let currentVersion = 1

    private static let fileManager = FileManager.default
    private static let migrationLock = NSLock()
    private static let migrationMarkerName = ".model-storage-migration"
    private static let migrationJournalName = ".model-storage-migration.journal.json"

    // MARK: - Public Migration API

    /// Migrate legacy files once. A journal is retained until every planned move
    /// has completed, so a later launch can safely continue an interrupted run.
    @discardableResult
    static func migrateIfNeeded(models: [AIModel] = ModelRegistry.allModels) -> ModelMigrationResult {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        ensureManagedDirectories()

        if hasCurrentVersionMarker {
            return .alreadyCurrent
        }

        let modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        var manifest = loadJournal() ?? buildManifest(models: models)
        if manifest.version != currentVersion {
            manifest = buildManifest(models: models)
        }

        do {
            try writeJournal(manifest)
        } catch {
            return .failed(remainingEntries: manifest.entries.count - manifest.completed.count)
        }

        for index in manifest.entries.indices {
            let entry = manifest.entries[index]
            guard !manifest.completed.contains(entry.id) else { continue }

            if process(entry, modelsByID: modelsByID) {
                manifest.completed.append(entry.id)
                do {
                    try writeJournal(manifest)
                } catch {
                    return .failed(remainingEntries: manifest.entries.count - manifest.completed.count)
                }
            }
        }

        let remaining = manifest.entries.count - manifest.completed.count
        guard remaining == 0 else {
            // Keep repair visible even if moving an invalid legacy artifact was
            // blocked by a transient filesystem error.
            for modelID in manifest.repairModelIDs {
                if let model = modelsByID[modelID] {
                    ModelManagerService.markRepairNeeded(for: model)
                }
            }
            return .failed(remainingEntries: remaining)
        }

        for modelID in manifest.repairModelIDs {
            if let model = modelsByID[modelID] {
                ModelManagerService.markRepairNeeded(for: model)
            }
        }

        do {
            try fileManager.removeItem(at: migrationJournalURL)
        } catch where fileManager.fileExists(atPath: migrationJournalURL.path) {
            return .failed(remainingEntries: 0)
        } catch {
            // The journal is already absent; this is still a completed run.
        }

        do {
            try Data("version=\(currentVersion)".utf8)
                .write(to: migrationMarkerURL, options: .atomic)
        } catch {
            return .failed(remainingEntries: 0)
        }

        removeEmptyLegacyDirectories()
        return .migrated(entryCount: manifest.entries.count)
    }

    /// Create all managed locations and mark model data as excluded from
    /// iCloud/iTunes backups. This deliberately does not start migration.
    static func ensureManagedDirectories() {
        let directories = [
            ModelManagerService.modelsDirectory,
            ModelManagerService.stagingDirectory,
            ModelManagerService.resumeDirectory,
            ModelManagerService.quarantineDirectory
        ]

        for directory in directories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
        }
    }

}

extension ModelMigrationService {
    // MARK: - Test Support

    /// Remove only migration bookkeeping. Tests use unique model IDs and clean
    /// their own files; this does not delete installed user model data.
    static func resetForTesting() {
        try? fileManager.removeItem(at: migrationMarkerURL)
        try? fileManager.removeItem(at: migrationJournalURL)
    }

    static var migrationVersionMarkerURL: URL { migrationMarkerURL }
    static var migrationJournalFileURL: URL { migrationJournalURL }

    // MARK: - Manifest

    private enum EntryKind: String, Codable {
        case installed
        case staging
        case resume
        case quarantine
    }

    private struct MigrationEntry: Codable, Hashable {
        let id: String
        let source: String
        let destination: String
        let kind: EntryKind
        let modelID: String?
        let artifact: String?
    }

    private struct MigrationManifest: Codable {
        let version: Int
        var entries: [MigrationEntry]
        var completed: [String]
        var repairModelIDs: [String]
    }

    private static var hasCurrentVersionMarker: Bool {
        guard let contents = try? String(contentsOf: migrationMarkerURL, encoding: .utf8) else {
            return false
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == "version=\(currentVersion)"
    }

    private static var migrationMarkerURL: URL {
        ModelManagerService.managedStorageDirectory.appendingPathComponent(migrationMarkerName)
    }

    private static var migrationJournalURL: URL {
        ModelManagerService.managedStorageDirectory.appendingPathComponent(migrationJournalName)
    }

    private static func loadJournal() -> MigrationManifest? {
        guard let data = try? Data(contentsOf: migrationJournalURL) else { return nil }
        return try? JSONDecoder().decode(MigrationManifest.self, from: data)
    }

    private static func writeJournal(_ manifest: MigrationManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: migrationJournalURL, options: .atomic)
    }

    private static func buildManifest(models: [AIModel]) -> MigrationManifest {
        let legacyRoot = ModelManagerService.legacyModelsDirectory
        var entries: [MigrationEntry] = []
        var repairModelIDs = Set<String>()
        var recognizedSources = Set<String>()
        var usedDestinations = Set<String>()

        for model in models {
            appendArtifact(
                model: model,
                artifact: .base,
                source: legacyRoot.appendingPathComponent("\(model.id).gguf"),
                entries: &entries,
                repairModelIDs: &repairModelIDs,
                recognizedSources: &recognizedSources,
                usedDestinations: &usedDestinations
            )

            if model.requiresMMProj {
                appendArtifact(
                    model: model,
                    artifact: .mmproj,
                    source: legacyRoot.appendingPathComponent("\(model.id)-mmproj.gguf"),
                    entries: &entries,
                    repairModelIDs: &repairModelIDs,
                    recognizedSources: &recognizedSources,
                    usedDestinations: &usedDestinations
                )
            }
        }

        // Resume files and partial/staging files have never been valid model
        // destinations. Move them intact, but keep them out of Models/.
        if let enumerator = fileManager.enumerator(at: legacyRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let source as URL in enumerator {
                guard isRegularFile(source), !recognizedSources.contains(source.path) else { continue }
                let kind = legacyKind(for: source, relativeTo: legacyRoot)
                let destinationDirectory: URL
                switch kind {
                case .staging:
                    destinationDirectory = ModelManagerService.stagingDirectory
                case .resume:
                    destinationDirectory = ModelManagerService.resumeDirectory
                case .quarantine, .installed:
                    destinationDirectory = ModelManagerService.quarantineDirectory
                }

                let relativePath = relativePath(of: source, from: legacyRoot)
                let destinationName = relativePath.replacingOccurrences(of: "/", with: "-")
                let destination = uniqueDestination(
                    directory: destinationDirectory,
                    name: destinationName,
                    usedDestinations: &usedDestinations
                )
                entries.append(MigrationEntry(
                    id: entryID(source: source, destination: destination),
                    source: source.path,
                    destination: destination.path,
                    kind: kind == .installed ? .quarantine : kind,
                    modelID: nil,
                    artifact: nil
                ))
            }
        }

        return MigrationManifest(
            version: currentVersion,
            entries: entries,
            completed: [],
            repairModelIDs: repairModelIDs.sorted()
        )
    }

    private static func appendArtifact(
        model: AIModel,
        artifact: ArtifactType,
        source: URL,
        entries: inout [MigrationEntry],
        repairModelIDs: inout Set<String>,
        recognizedSources: inout Set<String>,
        usedDestinations: inout Set<String>
    ) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        recognizedSources.insert(source.path)

        let issues = ModelManagerService.artifactValidationIssues(
            at: source,
            model: model,
            artifact: artifact
        )
        if !issues.isEmpty {
            repairModelIDs.insert(model.id)
        }

        let destination: URL
        let kind: EntryKind
        if issues.isEmpty {
            destination = destinationURL(for: model, artifact: artifact)
            kind = .installed
        } else {
            let name = "\(model.id)-\(artifactName(artifact))-\(source.lastPathComponent).quarantined"
            destination = uniqueDestination(
                directory: ModelManagerService.quarantineDirectory,
                name: name,
                usedDestinations: &usedDestinations
            )
            kind = .quarantine
        }

        entries.append(MigrationEntry(
            id: entryID(source: source, destination: destination),
            source: source.path,
            destination: destination.path,
            kind: kind,
            modelID: model.id,
            artifact: artifactName(artifact)
        ))
    }

    // MARK: - Entry Processing

    private static func process(
        _ entry: MigrationEntry,
        modelsByID: [String: AIModel]
    ) -> Bool {
        let source = URL(fileURLWithPath: entry.source)
        let destination = URL(fileURLWithPath: entry.destination)
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)

        // Never delete or move when a path regression aliases legacy and managed storage.
        if sameResource(source, destination) {
            return destinationExists
        }

        if !sourceExists {
            if entry.kind == .installed,
               let model = model(for: entry, in: modelsByID),
               let artifact = artifact(for: entry) {
                // A destination left by a move before the crash is accepted
                // only if it is still verified. Otherwise keep repair visible.
                if destinationExists {
                    let issues = ModelManagerService.artifactValidationIssues(
                        at: destination,
                        model: model,
                        artifact: artifact
                    )
                    if !issues.isEmpty {
                        ModelManagerService.markRepairNeeded(for: model)
                        _ = moveToQuarantine(at: destination, preferredName: destination.lastPathComponent)
                    }
                } else {
                    ModelManagerService.markRepairNeeded(for: model)
                }
            }
            return true
        }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            if destinationExists {
                if entry.kind == .installed,
                   let model = model(for: entry, in: modelsByID),
                   let artifact = artifact(for: entry) {
                    let destinationIssues = ModelManagerService.artifactValidationIssues(
                        at: destination,
                        model: model,
                        artifact: artifact
                    )
                    if destinationIssues.isEmpty {
                        try fileManager.removeItem(at: source)
                        return true
                    }
                    _ = moveToQuarantine(at: destination, preferredName: destination.lastPathComponent)
                } else {
                    // The destination is evidence that a prior move completed.
                    // Dropping the duplicate source makes reruns idempotent.
                    try fileManager.removeItem(at: source)
                    return true
                }
            }

            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func sameResource(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.resolvingSymlinksInPath().standardizedFileURL
        let right = rhs.resolvingSymlinksInPath().standardizedFileURL
        if left == right { return true }
        guard fileManager.fileExists(atPath: left.path), fileManager.fileExists(atPath: right.path) else {
            return false
        }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let leftID = try? left.resourceValues(forKeys: keys).fileResourceIdentifier as? AnyHashable
        let rightID = try? right.resourceValues(forKeys: keys).fileResourceIdentifier as? AnyHashable
        return leftID != nil && leftID == rightID
    }

    private static func model(for entry: MigrationEntry, in modelsByID: [String: AIModel]) -> AIModel? {
        guard let modelID = entry.modelID else { return nil }
        return modelsByID[modelID]
    }

    private static func artifact(for entry: MigrationEntry) -> ArtifactType? {
        switch entry.artifact {
        case "base": return .base
        case "mmproj": return .mmproj
        default: return nil
        }
    }

    private static func moveToQuarantine(at source: URL, preferredName: String) -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return true }
        var usedDestinations = Set<String>()
        let destination = uniqueDestination(
            directory: ModelManagerService.quarantineDirectory,
            name: "\(preferredName).quarantined",
            usedDestinations: &usedDestinations
        )
        do {
            try fileManager.createDirectory(at: ModelManagerService.quarantineDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Legacy Plan Helpers

    private static func destinationURL(for model: AIModel, artifact: ArtifactType) -> URL {
        switch artifact {
        case .base: return ModelManagerService.baseModelPath(for: model)
        case .mmproj: return ModelManagerService.mmprojModelPath(for: model)
        }
    }

    private static func artifactName(_ artifact: ArtifactType) -> String {
        switch artifact {
        case .base: return "base"
        case .mmproj: return "mmproj"
        }
    }

    private static func entryID(source: URL, destination: URL) -> String {
        "\(source.path)->\(destination.path)"
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count))
    }

    private static func legacyKind(for url: URL, relativeTo root: URL) -> EntryKind {
        let relative = relativePath(of: url, from: root).lowercased()
        let name = url.lastPathComponent.lowercased()
        if relative.split(separator: "/").contains(where: { $0 == "staging" || $0 == "tmp" })
            || name.hasSuffix(".tmp")
            || name.hasSuffix(".part")
            || name.hasSuffix(".partial")
            || name.hasSuffix(".download") {
            return .staging
        }
        if name.contains("resume") || name.hasSuffix(".resume") {
            return .resume
        }
        if relative.split(separator: "/").contains(where: { $0 == ".quarantine" || $0 == "quarantine" }) {
            return .quarantine
        }
        return .installed
    }

    private static func uniqueDestination(
        directory: URL,
        name: String,
        usedDestinations: inout Set<String>
    ) -> URL {
        let normalizedName = name.isEmpty ? "orphan" : name
        var candidate = directory.appendingPathComponent(normalizedName)
        var suffix = 1
        while usedDestinations.contains(candidate.path)
            || fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(normalizedName)-\(suffix)")
            suffix += 1
        }
        usedDestinations.insert(candidate.path)
        return candidate
    }

    // MARK: - Backup and Cleanup

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func removeEmptyLegacyDirectories() {
        guard fileManager.fileExists(atPath: ModelManagerService.legacyModelsDirectory.path) else { return }
        guard let children = try? fileManager.contentsOfDirectory(
            at: ModelManagerService.legacyModelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? fileManager.removeItem(at: child)
        }
    }
}

import Foundation
import CryptoKit

struct HuggingFaceProvenance: Codable, Hashable, Sendable {
    let repositoryID: String
    let revision: String
    let baseFilename: String
    let baseSHA256: String
    let architecture: String
    let projectorFilename: String?
    let projectorSHA256: String?

    var identityKey: String {
        [repositoryID, revision, baseFilename, projectorFilename ?? ""].joined(separator: ":")
    }
}

enum ModelSource: Codable, Hashable, Sendable {
    case curated
    case huggingFace(HuggingFaceProvenance)
}

enum ImportedModelLoadStatus: Codable, Hashable, Sendable {
    case neverLoaded
    case loaded
    case loadFailed(kind: String, diagnostic: String, at: Date)
    case configurationChanged
}

struct ImportedModelRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var description: String
    var modelType: ModelType
    var baseURL: URL
    var mmprojURL: URL?
    var baseFileSizeBytes: Int64
    var mmprojFileSizeBytes: Int64?
    var baseSHA256: String
    var mmprojSHA256: String?
    var quantization: String
    var config: ModelConfiguration
    var license: LicenseInfo
    var provenance: HuggingFaceProvenance
    var importedAt: Date
    var loadStatus: ImportedModelLoadStatus
    /// Present only while this record is an update transfer candidate. The
    /// staged record keeps a distinct ID so its transfer/status cannot mask
    /// the installed runtime with the stable target ID.
    var updateTargetModelID: String? = nil

    var model: AIModel {
        AIModel(
            id: id,
            displayName: displayName,
            description: description,
            modelType: modelType,
            baseURL: baseURL,
            mmprojURL: mmprojURL,
            baseFileSizeBytes: baseFileSizeBytes,
            mmprojFileSizeBytes: mmprojFileSizeBytes,
            baseSHA256: baseSHA256,
            mmprojSHA256: mmprojSHA256,
            quantization: quantization,
            config: config,
            license: license,
            source: .huggingFace(provenance)
        )
    }
}

extension Notification.Name {
    static let importedModelsDidChange = Notification.Name("ImportedModelsDidChange")
}

/// When a conversation references a model that has been removed, this status
/// helps the UI surface an explicit unavailable-model state.
enum UnavailableModelReason: Equatable, Sendable {
    case removed
    case neverExisted
}

enum ImportedModelStoreError: LocalizedError, Equatable {
    case registryUnavailable
    case recordNotFound(String)
    case provenanceChanged(String)

    var errorDescription: String? {
        switch self {
        case .registryUnavailable:
            "Imported model data is temporarily unavailable. Unlock the device and try again."
        case .recordNotFound(let id):
            "The imported model record ‘\(id)’ no longer exists."
        case .provenanceChanged(let id):
            "The imported model ‘\(id)’ changed while the operation was in progress."
        }
    }
}

/// Atomic JSON registry. It stores immutable repository/revision/artifact provenance,
/// so relaunch never resolves an installed model against a moving branch.
/// Read/decode failures are fail-closed: they never masquerade as an empty registry.
final class ImportedModelStore: @unchecked Sendable {
    static let shared = ImportedModelStore()

    typealias Reader = (URL) throws -> Data
    typealias Writer = (Data, URL) throws -> Void

    private let lock = NSLock()
    private let fileURL: URL
    private let backupURL: URL
    private let reader: Reader
    private let writer: Writer
    private var records: [ImportedModelRecord]
    private var available: Bool
    private var primaryIsValid: Bool

    init(
        directory: URL? = nil,
        reader: @escaping Reader = { try Data(contentsOf: $0) },
        writer: @escaping Writer = {
            try $0.write(to: $1, options: [.atomic, .completeFileProtection])
        }
    ) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZiroEdge/Models/Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("registry.json")
        backupURL = root.appendingPathComponent("registry.backup.json")
        self.reader = reader
        self.writer = writer
        let loaded = Self.load(fileURL: fileURL, backupURL: backupURL, reader: reader)
        records = loaded.records
        available = loaded.available
        primaryIsValid = loaded.primaryIsValid
    }

    var isAvailable: Bool {
        lock.withLock {
            recoverIfPossibleLocked()
            return available
        }
    }

    var allRecords: [ImportedModelRecord] {
        lock.withLock {
            recoverIfPossibleLocked()
            return records
        }
    }

    var models: [AIModel] { allRecords.map(\.model) }

    func record(id: String) -> ImportedModelRecord? {
        lock.withLock {
            recoverIfPossibleLocked()
            return records.first { $0.id == id }
        }
    }

    func record(repositoryID: String, revision: String, baseFilename: String, projectorFilename: String?) -> ImportedModelRecord? {
        lock.withLock {
            recoverIfPossibleLocked()
            return records.first {
                $0.provenance.repositoryID == repositoryID
                    && $0.provenance.revision == revision
                    && $0.provenance.baseFilename == baseFilename
                    && $0.provenance.projectorFilename == projectorFilename
            }
        }
    }

    @discardableResult
    func upsert(_ record: ImportedModelRecord) throws -> ImportedModelRecord {
        try mutate { records in
            if let duplicate = records.first(where: {
                $0.provenance.identityKey == record.provenance.identityKey
            }) { return duplicate }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
            return record
        }
    }

    func update(id: String, _ body: (inout ImportedModelRecord) -> Void) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw ImportedModelStoreError.recordNotFound(id)
            }
            body(&records[index])
        }
    }

    func replace(
        id: String,
        expectedProvenance: HuggingFaceProvenance,
        with replacement: ImportedModelRecord
    ) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw ImportedModelStoreError.recordNotFound(id)
            }
            guard records[index].provenance == expectedProvenance else {
                throw ImportedModelStoreError.provenanceChanged(id)
            }
            records[index] = replacement
        }
    }

    @discardableResult
    func remove(id: String) throws -> ImportedModelRecord? {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            return records.remove(at: index)
        }
    }

    private func mutate<T>(_ body: (inout [ImportedModelRecord]) throws -> T) throws -> T {
        lock.lock()
        recoverIfPossibleLocked()
        guard available else {
            lock.unlock()
            throw ImportedModelStoreError.registryUnavailable
        }
        let previous = records
        do {
            let result = try body(&records)
            let data = try JSONEncoder().encode(records)
            if primaryIsValid {
                try preserveCurrentPrimaryAsBackupLocked()
            }
            try writer(data, fileURL)
            primaryIsValid = true
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .importedModelsDidChange, object: nil)
            }
            return result
        } catch {
            records = previous
            lock.unlock()
            throw error
        }
    }

    private func recoverIfPossibleLocked() {
        guard !available else { return }
        let loaded = Self.load(fileURL: fileURL, backupURL: backupURL, reader: reader)
        guard loaded.available else { return }
        records = loaded.records
        available = true
        primaryIsValid = loaded.primaryIsValid
    }

    private func preserveCurrentPrimaryAsBackupLocked() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let current = try reader(fileURL)
        _ = try JSONDecoder().decode([ImportedModelRecord].self, from: current)
        try current.write(to: backupURL, options: [.atomic, .completeFileProtection])
    }

    private static func load(
        fileURL: URL,
        backupURL: URL,
        reader: Reader
    ) -> (records: [ImportedModelRecord], available: Bool, primaryIsValid: Bool) {
        let primaryExists = FileManager.default.fileExists(atPath: fileURL.path)
        let backupExists = FileManager.default.fileExists(atPath: backupURL.path)
        if primaryExists,
           let data = try? reader(fileURL),
           let decoded = try? JSONDecoder().decode([ImportedModelRecord].self, from: data) {
            return (decoded, true, true)
        }
        if backupExists,
           let data = try? reader(backupURL),
           let decoded = try? JSONDecoder().decode([ImportedModelRecord].self, from: data) {
            // A later successful mutation repairs the primary without first
            // replacing this known-good backup with missing or corrupt bytes.
            return (decoded, true, false)
        }
        if !primaryExists, !backupExists {
            return ([], true, true)
        }
        return ([], false, false)
    }
}

/// Durable update candidates remain separate from installed records until every
/// selected artifact verifies. This store is also the promotion journal.
final class ImportedModelUpdateStore: @unchecked Sendable {
    static let shared = ImportedModelUpdateStore()

    private let lock = NSLock()
    private let fileURL: URL
    private let backupURL: URL
    private let reader: ImportedModelStore.Reader
    private let writer: ImportedModelStore.Writer
    private var records: [ImportedModelRecord]
    private var available: Bool
    private var primaryIsValid: Bool

    init(
        directory: URL? = nil,
        reader: @escaping ImportedModelStore.Reader = { try Data(contentsOf: $0) },
        writer: @escaping ImportedModelStore.Writer = {
            try $0.write(to: $1, options: [.atomic, .completeFileProtection])
        }
    ) {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ZiroEdge/Models/Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("pending-updates.json")
        backupURL = root.appendingPathComponent("pending-updates.backup.json")
        self.reader = reader
        self.writer = writer
        let loaded = Self.load(fileURL: fileURL, backupURL: backupURL, reader: reader)
        records = loaded.records.map(Self.migrateLegacyRecord)
        available = loaded.available
        primaryIsValid = loaded.primaryIsValid
    }

    var isAvailable: Bool {
        lock.withLock {
            recoverIfPossibleLocked()
            return available
        }
    }

    var allRecords: [ImportedModelRecord] {
        lock.withLock {
            recoverIfPossibleLocked()
            return records
        }
    }

    var models: [AIModel] { allRecords.map(\.model) }

    func record(targetModelID: String) -> ImportedModelRecord? {
        lock.withLock {
            recoverIfPossibleLocked()
            return records.first { ($0.updateTargetModelID ?? $0.id) == targetModelID }
        }
    }

    func upsert(_ record: ImportedModelRecord) throws {
        try mutate { records in
            let targetID = record.updateTargetModelID ?? record.id
            if let index = records.firstIndex(where: { ($0.updateTargetModelID ?? $0.id) == targetID }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }
    }

    func remove(targetModelID: String) throws {
        try mutate { records in
            records.removeAll { ($0.updateTargetModelID ?? $0.id) == targetModelID }
        }
    }

    private func mutate(_ body: (inout [ImportedModelRecord]) throws -> Void) throws {
        lock.lock()
        recoverIfPossibleLocked()
        guard available else {
            lock.unlock()
            throw ImportedModelStoreError.registryUnavailable
        }
        let previous = records
        do {
            try body(&records)
            let data = try JSONEncoder().encode(records)
            if primaryIsValid {
                try preserveCurrentPrimaryAsBackupLocked()
            }
            try writer(data, fileURL)
            primaryIsValid = true
            lock.unlock()
        } catch {
            records = previous
            lock.unlock()
            throw error
        }
    }

    private func recoverIfPossibleLocked() {
        guard !available else { return }
        let loaded = Self.load(fileURL: fileURL, backupURL: backupURL, reader: reader)
        guard loaded.available else { return }
        records = loaded.records.map(Self.migrateLegacyRecord)
        available = true
        primaryIsValid = loaded.primaryIsValid
    }

    private func preserveCurrentPrimaryAsBackupLocked() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let current = try reader(fileURL)
        _ = try JSONDecoder().decode([ImportedModelRecord].self, from: current)
        try current.write(to: backupURL, options: [.atomic, .completeFileProtection])
    }

    private static func load(
        fileURL: URL,
        backupURL: URL,
        reader: ImportedModelStore.Reader
    ) -> (records: [ImportedModelRecord], available: Bool, primaryIsValid: Bool) {
        let primaryExists = FileManager.default.fileExists(atPath: fileURL.path)
        let backupExists = FileManager.default.fileExists(atPath: backupURL.path)
        if primaryExists,
           let data = try? reader(fileURL),
           let decoded = try? JSONDecoder().decode([ImportedModelRecord].self, from: data) {
            return (decoded, true, true)
        }
        if backupExists,
           let data = try? reader(backupURL),
           let decoded = try? JSONDecoder().decode([ImportedModelRecord].self, from: data) {
            return (decoded, true, false)
        }
        if !primaryExists, !backupExists {
            return ([], true, true)
        }
        return ([], false, false)
    }

    private static func migrateLegacyRecord(_ legacy: ImportedModelRecord) -> ImportedModelRecord {
        guard legacy.updateTargetModelID == nil else { return legacy }
        var migrated = legacy
        migrated.updateTargetModelID = legacy.id
        let projectorSuffix = legacy.provenance.projectorSHA256.map { String($0.prefix(4)) } ?? "text"
        migrated.id = "hf-update-\(legacy.provenance.baseSHA256.prefix(20))-\(projectorSuffix)"
        return migrated
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

struct HFGGUFMetadata: Hashable, Sendable {
    var architecture: String
    var contextLength: Int?
    var chatTemplate: String?
    var modelName: String?
}

struct HFArtifact: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable { case base, projector }
    var id: String { filename }
    let filename: String
    let size: Int64
    let sha256: String
    let quantization: String
    let architecture: String
    let role: Role
    let metadata: HFGGUFMetadata
}

struct HFRepositoryReview: Hashable, Sendable {
    let repositoryID: String
    let revision: String
    let licenseName: String
    let licenseURL: URL
    let artifacts: [HFArtifact]

    var baseArtifacts: [HFArtifact] { artifacts.filter { $0.role == .base } }
    var projectorArtifacts: [HFArtifact] { artifacts.filter { $0.role == .projector } }

    /// Vision pairing is intentionally strict: the unique projector must have
    /// deterministic family/naming or artifact-metadata evidence in addition
    /// to architecture and quantization compatibility.
    func suggestedVisionPair(base: HFArtifact) throws -> (HFArtifact, HFArtifact) {
        guard base.role == .base else { throw HFInspectionError.noCompatibleArtifact }
        guard !projectorArtifacts.isEmpty else { throw HFInspectionError.projectorMissing }
        guard let pair = VisionPairResolver().bestPair(for: base, in: self) else {
            let compatibleCount = VisionPairResolver().resolvePairs(from: self)
                .filter { $0.base == base && $0.confidence == .high }.count
            throw compatibleCount > 1 ? HFInspectionError.projectorAmbiguous : HFInspectionError.incompatibleVisionPair
        }
        return (pair.base, pair.projector)
    }
}

enum HFInspectionError: LocalizedError, Equatable {
    case malformedRepository
    case repositoryUnavailable
    case repositoryPrivate
    case transientFailure
    case noCompatibleArtifact
    case unsupportedArchitecture(String)
    case missingDigest(String)
    case malformedMetadata(String)
    case licenseTermsUnavailable
    case unsupportedShardedArtifact(String)
    case projectorMissing
    case projectorAmbiguous
    case incompatibleVisionPair

    var errorDescription: String? {
        switch self {
        case .malformedRepository: "Enter a public repository as owner/name or a huggingface.co/owner/name URL."
        case .repositoryUnavailable: "This Hugging Face repository does not exist or is unavailable."
        case .repositoryPrivate: "Private Hugging Face repositories cannot be imported."
        case .transientFailure: "Hugging Face could not be reached. Try inspection again."
        case .noCompatibleArtifact: "No compatible GGUF model artifact was found."
        case .unsupportedArchitecture(let value): "The GGUF architecture ‘\(value)’ is not supported by this ZiroEdge runtime."
        case .missingDigest(let file): "\(file) has no trustworthy SHA-256 digest and cannot be imported."
        case .malformedMetadata(let file): "\(file) has malformed size or integrity metadata."
        case .licenseTermsUnavailable: "This repository does not provide identifiable, reviewable license terms and cannot be imported."
        case .unsupportedShardedArtifact(let file): "\(file) is part of a split GGUF. Split or sharded GGUF models are not supported."
        case .projectorMissing: "No compatible vision projector was found at this revision."
        case .projectorAmbiguous: "More than one projector could match, so ZiroEdge will not guess."
        case .incompatibleVisionPair: "The base model and projector do not have deterministic compatibility evidence."
        }
    }
}

/// Read-only Hugging Face inspection. It requests metadata and GGUF bytes only;
/// repository code and remote-code directives are never downloaded or executed.
struct HFRepositoryInspector: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let loader: Loader
    private static let supportedArchitectures: Set<String> = [
        "llama", "gemma", "gemma2", "gemma3", "qwen2", "qwen2vl", "phi3", "mistral", "clip"
    ]
    /// Defensive supported-artifact ceiling. Larger metadata is rejected before
    /// it can influence storage, transfer, or memory arithmetic.
    static let maximumSupportedArtifactBytes: Int64 = 4 * 1_024 * 1_024 * 1_024 * 1_024

    init(loader: @escaping Loader = { request in
        try await HFRepositoryInspector.liveLoader(request)
    }) {
        self.loader = loader
    }

    static func normalizeRepositoryID(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if let url = URL(string: trimmed), let host = url.host {
            guard host == "huggingface.co" || host == "www.huggingface.co" else { throw HFInspectionError.malformedRepository }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 2 else { throw HFInspectionError.malformedRepository }
            candidate = components.joined(separator: "/")
        }
        let pieces = candidate.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && String($0).unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw HFInspectionError.malformedRepository
        }
        return candidate
    }

    func inspect(_ input: String) async throws -> HFRepositoryReview {
        let repositoryID = try Self.normalizeRepositoryID(input)
        let encoded = repositoryID.split(separator: "/").map(String.init).map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
        }.joined(separator: "/")
        let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true")!
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await loader(URLRequest(url: url)) }
        catch { throw HFInspectionError.transientFailure }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw HFInspectionError.repositoryPrivate
        case 404: throw HFInspectionError.repositoryUnavailable
        case 500...599: throw HFInspectionError.transientFailure
        default: throw HFInspectionError.repositoryUnavailable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = object["siblings"] as? [[String: Any]] else {
            throw HFInspectionError.transientFailure
        }
        guard let revision = object["sha"] as? String,
              revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit }) else {
            throw HFInspectionError.malformedMetadata("repository revision")
        }
        let card = object["cardData"] as? [String: Any]
        let declaredLicense = card?["license"] as? String
        let topGGUF = object["gguf"] as? [String: Any]
        let reviewedArchitecture = topGGUF?["architecture"] as? String
        var artifacts: [HFArtifact] = []
        for sibling in siblings {
            guard let filename = (sibling["rfilename"] ?? sibling["path"]) as? String else { continue }
            guard !Self.isSplitGGUF(filename) else {
                throw HFInspectionError.unsupportedShardedArtifact(filename)
            }
            guard filename.lowercased().hasSuffix(".gguf") else { continue }
            guard let size = Self.int64(sibling["size"]),
                  (1...Self.maximumSupportedArtifactBytes).contains(size) else {
                throw HFInspectionError.malformedMetadata(filename)
            }
            let lfs = sibling["lfs"] as? [String: Any]
            guard let digest = (lfs?["sha256"] as? String) ?? sibling["sha256"] as? String else {
                throw HFInspectionError.missingDigest(filename)
            }
            guard ModelManagerService.isValidSHA256(digest) else {
                throw HFInspectionError.malformedMetadata(filename)
            }
            let isProjector = filename.lowercased().contains("mmproj")
            let artifactGGUF = sibling["gguf"] as? [String: Any]
            let architecture = artifactGGUF.map { $0["architecture"] as? String }
                ?? (isProjector ? "clip" : reviewedArchitecture)
            guard let architecture else {
                throw HFInspectionError.malformedMetadata(filename)
            }
            guard Self.supportedArchitectures.contains(architecture) else {
                throw HFInspectionError.unsupportedArchitecture(architecture)
            }
            // Repository-level GGUF metadata describes the model as a whole,
            // not every sibling. Only base variants may inherit it; projector
            // pairing evidence must come from projector-specific metadata or
            // deterministic filenames.
            let metadata = artifactGGUF ?? (isProjector ? [:] : (topGGUF ?? [:]))
            artifacts.append(HFArtifact(
                filename: filename,
                size: size,
                sha256: digest,
                quantization: Self.quantization(filename),
                architecture: architecture,
                role: isProjector ? .projector : .base,
                metadata: HFGGUFMetadata(
                    architecture: architecture,
                    contextLength: Self.int(metadata["context_length"]),
                    chatTemplate: metadata["chat_template"] as? String,
                    modelName: metadata["name"] as? String
                )
            ))
        }
        guard artifacts.contains(where: { $0.role == .base }) else { throw HFInspectionError.noCompatibleArtifact }
        guard let license = Self.reviewableLicense(
            declaredName: declaredLicense,
            siblings: siblings,
            repositoryID: repositoryID,
            revision: revision
        ) else {
            throw HFInspectionError.licenseTermsUnavailable
        }
        return HFRepositoryReview(
            repositoryID: repositoryID,
            revision: revision,
            licenseName: license.name,
            licenseURL: license.url,
            artifacts: artifacts.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        )
    }

    static func liveLoader(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }


    private static func reviewableLicense(
        declaredName: String?,
        siblings: [[String: Any]],
        repositoryID: String,
        revision: String
    ) -> (name: String, url: URL)? {
        let normalizedName = declaredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let licenseNames: Set<String> = [
            "license", "license.md", "license.txt",
            "copying", "copying.md", "copying.txt"
        ]
        if let path = siblings.compactMap({ ($0["rfilename"] ?? $0["path"]) as? String }).first(where: {
            licenseNames.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased())
        }) {
            let displayName = normalizedName.flatMap { name in
                name.isEmpty || ["unknown", "other"].contains(name.lowercased()) ? nil : name
            } ?? "Repository license"
            return (
                displayName,
                ImportedModelFactory.resolveURL(
                    repo: repositoryID,
                    revision: revision,
                    filename: path
                )
            )
        }

        guard let normalizedName,
              !normalizedName.isEmpty,
              !["unknown", "other"].contains(normalizedName.lowercased()) else {
            return nil
        }
        let spdxIDs: [String: String] = [
            "apache-2.0": "Apache-2.0",
            "mit": "MIT",
            "bsd-2-clause": "BSD-2-Clause",
            "bsd-3-clause": "BSD-3-Clause",
            "isc": "ISC",
            "mpl-2.0": "MPL-2.0",
            "gpl-2.0": "GPL-2.0-only",
            "gpl-3.0": "GPL-3.0-only",
            "lgpl-2.1": "LGPL-2.1-only",
            "lgpl-3.0": "LGPL-3.0-only",
            "agpl-3.0": "AGPL-3.0-only",
            "cc-by-4.0": "CC-BY-4.0",
            "cc-by-sa-4.0": "CC-BY-SA-4.0",
            "cc0-1.0": "CC0-1.0",
            "unlicense": "Unlicense"
        ]
        guard let spdxID = spdxIDs[normalizedName.lowercased()],
              let url = URL(string: "https://spdx.org/licenses/\(spdxID).html") else {
            return nil
        }
        return (normalizedName, url)
    }

    private static func isSplitGGUF(_ filename: String) -> Bool {
        let name = filename.lowercased()
        let patterns = [
            #"-\d{5}-of-\d{5}\.gguf$"#,
            #"\.gguf\.\d+$"#,
            #"(?:^|[-_.])part[-_.]?\d+(?:[-_.]of[-_.]?\d+)?\.gguf$"#,
            #"(?:^|[-_.])shard[-_.]?\d+(?:[-_.]of[-_.]?\d+)?\.gguf$"#
        ]
        return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    private static func quantization(_ filename: String) -> String {
        let upper = filename.uppercased()
        let patterns = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_K_S", "Q4_K_M", "Q5_0", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0", "F16", "BF16"]
        return patterns.first(where: upper.contains) ?? "Unknown"
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        int64(value).map(Int.init)
    }
}

struct ImportStoragePreflight: Equatable, Sendable {
    let requiredBytes: Int64
    let safetyMarginBytes: Int64
    let availableBytes: Int64
    var canProceed: Bool {
        guard requiredBytes >= 0, safetyMarginBytes >= 0, availableBytes >= 0 else { return false }
        let (total, overflow) = requiredBytes.addingReportingOverflow(safetyMarginBytes)
        return !overflow && availableBytes >= total
    }
}

struct ImportRAMAssessment: Equatable, Sendable {
    enum Classification: Sendable { case likelyFits, risky }
    let estimatedBytes: UInt64
    let physicalBytes: UInt64
    let classification: Classification

    static func estimatedBytes(artifactBytes: Int64, contextLength: Int) -> UInt64 {
        let artifact = UInt64(clamping: artifactBytes / 3)
        let context = SaturatedArithmetic.multiply(UInt64(clamping: max(contextLength, 512)), 256_000)
        return SaturatedArithmetic.add(
            SaturatedArithmetic.add(artifact, context),
            MemoryProfile.productionReserveBytes
        )
    }

    var warning: String? {
        classification == .risky
            ? "This model may exceed available RAM. iOS may terminate ZiroEdge during loading."
            : nil
    }
}

struct ImportedModelFactory {
    static func makeRecord(
        review: HFRepositoryReview,
        base: HFArtifact,
        projector: HFArtifact? = nil,
        stableID: String? = nil,
        updateTargetModelID: String? = nil
    ) -> ImportedModelRecord {
        let id = stableID ?? stableIdentity(review: review, base: base, projector: projector)
        let revision = review.revision
        let baseURL = resolveURL(repo: review.repositoryID, revision: revision, filename: base.filename)
        let projectorURL = projector.map { resolveURL(repo: review.repositoryID, revision: revision, filename: $0.filename) }
        let promptPath: PromptPath = base.metadata.chatTemplate?.isEmpty == false ? .chatTemplate : .raw
        let config = ModelConfiguration.imported(
            promptPath: promptPath,
            contextLength: base.metadata.contextLength ?? 2048
        )
        let provenance = HuggingFaceProvenance(
            repositoryID: review.repositoryID,
            revision: revision,
            baseFilename: base.filename,
            baseSHA256: base.sha256,
            architecture: base.architecture,
            projectorFilename: projector?.filename,
            projectorSHA256: projector?.sha256
        )
        return ImportedModelRecord(
            id: id,
            displayName: "\(review.repositoryID.split(separator: "/").last ?? "Model") · \(base.quantization)",
            description: "Experimental model imported from \(review.repositoryID) at \(revision.prefix(8)).",
            modelType: projector == nil ? .text : .vision,
            baseURL: baseURL,
            mmprojURL: projectorURL,
            baseFileSizeBytes: base.size,
            mmprojFileSizeBytes: projector?.size,
            baseSHA256: base.sha256,
            mmprojSHA256: projector?.sha256,
            quantization: base.quantization,
            config: config,
            license: LicenseInfo(name: review.licenseName, url: review.licenseURL, copyright: "Imported from Hugging Face"),
            provenance: provenance,
            importedAt: Date(),
            loadStatus: .neverLoaded,
            updateTargetModelID: updateTargetModelID
        )
    }

    static func stableIdentity(review: HFRepositoryReview, base: HFArtifact, projector: HFArtifact?) -> String {
        let key = [review.repositoryID, review.revision, base.filename, projector?.filename ?? ""].joined(separator: ":")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "hf-\(digest.prefix(24))"
    }

    static func resolveURL(repo: String, revision: String, filename: String) -> URL {
        let root = URL(string: "https://huggingface.co")!
        let components = repo.split(separator: "/").map(String.init)
            + ["resolve", revision]
            + filename.split(separator: "/").map(String.init)
        return components.reduce(root) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }
}

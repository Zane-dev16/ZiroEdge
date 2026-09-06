import Foundation

extension DownloadManager {
    func storageSafetyMargin(for requiredBytes: Int64) -> Int64 {
        max(requiredBytes / 20, Self.storageSafetyMarginBytes)
    }

    func authoritativeDiskStatus(for model: AIModel) -> ModelDownloadStatus {
        Self.diskStatus(for: model)
    }

    /// Sendable full-verification status (exists + size + header + SHA-256).
    /// Static so the post-first-frame refresh can compute it off-main without
    /// touching MainActor-isolated state; the caller publishes the result.
    nonisolated static func diskStatus(for model: AIModel) -> ModelDownloadStatus {
        switch ModelManagerService.availability(for: model) {
        case .ready:
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .downloaded,
                mmprojState: model.requiresMMProj ? .downloaded : nil,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        case .unavailable:
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .notDownloaded,
                mmprojState: model.requiresMMProj ? .notDownloaded : nil,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        case .repairNeeded:
            guard model.requiresMMProj else {
                return ModelDownloadStatus(
                    modelID: model.id,
                    baseState: .notDownloaded,
                    mmprojState: nil,
                    baseExpectedBytes: model.baseFileSizeBytes
                )
            }
            let hasBase = ModelManagerService.isBaseDownloaded(model)
            let hasProjector = ModelManagerService.isMMProjDownloaded(model)
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: hasBase && !hasProjector ? .downloaded : .notDownloaded,
                mmprojState: hasProjector ? .downloaded : .notDownloaded,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        }
    }

    /// Sendable hash-free status for the launch seed. Same shape as
    /// `diskStatus(for:)` but driven by `quickAvailability` + presence probes
    /// so seeding never hashes. The deferred refresh replaces these with
    /// verified values shortly after first frame.
    nonisolated static func quickDiskStatus(for model: AIModel) -> ModelDownloadStatus {
        switch ModelManagerService.quickAvailability(for: model) {
        case .ready:
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .downloaded,
                mmprojState: model.requiresMMProj ? .downloaded : nil,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        case .unavailable:
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .notDownloaded,
                mmprojState: model.requiresMMProj ? .notDownloaded : nil,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        case .repairNeeded:
            guard model.requiresMMProj else {
                return ModelDownloadStatus(
                    modelID: model.id,
                    baseState: .notDownloaded,
                    mmprojState: nil,
                    baseExpectedBytes: model.baseFileSizeBytes
                )
            }
            let hasBase = ModelManagerService.isArtifactPresent(model, artifact: .base)
            let hasProjector = ModelManagerService.isArtifactPresent(model, artifact: .mmproj)
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: hasBase && !hasProjector ? .downloaded : .notDownloaded,
                mmprojState: hasProjector ? .downloaded : .notDownloaded,
                baseExpectedBytes: model.baseFileSizeBytes,
                mmprojExpectedBytes: model.mmprojFileSizeBytes,
                allowsTextOnly: model.allowsTextOnlyCapability
            )
        }
    }

}

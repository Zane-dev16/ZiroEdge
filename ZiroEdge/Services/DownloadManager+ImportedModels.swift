import Foundation

extension DownloadManager {
    func storageSafetyMargin(for requiredBytes: Int64) -> Int64 {
        max(requiredBytes / 20, Self.storageSafetyMarginBytes)
    }

    func authoritativeDiskStatus(for model: AIModel) -> ModelDownloadStatus {
        Self.diskStatus(for: model)
    }

    /// Sendable disk status at the caller's verification depth (exists + size +
    /// header + SHA-256 at `.full`, hash-free at `.quick`/`.presence`). Static
    /// so the post-first-frame refresh can compute it off-main without
    /// touching MainActor-isolated state; the caller publishes the result.
    /// The launch seed passes `.quick` so seeding never hashes; the deferred
    /// refresh replaces those with `.full` values shortly after first frame.
    nonisolated static func diskStatus(
        for model: AIModel,
        depth: ArtifactVerificationDepth = .full
    ) -> ModelDownloadStatus {
        let availability: ModelAvailability = switch depth {
        case .full:
            ModelManagerService.availability(for: model)
        case .presence, .quick:
            // No presence-tier availability sweep exists; the hash-free quick
            // sweep is the cheapest availability signal at or below `.quick`.
            ModelManagerService.quickAvailability(for: model)
        }
        switch availability {
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
            // Per-artifact states use the same depth as the sweep: full
            // verification at `.full`, hash-free quick check below it
            // (matches `quickAvailability`, never quarantines).
            let probe: ArtifactVerificationDepth = depth == .full ? .full : .quick
            let hasBase = ModelManagerService.isArtifactVerified(model, artifact: .base, depth: probe)
            let hasProjector = ModelManagerService.isArtifactVerified(model, artifact: .mmproj, depth: probe)
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

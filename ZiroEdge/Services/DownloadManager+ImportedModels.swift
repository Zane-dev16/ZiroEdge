import Foundation

extension DownloadManager {
    func storageSafetyMargin(for requiredBytes: Int64) -> Int64 {
        max(requiredBytes / 20, Self.storageSafetyMarginBytes)
    }

    func authoritativeDiskStatus(for model: AIModel) -> ModelDownloadStatus {
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

}

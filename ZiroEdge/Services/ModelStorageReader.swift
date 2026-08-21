// ModelStorageReader.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Read-only query surface over installed-model storage. The concrete
// implementation performs real filesystem I/O; depending on this protocol
// (instead of the ModelManagerService namespace directly) lets ViewModels
// and tests substitute isolated readers where useful.

import Foundation

/// Storage-reading helpers for installed models, expressed as static
/// requirements so the caseless `ModelManagerService` namespace conforms
/// without instantiation.
protocol ModelStorageReader {
    /// Whether the base artifact is present and passes full validation.
    static func isBaseDownloaded(_ model: AIModel) -> Bool

    /// Whether the projector artifact is present and passes full validation.
    static func isMMProjDownloaded(_ model: AIModel) -> Bool

    /// Whether every required artifact is downloaded and validated.
    static func isFullyDownloaded(_ model: AIModel) -> Bool

    /// Whether a repair marker exists for the model.
    static func isRepairNeeded(for model: AIModel) -> Bool

    /// Bytes owned by this model's artifacts on disk.
    static func diskUsage(for model: AIModel) -> Int64

    /// Human-formatted bytes owned by this model's artifacts.
    static func formattedDiskUsage(for model: AIModel) -> String
}

extension ModelManagerService: ModelStorageReader {}

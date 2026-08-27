// SettingsPage.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Settings presented as a pushed in-app page inside the app shell's
// navigation stack (migrated from the former gear-icon sheet). The shell
// owns the single navigation path, so this page must not wrap itself in a
// NavigationStack or provide Done/dismiss chrome.

import SwiftUI

/// Settings page with storage management, memory info, license attribution, and privacy policy.
struct SettingsPage: View {
    @ObservedObject var lifecycleManager: ModelLifecycleManager
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter
    let downloadManager: DownloadManager
    @ObservedObject var modelsViewModel: ModelsViewModel

    @AppStorage(ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    private var defaultSystemPrompt = ""

    /// Local state to trigger refresh after deletion.
    @State private var storageRefreshID = UUID()

    /// Confirmation dialog state for model deletion.
    @State private var modelToDelete: AIModel?

    /// Memory values (loaded async from actor).
    @State private var appMemoryHeadroom: String = "Loading..."
    @State private var totalRAM: String = "Loading..."

    private static let privacyPolicyURL = URL(string: "https://zane-dev16.github.io/ZiroEdge/privacy.html")
        ?? URL(fileURLWithPath: "/")

    /// Models that are currently downloaded on disk.
    private var downloadedModels: [AIModel] {
        ModelRegistry.libraryModels.filter { model in
            let status = downloadManager.status(for: model)
            return status.isReady
        }
    }

    var body: some View {
        List {
            // Models section.
            Section {
                NavigationLink(value: ShellRoute.models) {
                    Label("Manage Models", systemImage: "arrow.down.circle")
                }
            }

            // Active model section.
            Section("Active Model") {
                if let model = lifecycleManager.activeModel {
                    LabeledContent("Model", value: model.displayName)
                    LabeledContent("Size", value: model.formattedSize)
                    LabeledContent("Type", value: model.modelType.rawValue.capitalized)

                    Button {
                        Task { await lifecycleManager.unloadCurrentModel() }
                    } label: {
                        Label("Unload Model", systemImage: "eject")
                    }
                } else {
                    Text("No model loaded")
                        .foregroundStyle(.secondary)
                }
            }

            // Storage management section.
            Section {
                if downloadedModels.isEmpty {
                    Text("No models downloaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloadedModels) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                    .font(.body)
                                Text(formattedModelDiskUsage(model))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                modelToDelete = model
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete \(model.displayName)")
                        }
                    }
                }

                LabeledContent("Total Storage") {
                    Text(formattedTotalDiskUsage())
                        .id(storageRefreshID)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Models are stored locally on your device. Deleting a model frees disk space.")
            }

            Section {
                TextEditor(text: $defaultSystemPrompt)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Default model instructions")
            } header: {
                Text("Default Instructions")
            } footer: {
                Text("Applied to new conversations and used when a conversation has no custom instructions. Processing remains on device.")
            }

            // Memory section.
            Section {
                LabeledContent("App Memory Headroom", value: appMemoryHeadroom)
                LabeledContent("Total Device RAM", value: totalRAM)
#if DEBUG
                if let exportURL = MemoryDiagnosticRecorder.shared.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export Memory Calibration JSONL", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export-memory-calibration")
                }
#endif
            } header: {
                Text("Memory")
            } footer: {
                Text("App Memory Headroom is the memory iOS allowed ZiroEdge at the latest model load check, or a current sample before the first check. It is not unused device RAM.")
            }

            Section("Download Diagnostics") {
                let hasStructuredLog = FileManager.default.fileExists(atPath: DownloadDiagnosticRecorder.logURL.path)

                if hasStructuredLog {
                    if let summaryURL = DownloadDiagnosticRecorder.shared.writeSummary() {
                        ShareLink(item: summaryURL) {
                            Label("Export Structured Summary", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("export-download-summary")
                    }
                    ShareLink(item: DownloadDiagnosticRecorder.logURL) {
                        Label("Export JSONL Event Log", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("export-download-jsonl")
                } else {
                    Text("No download events recorded yet")
                        .foregroundStyle(.secondary)
                }
            }

            // Legal section.
            Section("Legal") {
                NavigationLink {
                    LicenseView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }

                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            // About.
            Section("About") {
                LabeledContent("Version", value: "1.0.0 (Phase 1)")
                LabeledContent("Engine", value: "llama.cpp (upstream)")
                LabeledContent("Privacy", value: "All data stays on device")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshMemoryInfo()
        }
        .confirmationDialog(
            "Delete \(modelToDelete?.displayName ?? "Model")?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            ),
            presenting: modelToDelete
        ) { model in
            Button("Delete \(model.displayName)", role: .destructive) {
                Task { await deleteModel(model) }
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { model in
            Text("This will permanently remove \(model.displayName) from your device. You can re-download it later.")
        }
        .alert(
            "Deletion Failed",
            isPresented: Binding(
                get: { modelsViewModel.updateMessage != nil },
                set: { if !$0 { modelsViewModel.updateMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { modelsViewModel.updateMessage = nil }
        } message: {
            Text(modelsViewModel.updateMessage ?? "The model could not be removed.")
        }
    }

    // MARK: - Helpers

    private func formattedModelDiskUsage(_ model: AIModel) -> String {
        ModelManagerService.formattedDiskUsage(for: model)
    }

    private func formattedTotalDiskUsage() -> String {
        downloadManager.cachedStorageBreakdown.formattedTotal
    }

    @MainActor
    private func deleteModel(_ model: AIModel) async {
        do {
            try await modelsViewModel.deleteModel(model)
            storageRefreshID = UUID()
            modelToDelete = nil
        } catch {
            modelsViewModel.updateMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshMemoryInfo() async {
        appMemoryHeadroom = await memoryBudgeter.formattedAppMemoryHeadroom()
        totalRAM = await memoryBudgeter.formattedTotalRAM()
    }
}

#if DEBUG
/// Previews need a real `LoadSafetyStore`; build one in a throwaway temp directory
/// so the throwing application-support initializer is never hit in preview sandboxes.
private func previewLoadSafetyStore() -> LoadSafetyStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZiroEdge-SettingsPreview-\(UUID().uuidString)", isDirectory: true)
    do {
        return try LoadSafetyStore(directory: directory)
    } catch {
        fatalError("Preview LoadSafetyStore creation failed: \(error)")
    }
}
#endif

#Preview {
    NavigationStack {
        SettingsPage(
            lifecycleManager: ModelLifecycleManager(
                inferenceService: InferenceService(loadSafetyStore: previewLoadSafetyStore()),
                memoryBudgeter: MemoryBudgeter(),
                loadSafetyStore: previewLoadSafetyStore()
            ),
            inferenceService: InferenceService(loadSafetyStore: previewLoadSafetyStore()),
            memoryBudgeter: MemoryBudgeter(),
            downloadManager: DownloadManager(),
            modelsViewModel: ModelsViewModel(
                downloadManager: DownloadManager(),
                lifecycleManager: ModelLifecycleManager(
                    inferenceService: InferenceService(loadSafetyStore: previewLoadSafetyStore()),
                    memoryBudgeter: MemoryBudgeter(),
                    loadSafetyStore: previewLoadSafetyStore()
                ),
                offlineAvailabilityReport: OfflineAvailabilityReport(
                    timestamp: Date(),
                    models: [:],
                    diagnostics: []
                )
            )
        )
    }
}

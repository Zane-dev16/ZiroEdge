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

    // Delete hit target: scales with Dynamic Type (like ChatView's
    // composerControlSide) so the glyph never overflows its frame at
    // accessibility sizes, while meeting the 44×44 minimum at the default
    // size.
    @ScaledMetric(relativeTo: .body) private var deleteControlSide: CGFloat = 44

    /// Memory values (loaded async from actor).
    @State private var appMemoryHeadroom: String = "Loading..."
    @State private var totalRAM: String = "Loading..."

    private static let privacyPolicyURL = URL(string: "https://zane-dev16.github.io/ZiroEdge/privacy.html")
        ?? URL(fileURLWithPath: "/")

    /// Read from the bundle at runtime so this row can never drift from the
    /// project's marketing-version / build-number settings on a version bump.
    private static var displayVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    /// Models that are currently downloaded on disk.
    private var downloadedModels: [AIModel] {
        ModelRegistry.libraryModels.filter { model in
            let status = downloadManager.status(for: model)
            return status.isReady
        }
    }

    var body: some View {
        List {
            // Models — the consumer entry point (Settings → "Manage Models"
            // → Models is the shell's navigation IA; label is contract).
            Section {
                NavigationLink(value: ShellRoute.models) {
                    Label("Manage Models", systemImage: "arrow.down.circle")
                }
            }

            // Active model.
            Section {
                if let model = lifecycleManager.activeModel {
                    LabeledContent("Model", value: model.displayName)
                    LabeledContent("Size") {
                        Text(model.formattedSize)
                            .font(ZiroType.technical(.footnote))
                    }
                    LabeledContent("Type", value: model.modelType.rawValue.capitalized)

                    Button {
                        Task { await lifecycleManager.unloadCurrentModel(userInitiated: true) }
                    } label: {
                        Label("Unload Model", systemImage: "eject")
                    }
                } else {
                    Text("No model loaded")
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
            } header: {
                ZiroSectionHeader(title: "Active Model", systemImage: "cpu")
            }

            // Storage management.
            Section {
                if downloadedModels.isEmpty {
                    Text("No models downloaded")
                        .foregroundStyle(ZiroTheme.secondaryText)
                } else {
                    ForEach(downloadedModels) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                    .font(ZiroType.body)
                                    .foregroundStyle(ZiroTheme.primaryText)
                                Text(formattedModelDiskUsage(model))
                                    .font(ZiroType.technical(.caption))
                                    .foregroundStyle(ZiroTheme.secondaryText)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                modelToDelete = model
                            } label: {
                                Image(systemName: "trash")
                            }
                            // Confine the destructive action's hit area to
                            // the icon: the default borderless-in-List style
                            // makes the whole row tappable, so tapping the
                            // model name/usage caption opened the delete
                            // confirmation.
                            .buttonStyle(.borderless)
                            // Reserve a scaled 44pt square so the glyph-only
                            // hit target meets the minimum tappable-area
                            // standard and grows with Dynamic Type.
                            .frame(width: deleteControlSide, height: deleteControlSide)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Delete \(model.displayName)")
                        }
                    }
                }

                LabeledContent("Total Storage") {
                    Text(formattedTotalDiskUsage())
                        .font(ZiroType.technical(.footnote))
                        .id(storageRefreshID)
                }
            } header: {
                ZiroSectionHeader(title: "Storage", systemImage: "externaldrive")
            } footer: {
                Text("Models are stored locally on your device. Deleting a model frees disk space.")
            }

            Section {
                TextEditor(text: $defaultSystemPrompt)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Default model instructions")
                    // In-field placeholder: hints at the intended content
                    // without adding a row, and never intercepts taps into
                    // the editor. Inset matches the editor's own text inset
                    // so the hint sits where typed text would start.
                    .overlay(alignment: .topLeading) {
                        if defaultSystemPrompt.isEmpty {
                            Text("e.g. Always answer in bullet points")
                                .font(ZiroType.body)
                                .foregroundStyle(ZiroTheme.tertiaryText)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                ZiroSectionHeader(title: "Default Instructions", systemImage: "text.bubble")
            } footer: {
                Text("Applied to new conversations and used when a conversation has no custom instructions. Processing remains on device.")
            }

            // Memory section. RAM figures are engineering data — technical voice.
            Section {
                LabeledContent("App Memory Headroom") {
                    Text(appMemoryHeadroom)
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Total Device RAM") {
                    Text(totalRAM)
                        .font(ZiroType.technical(.footnote))
                }
            } header: {
                ZiroSectionHeader(title: "Memory", systemImage: "memorychip")
            } footer: {
                Text("App Memory Headroom is the memory iOS allowed ZiroEdge at the latest model load check, or a current sample before the first check. It is not unused device RAM.")
            }

            // Legal section.
            Section {
                NavigationLink {
                    LicenseView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }

                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                ZiroSectionHeader(title: "Legal", systemImage: "checkmark.shield")
            }

            // About.
            Section {
                LabeledContent("Version") {
                    Text(Self.displayVersion)
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Engine") {
                    Text("llama.cpp (upstream)")
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Privacy", value: "All data stays on device")
            } header: {
                ZiroSectionHeader(title: "About", systemImage: "info.circle")
            }

            // Developer diagnostics — the JSONL exports live at the bottom
            // of the page so consumer settings read first (spec §8.4). All
            // export identifiers are UI-test contract and unchanged.
            Section {
                #if DEBUG
                if let exportURL = MemoryDiagnosticRecorder.shared.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export Memory Calibration JSONL", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export-memory-calibration")
                }
                #endif

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
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
            } header: {
                ZiroSectionHeader(title: "Download Diagnostics", systemImage: "terminal")
            }
        }
        // Grouped-list surfaces sit on the warm paper canvas with raised
        // card rows (design spec §3.1) — never the cool system grouped
        // background.
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
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

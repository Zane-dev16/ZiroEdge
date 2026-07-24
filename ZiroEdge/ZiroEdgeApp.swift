// ZiroEdgeApp.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

@main
struct ZiroEdgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var runtime = AppRuntime()

    static let diagnosticLogURL: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-diagnostic.log")

    static func diagnosticLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let url = diagnosticLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await runtime.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background,
                          case .ready(let services) = runtime.state else { return }
                    Task {
                        let failures = await services.persistence.flushPendingWrites()
                        if let failure = failures.values.first {
                            await MainActor.run {
                                services.chatViewModel.presentBackgroundPersistenceFailure(failure)
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch runtime.state {
        case .loading(let attempt):
            ProgressView("Opening local history (attempt \(attempt))…")
        case .ready(let services):
            MainView(
                chatViewModel: services.chatViewModel,
                conversationListViewModel: services.conversationListViewModel,
                lifecycleManager: services.lifecycleManager,
                inferenceService: services.inferenceService,
                memoryBudgeter: services.memoryBudgeter,
                downloadManager: services.downloadManager,
                modelsViewModel: services.modelsViewModel,
                onboardingManager: OnboardingManager()
            )
            .task {
                // Unit-test hosts execute the app entry point; avoid racing test-owned fixtures.
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                ModelMigrationService.migrateIfNeeded()
                ModelManagerService.ensureModelsDirectory()
                await services.conversationListViewModel.loadConversations()
                if CommandLine.arguments.contains("--uitesting") {
                    await services.lifecycleManager.autoLoadFirstModel()
                }
            }
        case .failed(let failure):
            StoreRecoveryView(
                failure: failure,
                diagnosticsURL: runtime.diagnosticsURL,
                onRetry: runtime.retry,
                onExportDiagnostics: runtime.exportDiagnostics,
                onReset: runtime.prepareReset
            )
        case .quarantining:
            ProgressView("Copying local history for recovery…")
        case .awaitingResetConfirmation(let artifact):
            VStack(spacing: 20) {
                Image(systemName: "externaldrive.badge.checkmark").font(.largeTitle)
                Text("Recovery Copy Created").font(.title2.bold())
                Text("A byte-for-byte recovery copy was created. Resetting will now remove the original local history and create a new store.")
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", action: runtime.cancelReset)
                    Button("Confirm Reset", role: .destructive) { runtime.confirmReset(artifact) }
                }
            }
            .padding()
        case .resetting:
            ProgressView("Resetting local history…")
        }
    }
}

// MARK: - Main View

/// The root view. Uses NavigationSplitView on iPad/macOS, NavigationStack on iPhone.
struct MainView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @ObservedObject var conversationListViewModel: ConversationListViewModel
    @ObservedObject var lifecycleManager: ModelLifecycleManager
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter
    let downloadManager: DownloadManager
    let modelsViewModel: ModelsViewModel
    @ObservedObject var onboardingManager: OnboardingManager

    @State private var showSettings = false
    @State private var showModelsFromPicker = false

    /// Whether any models are currently downloaded.
    private var hasModels: Bool {
        ModelRegistry.allModels.contains { downloadManager.status(for: $0).isReady }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: conversationListViewModel,
                onNewConversation: {
                    Task {
                        // Load the model before creating conversation.
                        print("[NEWCONV] Loading model...")
                        await lifecycleManager.autoLoadFirstModel()
                        print("[NEWCONV] After autoLoad: isLoaded=\(lifecycleManager.isModelLoaded), state=\(lifecycleManager.currentState)")
                        
                        chatViewModel.autoSelectModel()
                        if chatViewModel.needsModelRedirect {
                            showModelsFromPicker = true
                        } else if let model = chatViewModel.selectedModel {
                            if let id = await conversationListViewModel.createConversation(
                                modelID: model.id
                            ) {
                                await chatViewModel.loadConversation(id)
                                print("[NEWCONV] Conversation \(id) created")
                            }
                        }
                    }
                },
                onSelectConversation: { id in
                    conversationListViewModel.selectConversation(id)
                    Task { await chatViewModel.loadConversation(id) }
                }
            )
        } detail: {
            if conversationListViewModel.selectedConversationID != nil {
                ChatView(viewModel: chatViewModel)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { showSettings = true }) {
                                Image(systemName: "gear")
                            }
                        }
                    }
            } else {
                // No conversation selected — show welcome screen.
                WelcomeView(onNewConversation: {
                    Task {
                        chatViewModel.autoSelectModel()
                        if chatViewModel.needsModelRedirect {
                            showModelsFromPicker = true
                        } else if let model = chatViewModel.selectedModel {
                            if let id = await conversationListViewModel.createConversation(
                                modelID: model.id
                            ) {
                                await chatViewModel.loadConversation(id)
                            }
                        }
                    }
                }, hasModels: hasModels)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter,
                downloadManager: downloadManager,
                modelsViewModel: modelsViewModel
            )
        }
        .alert("Memory Warning", isPresented: $lifecycleManager.showMemoryWarning) {
            Button("Reload Model") {
                Task { await lifecycleManager.reloadEvictedModel() }
            }
            Button("Dismiss", role: .cancel) {
                lifecycleManager.dismissMemoryWarning()
            }
        } message: {
            Text("The model was unloaded due to memory pressure. Tap Reload to continue chatting.")
        }
        .sheet(isPresented: $showModelsFromPicker) {
            NavigationStack {
                ModelsView(viewModel: modelsViewModel)
                    .navigationTitle("Download a Model")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Done") { showModelsFromPicker = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $onboardingManager.showOnboarding) {
            OnboardingView(isPresented: $onboardingManager.showOnboarding)
        }
    }
}

// MARK: - Welcome View

/// Shown when no conversation is selected.
struct WelcomeView: View {
    let onNewConversation: () -> Void
    let hasModels: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: hasModels ? "brain.head.profile" : "arrow.down.circle.dotted")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text(hasModels ? "Welcome to ZiroEdge" : "Download a Model")
                .font(.largeTitle.bold())

            Text(hasModels
                ? "Your private AI assistant. Everything runs on your device — no data ever leaves your phone."
                : "You need a model to start chatting. Download one to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: onNewConversation) {
                Label(hasModels ? "Start a Conversation" : "Download a Model", systemImage: hasModels ? "plus.circle.fill" : "arrow.down.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings View

/// Settings view with storage management, memory info, license attribution, and privacy policy.
struct SettingsView: View {
    @ObservedObject var lifecycleManager: ModelLifecycleManager
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter
    let downloadManager: DownloadManager
    @ObservedObject var modelsViewModel: ModelsViewModel

    @Environment(\.dismiss) private var dismiss

    /// Local state to trigger refresh after deletion.
    @State private var storageRefreshID = UUID()

    /// Confirmation dialog state for model deletion.
    @State private var modelToDelete: AIModel?

    /// Memory values (loaded async from actor).
    @State private var availableRAM: String = "Loading..."
    @State private var totalRAM: String = "Loading..."

    private static let privacyPolicyURL = URL(string: "https://ziroedge.app/privacy")
        ?? URL(fileURLWithPath: "/")

    /// Models that are currently downloaded on disk.
    private var downloadedModels: [AIModel] {
        ModelRegistry.allModels.filter { model in
            let status = downloadManager.status(for: model)
            return status.isReady
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Models section.
                Section {
                    NavigationLink {
                        ModelsView(viewModel: modelsViewModel)
                    } label: {
                        Label("Manage Models", systemImage: "arrow.down.circle")
                    }
                }

                // Active model section.
                Section("Active Model") {
                    if let model = lifecycleManager.activeModel {
                        LabeledContent("Model", value: model.displayName)
                        LabeledContent("Size", value: model.formattedSize)
                        LabeledContent("Type", value: model.modelType.rawValue.capitalized)

                        Button("Unload Model", role: .destructive) {
                            Task { await lifecycleManager.unloadCurrentModel() }
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

                // Memory section.
                Section("Memory") {
                    LabeledContent("Available RAM", value: availableRAM)
                    LabeledContent("Total Device RAM", value: totalRAM)
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
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
        }
    }

    // MARK: - Helpers

    private func formattedModelDiskUsage(_ model: AIModel) -> String {
        ModelManagerService.formattedDiskUsage(for: model)
    }

    private func formattedTotalDiskUsage() -> String {
        ModelManagerService.formattedDiskUsage()
    }

    @MainActor
    private func deleteModel(_ model: AIModel) async {
        // Never remove an mmap-backed file until the engine has finished unloading it.
        if lifecycleManager.activeModel?.id == model.id {
            await lifecycleManager.unloadCurrentModel()
        }
        downloadManager.deleteModel(model)
        storageRefreshID = UUID()
        modelToDelete = nil
    }

    @MainActor
    private func refreshMemoryInfo() async {
        availableRAM = await memoryBudgeter.formattedAvailableRAM()
        totalRAM = await memoryBudgeter.formattedTotalRAM()
    }
}

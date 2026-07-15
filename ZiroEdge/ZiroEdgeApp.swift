// ZiroEdgeApp.swift
// ZiroEdge — Privacy-first local AI assistant
//
// App entry point. Initializes Core Data, creates shared services,
// and recovers any incomplete streams from the previous session.

import SwiftUI

@main
struct ZiroEdgeApp: App {

    // MARK: - Shared Services

    /// Core Data persistence — actor-isolated background writer.
    @State private var persistence: PersistenceController

    /// LLM inference service.
    @State private var inferenceService: InferenceService

    /// Memory budget checker.
    @State private var memoryBudgeter: MemoryBudgeter

    /// Model lifecycle manager.
    @State private var lifecycleManager: ModelLifecycleManager

    /// Chat session actor.
    @State private var sessionActor: ChatSessionActor

    /// ViewModels.
    @State private var chatViewModel: ChatViewModel
    @State private var conversationListViewModel: ConversationListViewModel

    /// Download manager.
    @State private var downloadManager: DownloadManager

    /// Models page view model.
    @State private var modelsViewModel: ModelsViewModel

    /// Onboarding manager.
    @State private var onboardingManager = OnboardingManager()

    // MARK: - Init

    init() {
        let persistence = PersistenceController()
        let inferenceService = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycleManager = ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter
        )
        let sessionActor = ChatSessionActor(
            inferenceService: inferenceService,
            persistence: persistence
        )
        let conversationListViewModel = ConversationListViewModel(persistence: persistence)
        let downloadManager = DownloadManager()
        let chatViewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inferenceService,
            sessionActor: sessionActor,
            lifecycleManager: lifecycleManager,
            downloadStatusProvider: downloadManager
        )
        chatViewModel.conversationListViewModel = conversationListViewModel
        let modelsViewModel = ModelsViewModel(
            downloadManager: downloadManager,
            lifecycleManager: lifecycleManager
        )

        _persistence = State(initialValue: persistence)
        _inferenceService = State(initialValue: inferenceService)
        _memoryBudgeter = State(initialValue: memoryBudgeter)
        _lifecycleManager = State(initialValue: lifecycleManager)
        _sessionActor = State(initialValue: sessionActor)
        _chatViewModel = State(initialValue: chatViewModel)
        _conversationListViewModel = State(initialValue: conversationListViewModel)
        _downloadManager = State(initialValue: downloadManager)
        _modelsViewModel = State(initialValue: modelsViewModel)
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            MainView(
                chatViewModel: chatViewModel,
                conversationListViewModel: conversationListViewModel,
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter,
                downloadManager: downloadManager,
                modelsViewModel: modelsViewModel,
                onboardingManager: onboardingManager
            )
            .task {
                // Recover any incomplete streams from the previous session.
                await persistence.recoverIncompleteStreams()

                // Ensure models directory exists.
                ModelManagerService.ensureModelsDirectory()

                // UI testing: auto-load the first available model.
                if CommandLine.arguments.contains("--uitesting") {
                    await lifecycleManager.autoLoadFirstModel()
                }
            }
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
                        chatViewModel.autoSelectModel()
                        if chatViewModel.needsModelRedirect {
                            showModelsFromPicker = true
                        } else if let model = chatViewModel.selectedModel {
                            let id = await conversationListViewModel.createConversation(
                                modelID: model.id
                            )
                            await chatViewModel.loadConversation(id)
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
                            let id = await conversationListViewModel.createConversation(
                                modelID: model.id
                            )
                            await chatViewModel.loadConversation(id)
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
                            lifecycleManager.unloadCurrentModel()
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

                    Link(destination: URL(string: "https://ziroedge.app/privacy")!) {
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
                    deleteModel(model)
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

    private func deleteModel(_ model: AIModel) {
        // Unload if currently active.
        if lifecycleManager.activeModel?.id == model.id {
            lifecycleManager.unloadCurrentModel()
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

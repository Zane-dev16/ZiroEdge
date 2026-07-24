// ZiroEdgeApp.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

@main
struct ZiroEdgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            StoreOperationProgressView(
                symbol: "lock.open.display",
                title: "Opening local history",
                message: attempt > 1
                    ? "Retry attempt \(attempt). Large histories can take a moment to verify."
                    : "Preparing your private conversations on this device."
            )
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
            .overlay(alignment: .top) {
                if let message = runtime.postResetMessage {
                    ZiroStatusBanner(
                        icon: "checkmark.circle.fill",
                        message: message,
                        tint: .green
                    )
                    .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: runtime.postResetMessage)
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
                diagnosticsExportError: runtime.diagnosticsExportError,
                onRetry: runtime.retry,
                onExportDiagnostics: runtime.exportDiagnostics,
                onReset: runtime.prepareReset
            )
        case .quarantining:
            StoreOperationProgressView(
                symbol: "doc.on.doc.fill",
                title: "Creating a recovery copy",
                message: "Copying and verifying local history before any changes are made."
            )
        case .awaitingResetConfirmation(let artifact):
            StoreResetConfirmationView(
                artifact: artifact,
                onCancel: runtime.cancelReset,
                onConfirm: { runtime.confirmReset(artifact) }
            )
        case .resetting:
            StoreOperationProgressView(
                symbol: "arrow.clockwise.circle.fill",
                title: "Starting fresh",
                message: "Preserving the recovery copy and creating a clean local history."
            )
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

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSettings = false
    @State private var showModelsFromPicker = false
    @State private var compactPath: [UUID] = []

    private var hasModels: Bool {
        ModelRegistry.allModels.contains { downloadManager.status(for: $0).isReady }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactNavigation
            } else {
                splitNavigation
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
        .alert("Model Unloaded", isPresented: $lifecycleManager.showMemoryWarning) {
            Button("Reload Model") { Task { await lifecycleManager.reloadEvictedModel() } }
            Button("Not Now", role: .cancel) { lifecycleManager.dismissMemoryWarning() }
        } message: {
            Text("ZiroEdge released the model to protect your device under memory pressure. Reload it when you are ready to continue.")
        }
        .alert("Model Needs More Memory", isPresented: $lifecycleManager.showInsufficientMemoryWarning) {
            Button("Choose Another Model") { showModelsFromPicker = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(lifecycleManager.insufficientMemoryMessage ?? "This model cannot be loaded safely on the available memory.")
        }
        .sheet(isPresented: $showModelsFromPicker) {
            NavigationStack {
                ModelsView(viewModel: modelsViewModel)
                    .navigationTitle("Choose a Model")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showModelsFromPicker = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $onboardingManager.showOnboarding) {
            OnboardingView(isPresented: $onboardingManager.showOnboarding)
        }
        .onChange(of: conversationListViewModel.selectedConversationID) { _, selection in
            if selection == nil {
                chatViewModel.clearActiveConversation()
                compactPath.removeAll()
            }
        }
        .onChange(of: chatViewModel.needsModelRedirect) { _, needsRedirect in
            if needsRedirect {
                showModelsFromPicker = true
                chatViewModel.needsModelRedirect = false
            }
        }
    }

    private var compactNavigation: some View {
        NavigationStack(path: $compactPath) {
            sidebar(navigateInCompactLayout: true)
                .toolbar { settingsToolbar }
                .navigationDestination(for: UUID.self) { _ in
                    ChatView(viewModel: chatViewModel)
                        .toolbar { settingsToolbar }
                }
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            sidebar(navigateInCompactLayout: false)
                .toolbar { settingsToolbar }
        } detail: {
            if conversationListViewModel.selectedConversationID != nil {
                ChatView(viewModel: chatViewModel)
                    .toolbar { settingsToolbar }
            } else {
                WelcomeView(
                    onNewConversation: { startNewConversation(navigateInCompactLayout: false) },
                    hasModels: hasModels
                )
                .toolbar { settingsToolbar }
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
    }

    private func sidebar(navigateInCompactLayout: Bool) -> some View {
        SidebarView(
            viewModel: conversationListViewModel,
            onNewConversation: { startNewConversation(navigateInCompactLayout: navigateInCompactLayout) },
            onSelectConversation: { id in
                conversationListViewModel.selectConversation(id)
                if navigateInCompactLayout { compactPath = [id] }
                Task { await chatViewModel.loadConversation(id) }
            }
        )
    }

    private func startNewConversation(navigateInCompactLayout: Bool) {
        Task {
            chatViewModel.autoSelectModel()
            guard !chatViewModel.needsModelRedirect, let model = chatViewModel.selectedModel else {
                showModelsFromPicker = true
                return
            }
            await chatViewModel.selectModel(model)
            guard lifecycleManager.activeModel?.id == model.id else { return }
            guard let id = await conversationListViewModel.createConversation(modelID: model.id) else { return }
            if navigateInCompactLayout { compactPath = [id] }
            await chatViewModel.loadConversation(id)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
    }
}

// MARK: - Welcome View

/// Shown when no conversation is selected.
struct WelcomeView: View {
    let onNewConversation: () -> Void
    let hasModels: Bool

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.xLarge) {
            ZiroHero(
                symbol: hasModels ? "brain.head.profile" : "arrow.down.circle.dotted",
                title: hasModels ? "Private AI, ready when you are" : "Choose your local model",
                message: hasModels
                    ? "Start a focused conversation. Everything you write and every response stays on this device."
                    : "Download a model once, then chat privately without an internet connection.",
                tint: hasModels ? .accentColor : .green
            )

            Button(action: onNewConversation) {
                Label(
                    hasModels ? "New Conversation" : "Browse Models",
                    systemImage: hasModels ? "square.and.pencil" : "arrow.down.circle.fill"
                )
            }
            .buttonStyle(ZiroPrimaryButtonStyle())
            .frame(maxWidth: 320)
            .accessibilityHint(hasModels ? "Creates a new private chat" : "Opens the model catalog")

            Label("No cloud account required", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(ZiroTheme.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZiroTheme.pageBackground)
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
    @AppStorage(ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    private var defaultSystemPrompt = ""

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

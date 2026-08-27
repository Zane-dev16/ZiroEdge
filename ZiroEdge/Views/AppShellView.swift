// AppShellView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Root application surface shown once startup reaches `.ready`.
// One detail stack rooted at the chat surface is shared by both size
// classes; only the sidebar presentation differs:
//   · Compact width  — chat IS the base layer. The conversation list opens
//     as a drawer sheet from the toolbar button; conversations swap in place.
//   · Regular width  — NavigationSplitView with a persistent sidebar column;
//     the detail column hosts the same stack so Settings/Models pages stay
//     one pop away from the chat.

import SwiftUI

/// A pushed destination reachable from the sidebar or from other pages.
enum ShellRoute: Hashable {
    case models
    case modelDetail(id: String)
    case settings
}

struct AppShellView: View {
    let services: RuntimeServices
    @ObservedObject var onboardingManager: OnboardingManager

    // Explicit observed objects so alert bindings and toolbar content stay
    // reactive; all values alias the same live services bundle.
    @ObservedObject var chatViewModel: ChatViewModel
    @ObservedObject var conversationListViewModel: ConversationListViewModel
    @ObservedObject var lifecycleManager: ModelLifecycleManager
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter
    let downloadManager: DownloadManager
    let modelsViewModel: ModelsViewModel

    init(services: RuntimeServices, onboardingManager: OnboardingManager) {
        self.services = services
        self.onboardingManager = onboardingManager
        self.chatViewModel = services.chatViewModel
        self.conversationListViewModel = services.conversationListViewModel
        self.lifecycleManager = services.lifecycleManager
        self.inferenceService = services.inferenceService
        self.memoryBudgeter = services.memoryBudgeter
        self.downloadManager = services.downloadManager
        self.modelsViewModel = services.modelsViewModel
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var detailRoutes: [ShellRoute] = []
    @State private var showSidebarDrawer = false
#if DEBUG
    @State private var memoryDiagnosticWorkloadState = "workload-starting"
#endif

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactShell
            } else {
                splitShell
            }
        }
        .alert("Model Unloaded", isPresented: $lifecycleManager.showMemoryWarning) {
            Button("OK", role: .cancel) { lifecycleManager.dismissMemoryWarning() }
        } message: {
            Text("ZiroEdge released the model to protect your device under memory pressure. Reload it when you are ready to continue.")
        }
        .alert("Model Load Failed", isPresented: $lifecycleManager.showLoadFailure) {
            Button("Choose Another Model") { openShellRoute(.models) }
            Button("OK", role: .cancel) {}
        } message: {
            Text(lifecycleManager.loadFailureMessage ?? "The local model could not be loaded.")
        }
        .alert("Model Needs More Memory", isPresented: $lifecycleManager.showInsufficientMemoryWarning) {
            Button("Choose Another Model") { openShellRoute(.models) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(lifecycleManager.insufficientMemoryMessage ?? "This model cannot be loaded safely on the available memory.")
        }
        .fullScreenCover(isPresented: $onboardingManager.showOnboarding) {
            OnboardingView(isPresented: $onboardingManager.showOnboarding)
        }
        .onChange(of: conversationListViewModel.selectedConversationID) { _, selection in
            if selection == nil {
                // Deselection (New Conversation, deleting the open chat) always
                // lands on an unsaved draft chat.
                chatViewModel.beginNewDraft()
            } else {
                // Selection always wins over any routed page: return to chat.
                detailRoutes.removeAll()
            }
        }
        .onChange(of: chatViewModel.needsModelRedirect) { _, needsRedirect in
            if needsRedirect {
                openShellRoute(.models)
                chatViewModel.needsModelRedirect = false
            }
        }
        .task {
            // Post-ready setup that does not gate the first frame:
            // migration bookkeeping and sidebar hydration run here, while the
            // model itself loads lazily once it is actually needed.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            let migrationResult = ModelMigrationService.migrateIfNeeded()
            if case .migrated = migrationResult {
                // DownloadManager snapshotted downloadStatuses during init,
                // before migration moved legacy files into managed storage;
                // without this refresh migrated models read as Not
                // Downloaded for the whole session.
                downloadManager.updateStatusesFromDisk()
            }
            ModelManagerService.ensureModelsDirectory()
            await conversationListViewModel.loadConversations()
            if CommandLine.arguments.contains("--uitesting") {
                await lifecycleManager.autoLoadFirstModel()
            }
#if DEBUG
            if CommandLine.arguments.contains("--uitesting-sendtest"),
               let model = lifecycleManager.activeModel {
                await chatViewModel.selectModel(model)
                if let id = await conversationListViewModel.createConversation(
                    modelID: model.id,
                    title: "UITest Send Test"
                ) {
                    await chatViewModel.loadConversation(id)
                    chatViewModel.inputText = "Reply with exactly OK."
                    await chatViewModel.sendMessage()
                }
            }

            // E2E: drive the FULL HuggingFace import flow headlessly.
            // Mirrors --uitesting-sendtest style; skipped under XCTest hosts.
            if CommandLine.arguments.contains("--e2e-hf-import") {
                _ = HFImportE2ERunner.run(services: services, arguments: CommandLine.arguments)
            }
#endif
        }
#if DEBUG
        .task {
            guard MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled else { return }
            for _ in 0..<240 where !lifecycleManager.isModelLoaded {
                if lifecycleManager.currentState == .loadFailed { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard lifecycleManager.isModelLoaded else {
                memoryDiagnosticWorkloadState = "workload-failed-initial-load"
                return
            }
            memoryDiagnosticWorkloadState = await MemoryDiagnosticWorkload.run(
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService
            ) { state in
                memoryDiagnosticWorkloadState = state
            }
        }
        .overlay(alignment: .bottom) {
            if MemoryDiagnosticRecorder.shared.isEnabled {
                Text(memoryDiagnosticState)
                    .font(.caption2)
                    .accessibilityIdentifier("memory-diagnostic-state")
                    .padding(4)
            }
        }
#endif
    }

    // MARK: - Layouts

    /// iPhone: chat is the root; the sidebar opens as a drawer sheet.
    private var compactShell: some View {
        NavigationStack(path: $detailRoutes) {
            ChatView(
                viewModel: chatViewModel,
                showsSidebarToggle: true,
                onNavigateToRoute: openShellRoute,
                onOpenSidebar: { showSidebarDrawer = true }
            )
            .navigationDestination(for: ShellRoute.self) { route in
                routeDestination(route)
            }
        }
        .sheet(isPresented: $showSidebarDrawer) {
            drawerSidebar
        }
    }

    /// iPad: persistent sidebar column plus the shared chat-rooted stack.
    private var splitShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $detailRoutes) {
                ChatView(viewModel: chatViewModel, onNavigateToRoute: openShellRoute)
                    .navigationDestination(for: ShellRoute.self) { route in
                        routeDestination(route)
                    }
            }
        }
        // Keep the conversation list and active chat visible together on iPad.
        // `.prominentDetail` collapses the sidebar in portrait, obscuring the
        // app's primary split-view navigation.
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        SidebarView(
            viewModel: conversationListViewModel,
            onNewConversation: handleNewConversation,
            onSelectConversation: selectConversation,
            onOpenRoute: openShellRoute
        )
    }

    private var drawerSidebar: some View {
        NavigationStack {
            sidebar
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Routes

    @ViewBuilder
    private func routeDestination(_ route: ShellRoute) -> some View {
        switch route {
        case .models:
            ModelsView(viewModel: modelsViewModel, onStartChatting: startChatting(with:))
        case .settings:
            SettingsPage(
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter,
                downloadManager: downloadManager,
                modelsViewModel: modelsViewModel
            )
        case .modelDetail(let id):
            if let model = resolvedDetailModel(for: id) {
                ModelDetailView(model: model, viewModel: modelsViewModel, onStartChatting: startChatting(with:))
            } else {
                ContentUnavailableView(
                    "Model Not Found",
                    systemImage: "questionmark.folder",
                    description: Text("This model profile is no longer available on this device.")
                )
            }
        }
    }

    private func resolvedDetailModel(for id: String) -> AIModel? {
        ModelRegistry.model(for: id) ?? modelsViewModel.importedModels.first { $0.id == id }
    }

    /// Dismiss the drawer first so pushes land over the chat root.
    private func openShellRoute(_ route: ShellRoute) {
        showSidebarDrawer = false
        detailRoutes.append(route)
    }

    private func selectConversation(_ id: UUID) {
        conversationListViewModel.selectConversation(id)
        showSidebarDrawer = false
        Task { await chatViewModel.loadConversation(id) }
    }

    /// New Conversation shows an unsaved draft immediately; model loading is
    /// already handled by the deferred loader (or persists untouched when
    /// loaded/failed states exist).
    private func handleNewConversation() {
        showSidebarDrawer = false
        chatViewModel.beginNewDraft()
    }

    /// Import wizard Done page "Start Chatting": pop back to the chat root,
    /// load the newly imported model, then show a fresh draft chat. Loading
    /// first means `beginNewDraft` won't spawn a redundant deferred load for
    /// the auto candidate.
    private func startChatting(with model: AIModel) {
        detailRoutes.removeAll()
        Task {
            await chatViewModel.selectModel(model)
            chatViewModel.beginNewDraft()
        }
    }

#if DEBUG
    private var memoryDiagnosticState: String {
        let targetID = MemoryDiagnosticRecorder.targetModelID
        guard let target = ModelRegistry.model(for: targetID),
              ModelManagerService.isFullyDownloaded(target) else {
            return "missing-\(targetID)"
        }
        if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled {
            return memoryDiagnosticWorkloadState
        }
        if lifecycleManager.activeModel?.id == targetID, lifecycleManager.currentState == .loaded {
            return "loaded-\(targetID)"
        }
        if lifecycleManager.showInsufficientMemoryWarning {
            return "blocked-\(targetID)"
        }
        return "\(lifecycleManager.currentState)-\(targetID)"
    }
#endif
}

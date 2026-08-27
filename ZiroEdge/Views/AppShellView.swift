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
                // lands on an unsaved draft chat. The draft is the base layer
                // (plan §A.2/§A.4), so any routed Models/Settings page is
                // popped too — selection always wins over routed pages.
                detailRoutes.removeAll()
                chatViewModel.beginNewDraft()
            } else {
                // Selection always wins over any routed page: return to chat.
                detailRoutes.removeAll()
                // Plan §B.4 routes conversation loading through this handler,
                // so selection writes that bypass the sidebar row's tap
                // gesture (full-keyboard/VoiceOver List(selection:) tag
                // activation, programmatic writes) still load the transcript.
                // loadGeneration dedupes this against the tap closure's own
                // load; the guard keeps already-active selections (draft
                // materialization) single-load. The --uitesting-sendtest
                // bootstrap reuses this selection-driven load instead of
                // starting its own.
                if let selection, selection != chatViewModel.activeConversationID {
                    Task { await chatViewModel.loadConversation(selection) }
                }
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
                // The chat surface's appear-time deferred kick ran before this
                // task (child onAppear precedes the ancestor task), so on
                // legacy installs it saw no managed artifacts yet and parked
                // the chat on .needsDownload. Migration has just made models
                // available — re-kick the idempotent deferred loader so the
                // chat converges with a fresh install. Flag choreographies
                // drive their own loads below and are left alone.
                if !CommandLine.arguments.contains("--uitesting"),
                   !CommandLine.arguments.contains("--e2e-hf-import") {
                    chatViewModel.startDeferredModelLoadIfNeeded()
                }
            }
            ModelManagerService.ensureModelsDirectory()
            await conversationListViewModel.loadConversations()
            if CommandLine.arguments.contains("--uitesting") {
                await lifecycleManager.autoLoadFirstModel()
            }
#if DEBUG
            if CommandLine.arguments.contains("--uitesting-sendtest") {
                // The deferred autoload kicked from ChatView.onAppear may have
                // claimed the load before this task ran (child onAppear
                // precedes the ancestor task), which turns the --uitesting
                // autoLoad above into a guarded no-op while the model is
                // still loading. Await residency — bounded, with an early
                // exit on terminal failure — before reading activeModel so
                // this bootstrap is order-independent. A device with no
                // usable model times out here and the hook simply stays
                // skipped, matching the pre-overhaul failure mode.
                for _ in 0..<480 where lifecycleManager.activeModel == nil {
                    if lifecycleManager.currentState == .loadFailed { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let model = lifecycleManager.activeModel {
                    await chatViewModel.selectModel(model)
                    if let id = await conversationListViewModel.createConversation(
                        modelID: model.id,
                        title: "UITest Send Test"
                    ) {
                        // The selection write above drives the transcript load
                        // through the onChange(selectedConversationID) handler.
                        // This bootstrap used to also call loadConversation
                        // directly; the two loads raced on loadGeneration — the
                        // loser returned early while the winner was still
                        // fetching, leaving isLoadingConversation set, and
                        // sendMessage's precondition guard silently dropped the
                        // seeded send. Reuse the selection-driven load: await
                        // quiescence (bounded, matching the model-load wait)
                        // before seeding and sending.
                        for _ in 0..<480
                        where chatViewModel.activeConversationID != id
                            || chatViewModel.isLoadingConversation {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        if chatViewModel.activeConversationID == id,
                           !chatViewModel.isLoadingConversation {
                            chatViewModel.inputText = "Reply with exactly OK."
                            await chatViewModel.sendMessage()
                        }
                    }
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

    /// Dismiss the drawer first so pushes land over the chat root. A route
    /// already on the stack pops back to its existing page instead of pushing
    /// a duplicate: the iPad sidebar is persistent, so its Models/Settings
    /// rows stay tappable while that page is open (the "Choose Another Model"
    /// alert actions reach here through the same path).
    private func openShellRoute(_ route: ShellRoute) {
        showSidebarDrawer = false
        if let existingIndex = detailRoutes.firstIndex(of: route) {
            detailRoutes.removeSubrange(detailRoutes.index(after: existingIndex)...)
        } else {
            detailRoutes.append(route)
        }
    }

    /// Sidebar row tap. Routed pages are popped unconditionally (mirroring
    /// handleNewConversation and the onChange nil branch): re-tapping the
    /// already-active conversation never fires onChange(of:
    /// selectedConversationID), yet selection must still win over a pushed
    /// Models/Settings page (plan §A.4/§7).
    private func selectConversation(_ id: UUID) {
        conversationListViewModel.selectConversation(id)
        detailRoutes.removeAll()
        showSidebarDrawer = false
        Task { await chatViewModel.loadConversation(id) }
    }

    /// New Conversation shows an unsaved draft immediately; model loading is
    /// already handled by the deferred loader (or persists untouched when
    /// loaded/failed states exist). The draft is the base layer (plan
    /// §A.2/§A.4), so routed pages are popped just like the onChange nil
    /// branch — the draft chat surface must be the visible one.
    private func handleNewConversation() {
        showSidebarDrawer = false
        detailRoutes.removeAll()
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

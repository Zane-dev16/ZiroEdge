// AppShellView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Root application surface shown once startup reaches `.ready`.
// One detail stack rooted at the chat surface is shared by both size
// classes; only the sidebar presentation differs:
//   · Compact width  — chat IS the base layer and stays mounted. The
//     conversation list slides in from the leading edge as a slide-over
//     panel (scrim + panel) from the toolbar button; conversations swap
//     in place.
//   · Regular width  — NavigationSplitView with a persistent sidebar column;
//     the detail column hosts the same stack so Settings/Models pages stay
//     one pop away from the chat.

import SwiftUI

/// A pushed destination reachable from the sidebar or from other pages.
enum ShellRoute: Hashable {
    case chats
    case models
    case modelDetail(id: String)
    case settings
    case license
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailRoutes: [ShellRoute] = []
    @State private var showSidebarDrawer = false
    /// Deferred "Start Chatting" target while the first-use experimental-consent
    /// alert is up (see startChatting): beginNewDraft stays deferred until the
    /// consent resolves so the chat never parks on .needsDownload behind the alert.
    @State private var pendingStartChattingModel: AIModel?
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
        .onAppear {
            // Drop/renominate the chat's stale selection when its model is
            // deleted (Models/Settings/import-detail all funnel through
            // ModelsViewModel.deleteModel). Without this the pill keeps a
            // ghost name with a silently disabled composer and no hint.
            // autoSelectModel renominates (or parks needsModelRedirect when
            // nothing remains); the extra refresh covers its nil-branch
            // early return so the phase projects .needsDownload immediately.
            modelsViewModel.onDidDeleteModel = { deleted in
                guard chatViewModel.selectedModel?.id == deleted.id else { return }
                chatViewModel.autoSelectModel()
                chatViewModel.refreshModelLoadPhase()
            }
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
                // Keyboard/VoiceOver List(selection:) activation writes
                // selectedConversationID without touching the row tap closure,
                // so the slide-over must dismiss here too (mirrors
                // selectConversation) or the loaded chat stays hidden behind
                // the open slide-over on iPhone.
                detailRoutes.removeAll()
                setSidebarDrawer(false)
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
        .onChange(of: chatViewModel.showingExperimentalConsent) { _, showing in
            if !showing {
                resolvePendingStartChatting()
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
#if DEBUG
                // Explicit hermetic scenarios (--uitesting-hermetic-needs-download
                // / --uitesting-hermetic-failed-load) drive their own deterministic
                // choreography from ChatView's deferred loader; the shell autoload
                // would double-attempt and could resurface the load-failure alert
                // after the inline retry row already suppressed it.
                if !HermeticUITestRuntime.hasExplicitScenario {
                    await lifecycleManager.autoLoadFirstModel()
                }
#else
                await lifecycleManager.autoLoadFirstModel()
#endif
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
                    .font(ZiroType.micro)
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .accessibilityIdentifier("memory-diagnostic-state")
                    .padding(ZiroTheme.Spacing.xSmall)
            }
        }
#endif
    }

    // MARK: - Layouts

    /// iPhone: chat is the root and stays mounted as the base layer; the
    /// sidebar slides in from the leading edge as a slide-over (scrim +
    /// panel) hosting the same `sidebar` content as the iPad column.
    private var compactShell: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                NavigationStack(path: $detailRoutes) {
                    ChatView(
                        viewModel: chatViewModel,
                        showsSidebarToggle: true,
                        onNavigateToRoute: openShellRoute,
                        onOpenSidebar: { setSidebarDrawer(true) },
                        onDeleteConversation: deleteActiveConversation
                    )
                    .navigationDestination(for: ShellRoute.self) { route in
                        routeDestination(route)
                    }
                }

                if showSidebarDrawer {
                    slideOverScrim
                    slideOverPanel(width: slideOverWidth(containerWidth: geometry.size.width))
                }
            }
            .ziroAnimation(ZiroMotion.appear, value: showSidebarDrawer)
        }
    }

    /// iPad: persistent sidebar column plus the shared chat-rooted stack.
    private var splitShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $detailRoutes) {
                ChatView(
                    viewModel: chatViewModel,
                    onNavigateToRoute: openShellRoute,
                    onDeleteConversation: deleteActiveConversation
                )
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
            onOpenRoute: openShellRoute,
            onDeleteConversation: handleSidebarDelete
        )
    }

    // MARK: - Routes

    @ViewBuilder
    private func routeDestination(_ route: ShellRoute) -> some View {
        switch route {
        case .chats:
            ChatsView(
                viewModel: conversationListViewModel,
                onNewConversation: handleNewConversation,
                onSelectConversation: selectConversation,
                onDeleteConversation: handleSidebarDelete
            )
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
        case .license:
            LicenseView()
        }
    }

    private func resolvedDetailModel(for id: String) -> AIModel? {
        ModelRegistry.model(for: id) ?? modelsViewModel.importedModels.first { $0.id == id }
    }

    /// Dismiss the slide-over first so pushes land over the chat root. A route
    /// already on the stack pops back to its existing page instead of pushing
    /// a duplicate: the iPad sidebar is persistent, so its Models/Settings
    /// rows stay tappable while that page is open (the "Choose Another Model"
    /// alert actions reach here through the same path).
    private func openShellRoute(_ route: ShellRoute) {
        setSidebarDrawer(false)
        if let existingIndex = detailRoutes.firstIndex(of: route) {
            detailRoutes.removeSubrange(detailRoutes.index(after: existingIndex)...)
        } else {
            detailRoutes.append(route)
        }
    }

    /// Deletes the currently open conversation via the same path as the
    /// sidebar swipe/context-menu delete (cancels an in-flight stream into
    /// it first). Drafts have no row yet, so there is nothing to delete.
    private func deleteActiveConversation() {
        guard let id = chatViewModel.activeConversationID else { return }
        handleSidebarDelete(id)
    }

    /// Sidebar delete (swipe action / context menu → confirm). Cancels an
    /// in-flight chat stream targeting the deleted conversation first, so its
    /// terminal journal write settles before the cascade deletes the row
    /// (PersistenceController.deleteConversation also drops any recovery
    /// journal left targeting the deleted conversation, and terminal replays
    /// treat an already-gone row as consumed). Deleting a different
    /// conversation never disturbs a live stream into another one.
    private func handleSidebarDelete(_ id: UUID) {
        Task {
            if chatViewModel.isStreaming, chatViewModel.streamedConversationID == id {
                await chatViewModel.cancelStream()
            }
            await conversationListViewModel.deleteConversation(id)
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
        setSidebarDrawer(false)
        Task { await chatViewModel.loadConversation(id) }
    }

    /// New Conversation shows an unsaved draft immediately; model loading is
    /// already handled by the deferred loader (or persists untouched when
    /// loaded/failed states exist). The draft is the base layer (plan
    /// §A.2/§A.4), so routed pages are popped just like the onChange nil
    /// branch — the draft chat surface must be the visible one.
    private func handleNewConversation() {
        setSidebarDrawer(false)
        detailRoutes.removeAll()
        chatViewModel.beginNewDraft()
    }

    /// Import wizard Done page "Start Chatting": pop back to the chat root,
    /// load the newly imported model, then show a fresh draft chat. Loading
    /// first means `beginNewDraft` won't spawn a redundant deferred load for
    /// the auto candidate.
    /// An unconsented experimental import parks `selectModel` on the first-use
    /// consent alert (returns false with `showingExperimentalConsent` set).
    /// Beginning the draft anyway would nominate the auto candidate — which
    /// deliberately excludes unconsented imports — and park the chat on
    /// .needsDownload behind the alert. So the draft stays deferred until the
    /// consent resolves (see the `showingExperimentalConsent` onChange):
    /// confirm re-selects the now-consented model and then drafts; cancel
    /// leaves the previous chat surface untouched.
    private func startChatting(with model: AIModel) {
        detailRoutes.removeAll()
        Task {
            let didSelect = await chatViewModel.selectModel(model)
            if didSelect {
                chatViewModel.beginNewDraft()
            } else if chatViewModel.showingExperimentalConsent {
                pendingStartChattingModel = model
            } else {
                chatViewModel.beginNewDraft()
            }
        }
    }

    /// Resolve a deferred "Start Chatting" once the first-use consent alert
    /// dismisses. Confirm re-runs the select-then-draft sequence (the second
    /// select is a no-op when the alert's own confirm already loaded the model,
    /// and a correct waiter when its load is still in flight — both target the
    /// same model, so no wrong-model load can interleave). Cancel clears the
    /// deferral without touching the chat surface.
    private func resolvePendingStartChatting() {
        guard let pending = pendingStartChattingModel else { return }
        pendingStartChattingModel = nil
        guard ExperimentalModelConsent.isGranted(for: pending) else { return }
        Task {
            await chatViewModel.selectModel(pending)
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

// MARK: - Compact slide-over

/// iPhone slide-over helpers, housed here so the AppShellView struct body
/// stays within the type-body-length gate. Same file, so `private` members
/// of the struct remain reachable.
extension AppShellView {
    /// Single funnel for slide-over visibility so opening AND dismissal
    /// both ride the appear spring explicitly (the container also carries
    /// a value-based `.ziroAnimation`, but an explicit transaction keeps
    /// the slide-out alive even when the dismiss lands alongside a
    /// navigation-stack change). Reduce Motion skips the animation.
    private func setSidebarDrawer(_ open: Bool) {
        if reduceMotion {
            showSidebarDrawer = open
        } else {
            withAnimation(ZiroMotion.appear) {
                showSidebarDrawer = open
            }
        }
    }

    /// Full-screen tap-to-dismiss dim behind the slide-over panel. A Button
    /// (not a tap gesture) so VoiceOver lands on a labelled control. The
    /// fill reuses the floating-shadow token — an appearance-adaptive black
    /// dim — because no dedicated scrim token exists.
    private var slideOverScrim: some View {
        Button {
            setSidebarDrawer(false)
        } label: {
            ZiroTheme.shadowFloating
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss sidebar")
        .accessibilityIdentifier("dismiss-sidebar-scrim")
        .transition(.opacity)
    }

    /// Leading slide-over panel hosting the SAME `sidebar` builder (and its
    /// callbacks) as the iPad column, so select/new/delete/route/alert
    /// behaviors match. Dismissal is swipe/scrim only (no close button),
    /// and the brand mark sits chromeless in the header row — so the root
    /// nav bar stays hidden and the shared SidebarView needs no toolbar of
    /// its own. Pushed pages (Chats, Models, Settings) bring their own nav
    /// bars. Panel content (NavigationStack/List) keeps its system safe-area
    /// insets; only plain container frames span edge to edge, so nothing
    /// underlaps the notch or home indicator.
    private func slideOverPanel(width: CGFloat) -> some View {
        NavigationStack {
            sidebar
                .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(ZiroTheme.overlayBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ZiroTheme.hairline)
                .frame(width: 1)
        }
        .ziroShadow(.floating)
        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
        .simultaneousGesture(slideOverDismissDrag)
    }

    /// Slide-over width: 72pt of chat stays visible as a context anchor,
    /// clamped to a 240–320pt panel (spec-mandated points, not spacing).
    private func slideOverWidth(containerWidth: CGFloat) -> CGFloat {
        min(320, max(240, containerWidth - 72))
    }

    /// Leading-edge swipe to dismiss. Simultaneous (never high-priority) so
    /// the conversation List keeps its vertical scroll and row swipe-actions:
    /// only a clearly horizontal leftward drag past the commit threshold
    /// dismisses; vertical (scroll) and short trailing (row-action reveal)
    /// drags fall through untouched. Distances compose spacing tokens
    /// (24pt engage, 56pt commit).
    private var slideOverDismissDrag: some Gesture {
        DragGesture(
            minimumDistance: ZiroTheme.Spacing.xLarge,
            coordinateSpace: .local
        )
        .onEnded { value in
            let commit = ZiroTheme.Spacing.xxLarge + ZiroTheme.Spacing.large
            let translation = value.translation
            guard translation.width < -commit,
                  abs(translation.width) > abs(translation.height) * 1.5
            else { return }
            setSidebarDrawer(false)
        }
    }
}

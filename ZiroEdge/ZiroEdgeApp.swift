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
        let chatViewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inferenceService,
            sessionActor: sessionActor,
            lifecycleManager: lifecycleManager
        )
        let conversationListViewModel = ConversationListViewModel(persistence: persistence)

        _persistence = State(initialValue: persistence)
        _inferenceService = State(initialValue: inferenceService)
        _memoryBudgeter = State(initialValue: memoryBudgeter)
        _lifecycleManager = State(initialValue: lifecycleManager)
        _sessionActor = State(initialValue: sessionActor)
        _chatViewModel = State(initialValue: chatViewModel)
        _conversationListViewModel = State(initialValue: conversationListViewModel)
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            MainView(
                chatViewModel: chatViewModel,
                conversationListViewModel: conversationListViewModel,
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter
            )
            .task {
                // Recover any incomplete streams from the previous session.
                await persistence.recoverIncompleteStreams()

                // Ensure models directory exists.
                ModelManagerService.ensureModelsDirectory()
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

    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                viewModel: conversationListViewModel,
                onNewConversation: {
                    Task {
                        let id = await conversationListViewModel.createConversation(
                            modelID: ModelRegistry.llama32_3B.id
                        )
                        await chatViewModel.loadConversation(id)
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
                        let id = await conversationListViewModel.createConversation(
                            modelID: ModelRegistry.llama32_3B.id
                        )
                        await chatViewModel.loadConversation(id)
                    }
                })
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                memoryBudgeter: memoryBudgeter
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
    }
}

// MARK: - Welcome View

/// Shown when no conversation is selected.
struct WelcomeView: View {
    let onNewConversation: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("Welcome to ZiroEdge")
                .font(.largeTitle.bold())

            Text("Your private AI assistant. Everything runs on your device — no data ever leaves your phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: onNewConversation) {
                Label("Start a Conversation", systemImage: "plus.circle.fill")
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

// MARK: - Settings View (Stub for Phase 1)

/// Settings view — Phase 1 stub with model management.
struct SettingsView: View {
    @ObservedObject var lifecycleManager: ModelLifecycleManager
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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

                // Available models.
                Section("Available Models") {
                    ForEach(ModelRegistry.allModels) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                    .font(.body)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if lifecycleManager.activeModel?.id == model.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Load") {
                                    Task { await lifecycleManager.loadModel(model) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                // Memory section.
                Section("Memory") {
                    LabeledContent("Available RAM") {
                        Text("Loading...")
                            .task {
                                // This would update in real implementation.
                            }
                    }
                    LabeledContent("Total Device RAM") {
                        Text("Loading...")
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
        }
    }
}

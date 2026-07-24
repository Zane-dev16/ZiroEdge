import Foundation
import SwiftUI

struct RuntimeServices {
    let persistence: PersistenceController
    let inferenceService: InferenceService
    let memoryBudgeter: MemoryBudgeter
    let lifecycleManager: ModelLifecycleManager
    let sessionActor: ChatSessionActor
    let chatViewModel: ChatViewModel
    let conversationListViewModel: ConversationListViewModel
    let downloadManager: DownloadManager
    let modelsViewModel: ModelsViewModel
}

@MainActor
final class AppRuntime: ObservableObject {
    enum State {
        case loading(attempt: Int)
        case ready(RuntimeServices)
        case failed(PersistenceFailure)
        case quarantining
        case awaitingResetConfirmation(StoreRecoveryArtifact)
        case resetting
    }

    @Published private(set) var state: State = .loading(attempt: 1)
    @Published private(set) var diagnosticsURL: URL?
    @Published private(set) var diagnosticsExportError: String?
    @Published private(set) var postResetMessage: String?

    private let configuration: PersistenceConfiguration
    private let faultInjector: any PersistenceFaultInjecting
    private let recoveryCoordinator: StoreRecoveryCoordinator
    private var openTask: Task<Void, Never>?
    private var attempt = 0
    private var lastFailure: PersistenceFailure?
    private var isCompletingReset = false

    init(
        configuration: PersistenceConfiguration = .production,
        faultInjector: any PersistenceFaultInjecting = NoopPersistenceFaultInjector(),
        recoveryCoordinator: StoreRecoveryCoordinator = StoreRecoveryCoordinator()
    ) {
        self.configuration = configuration
        self.faultInjector = faultInjector
        self.recoveryCoordinator = recoveryCoordinator
    }

    func start() async {
        guard attempt == 0 else { return }
        await openStore()
    }

    func retry() {
        guard case .failed = state, openTask == nil else { return }
        openTask = Task { [weak self] in
            guard let self else { return }
            await self.openStore()
            self.openTask = nil
        }
    }

    func exportDiagnostics() {
        guard let failure = lastFailure else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZiroEdge-persistence-diagnostics.txt")
            try Data(failure.sanitizedDiagnostic.utf8).write(to: url, options: .atomic)
            diagnosticsURL = url
            diagnosticsExportError = nil
        } catch {
            diagnosticsURL = nil
            diagnosticsExportError = "Could not save diagnostics. Check available storage."
        }
    }

    func prepareReset() {
        guard case .failed(let failure) = state,
              let storeURL = configuration.storeURL else { return }
        state = .quarantining
        Task {
            let result = await recoveryCoordinator.quarantine(
                storeURL: storeURL,
                failure: failure
            )
            switch result {
            case .success(let artifact): state = .awaitingResetConfirmation(artifact)
            case .failure(let error):
                lastFailure = error
                state = .failed(error)
            }
        }
    }

    func cancelReset() {
        guard case .awaitingResetConfirmation = state, let lastFailure else { return }
        state = .failed(lastFailure)
    }

    func confirmReset(_ artifact: StoreRecoveryArtifact) {
        guard case .awaitingResetConfirmation(let expected) = state,
              expected == artifact,
              let storeURL = configuration.storeURL else { return }
        state = .resetting
        isCompletingReset = true
        Task {
            switch await recoveryCoordinator.destroyStore(
                at: storeURL,
                after: artifact
            ) {
            case .success:
                await openStore()
            case .failure(let failure):
                isCompletingReset = false
                lastFailure = failure
                state = .failed(failure)
            }
        }
    }

    private func openStore() async {
        attempt += 1
        state = .loading(attempt: attempt)
        let result = await PersistenceController.open(
            configuration: configuration,
            faultInjector: faultInjector
        )
        switch result {
        case .success(let persistence):
            switch await persistence.recoverIncompleteStreams() {
            case .success:
                lastFailure = nil
                diagnosticsURL = nil
                diagnosticsExportError = nil
                state = .ready(makeServices(persistence: persistence))
                if isCompletingReset {
                    isCompletingReset = false
                    postResetMessage = "Local history reset successfully. You can start a new conversation."
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        self?.postResetMessage = nil
                    }
                }
            case .failure(let failure):
                lastFailure = failure
                state = .failed(failure)
            }
        case .failure(let failure):
            lastFailure = failure
            state = .failed(failure)
        }
    }

    private func makeServices(persistence: PersistenceController) -> RuntimeServices {
        let inferenceService = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycleManager = ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter
        )
        let sessionActor = ChatSessionActor(inferenceService: inferenceService, persistence: persistence)
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
        return RuntimeServices(
            persistence: persistence,
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter,
            lifecycleManager: lifecycleManager,
            sessionActor: sessionActor,
            chatViewModel: chatViewModel,
            conversationListViewModel: conversationListViewModel,
            downloadManager: downloadManager,
            modelsViewModel: ModelsViewModel(
                downloadManager: downloadManager,
                lifecycleManager: lifecycleManager
            )
        )
    }
}

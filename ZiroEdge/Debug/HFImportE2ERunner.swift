// HFImportE2ERunner.swift
// ZiroEdge — Privacy-first local AI assistant
//
// DEBUG-only, code-driven end-to-end exercise of the Hugging Face import
// flow inside the real app process: repository inspection, artifact listing,
// registration, download/verification/promotion, experimental-consent load,
// one chat turn, persisted-reply capture. No UI interaction.
//
// Launch contract (see ZiroEdgeApp .task hook):
//   --e2e-hf-import                     master enable
//   --e2e-repo <repo-id-or-url>         default bartowski/SmolLM2-135M-Instruct-GGUF
//   --e2e-file <filename.gguf>          default: prefer *Q4_K_M*, else smallest base artifact
//   --e2e-prompt <text>                 default "Reply with exactly OK."
//   --e2e-download-timeout <seconds>    default 900
// Terminal markers (last line of every run):
//   E2E_RESULT: SUCCESS repo=<r> file=<f> modelID=<id> conversationID=<uuid> reply=<text>
//   E2E_RESULT: FAILURE step=<n> reason=<single line>

#if DEBUG
import Foundation
import UIKit

@MainActor
enum HFImportE2ERunner {

    // MARK: - Entry

    /// Fire-and-forget. Returns a no-op Task when not enabled.
    static func run(services: RuntimeServices,
                    arguments: [String] = CommandLine.arguments) -> Task<Void, Never> {
        guard arguments.contains("--e2e-hf-import"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return Task {}
        }
        return Task { await Self.execute(services: services, arguments: arguments) }
    }

    // MARK: - Failure plumbing

    private struct E2EFailure: Error {
        let step: Int
        let reason: String
    }

    // MARK: - State

    private static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("e2e-import.log")
    }
    private static var handle: FileHandle?

    // MARK: - Execution

    private static func execute(services: RuntimeServices, arguments: [String]) async {
        do {
            try await runSteps(services: services, arguments: arguments)
        } catch let failure as E2EFailure {
            emit("E2E_RESULT: FAILURE step=\(failure.step) reason=\(sanitize(failure.reason))", step: failure.step)
        } catch {
            emit("E2E_RESULT: FAILURE step=-1 reason=\(sanitize(error.localizedDescription))")
        }
    }

    private static func runSteps(services: RuntimeServices, arguments: [String]) async throws {
        openLog()

        // ---- Step 0: environment & arg parsing --------------------------------
        let parsed = parseArguments(arguments)
        let processInfo = ProcessInfo.processInfo
        emit("E2E_RUN_BEGIN id=\(timestamp)-\(processInfo.processIdentifier) repo=\(parsed.repo) file=\(parsed.file ?? "auto") " +
             "prompt=\"\(parsed.prompt)\" downloadTimeoutSec=\(parsed.downloadTimeout)", step: 0)
        emit("DEVICE os=\(processInfo.operatingSystemVersionString) physicalMemory=\(processInfo.physicalMemory) diskAvailable=\(services.downloadManager.availableDiskSpace)", step: 0)

        // ---- Step 1: normalize repo id ----------------------------------------
        let normalized: String
        do {
            normalized = try HFRepositoryInspector.normalizeRepositoryID(parsed.repo)
        } catch {
            throw E2EFailure(step: 1, reason: "normalize failed for '\(parsed.repo)': \(error)")
        }
        emit("NORMALIZED repo=\(normalized)", step: 1)

        // ---- Step 2: inspect repository (live HF API) -------------------------
        emit("INSPECTING repo=\(normalized) …", step: 2)
        let inspector = HFRepositoryInspector()
        let review: HFRepositoryReview
        do {
            review = try await inspector.inspect(normalized)
        } catch {
            throw E2EFailure(step: 2, reason: "inspection failed: \(error)")
        }
        emit("INSPECTED repo=\(review.repositoryID) revision=\(review.revision) license=\(review.licenseName) url=\(review.licenseURL.absoluteString) artifacts=\(review.artifacts.count)", step: 2)

        // ---- Step 3: what the UI would render + selection + gates -------------
        logArtifacts(of: review)
        let selected = try selectBaseArtifact(from: review, explicit: parsed.file)

        let requiredBytes = SaturatedArithmetic.add(selected.size, 0)
        let margin = services.downloadManager.storageSafetyMargin(for: requiredBytes)
        let available = services.downloadManager.availableDiskSpace
        let canProceed = available >= SaturatedArithmetic.add(requiredBytes, margin)
        emit("STORAGE required=\(requiredBytes) margin=\(margin) available=\(available) canProceed=\(canProceed)", step: 3)
        guard canProceed else {
            throw E2EFailure(step: 3, reason: "storage preflight failed")
        }

        // ---- Step 4: register (or reuse) the imported record ------------------
        // Vision repos carry companion projector artifacts; pick the smallest
        // so the import exercises the full pairing path when one exists.
        let projector = review.projectorArtifacts.min(by: { $0.size < $1.size })
        if let projector {
            emit("SELECTED mmproj=\(projector.filename) bytes=\(projector.size) arch=\(projector.architecture)", step: 4)
        }
        let store = ImportedModelStore.shared
        let record: ImportedModelRecord
        if let duplicate = store.record(repositoryID: review.repositoryID,
                                        revision: review.revision,
                                        baseFilename: selected.filename,
                                        projectorFilename: projector?.filename) {
            emit("DEDUP existing modelID=\(duplicate.model.id)", step: 4)
            record = duplicate
        } else {
            let fresh = ImportedModelFactory.makeRecord(review: review, base: selected, projector: projector)
            do {
                record = try store.upsert(fresh)
            } catch {
                throw E2EFailure(step: 4, reason: "registry upsert failed: \(error)")
            }
            emit("REGISTERED modelID=\(record.model.id) displayName=\(record.displayName) type=\(record.modelType)", step: 4)
            emit("LEGAL license=\(record.license.name) url=\(record.license.url.absoluteString)", step: 4)
        }

        // ---- Step 5: download (skipped when already installed) -----------------
        let alreadyInstalled = services.downloadManager.status(for: record.model).isReady
            || ModelManagerService.isBaseDownloaded(record.model)
        if alreadyInstalled {
            emit("DOWNLOAD skipped: artifact already installed", step: 5)
        } else {
            services.downloadManager.updateStatusesFromDisk()
            emit("DOWNLOAD starting for \(record.model.id) bytes=\(record.baseFileSizeBytes) url=\(record.baseURL.absoluteString)", step: 5)
            services.downloadManager.startDownload(for: record.model)
            try await waitForTerminalStatus(services: services, model: record.model, timeoutSeconds: parsed.downloadTimeout)
        }

        try await runtimeHalf(services: services, record: record, prompt: parsed.prompt,
                              promptWasExplicit: parsed.promptExplicit, stepBase: 5)
    }

    private static func waitForTerminalStatus(services: RuntimeServices,
                                              model: AIModel,
                                              timeoutSeconds: Int) async throws {
        let startedAt = Date()
        var lastProgressLine = Date.distantPast
        while true {
            let status = services.downloadManager.status(for: model)
            if status.isReady {
                emit("DOWNLOAD TERMINAL state=downloaded elapsedSec=\(Int(Date().timeIntervalSince(startedAt)))", step: 6)
                break
            }
            if case .failed(let error) = status.baseState {
                throw E2EFailure(step: 6, reason: "download failed: \(error.localizedDescription)")
            }
            if Date().timeIntervalSince(startedAt) > TimeInterval(timeoutSeconds) {
                throw E2EFailure(step: 6, reason: "download timed out after \(timeoutSeconds)s lastState=\(status.baseState)")
            }
            if Date().timeIntervalSince(lastProgressLine) >= 5 {
                lastProgressLine = Date()
                let progressText: String
                switch status.baseState {
                case .downloading(let progress): progressText = String(format: "%.2f", progress)
                case .verifying: progressText = "verifying"
                default: progressText = "\(status.baseState)"
                }
                emit("PROGRESS state=\(progressText) elapsedSec=\(Int(Date().timeIntervalSince(startedAt)))", step: 6)
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Runtime half (shared by fresh import and dedup path)

    private static func runtimeHalf(services: RuntimeServices,
                                    record: ImportedModelRecord,
                                    prompt: String,
                                    promptWasExplicit: Bool,
                                    stepBase: Int) async throws {
        let model = record.model
        let baseStep = stepBase + 1
        guard ModelManagerService.isBaseDownloaded(model) else {
            throw E2EFailure(step: baseStep, reason: "post-promotion check failed: base artifact not present on disk")
        }
        emit("PROMOTED baseArtifactPresent=true destinationStorageID=\(model.baseArtifactStorageID)", step: baseStep)

        // Consent (experimental runtime identity requires explicit opt-in).
        ExperimentalModelConsent.setGranted(true, for: model)
        guard ExperimentalModelConsent.isGranted(for: model) else {
            throw E2EFailure(step: baseStep + 1, reason: "experimental consent did not persist (profile synthesis missing?)")
        }
        emit("CONSENT granted=true profile=\(MemoryProfileRegistry.profile(for: model)?.id ?? "nil") eligibility=\(model.runtimeEligibility)", step: baseStep + 1)

        // Engine load.
        let loadStartedAt = Date()
        let selected = await services.chatViewModel.selectModel(model)
        let loaded = selected
            && services.lifecycleManager.isModelLoaded
            && services.lifecycleManager.activeModel?.id == model.id
        emit("LOAD selected=\(selected) loaded=\(loaded) activeModel=\(services.lifecycleManager.activeModel?.id ?? "nil") " +
             "elapsedSec=\(Int(Date().timeIntervalSince(loadStartedAt)))", step: baseStep + 2)
        guard loaded else {
            let message = await services.lifecycleManager.loadFailureMessage ?? "selectModel returned false"
            throw E2EFailure(step: baseStep + 2, reason: "engine load failed: \(message)")
        }

        // Conversation.
        guard let conversationID = await services.conversationListViewModel.createConversation(
            modelID: model.id,
            title: record.modelType == .vision ? "HF Import Vision E2E" : "HF Import E2E"
        ) else {
            throw E2EFailure(step: baseStep + 3, reason: "createConversation returned nil: \(services.conversationListViewModel.errorMessage ?? "no error surfaced")")
        }
        emit("CONVERSATION id=\(conversationID.uuidString)", step: baseStep + 3)
        await services.chatViewModel.loadConversation(conversationID)

        // One chat turn through the production send path. Vision models get a
        // generated attachment so the mmproj-backed stream is exercised too.
        var effectivePrompt = prompt
        if record.modelType == .vision {
            if let imageError = await attachGeneratedImage(services: services) {
                throw E2EFailure(step: baseStep + 4, reason: "image attachment failed: \(imageError)")
            }
            emit("IMAGE attached bytes=\(services.chatViewModel.pendingImages.first?.count ?? 0)", step: baseStep + 4)
            if !promptWasExplicit {
                effectivePrompt = "Describe this image."
            }
        }
        guard let imageData = services.chatViewModel.pendingImages.first,
              UIImage(data: imageData) != nil || record.modelType != .vision else {
            throw E2EFailure(step: baseStep + 4, reason: "pending image failed to decode")
        }
        services.chatViewModel.inputText = effectivePrompt
        emit("SEND prompt=\"\(effectivePrompt)\" images=\(services.chatViewModel.pendingImages.count)", step: baseStep + 4)
        let sendStartedAt = Date()
        await services.chatViewModel.sendMessage()

        // Wait for the stream to actually begin (precondition failures exit silently).
        let streamStartDeadline = Date().addingTimeInterval(90)
        while !services.chatViewModel.isStreaming {
            if Date() > streamStartDeadline {
                throw E2EFailure(step: baseStep + 4, reason: "stream never started; errorMessage=\(services.chatViewModel.errorMessage ?? "none")")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        emit("STREAM started=true waitMs=\(Int(Date().timeIntervalSince(sendStartedAt) * 1000))", step: baseStep + 4)

        // Wait for completion (hard cap covers cold-start token latency).
        let completionDeadline = Date().addingTimeInterval(300)
        while services.chatViewModel.isStreaming {
            if Date() > completionDeadline {
                await services.chatViewModel.cancelStream()
                throw E2EFailure(step: baseStep + 5, reason: "generation exceeded 300s; cancelled")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if services.chatViewModel.showError, let message = services.chatViewModel.errorMessage {
            throw E2EFailure(step: baseStep + 5, reason: "chat error surfaced: \(message)")
        }
        emit("STREAM ended elapsedMs=\(Int(Date().timeIntervalSince(sendStartedAt) * 1000))", step: baseStep + 5)

        // Ground truth: the persisted assistant row.
        guard case .success(let messages) = await services.persistence.fetchMessagesResult(conversationID: conversationID),
              let reply = messages.last(where: { $0.role == .assistant }),
              !reply.content.isEmpty else {
            throw E2EFailure(step: baseStep + 6, reason: "no persisted assistant reply (finalization may have failed)")
        }
        emit("REPLY chars=\(reply.content.count) content=\(sanitize(reply.content))", step: baseStep + 6)

        let successLine = "E2E_RESULT: SUCCESS repo=\(record.provenance.repositoryID) file=\(record.provenance.baseFilename) " +
            "modelID=\(model.id) conversationID=\(conversationID.uuidString) reply=\(sanitize(reply.content))"
        emit(successLine, step: baseStep + 6)
    }

    // MARK: - Arguments

    private struct ParsedArguments {
        var repo = "bartowski/SmolLM2-135M-Instruct-GGUF"
        var file: String?
        var prompt = "Reply with exactly OK."
        var promptExplicit = false
        var downloadTimeout = 900
    }

    /// Logs every GGUF the import review UI would render, in production order.
    private static func logArtifacts(of review: HFRepositoryReview) {
        for (index, artifact) in review.artifacts.enumerated() {
            let template = artifact.metadata.chatTemplate != nil ? "present" : "absent"
            let ctx = artifact.metadata.contextLength.map(String.init) ?? "nil"
            emit("HF-ARTIFACT \(index + 1)/\(review.artifacts.count) name=\(artifact.filename) role=\(artifact.role.rawValue) " +
                 "bytes=\(artifact.size) quant=\(artifact.quantization) arch=\(artifact.architecture) " +
                 "sha256=\(artifact.sha256.prefix(12))… ctx=\(ctx) template=\(template)", step: 3)
        }
    }

    private static func selectBaseArtifact(from review: HFRepositoryReview, explicit: String?) throws -> HFArtifact {
        if let explicit {
            guard let match = review.baseArtifacts.first(where: { $0.filename == explicit }) else {
                throw E2EFailure(step: 3, reason: "--e2e-file \(explicit) not among base artifacts")
            }
            emit("SELECTED base=\(match.filename) bytes=\(match.size) rule=explicit", step: 3)
            return match
        }
        guard let fallback = review.baseArtifacts.first(where: { $0.filename.contains("Q4_K_M") })
            ?? review.baseArtifacts.min(by: { $0.size < $1.size }) else {
            throw E2EFailure(step: 3, reason: "repository exposes no base artifacts")
        }
        let rule = fallback.filename.contains("Q4_K_M") ? "Q4KM" : "smallest"
        emit("SELECTED base=\(fallback.filename) bytes=\(fallback.size) rule=\(rule)", step: 3)
        return fallback
    }

    private static func parseArguments(_ arguments: [String]) -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        func value(after flag: String) -> String? {
            guard index + 1 < arguments.count else { return nil }
            defer { index += 1 }
            return arguments[index + 1]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--e2e-repo": parsed.repo = value(after: "--e2e-repo") ?? parsed.repo
            case "--e2e-file": parsed.file = value(after: "--e2e-file") ?? parsed.file
            case "--e2e-prompt":
                if let explicit = value(after: "--e2e-prompt") {
                    parsed.prompt = explicit
                    parsed.promptExplicit = true
                }
            case "--e2e-download-timeout":
                parsed.downloadTimeout = Int(value(after: "--e2e-download-timeout") ?? "") ?? parsed.downloadTimeout
            default:
                break
            }
            index += 1
        }
        return parsed
    }

    /// Generates a small solid-color PNG in-process and attaches it through
    /// the production addImage seam. Returns a failure reason on rejection.
    private static func attachGeneratedImage(services: RuntimeServices) async -> String? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.white.setFill()
            context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        guard let png = image.pngData(), !png.isEmpty else {
            return "PNG encoding produced no data"
        }
        await services.chatViewModel.addImage(png)
        return services.chatViewModel.pendingImages.isEmpty ? "attachment did not register" : nil
    }

    // MARK: - Logging

    private static func openLog() {
        let url = logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func emit(_ line: String, step: Int? = nil) {
        let full = "[\(timestamp())] \(step.map { "[step \($0)] " } ?? "")\(line)\n"
        print(full, terminator: "")
        handle?.write(Data(full.utf8))
    }
}
#endif

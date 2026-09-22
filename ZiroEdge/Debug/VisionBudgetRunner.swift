// VisionBudgetRunner.swift
// ZiroEdge — DEBUG-only live vision-budget proof (Turns A/B/C).
//
// In-app harness: runs inside the real app process (XCUITest launches the app
// with --vision-budget-turn <A|B|C>), generates test images programmatically
// (no PhotosPicker), attaches via ChatViewModel.addImage, sends via
// ChatViewModel.sendMessage, and emits terminal markers + JSONL rows.
//
// Launch contract:
//   --vision-budget-turn A   1024px JPEG q0.8, empty chat: attach ACCEPTED, eval SUCCESS
//   --vision-budget-turn B   4000x3000 panorama: capped to allowance, SUCCESS
//   --vision-budget-turn C   light attach then heavy history: contextWindowExceeded, app alive, NO abort
// Terminal markers (console):
//   VISION_BUDGET_RESULT: SUCCESS turn=<X> n_pos=<n> target=<WxH> peakBytes=<b> attach=<a>
//   VISION_BUDGET_RESULT: FAILURE turn=<X> reason=<single line>
// Status export for XCUITest: VisionBudgetRunner.state mirrored to the
// `vision-budget-state` accessibility label by AppShellView.
// JSONL rows: Documents/budget-proof-turns/turn-<X>.jsonl (one row per attempt).

#if DEBUG
import Foundation
import ImageIO
import SwiftLlama
import UIKit

@MainActor
enum VisionBudgetRunner {
    static var state: String = "idle"

    static func turnID(arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: "--vision-budget-turn"),
              idx + 1 < arguments.count else { return nil }
        let turn = arguments[idx + 1].uppercased()
        return ["A", "B", "C"].contains(turn) ? turn : nil
    }

    /// DEBUG-only threshold-probe bypass: `--vision-probe-bypass` lets the
    /// send-gate pass over-safe probe images through to eval (with full
    /// n_pos/peak/console logging) so the 512...1024 abort threshold can be
    /// measured. Without the flag the prod path keeps refusing (see
    /// `InferenceService.throwIfVisionExceedsBudget`). DEBUG-only, like
    /// `--vision-force-cpu`.
    static func isProbeBypass(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--vision-probe-bypass")
    }

    /// Threshold probe size: `--vision-threshold-size <px>` (square SxS JPEG q0.8
    /// at native dims, bypassing the visionGate downscale). Bounded 64...2048.
    static func thresholdSize(arguments: [String] = CommandLine.arguments) -> Int? {
        guard let idx = arguments.firstIndex(of: "--vision-threshold-size"),
              idx + 1 < arguments.count, let size = Int(arguments[idx + 1]),
              (64...2048).contains(size) else { return nil }
        return size
    }

    static func isEnabled(arguments: [String] = CommandLine.arguments) -> Bool {
        turnID(arguments: arguments) != nil || thresholdSize(arguments: arguments) != nil
    }

    static func run(services: RuntimeServices,
                    arguments: [String] = CommandLine.arguments) -> Task<Void, Never> {
        guard isEnabled(arguments: arguments) else { return Task {} }
        return Task { await execute(services: services, arguments: arguments) }
    }

    // MARK: - Execution

    private static func execute(services: RuntimeServices, arguments: [String]) async {
        if let size = thresholdSize(arguments: arguments) {
            await executeThreshold(size: size, services: services, arguments: arguments)
            return
        }
        guard let turn = turnID(arguments: arguments) else { return }
        state = "turn-\(turn)-running"
        do {
            let row = try await runTurn(turn, services: services)
            persistRow(turn: turn, row: row)
            state = "turn-\(turn)-complete"
            print("VISION_BUDGET_RESULT: SUCCESS turn=\(turn) n_pos=\(row["n_pos"] ?? "nil") target=\(row["target"] ?? "nil") peakBytes=\(row["peakBytes"] ?? "nil") attach=\(row["attach"] ?? "nil")")
        } catch let failure as BudgetFailure {
            state = "turn-\(turn)-failed-\(failure.reason)"
            print("VISION_BUDGET_RESULT: FAILURE turn=\(turn) reason=\(failure.reason)")
            persistRow(turn: turn, row: [
                "turn": turn, "outcome": "FAILURE", "reason": failure.reason,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(160).description
            state = "turn-\(turn)-failed-error"
            print("VISION_BUDGET_RESULT: FAILURE turn=\(turn) reason=\(reason)")
            persistRow(turn: turn, row: [
                "turn": turn, "outcome": "FAILURE", "reason": reason,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }
    }

    private struct BudgetFailure: Error { let reason: String }

    // MARK: - Threshold execution (abort-threshold binary search)

    private static func executeThreshold(size: Int, services: RuntimeServices, arguments: [String]) async {
        let mode = arguments.contains("--vision-force-cpu") ? "cpu" : "metal"
        let bypass = isProbeBypass(arguments: arguments)
        state = "threshold-\(size)-\(mode)-running"
        do {
            let row = try await runThreshold(size: size, services: services, arguments: arguments)
            persistThresholdRow(size: size, mode: mode, row: row)
            state = "threshold-\(size)-\(mode)-complete"
            print("VISION_THRESHOLD_RESULT: SUCCESS size=\(size) mode=\(mode) bypass=\(bypass)" +
                " n_pos=\(row["n_pos"] ?? "nil") target=\(row["target"] ?? "nil")" +
                " peakBytes=\(row["peakBytes"] ?? "nil") attach=\(row["attach"] ?? "nil")")
        } catch let failure as BudgetFailure {
            state = "threshold-\(size)-\(mode)-failed-\(failure.reason)"
            print("VISION_THRESHOLD_RESULT: FAILURE size=\(size) mode=\(mode) bypass=\(bypass) reason=\(failure.reason)")
            persistThresholdRow(size: size, mode: mode, row: [
                "turn": "T\(size)-\(mode)", "outcome": "FAILURE", "reason": failure.reason,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(160).description
            state = "threshold-\(size)-\(mode)-failed-error"
            print("VISION_THRESHOLD_RESULT: FAILURE size=\(size) mode=\(mode) bypass=\(bypass) reason=\(reason)")
            persistThresholdRow(size: size, mode: mode, row: [
                "turn": "T\(size)-\(mode)", "outcome": "FAILURE", "reason": reason,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }
    }

    private static func runTurn(_ turn: String, services: RuntimeServices) async throws -> [String: String] {
        let (vm, ctxLen, maxTok) = try await prepareFreshE2BChat(
            services: services, title: "Budget Proof Turn \(turn)")
        switch turn {
        case "A": return try await runTurnA(vm: vm, ctxLen: ctxLen, maxTok: maxTok)
        case "B": return try await runTurnB(vm: vm, ctxLen: ctxLen, maxTok: maxTok)
        case "C": return try await runTurnC(vm: vm, ctxLen: ctxLen, maxTok: maxTok)
        default: throw BudgetFailure(reason: "unknown-turn")
        }
    }

    /// Shared preamble: E2B installed -> select + residency -> fresh conversation.
    /// Returns (view model, contextLength, maxTokens).
    private static func prepareFreshE2BChat(services: RuntimeServices, title: String) async throws
        -> (ChatViewModel, Int, Int) {
        let vm = services.chatViewModel
        let lifecycle = services.lifecycleManager
        let conversations = services.conversationListViewModel

        // ---- Step 1: E2B must be installed ---------------------------------
        guard let e2b = ModelRegistry.model(for: "gemma-4-e2b-q4") else {
            throw BudgetFailure(reason: "missing-model-registry")
        }
        guard ModelManagerService.isFullyDownloaded(e2b) else {
            throw BudgetFailure(reason: "missing-model-not-downloaded")
        }
        let ctxLen = e2b.config.contextLength
        let maxTok = e2b.config.defaultSampling.maxTokens

        // ---- Step 2: select E2B + await residency (bounded 180s) ------------
        _ = await vm.selectModel(e2b)
        var waited: Int = 0
        while !(lifecycle.isModelLoaded && lifecycle.activeModel?.id == e2b.id) {
            if lifecycle.currentState == .loadFailed {
                throw BudgetFailure(reason: "model-load-failed")
            }
            if waited >= 360 { throw BudgetFailure(reason: "model-load-timeout") }
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }

        // ---- Step 3: fresh conversation ------------------------------------
        guard let convID = await conversations.createConversation(modelID: e2b.id, title: title) else {
            throw BudgetFailure(reason: "conversation-create-failed")
        }
        conversations.selectConversation(convID)
        await vm.loadConversation(convID)
        // Await transcript quiescence: loadConversation sets the flag after
        // its first suspension, so await start (bounded) then end (bounded).
        // A no-op reload may never set it; require activeConversationID match.
        for _ in 0..<40 where vm.isLoadingConversation == false && vm.activeConversationID != convID {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for _ in 0..<240 where vm.isLoadingConversation {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Extra beat for post-load banner/phase projection to settle.
        try? await Task.sleep(for: .milliseconds(1000))
        return (vm, ctxLen, maxTok)
    }

    // MARK: - Threshold probe: SxS JPEG q0.8 at NATIVE dims, empty chat

    /// Binary-search probe for the live abort threshold. Attaches the generated
    /// image at native dims, bypassing the `visionGate` downscale (production
    /// attach always caps to `visionSafeMaxPixels`). `--vision-force-cpu`
    /// serves the CPU profile instead of auto-Metal. `--vision-probe-bypass`
    /// lets the send-gate pass the native probe to eval (with full
    /// n_pos/peak/console logging); without it the send-gate refuses
    /// over-safe probes and the threshold cannot be measured.
    private static func runThreshold(size: Int, services: RuntimeServices, arguments: [String]) async throws
        -> [String: String] {
        let forceCPU = arguments.contains("--vision-force-cpu")
        MemoryProfileRegistry.forceCPUVision = forceCPU
        let bypass = isProbeBypass(arguments: arguments)
        let mode = forceCPU ? "cpu" : "metal"
        let (vm, _, _) = try await prepareFreshE2BChat(
            services: services, title: "Threshold \(size)px \(mode)")
        let image = try makeJPEG(width: size, height: size, quality: 0.8)
        let dims = ChatViewModel.pixelDimensions(of: image)
        guard dims?.width == size, dims?.height == size else {
            let got = dims.map { "\($0.width)x\($0.height)" } ?? "nil"
            throw BudgetFailure(reason: "threshold-image-dims got=\(got) want=\(size)x\(size)")
        }
        vm.clearImages()
        vm.pendingImages.append(image)
        vm.visionWarning = nil
        guard vm.pendingImages.count == 1 else { throw BudgetFailure(reason: "threshold-attach-failed") }
        let assessed = assessAttached(vm: vm)
        let (outcome, nPos, peak) = try await sendAndAwait(vm: vm, text: "Describe this image in one short sentence.")
        guard outcome == "eval-success" else {
            throw BudgetFailure(reason: "eval-\(outcome)")
        }
        var row = baseRow(turn: "T\(size)-\(mode)", attach: "NATIVE", target: "\(size)x\(size)",
            nPos: nPos, peak: peak, outcome: "SUCCESS", extra: assessed)
        row["size"] = String(size)
        row["mode"] = mode
        row["bypass"] = String(bypass)
        return row
    }

    private static func persistThresholdRow(size: Int, mode: String, row: [String: String]) {
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("threshold-runs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("threshold-\(size)-\(mode).jsonl")
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            print("[VISION-THRESHOLD-ROW] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {
            print("[VISION-THRESHOLD-ERROR] persist failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Turn A: 1024px JPEG q0.8, empty chat

    private static func runTurnA(vm: ChatViewModel, ctxLen: Int, maxTok: Int) async throws -> [String: String] {
        let image = try makeJPEG(width: 1024, height: 1024, quality: 0.8)
        let target = LlamaEngine.visionTargetSize(imageWidth: 1024, imageHeight: 1024,
            promptTokens: 0, contextLength: ctxLen, maxTokens: maxTok)
        let targetStr = target.map { "\($0.width)x\($0.height)" } ?? "nil"
        guard target != nil else { throw BudgetFailure(reason: "attach-budget-nil-empty-chat") }

        vm.clearImages()
        await vm.addImage(image)
        guard vm.pendingImages.count == 1 else {
            throw BudgetFailure(reason: "attach-refused-empty-chat warning=\(vm.visionWarning ?? "nil")")
        }
        let assessed = assessAttached(vm: vm)
        let (outcome, nPos, peak) = try await sendAndAwait(vm: vm, text: "Describe this image in one short sentence.")
        guard outcome == "eval-success" else {
            throw BudgetFailure(reason: "eval-\(outcome)")
        }
        return baseRow(turn: "A", attach: "ACCEPTED", target: targetStr,
            nPos: nPos, peak: peak, outcome: "SUCCESS", extra: assessed)
    }

    // MARK: - Turn B: 12MP panorama, capped to allowance

    private static func runTurnB(vm: ChatViewModel, ctxLen: Int, maxTok: Int) async throws -> [String: String] {
        let image = try makeJPEG(width: 4000, height: 3000, quality: 0.8)
        let target = LlamaEngine.visionTargetSize(imageWidth: 4000, imageHeight: 3000,
            promptTokens: 0, contextLength: ctxLen, maxTokens: maxTok)
        let targetStr = target.map { "\($0.width)x\($0.height)" } ?? "nil"
        guard let capped = target else { throw BudgetFailure(reason: "panorama-budget-nil") }
        // Allowance cap: target must be smaller than source (capped, never nil here).
        guard capped.width < 4000 && capped.height < 3000 else {
            throw BudgetFailure(reason: "panorama-not-capped target=\(targetStr)")
        }

        vm.clearImages()
        await vm.addImage(image)
        guard vm.pendingImages.count == 1 else {
            throw BudgetFailure(reason: "panorama-attach-refused warning=\(vm.visionWarning ?? "nil")")
        }
        let assessed = assessAttached(vm: vm)
        let (outcome, nPos, peak) = try await sendAndAwait(vm: vm, text: "Describe this panorama in one short sentence.")
        guard outcome == "eval-success" else {
            throw BudgetFailure(reason: "eval-\(outcome)")
        }
        return baseRow(turn: "B", attach: "ACCEPTED-CAPPED", target: targetStr,
            nPos: nPos, peak: peak, outcome: "SUCCESS", extra: assessed)
    }

    // MARK: - Turn C: light attach, then heavy history -> contextWindowExceeded

    private static func runTurnC(vm: ChatViewModel, ctxLen: Int, maxTok: Int) async throws -> [String: String] {
        let image = try makeJPEG(width: 1024, height: 1024, quality: 0.8)
        vm.clearImages()
        await vm.addImage(image)
        guard vm.pendingImages.count == 1 else {
            throw BudgetFailure(reason: "light-attach-refused warning=\(vm.visionWarning ?? "nil")")
        }
        let assessed = assessAttached(vm: vm)
        // Grow history heavy since attach (mirrors Batch24: 1970 tokens + 441 + 2048 + 1 > 4096).
        vm.inputText = String(repeating: "a", count: 1970 * 4) + " Describe the attached image."
        let (outcome, nPos, peak) = try await sendAndAwait(vm: vm, text: nil)
        // Expect clean contextWindowExceeded surfaced, app alive, no abort.
        // sendAndAwait maps errorMessage containing "context window" to context-exceeded.
        guard outcome == "context-exceeded" else {
            throw BudgetFailure(reason: "expected-context-exceeded got=\(outcome) n_pos=\(nPos ?? "nil")")
        }
        // App alive: view model still responsive, no crash (we are running).
        return baseRow(turn: "C", attach: "ACCEPTED-THEN-EXCEEDED", target: "n/a",
            nPos: nPos, peak: peak, outcome: "SUCCESS-CLEAN-EXCEEDED", extra: assessed)
    }

    // MARK: - Send helper (peak sampler + outcome classification)

    /// Sends (text or current inputText when text is nil) and awaits streaming end.
    /// Returns (outcome, nPos, peakBytes): outcome is eval-success | context-exceeded | eval-error-<msg>.
    private static func sendAndAwait(vm: ChatViewModel, text: String?) async throws -> (String, String?, String) {
        LlamaEngine.lastVisionChunkPositions = 0
        let baseline = MemorySnapshotReader.capture(.cold).physicalFootprintBytes
        var peak = baseline
        var sawStreaming = false
        var sawText = false
        let sampler = Task {
            while !Task.isCancelled {
                let snap = MemorySnapshotReader.capture(.periodic).physicalFootprintBytes
                if snap > peak { peak = snap }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }
        if let text { vm.inputText = text }
        // Pre-send quiescence: a send landing mid-load is dropped via the
        // transient truncation banner (no errorMessage), so settle first.
        for _ in 0..<120 where vm.isLoadingConversation || vm.isStreaming {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let assistantBefore = vm.messages.filter { $0.role == .assistant }.count
        await vm.sendMessage()
        // Silent-drop retry: pending intact + never streamed + no error means
        // the load-gate dropped it ("try again now that it's open").
        if !vm.isStreaming, vm.pendingImages.count > 0, (vm.errorMessage ?? "").isEmpty,
           vm.messages.filter({ $0.role == .assistant }).count == assistantBefore,
           vm.streamingText.isEmpty {
            try? await Task.sleep(for: .milliseconds(2000))
            if !vm.isLoadingConversation, !vm.isStreaming,
               vm.messages.filter({ $0.role == .assistant }).count == assistantBefore {
                await vm.sendMessage()
            }
        }
        // Await streaming end (bounded 600s for on-device eval). The
        // onComplete/onError handlers dispatch async Tasks that set
        // isStreaming=false (finishGeneration) BEFORE appending the reply /
        // error, so a settle delay after the flag drops is required.
        var waited = 0
        while vm.isStreaming {
            sawStreaming = true
            if !vm.streamingText.isEmpty { sawText = true }
            if waited >= 1200 { sampler.cancel(); throw BudgetFailure(reason: "stream-timeout") }
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
            let snap = MemorySnapshotReader.capture(.periodic).physicalFootprintBytes
            if snap > peak { peak = snap }
        }
        sampler.cancel()
        // Settle: let the completion task append + reload (bounded 15s).
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            if vm.messages.filter({ $0.role == .assistant }).count > assistantBefore { break }
            if !(vm.errorMessage ?? "").isEmpty { break }
            if !vm.streamingText.isEmpty { break }
        }
        let nPos = LlamaEngine.lastVisionChunkPositions > 0
            ? String(LlamaEngine.lastVisionChunkPositions) : nil
        let assistantAfter = vm.messages.filter { $0.role == .assistant }.count
        if assistantAfter > assistantBefore || sawText || !vm.streamingText.isEmpty {
            return ("eval-success", nPos, String(peak))
        }
        let err = (vm.errorMessage ?? "").lowercased()
        if err.contains("context window") { return ("context-exceeded", nPos, String(peak)) }
        if !err.isEmpty {
            let clean = vm.errorMessage!.replacingOccurrences(of: "\n", with: " ").prefix(120).description
            return ("eval-error-\(clean)", nPos, String(peak))
        }
        let warn = (vm.visionWarning ?? "nil").prefix(80).description
        let trunc = (vm.truncationWarning ?? "nil").prefix(80).description
        let detail = "sawStreaming=\(sawStreaming) loading=\(vm.isLoadingConversation)" +
            " pend=\(vm.pendingImages.count) warn=\(warn) trunc=\(trunc)" +
            " streaming=\(vm.streamingText.prefix(40))"
        return ("eval-error-unknown \(detail)", nPos, String(peak))
    }

    // MARK: - Image synthesis + attachments

    private static func makeJPEG(width: Int, height: Int, quality: Double) throws -> Data {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BudgetFailure(reason: "image-context-failed")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Contrast square so the image is not degenerate.
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let cg = ctx.makeImage() else { throw BudgetFailure(reason: "image-render-failed") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw BudgetFailure(reason: "jpeg-dest-failed")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BudgetFailure(reason: "jpeg-encode-failed") }
        return out as Data
    }

    private static func assessAttached(vm: ChatViewModel) -> [String: String] {
        guard let data = vm.pendingImages.first,
              let dims = ChatViewModel.pixelDimensions(of: data) else {
            return ["attachedDims": "unknown", "attachedBytes": String(vm.pendingImages.first?.count ?? 0)]
        }
        return ["attachedDims": "\(dims.width)x\(dims.height)", "attachedBytes": String(data.count)]
    }

    private static func baseRow(turn: String, attach: String, target: String,
        nPos: String?, peak: String, outcome: String, extra: [String: String]) -> [String: String] {
        var row: [String: String] = [
            "turn": turn, "outcome": outcome, "attach": attach, "target": target,
            "n_pos": nPos ?? "nil", "peakBytes": peak,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        for (key, value) in extra { row[key] = value }
        return row
    }

    private static func persistRow(turn: String, row: [String: String]) {
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("budget-proof-turns", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("turn-\(turn).jsonl")
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            print("[VISION-BUDGET-ROW] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {
            print("[VISION-BUDGET-ERROR] persist failed: \(error.localizedDescription)")
        }
    }
}
#endif

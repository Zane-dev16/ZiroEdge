import Foundation
import Darwin
import os

protocol MemoryMetricsProviding: Sendable {
    func processAvailableMemory() -> UInt64
    func totalRAM() -> UInt64
    /// The ceiling this process can ever reach: its jetsam limit. `0` means the
    /// platform would not say, and no caller may claim a structural refusal
    /// without it.
    ///
    /// Derived, not guessed: `os_proc_available_memory()` is documented as the
    /// app's limit minus its current footprint, so limit = available +
    /// phys_footprint. This is a *reporting* input only. It separates "you are
    /// short right now" from "this iPhone will never give ZiroEdge that much",
    /// and it never admits a load (required > limit implies required >
    /// available, so every structural refusal was already a refusal).
    func processMemoryLimit() -> UInt64
}

extension MemoryMetricsProviding {
    func processMemoryLimit() -> UInt64 { 0 }
}

struct FixedMemoryMetricsProvider: MemoryMetricsProviding {
    let processAvailable: UInt64
    let total: UInt64
    /// `0` (the default) keeps every existing fixture on the pre-ceiling path:
    /// no test may start reporting a structural refusal by accident.
    var processLimit: UInt64 = 0

    func processAvailableMemory() -> UInt64 { processAvailable }
    func totalRAM() -> UInt64 { total }
    func processMemoryLimit() -> UInt64 { processLimit }
}

struct SystemMemoryMetricsProvider: MemoryMetricsProviding {
    func processAvailableMemory() -> UInt64 { UInt64(os_proc_available_memory()) }
    func totalRAM() -> UInt64 {
        var size: UInt64 = 0
        var sizeSize = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &sizeSize, nil, 0) == 0 ? size : 0
    }
    func processMemoryLimit() -> UInt64 {
        let available = UInt64(os_proc_available_memory())
        guard available > 0, let footprint = Self.physicalFootprintBytes() else { return 0 }
        return SaturatedArithmetic.add(available, footprint)
    }

    /// Jetsam accounts the same `phys_footprint` this reads; it is the term the
    /// kernel subtracts before `os_proc_available_memory` answers.
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

struct MemoryLoadDecision: Equatable, Sendable {
    let recommendation: MemoryRecommendation
    let processAvailableBytes: UInt64
    let totalPhysicalBytes: UInt64
    let profileID: String?
    let requiredBytes: UInt64?
    let reason: MemoryAdmissionFailure?
    /// Post-teardown projection (raw headroom + reclaimable resident) and
    /// the reclaimable credit used. Nil for pre-credit callers/tests.
    var projectedAvailableBytes: UInt64? = nil
    var reclaimableBytes: UInt64? = nil
    /// The most this process can ever have (its jetsam limit), sampled with the
    /// rest of the reading. `0` when the platform would not say. Reporting and
    /// wording only — see `MemoryMetricsProviding.processMemoryLimit()`.
    var appMemoryLimitBytes: UInt64 = 0

    /// A regression sentinel: admission never consumes download/storage byte counts.
    var artifactBytesUsedForAdmission: UInt64? { nil }

    var formattedAppMemoryHeadroom: String { Self.format(bytes: processAvailableBytes) }

    static func format(bytes: UInt64) -> String {
        StorageByteFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    var logSummary: String {
        [
            "recommendation=\(recommendation)",
            "processHeadroomBytes=\(processAvailableBytes)",
            "projectedAvailableBytes=\(projectedAvailableBytes.map(String.init) ?? "none")",
            "reclaimableBytes=\(reclaimableBytes.map(String.init) ?? "none")",
            "totalPhysicalBytes=\(totalPhysicalBytes)",
            "profileID=\(profileID ?? "unknown")",
            "requiredBytes=\(requiredBytes.map(String.init) ?? "unknown")",
            "appMemoryLimitBytes=\(appMemoryLimitBytes)",
            "reason=\(reason?.rawValue ?? "none")",
        ].joined(separator: " ")
    }

    /// Plain-language sentence for a refused load.
    ///
    /// Delegates to `ModelLoadCopy` so an alert, an inline banner, and a model
    /// page cannot word the same state three different ways — and so the app
    /// never names a cause it has not explained. The switch stays exhaustive on
    /// purpose: adding a reason is a compile error here rather than a case that
    /// silently inherits another reason's sentence.
    func alertMessage(modelName: String, priorActive: AIModel? = nil) -> String {
        switch reason {
        case .profileUnvalidated, .profileMissing, .none:
            // Neither measurement nor estimate exists for this shape. Unreachable
            // for a shipped catalog row — `ModelCatalogValidator` refuses one —
            // so the fallback must not describe internal machinery.
            return ModelLoadCopy.genericFailure(modelName: modelName)
        case .profileDisabled:
            return ModelLoadCopy.pausedAfterRepeatedStops(modelName: modelName)
        case .consentRequired:
            return ModelLoadCopy.experimentalConsentRequired(modelName: modelName)
        case .metricsUnavailable:
            return ModelLoadCopy.memoryCheckUnavailable(modelName: modelName)
        case .physicalRAMBelowMinimum:
            return ModelLoadCopy.tooLargeForDevice(modelName: modelName)
        case .moreThanThisAppCanUse:
            return ModelLoadCopy.moreThanThisAppCanUse(
                modelName: modelName,
                requiredBytes: requiredBytes,
                limitBytes: appMemoryLimitBytes
            )
        case .postLoadReserveBreached:
            return ModelLoadCopy.wouldStarveDevice(modelName: modelName)
        case .insufficientProcessHeadroom:
            let base = ModelLoadCopy.notEnoughMemory(
                modelName: modelName,
                requiredBytes: requiredBytes,
                availableBytes: processAvailableBytes
            )
            // Zero-credit guidance (Fix verify b): when the resident prior
            // contributed no reclaimable credit because its shape has no size at
            // all, projected == raw by construction. Tell the user the remedy
            // (unload first, then retry) instead of leaving a bare number.
            // Purely presentational — admission math stays untouched.
            if (reclaimableBytes ?? 0) == 0,
               let prior = priorActive,
               Self.priorHasNoMeasurableEvidence(prior) {
                return base + " " + ModelLoadCopy.unloadFirst(
                    priorName: prior.displayName,
                    modelName: modelName
                )
            }
            return base
        }
    }

    /// True when `prior` exists but its shape has no size ZiroEdge can account
    /// for: no measurement, and no estimate either. An estimated shape does have
    /// a number, so it is explicitly not this case — that distinction is what
    /// keeps the "unload it first" advice from appearing for a model the app
    /// can already size.
    private static func priorHasNoMeasurableEvidence(_ prior: AIModel) -> Bool {
        guard let profile = MemoryProfileRegistry.profile(for: prior) else { return true }
        if profile.evidenceStatus == .validated { return false }
        if (try? profile.requiredProcessHeadroomBytes()) != nil { return false }
        if (try? profile.experimentalRequiredProcessHeadroomBytes()) != nil { return false }
        return (try? profile.estimatedRequiredProcessHeadroomBytes()) == nil
    }
}

enum MemoryAdmissionFailure: String, Sendable, Equatable {
    case metricsUnavailable
    case profileMissing
    case profileUnvalidated
    /// The shape has measured evidence, but the user has not agreed to the
    /// experimental runtime yet. Distinct from `.profileUnvalidated` because
    /// the remedy is different: nothing is wrong with the model, it just needs
    /// permission.
    case consentRequired
    case physicalRAMBelowMinimum
    case insufficientProcessHeadroom
    /// The shape's requirement exceeds this app's own memory limit, sampled as
    /// available + footprint. A resident model cannot be unloaded to close this
    /// gap and no other app is holding the memory: the process will never be
    /// allowed to allocate that much on this device. Distinct from
    /// `.insufficientProcessHeadroom`, whose remedy is to free memory now.
    case moreThanThisAppCanUse
    case postLoadReserveBreached
    case profileDisabled
}

/// One admission verdict: what to do, why, and the number it was compared to.
private struct MemoryAdmissionVerdict {
    var recommendation: MemoryRecommendation
    var reason: MemoryAdmissionFailure?
    var requiredBytes: UInt64?
}

/// One reading of the device's memory, taken together so no branch can compare
/// against a sample from a different moment.
private struct DeviceMemorySample {
    /// Process headroom right now. Every fail-closed gate reads this.
    let available: UInt64
    /// Headroom after the resident model is unloaded. Comparison-only.
    let projected: UInt64
    let total: UInt64
    /// The most this process can ever have. `0` = unknown, which forbids a
    /// structural refusal. Reporting only: it never admits a load.
    let limit: UInt64
}

/// Profile-based model-load policy. The caller must complete unload/recovery before invoking `decision`.
actor MemoryBudgeter {
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "memory")
    private let metrics: any MemoryMetricsProviding
    private var lastDecision: MemoryLoadDecision?

    init(metrics: any MemoryMetricsProviding = SystemMemoryMetricsProvider()) {
        self.metrics = metrics
    }

    func appMemoryHeadroom() -> UInt64 { metrics.processAvailableMemory() }
    func totalDeviceRAM() -> UInt64 { metrics.totalRAM() }

    /// P1-1: single fresh sample after the caller completes unload recovery.
    /// A transient zero (jetsam pressure settling) retries once immediately
    /// before failing closed as metricsUnavailable. Callers must NOT reuse a
    /// pre-teardown decision: re-invoke this immediately pre-mmap/context init
    /// (see constructAndCommit fresh resample + InferenceService pre-mmap gate).
    /// P1-4: malformed catalog sizes fail closed here as well (profileUnvalidated,
    /// artifact quantity still never used — sentinel stays nil).
    /// Pre-teardown switch callers pass the resident model's reclaimable
    /// credit: raw headroom failing while the projected (post-eviction)
    /// headroom passes returns .unloadCurrentFirst (proceed to teardown)
    /// instead of .insufficientRAM. Post-teardown gates pass reclaimable 0.
    /// Projected headroom after evicting the resident model. Saturated add:
    /// the projection never wraps and the decision caps it at total RAM.
    static func projectedAvailableAfterEviction(currentAvailable: UInt64, reclaimableBytes: UInt64) -> UInt64 {
        SaturatedArithmetic.add(currentAvailable, reclaimableBytes)
    }

    /// Device-calibrated actually-freed bytes (iPhone 5A3DC1B6, fresh signed
    /// DEBUG build 23:35 UTC, `devicectl launch --console`, `--switch-proof
    /// --memory-diagnostic`): gemma-4-e2b-q4 freed 736381808 (raw 2756243512
    /// ->3492625320), SmolLM prior hf-cf4a0dfb60e5eb160978dd9e freed 4390984
    /// (raw 3396418280->3400809264). Qwen target hf-ec6e37fe3e99bf0d922fe1fc
    /// (986MB base + 710MB projector, ctx4096) requires 2850000000 under the
    /// mmap-weighted estimator (est 1613886100 → 2100000000 + 750M reserve),
    /// so the 3390MB device headroom admits with ~540MB margin. The old
    /// full-projector weight demanded 3450000000 and refused by ~49M —
    /// estimate noise treated as OOM. Narrow pre-teardown misses still attempt
    /// teardown and let the post-teardown gates measure reality (with
    /// prior-restore as the net). Required-side conservatism stays fail-closed
    /// by design: no Qwen load peak exists yet.
    static let deviceMeasuredFreedValidatedVisionBytes: UInt64 = 736_381_808
    static let deviceMeasuredFreedUnvalidatedTextBytes: UInt64 = 4_390_984

    /// Reclaimable credit for evicting `priorActive`: min(estimated, measured
    /// actually-freed) — never more than teardown frees. Validated priors
    /// min(required, 736M device: gemma freed 42% of required, 2.4x fantasy
    /// removed, verdict unchanged); unvalidated text min(peak, 4M device:
    /// mmap base + untouched ctx never resident, SmolLM ~247x fantasy, so
    /// projected == post-teardown raw. A narrow miss on that projection is
    /// estimate noise, so pre-teardown gates attempt teardown and let the
    /// post-teardown gates measure reality (prior-restore on failure)
    /// instead of refusing while manual unload+load succeeds. Vision priors
    /// keep the mmap-weighted peak (projector pages like base) until their
    /// own teardown calibration lands; nil-peak priors (llama32-3B) stay 0 so
    /// projected==raw. Post-teardown hard gate (raw>=req_target, zero credit)
    /// stays authoritative. Smaller is fail-closed (refuses, never admits).
    static func reclaimableBytes(for priorActive: AIModel?) -> UInt64 {
        reclaimableCreditDetails(for: priorActive).bytes
    }

    /// Diagnosable reclaimable credit: same `bytes` math as
    /// `reclaimableBytes(for:)`, plus prior profile identity and evidence status.
    /// Logging-only — never an admission input.
    static func reclaimableCreditDetails(for priorActive: AIModel?) -> (bytes: UInt64, profileID: String?, evidenceStatus: String?) {
        guard let priorActive else { return (0, nil, nil) }
        guard let profile = MemoryProfileRegistry.profile(for: priorActive) else { return (0, nil, nil) }
        let status = profile.evidenceStatus.rawValue
        if let required = try? profile.requiredProcessHeadroomBytes() {
            // ponytail: min(required, measured freed); per-shape table if more validated models land.
            return (min(required, Self.deviceMeasuredFreedValidatedVisionBytes), profile.id, status)
        }
        if let estimatedRequired = try? profile.estimatedRequiredProcessHeadroomBytes() {
            // Estimated prior: its required floor is an upper bound on what the
            // resident model occupies, so crediting it would make the projection
            // more optimistic than reality — the one direction admission may
            // never move. Credit what teardown measurably frees for the same
            // class instead (text ~4MB: mmap base, context untouched), which
            // keeps projected == raw for text and stays fail-closed for vision.
            let cap = profile.mode == .text
                ? Self.deviceMeasuredFreedUnvalidatedTextBytes
                : Self.deviceMeasuredFreedValidatedVisionBytes
            return (min(estimatedRequired, cap), profile.id, status)
        }
        // ponytail: min(peak, measured freed) for text; vision keeps peak until
        // calibrated (see above). Policy-validated via experimental succeeding;
        // peak nil/invalid -> 0.
        guard (try? profile.experimentalRequiredProcessHeadroomBytes()) != nil,
              let peak = profile.measuredLoadDeltaBytes else {
            return (0, profile.id, status)
        }
        if profile.mode == .text {
            return (min(peak, Self.deviceMeasuredFreedUnvalidatedTextBytes), profile.id, status)
        }
        return (peak, profile.id, status)
    }

    /// Settle window for the pre-teardown transient-dip retry (Fix verify c):
    /// a headroom miss whose shortfall (required − projected) fits inside
    /// this window is worth one 1s settle + resample, because jetsam pressure
    /// routinely dips ~0.65GB (2.8GB vs 3.45GB observed) and recovers.
    /// Larger shortfalls (true OOM, e.g. 14GB model) skip the settle.
    static let transientDipSettleWindowBytes: UInt64 = 1_000_000_000

    /// Stable-settle rule (unified sampler for manual + switch paths):
    /// headroom is settled when `settleStableSamples` consecutive 100ms
    /// samples each land within ±`settleStableDeltaBytes` of the previous
    /// (~200ms of steadiness). Every wait is bounded by the caller's timeout
    /// and returns the last sample on timeout (callers fail closed on it as
    /// today). 50MB << 1GB dip window, so genuine recovery is detected
    /// without masking real shortfalls. decision() stays a pure single-sample
    /// function; polling lives here and one layer up so Fixed-provider tests
    /// stay deterministic.
    static let settleStableDeltaBytes: UInt64 = 50_000_000
    static let settleStableSamples: Int = 3
    static let settleSampleInterval: Duration = .milliseconds(100)
    /// Transient-dip settle budget: matches the previous fixed 2s sleep
    /// (fixes the stale "wait 1s" comment) as a bounded stable-wait.
    static let transientDipSettleTimeout: Duration = .seconds(2)
    /// Pre-mmap / pre-inference dip gate: 5 samples — a dip wait, not a
    /// full recovery.
    static let reserveDipSettleTimeout: Duration = .milliseconds(500)

    /// Poll processAvailable every 100ms until 3 consecutive samples agree
    /// within ±50MB or `timeout` elapses. Zero timeout returns one sample
    /// with no sleep (preserves `.zero` recoveryDelay tests). Cancellation
    /// returns the last sample promptly; epoch checks stay at MainActor call
    /// sites, which re-verify before any destructive step — a stale epoch
    /// therefore wastes at most this timeout, never loads stale.
    func settledAvailable(
        timeout: Duration,
        stableDeltaBytes: UInt64 = settleStableDeltaBytes,
        stableSamples: Int = settleStableSamples
    ) async -> UInt64 {
        var prev = metrics.processAvailableMemory()
        if timeout <= .zero || stableSamples <= 1 { return prev }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var steady = 1
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return prev }
            do {
                try await Task.sleep(for: Self.settleSampleInterval)
            } catch {
                return prev
            }
            let cur = metrics.processAvailableMemory()
            steady = (cur >= prev ? cur - prev : prev - cur) <= stableDeltaBytes ? steady + 1 : 1
            prev = cur
            if steady >= stableSamples { return prev }
        }
        return prev
    }

    /// Thin dip-retry wrapper: wait for settled headroom, then take the full
    /// decision fresh (when stable the fresh sample ≈ the settled one).
    /// Logger only — verdict math unchanged.
    func settledDecision(
        for model: AIModel,
        allowUnvalidatedCalibration allow: Bool = false,
        reclaimableBytes: UInt64 = 0,
        timeout: Duration
    ) async -> MemoryLoadDecision {
        let settled = await settledAvailable(timeout: timeout)
        logger.info("Settled resample headroom=\(settled, privacy: .public) model=\(model.id, privacy: .public)")
        return await decision(for: model, allowUnvalidatedCalibration: allow, reclaimableBytes: reclaimableBytes)
    }

    func decision(for model: AIModel, allowUnvalidatedCalibration: Bool = false, reclaimableBytes: UInt64 = 0) -> MemoryLoadDecision {
        // P1-4 fail-closed validity gate: quantity never admits, but malformed
        // sizes must refuse even before profile checks. IDs public.
        let needsProjector = model.requiresMMProj || model.mmprojURL != nil
        let hasValidSizes = model.baseFileSizeBytes > 0
            && (!needsProjector || (model.mmprojFileSizeBytes ?? 0) > 0)
        if !hasValidSizes {
            logger.fault("Load refused malformed artifact size \(model.id, privacy: .public)")
            let refused = MemoryLoadDecision(
                recommendation: .insufficientRAM,
                processAvailableBytes: metrics.processAvailableMemory(),
                totalPhysicalBytes: metrics.totalRAM(),
                profileID: MemoryProfileRegistry.profile(for: model)?.id,
                requiredBytes: nil,
                reason: .profileUnvalidated,
                appMemoryLimitBytes: metrics.processMemoryLimit()
            )
            lastDecision = refused
            return refused
        }
        var processAvailable = metrics.processAvailableMemory()
        var total = metrics.totalRAM()
        if processAvailable == 0 || total == 0 {
            // P1-1 retry-once: one immediate resample before failing closed.
            logger.fault("Memory metrics transient zero \(model.id, privacy: .public) retrying once")
            processAvailable = metrics.processAvailableMemory()
            total = metrics.totalRAM()
        }
        let profile = MemoryProfileRegistry.profile(for: model)
        // Projected post-eviction headroom: only the memory comparison may
        // use it — every fail-closed gate stays on raw samples. Capped at
        // total RAM so eviction can never free more than exists.
        let projected = min(
            Self.projectedAvailableAfterEviction(currentAvailable: processAvailable, reclaimableBytes: reclaimableBytes),
            total
        )
        // Sampled with the same reading as headroom, and never used to admit.
        let limit = metrics.processMemoryLimit()
        let verdict = Self.verdict(
            profile: profile,
            measuredRequired: try? profile?.requiredProcessHeadroomBytes(),
            allowUnvalidatedCalibration: allowUnvalidatedCalibration,
            sample: DeviceMemorySample(
                available: processAvailable,
                projected: projected,
                total: total,
                limit: limit
            )
        )
        let recommendation = verdict.recommendation
        let reason = verdict.reason
        let required = verdict.requiredBytes

        let decision = MemoryLoadDecision(
            recommendation: recommendation,
            processAvailableBytes: processAvailable,
            totalPhysicalBytes: total,
            profileID: profile?.id,
            requiredBytes: required,
            reason: reason,
            projectedAvailableBytes: projected,
            reclaimableBytes: reclaimableBytes,
            appMemoryLimitBytes: limit
        )
        lastDecision = decision
        // Fix verify (a): always log the calibration gate alongside the
        // decision so a consent-missing profileUnvalidated (required=nil)
        // can never masquerade as a headroom miss in logs. IDs public.
        let allowFlag = allowUnvalidatedCalibration ? 1 : 0
        let profileID = profile?.id ?? "nil"
        logger.info("Memory decision model=\(model.id, privacy: .public) allow=\(allowFlag, privacy: .public) profile=\(profileID, privacy: .public) \(decision.logSummary, privacy: .public)")
        // SWITCH-PROOF console mirror: Logger.info does not forward over devicectl --console.
        print("[SWITCH-PROOF-BUDGET] model=\(model.id) allow=\(allowFlag) profile=\(profileID) " +
            "raw=\(processAvailable) projected=\(projected) reclaimable=\(reclaimableBytes) " +
            "required=\(decision.requiredBytes.map(String.init) ?? "nil") " +
            "recommendation=\(recommendation) reason=\(reason?.rawValue ?? "none")")
        print("[SWITCH-PROOF-BUDGET-SUMMARY] \(decision.logSummary)")
        if reason == .profileUnvalidated {
            // Fault-level: the common cause is missing experimental consent
            // (or a missing controlled-workload override) on an imported
            // target whose experimentalRequired was therefore never compared
            // against the projection — not a headroom shortfall.
            logger.fault("Refused unvalidated model=\(model.id, privacy: .public) profile=\(profileID, privacy: .public) allow=\(allowFlag, privacy: .public) hint=grant-consent-or-override")
        } else if reason == .insufficientProcessHeadroom, reclaimableBytes == 0 {
            // Zero-credit headroom miss: projected==raw by construction
            // (no resident credit). Prior cause (unvalidated resident) is
            // logged by the lifecycle gates, which know priorActive.
            logger.fault("Refused headroom miss zero-credit model=\(model.id, privacy: .public) \(decision.logSummary, privacy: .public)")
        }
        return decision
    }

    /// Decide one load. Split out of `decision(for:...)` so the policy chain
    /// stays readable on its own: every branch here answers "may this shape be
    /// compared against device headroom, and with what number?"
    ///
    /// Order matters and is load-bearing:
    /// 1. unreadable samples refuse (never invent a number);
    /// 2. a model with no shape at all refuses (catalog gate prevents this);
    /// 3. a device below the shape's physical floor can never host it;
    /// 4. explicit consent (or DEBUG calibration) uses retained measured evidence;
    /// 5. with no measurement, the conservative static estimate admits or refuses;
    /// 6. nothing left to compare against refuses.
    private static func verdict(
        profile: MemoryProfile?,
        measuredRequired: UInt64?,
        allowUnvalidatedCalibration: Bool,
        sample: DeviceMemorySample
    ) -> MemoryAdmissionVerdict {
        // Raw pass → proceed. Raw fail but projected pass → unloadCurrentFirst
        // (proceed to teardown; the post-teardown hard gate re-samples with
        // zero credit). Both fail → insufficientRAM.
        func compare(_ required: UInt64) -> MemoryAdmissionVerdict {
            // Structural first: a requirement above the process's own limit can
            // never be met, so no headroom number is worth consulting. Reported
            // as its own reason so the sentence a user reads says "this will not
            // fit here" instead of advising them to free memory that is not there.
            if sample.limit > 0, required > sample.limit {
                return refuse(.moreThanThisAppCanUse, required: required)
            }
            if sample.available >= required {
                return MemoryAdmissionVerdict(recommendation: .proceed, reason: nil, requiredBytes: required)
            }
            if sample.projected >= required {
                return MemoryAdmissionVerdict(recommendation: .unloadCurrentFirst, reason: nil, requiredBytes: required)
            }
            return MemoryAdmissionVerdict(
                recommendation: .insufficientRAM,
                reason: .insufficientProcessHeadroom,
                requiredBytes: required
            )
        }
        func refuse(_ reason: MemoryAdmissionFailure, required: UInt64? = nil) -> MemoryAdmissionVerdict {
            MemoryAdmissionVerdict(recommendation: .insufficientRAM, reason: reason, requiredBytes: required)
        }

        if sample.available == 0 || sample.total == 0 {
            return refuse(.metricsUnavailable)
        }
        guard let profile else {
            return refuse(.profileMissing)
        }
        if sample.total < profile.minimumPhysicalRAMBytes {
            return refuse(.physicalRAMBelowMinimum)
        }
        if let measuredRequired {
            return compare(measuredRequired)
        }
        if allowUnvalidatedCalibration {
            // Normal experimental consent still requires measured runtime
            // evidence. DEBUG controlled calibration is the only path that may
            // gather the first evidence for a shape that has none.
            if let experimentalRequired = try? profile.experimentalRequiredProcessHeadroomBytes() {
                return compare(experimentalRequired)
            }
#if DEBUG
            if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled {
                return MemoryAdmissionVerdict(recommendation: .proceed, reason: nil, requiredBytes: nil)
            }
#endif
            return refuse(.profileUnvalidated)
        }
        // No device measurement exists for this exact shape, so admit on the
        // conservative static estimate rather than refusing forever.
        //
        // This is the tier that makes the catalog usable: before it, only a shape
        // that had completed a DEBUG-only calibration run could load, which made
        // nine of the ten shipped models permanently unloadable and left the user
        // reading a memory-policy sentence instead of getting an answer. The
        // estimate over-states on every term (see
        // `MemoryProfile.estimatedLoadDeltaBytes`), the post-load reserve check
        // still runs, and memory pressure still unloads, so the failure
        // direction is a refused load, never a jetsam.
        if let estimated = try? profile.estimatedRequiredProcessHeadroomBytes() {
            return compare(estimated)
        }
        // Nothing to compare against. Distinguish the two ways to get here: a
        // measured-but-unconsented shape (the remedy is permission) from a shape
        // with no number at all (the remedy is a catalog fix).
        if profile.runtimeEligibility == .experimental {
            return refuse(.consentRequired)
        }
        return refuse(.profileUnvalidated)
    }

    /// One post-load sample; validated and calibration loads must retain the fixed reserve.
    func postLoadReserveSatisfied() -> Bool {
        metrics.processAvailableMemory() >= MemoryProfile.productionReserveBytes
    }

    func formattedAppMemoryHeadroom() -> String {
        if let lastDecision { return lastDecision.formattedAppMemoryHeadroom }
        return MemoryLoadDecision.format(bytes: appMemoryHeadroom())
    }

    func formattedTotalRAM() -> String { MemoryLoadDecision.format(bytes: totalDeviceRAM()) }
}

enum MemoryRecommendation: Sendable, Equatable {
    case proceed
    case unloadCurrentFirst
    case insufficientRAM
}

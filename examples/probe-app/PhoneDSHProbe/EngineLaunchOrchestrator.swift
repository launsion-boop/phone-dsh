// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the one owner of "when the engine starts and when the
// ready sweep runs" on iOS (PLAN §2.1, host contract §10.2).
//
// Every channel funnels one request into ``wake(_:lease:)``:
//
//   phase A  content that needs no engine (Bot store + roster, session
//            snapshot, outbox scan, admission pass)
//   phase B  one idempotent `ensureEngine` decision (boot / resume / ready)
//   phase C  bind the consumers (Bot composition → DSH session → MCP listener)
//   phase D  ReadySweep: native steps 1–3 here, Bot steps 4–7 in
//            `BotRuntimeComposition.runReadySweep(_:)`, merged into one report
//
// Serial and merged: one wake per `(engineIncarnation, wakeId)` runs at most
// once; a second caller with the same key joins the in-flight run or its
// completed outcome.

import Foundation
import PhoneDSH
import ProbeKit
import UIKit

@MainActor
final class EngineLaunchOrchestrator {
    static let shared = EngineLaunchOrchestrator()

    private struct WakeKey: Hashable {
        let incarnation: Int
        let wakeId: String
    }

    private let chat: ChatModel
    private let cloud: CloudTaskCenter
    /// The one in-flight wake. A wake arriving before stage D joins it; one
    /// arriving during stage D collapses into at most one pending follow-up
    /// (§10.2.5 merge rule).
    private var current: Task<EngineLaunchOutcome, Never>?
    private var currentPhase: WakePhase?
    private var pendingWake: PendingWake?
    private var runGeneration = 0
    private struct PendingWake {
        var reason: WakeReason
        var lease: WakeLease?
        var wakeId: String
    }
    private var recent: [WakeKey: EngineLaunchOutcome] = [:]
    private var recentOrder: [WakeKey] = []
    private static let recentLimit = 32
    private var wakeCounter = 0

    private let boardSource = BoardWakeSource()
    private let pushSource = PushWakeSource()
    private var wakeSourcesInstalled = false

    /// PLAN §2.9 I2/I5: the durable demand ledger plus its resident timer and
    /// OS-channel projection. The scheduler only knows how to ask for a
    /// `.scheduledDemand` wake; the orchestrator stays the only engine entry.
    private lazy var scheduler: WakeScheduler = {
        WakeScheduler(
            ledger: WakeDemandLedger.applicationSupport(),
            projection: WakeScheduler.Projection(
                wake: { [weak self] in
                    _ = await self?.wake(.scheduledDemand, lease: nil)
                },
                project: { backgroundEarliestMs in
                    // §10.3.3: the background request never asks earlier than
                    // now + minBackgroundDelayMs, resident or not.
                    let date = backgroundEarliestMs.map {
                        Date(timeIntervalSince1970: Double($0) / 1000)
                    }
                    if let date {
                        _ = EngineLaunchRefreshTask.submit(earliestBeginDate: date)
                        _ = EngineLaunchProcessingTask.submit(earliestBeginDate: date)
                    } else {
                        EngineLaunchRefreshTask.cancel()
                        EngineLaunchProcessingTask.cancel()
                    }
                },
                isResident: {
                    // §10.1 residency: foreground (a cold launch is inactive) or
                    // an existing audio keep-alive. The projection never creates it.
                    UIApplication.shared.applicationState != .background
                        || SilentAudioKeepAlive.shared.isActive
                }))
    }()

    private init() {
        chat = .shared
        cloud = .shared
    }

    /// The current engine instance generation (bumped by ChatModel on every
    /// fresh Host adoption). Part of the sweep merge key.
    var engineIncarnation: Int { chat.engineIncarnation }

    // MARK: - Wake sources (PLAN §2.8)

    /// Installs the App-side adapters on the single entry. Idempotent.
    func installWakeSources() {
        guard !wakeSourcesInstalled else { return }
        wakeSourcesInstalled = true
        boardSource.start { [weak self] lease in
            _ = await self?.wake(.boardWake, lease: lease)
        }
        pushSource.start { [weak self] lease in
            _ = await self?.wake(.cloudTaskPush, lease: lease)
        }
        // PLAN §2.9: resume the host timer over the durable ledger and project
        // the earliest due time onto the OS channels.
        scheduler.start()
    }

    // MARK: - WakeDemand ledger (PLAN §2.9)

    /// Upserts one future due point and re-projects the OS wake channels.
    /// Producers (Bot routines, connectors, DSH schedule mirror, host retries)
    /// call this before expressing any "run later" intent.
    func upsertWakeDemand(_ demand: WakeDemand) async {
        do {
            try await scheduler.upsert(demand)
        } catch {
            ChatModel.appendDiagnostic("wake demand upsert failed: \(NativeLogRedaction.error(error))")
        }
    }

    func removeWakeDemand(source: WakeDemandSource, key: String) async {
        do {
            try await scheduler.remove(source: source, key: key)
        } catch {
            ChatModel.appendDiagnostic("wake demand remove failed: \(NativeLogRedaction.error(error))")
        }
    }

    func removeWakeDemands(source: WakeDemandSource) async {
        do {
            try await scheduler.removeAll(source: source)
        } catch {
            ChatModel.appendDiagnostic("wake demand removeAll failed: \(NativeLogRedaction.error(error))")
        }
    }

    func wakeDemands() async -> [WakeDemand] {
        do {
            return try await scheduler.demands()
        } catch {
            ChatModel.appendDiagnostic("wake demand read unavailable: \(NativeLogRedaction.error(error))")
            return []
        }
    }

    /// Called on `applicationDidEnterBackground` / before a park: the resident
    /// timer will not run, so the earliest due time goes to the OS channels now.
    func appDidEnterBackground() async {
        await scheduler.enterBackground()
    }

    /// I4: every newly adopted engine instance owes one ReadySweep, no matter
    /// which path booted/resumed it. ChatModel calls this after adoption; an
    /// in-flight wake already owns the sweep, so it is merged rather than
    /// duplicated.
    func engineIncarnationAdopted(_ incarnation: Int) async {
        guard EngineAdoptionPolicy.shouldSweep(
            incarnationChanged: incarnation == engineIncarnation,
            wakeInFlight: current != nil) else { return }
        let reason: WakeReason = UIApplication.shared.applicationState == .background
            ? .engineRecovered : .foreground
        _ = await wake(reason, lease: nil)
    }

    /// A board wake event; the voice turn writes its admission before it needs
    /// the engine, so this adapter's durable request is the admission record
    /// itself (the wake carries no payload).
    func boardWake() async {
        await boardSource.signal()
    }

    /// The one entry every channel uses.
    ///
    /// `lease` is `nil` for a foreground / resident-audio wake; a push or
    /// BGTask wake passes the lease built from its OS window. This method never
    /// starts the engine directly for an individual caller: the policy decides.
    ///
    /// Merge rule (§10.2.5): a wake that arrives before the in-flight wake
    /// reaches stage D joins it; arrivals during stage D collapse into one
    /// follow-up wake with the widest eligibility. The caller always awaits the
    /// run it joined, so it never returns before its engine decision exists.
    func wake(_ reason: WakeReason, lease: WakeLease?) async -> EngineLaunchOutcome {
        let wakeId = lease?.wakeId ?? "\(reason.rawValue)-\(nextWakeID())"
        let key = WakeKey(incarnation: engineIncarnation, wakeId: wakeId)
        if let completed = recent[key] { return completed }
        if let running = current {
            switch WakeMergePolicy.action(hasInFlight: true, phase: currentPhase) {
            case .joinInFlight:
                return await running.value
            case .mergePending:
                if var pending = pendingWake {
                    pending.lease = WakeMergePolicy.mergedLease(pending.lease, lease)
                    if lease == nil { pending.reason = reason }
                    pendingWake = pending
                } else {
                    pendingWake = PendingWake(reason: reason, lease: lease, wakeId: wakeId)
                }
                return await running.value
            case .start:
                break
            }
        }
        let task = startRun(reason: reason, lease: lease, wakeId: wakeId, key: key)
        return await task.value
    }

    private func startRun(reason: WakeReason, lease: WakeLease?, wakeId: String,
                          key: WakeKey) -> Task<EngineLaunchOutcome, Never> {
        runGeneration += 1
        let generation = runGeneration
        currentPhase = .stageA
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return EngineLaunchOutcome(wakeId: wakeId, reason: reason,
                                           engineIncarnation: 0, decision: .deferred,
                                           engine: .notRequested)
            }
            let outcome = await self.performWake(reason: reason, lease: lease, wakeId: wakeId)
            await self.finishRun(generation: generation, key: key, outcome: outcome)
            return outcome
        }
        current = task
        return task
    }

    private func finishRun(generation: Int, key: WakeKey,
                           outcome: EngineLaunchOutcome) async {
        guard generation == runGeneration else { return }
        remember(key, outcome)
        currentPhase = nil
        current = nil
        if let pending = pendingWake {
            pendingWake = nil
            _ = startRun(reason: pending.reason, lease: pending.lease,
                         wakeId: pending.wakeId,
                         key: WakeKey(incarnation: engineIncarnation, wakeId: pending.wakeId))
        }
    }

    static func nowMs() -> Int64 { WakeDemandLedger.nowMs() }

    private func nextWakeID() -> Int {
        wakeCounter += 1
        return wakeCounter
    }

    private func remember(_ key: WakeKey, _ outcome: EngineLaunchOutcome) {
        recent[key] = outcome
        recentOrder.append(key)
        while recentOrder.count > Self.recentLimit {
            recent.removeValue(forKey: recentOrder.removeFirst())
        }
    }

    // MARK: - One wake

    private func performWake(reason: WakeReason, lease: WakeLease?, wakeId: String) async -> EngineLaunchOutcome {
        let decision = EngineLaunchPolicy.decide(
            reason: reason,
            foreground: UIApplication.shared.applicationState != .background,
            residentAudio: SilentAudioKeepAlive.shared.isActive,
            hostState: chat.engineHostState,
            leaseRemainingMs: lease?.remainingMs(),
            userStopped: chat.engineUserStopped,
            needsReset: chat.engineNeedsReset)

        // Phase A — engine-free immediate content. Runs for every decision so
        // the page paints before the engine exists and a deferred wake still
        // keeps its durable queue moving.
        currentPhase = .stageA
        await chat.prepareLaunchContentForWake()
        // Residency may have changed since the last projection; re-arm the
        // resident timer now (I5 also re-projects on every ledger write).
        await scheduler.refresh()

        var engineResult: EngineLaunchOutcome.EngineResult = .notRequested
        var consumersBound = false

        currentPhase = .stageB
        switch decision {
        case .boot, .resume:
            // The lease authorizes this wake for its whole span; every gate in
            // ChatModel reads the same value until the sweep ends.
            chat.adoptWakeLease(lease, reason: reason)
            if decision == .boot {
                await chat.startForWake(reason)
                engineResult = chat.engineHostState == .running ? .booted : .failed
            } else {
                await chat.resumeForWake(reason)
                engineResult = chat.engineHostState == .running ? .resumed : .failed
            }
            if engineResult == .booted || engineResult == .resumed {
                // Phase C.
                currentPhase = .stageC
                consumersBound = await chat.prepareConsumersForWake()
            }
        case .ready:
            chat.adoptWakeLease(lease, reason: reason)
            currentPhase = .stageC
            consumersBound = await chat.prepareConsumersForWake()
        case .nativeOnly, .deferred, .needsAttention:
            break
        }

        // ReadySweep runs only after stage C succeeded (§10.2.5). A wake that
        // could not bring the engine up produces no report at all; the durable
        // work stays where it is for the next eligible wake.
        var report: ReadySweepReport?
        switch decision {
        case .ready:
            currentPhase = .stageD
            report = await runReadySweep(wakeId: wakeId, reason: reason, lease: lease,
                                         consumersBound: consumersBound)
        case .boot, .resume:
            if engineResult == .booted || engineResult == .resumed {
                currentPhase = .stageD
                report = await runReadySweep(wakeId: wakeId, reason: reason, lease: lease,
                                             consumersBound: consumersBound)
            }
        case .nativeOnly:
            // Lease too short (or no residency): the engine-free passes only.
            await runNativePasses(lease: lease)
            // Ask the system for a later, longer window; the work stays durable.
            _ = EngineLaunchProcessingTask.submit()
        case .deferred, .needsAttention:
            break
        }

        chat.clearWakeLease()
        return EngineLaunchOutcome(wakeId: wakeId,
                                   reason: reason,
                                   engineIncarnation: engineIncarnation,
                                   decision: decision,
                                   engine: engineResult,
                                   sweep: report)
    }

    // MARK: - Phase D (ReadySweep as a source registry, PLAN §2.9 I4)

    /// One pass over every contract source, in order. Native steps 1–3, the
    /// Bot composition's steps 4–7 (through one aggregate adapter around its
    /// `runReadySweep`), and the host's steps 8–9 are all sources; adding a
    /// source never changes this method.
    private func runReadySweep(wakeId: String, reason: WakeReason, lease: WakeLease?,
                               consumersBound: Bool) async -> ReadySweepReport {
        let remaining: @Sendable () -> Int64 = { [lease] in lease?.remainingMs() ?? .max }
        let context = ReadySweepContext(wakeId: wakeId, reason: reason,
                                        engineIncarnation: engineIncarnation,
                                        remainingMs: remaining)
        let botGroup = BotSweepAggregate(chat: chat, engineBound: consumersBound)
        let registry = ReadySweepRegistry(providers: [
            { [weak self] in
                guard let self else { return [] }
                return [OutboxReadySweepSource(chat: self.chat),
                        ExternalAdmissionReadySweepSource(chat: self.chat),
                        CloudPullReadySweepSource(cloud: self.cloud)]
            },
            { botGroup.sources },
            { [weak self] in
                guard let self else { return [] }
                return [DshScheduleReadySweepSource(chat: self.chat),
                        HostRetriesReadySweepSource(chat: self.chat, scheduler: self.scheduler)]
            },
        ])
        return await registry.run(context)
    }

    /// Lease fallback (§10.2.4 step 5, PLAN §2.3): the engine-free passes only.
    /// These are stage-A work, so they produce no ReadySweep report.
    private func runNativePasses(lease: WakeLease?) async {
        await chat.runAdmissionPassForWake()
        if let last = cloud.lastPullAt,
           Date().timeIntervalSince(last) * 1000
               < Double(EngineLaunchThresholds.cloudPullFreshnessMs) {
            return
        }
        _ = await cloud.runWakePull()
    }


}

// MARK: - ReadySweep sources (PLAN §2.9 I4)

/// Step 1: the user's own queued sends. The source is "due" whenever the
/// registry asks; an empty queue reports `skipped("empty")`.
@MainActor
final class OutboxReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep = .userOutbox
    private let chat: ChatModel

    init(chat: ChatModel) { self.chat = chat }

    func due(nowMs: Int64) async -> Bool { true }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        await chat.drainOutboxForWake() ? .ran : .skipped(.noWork)
    }
}

/// Step 2: admitted external requests. The journal remains the durable owner;
/// the pass only hands ready records to their target.
@MainActor
final class ExternalAdmissionReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep = .externalAdmission
    private let chat: ChatModel

    init(chat: ChatModel) { self.chat = chat }

    func due(nowMs: Int64) async -> Bool { true }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        await chat.runAdmissionPassForWake()
        return .ran
    }
}

/// Step 3: one cloud pull, skipped when this wake already pulled inside the
/// contract's freshness window.
@MainActor
final class CloudPullReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep = .cloudTaskPull
    private let cloud: CloudTaskCenter

    init(cloud: CloudTaskCenter) { self.cloud = cloud }

    func due(nowMs: Int64) async -> Bool { true }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        if let last = cloud.lastPullAt,
           Date().timeIntervalSince(last) * 1000
               < Double(EngineLaunchThresholds.cloudPullFreshnessMs) {
            return .skipped(.alreadyPulled)
        }
        return await cloud.runWakePull() ? .ran : .skipped(.gate)
    }
}

/// Steps 4–7: the Bot composition's four sources, exposed through ONE adapter
/// around its frozen `runReadySweep(_:)` (PLAN §4). The first Bot step the
/// registry reaches runs that pass; the other three read its report, so the
/// Bot side never duplicates work in one wake.
@MainActor
final class BotSweepAggregate {
    private let chat: ChatModel
    private let engineBound: Bool
    private var ranForWakeId: String?
    private var report = ReadySweepReport()

    init(chat: ChatModel, engineBound: Bool) {
        self.chat = chat
        self.engineBound = engineBound
    }

    var sources: [any ReadySweepSource] {
        [BotStepReadySweepSource(id: .botHeldInbox, group: self),
         BotStepReadySweepSource(id: .missedRoutines, group: self),
         BotStepReadySweepSource(id: .connectorScan, group: self),
         BotStepReadySweepSource(id: .approvalReminderSync, group: self)]
    }

    func outcome(for step: ReadySweepStep, context: ReadySweepContext) async -> ReadySweepOutcome {
        guard engineBound else { return .failed(reason: "bot_runtime_unavailable") }
        if ranForWakeId != context.wakeId {
            ranForWakeId = context.wakeId
            report = await chat.botRuntime?.runReadySweep(context) ?? ReadySweepReport()
        }
        return report.outcome(for: step) ?? .failed(reason: "bot_runtime_unavailable")
    }
}

@MainActor
final class BotStepReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep
    private let group: BotSweepAggregate

    init(id: ReadySweepStep, group: BotSweepAggregate) {
        self.id = id
        self.group = group
    }

    func due(nowMs: Int64) async -> Bool { true }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        await group.outcome(for: id, context: context)
    }
}

/// Step 8: the DSH schedule mirror (§10.3.5). While the engine is ready the
/// host refreshes the mirror with the existing DSH remote `schedule/list`; the
/// engine's own scheduler runs the due tasks, so this step only maintains the
/// wake hint.
@MainActor
final class DshScheduleReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep = .dshSchedule
    private let chat: ChatModel

    init(chat: ChatModel) { self.chat = chat }

    func due(nowMs: Int64) async -> Bool { chat.engineHostState == .running }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        await chat.refreshDshScheduleMirror() ? .ran : .failed(reason: "mirror-refresh")
    }
}

/// Step 9: host-owned retries that used to live only in `Task.sleep` — the
/// engine backoff window (`engineBoot`) and the outbox settle flush
/// (`outboxSettle`). `engineBoot` is consumed by the wake itself: the
/// orchestrator already decided the boot before stage D (§10.3.5).
@MainActor
final class HostRetriesReadySweepSource: ReadySweepSource {
    let id: ReadySweepStep = .hostRetries
    private let chat: ChatModel
    private let scheduler: WakeScheduler

    init(chat: ChatModel, scheduler: WakeScheduler) {
        self.chat = chat
        self.scheduler = scheduler
    }

    func due(nowMs: Int64) async -> Bool {
        guard let due = try? await scheduler.dueDemands(source: .hostRetry, nowMs: nowMs) else {
            ChatModel.appendDiagnostic("hostRetry demands unavailable")
            return false
        }
        return !due.isEmpty
    }

    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
        let due: [WakeDemand]
        do {
            due = try await scheduler.dueDemands(source: .hostRetry,
                                                 nowMs: EngineLaunchOrchestrator.nowMs())
        } catch {
            return .failed(reason: "ledger-unavailable")
        }
        guard !due.isEmpty else { return .skipped(.noWork) }
        for demand in due {
            switch demand.key {
            case "engineBoot":
                // The wake already made the decision; the demand is consumed.
                try? await scheduler.remove(source: .hostRetry, key: demand.key)
            case "outboxSettle":
                await chat.flushSettleFromDemand()
                try? await scheduler.remove(source: .hostRetry, key: demand.key)
            default:
                try? await scheduler.remove(source: .hostRetry, key: demand.key)
            }
        }
        return .ran
    }
}

// MARK: - Channel adapters (PLAN §2.8)

/// The TonoLink board / trusted BLE channel. `TonoLinkVoiceHost.receive` calls
/// ``signal()`` when the board's `ev wake` arrives; the voice turn's admission
/// record is the durable request and is written before any execution.
@MainActor
final class BoardWakeSource: WakeSource {
    let wakeReason: WakeReason = .boardWake
    private var deliver: (@MainActor (WakeLease?) async -> Void)?

    func start(deliver: @escaping @MainActor (WakeLease?) async -> Void) {
        self.deliver = deliver
    }

    func stop() {
        deliver = nil
    }

    /// One board wake. No lease: an armed board already holds the process with
    /// its audio keep-alive, which is the eligibility source (host §10.2).
    func signal() async {
        await deliver?(nil)
    }
}

/// The cloud-task push channel. `CloudTaskCenter` performs pull → admit → ack
/// first, then passes the lease built from `beginBackgroundTask`.
@MainActor
final class PushWakeSource: WakeSource {
    let wakeReason: WakeReason = .cloudTaskPush
    private var deliver: (@MainActor (WakeLease?) async -> Void)?

    func start(deliver: @escaping @MainActor (WakeLease?) async -> Void) {
        self.deliver = deliver
    }

    func stop() {
        deliver = nil
    }

    func signal(lease: WakeLease) async {
        await deliver?(lease)
    }
}

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
    /// Tail of the serial wake chain. A new wake runs after the previous one
    /// finished, so two wakes never interleave their engine transitions.
    private var tail: Task<Void, Never>?
    private var inFlight: [WakeKey: Task<EngineLaunchOutcome, Never>] = [:]
    private var recent: [WakeKey: EngineLaunchOutcome] = [:]
    private var recentOrder: [WakeKey] = []
    private static let recentLimit = 32
    private var wakeCounter = 0

    private let boardSource = BoardWakeSource()
    private let pushSource = PushWakeSource()
    private var wakeSourcesInstalled = false

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
    func wake(_ reason: WakeReason, lease: WakeLease?) async -> EngineLaunchOutcome {
        let wakeId = lease?.wakeId ?? "\(reason.rawValue)-\(nextWakeID())"
        let key = WakeKey(incarnation: engineIncarnation, wakeId: wakeId)
        if let completed = recent[key] { return completed }
        if let running = inFlight[key] { return await running.value }
        let previous = tail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else {
                return EngineLaunchOutcome(wakeId: wakeId, reason: reason,
                                           engineIncarnation: 0, decision: .deferred,
                                           engine: .notRequested)
            }
            return await self.performWake(reason: reason, lease: lease, wakeId: wakeId)
        }
        inFlight[key] = task
        tail = Task { _ = await task.value }
        let outcome = await task.value
        inFlight[key] = nil
        remember(key, outcome)
        return outcome
    }

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
        await chat.prepareLaunchContentForWake()

        var engineResult: EngineLaunchOutcome.EngineResult = .notRequested
        var consumersBound = false

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
                consumersBound = await chat.prepareConsumersForWake()
            }
        case .ready:
            chat.adoptWakeLease(lease, reason: reason)
            consumersBound = await chat.prepareConsumersForWake()
        case .nativeOnly, .deferred, .needsAttention:
            break
        }

        let report: ReadySweepReport?
        switch decision {
        case .ready, .boot, .resume:
            if decision == .ready || engineResult == .booted || engineResult == .resumed {
                report = await runReadySweep(wakeId: wakeId, reason: reason, lease: lease,
                                             consumersBound: consumersBound)
            } else {
                report = skippedSweep(reason: "engine_not_ready")
            }
        case .nativeOnly:
            // Lease too short (or no residency): the engine-free part only.
            report = await runNativeOnlyPasses(lease: lease)
            // Ask the system for a later, longer window; the work stays durable.
            _ = EngineLaunchProcessingTask.submit()
        case .deferred, .needsAttention:
            report = nil
        }

        chat.clearWakeLease()
        return EngineLaunchOutcome(wakeId: wakeId,
                                   reason: reason,
                                   engineIncarnation: engineIncarnation,
                                   decision: decision,
                                   engine: engineResult,
                                   sweep: report)
    }

    // MARK: - Phase D

    /// Native steps 1–3 and, when the Bot side is bound, its steps 4–7 merged
    /// into one report in the contract's fixed order.
    private func runReadySweep(wakeId: String, reason: WakeReason, lease: WakeLease?,
                               consumersBound: Bool) async -> ReadySweepReport {
        var report = ReadySweepReport()
        let remaining: @Sendable () -> Int64 = { [lease] in lease?.remainingMs() ?? .max }
        // 1. The user's own outbox.
        if ReadySweepPolicy.shouldRun(.userOutbox, remainingMs: remaining()) {
            if await chat.drainOutboxForWake() {
                report.record(.userOutbox, .ran)
            } else {
                report.record(.userOutbox, .skipped(reason: "empty"))
            }
        } else {
            report.record(.userOutbox, .skipped(reason: "lease"))
        }

        // 2. External admission pass.
        if ReadySweepPolicy.shouldRun(.externalAdmission, remainingMs: remaining()) {
            await chat.runAdmissionPassForWake()
            report.record(.externalAdmission, .ran)
        } else {
            report.record(.externalAdmission, .skipped(reason: "lease"))
        }

        // 3. One cloud pull; a pass that ran within the freshness window this
        // wake already pulled, so its own result is reused.
        if ReadySweepPolicy.shouldRun(.cloudTaskPull, remainingMs: remaining()) {
            if let last = cloud.lastPullAt,
               Date().timeIntervalSince(last) * 1000 < Double(EngineLaunchThresholds.cloudPullFreshnessMs) {
                report.record(.cloudTaskPull, .skipped(reason: "fresh"))
            } else if await cloud.runWakePull() {
                report.record(.cloudTaskPull, .ran)
            } else {
                report.record(.cloudTaskPull, .skipped(reason: "disabled"))
            }
        } else {
            report.record(.cloudTaskPull, .skipped(reason: "lease"))
        }

        // 4–7. The Bot side owns its four steps and re-reads the lease before
        // each one. `ReadySweepContext` is the frozen interface (PLAN §4).
        let botSteps: [ReadySweepStep] = [.botHeldInbox, .missedRoutines, .connectorScan, .approvalReminderSync]
        if consumersBound {
            let context = ReadySweepContext(wakeId: wakeId, reason: reason,
                                            engineIncarnation: engineIncarnation,
                                            remainingMs: remaining)
            report.steps.append(contentsOf: await botReadySweep(context).steps)
        } else {
            for step in botSteps { report.record(step, .skipped(reason: "engine_not_ready")) }
        }

        return report.ordered()
    }

    /// Lease fallback: only the engine-free passes, in order. Step 1 cannot
    /// run without a host; 4–7 belong to a wake that can boot.
    private func runNativeOnlyPasses(lease: WakeLease?) async -> ReadySweepReport {
        var report = ReadySweepReport()
        let remaining: @Sendable () -> Int64 = { [lease] in lease?.remainingMs() ?? .max }
        report.record(.userOutbox, .skipped(reason: "lease"))

        if ReadySweepPolicy.shouldRun(.externalAdmission, remainingMs: remaining()) {
            await chat.runAdmissionPassForWake()
            report.record(.externalAdmission, .ran)
        } else {
            report.record(.externalAdmission, .skipped(reason: "lease"))
        }

        if ReadySweepPolicy.shouldRun(.cloudTaskPull, remainingMs: remaining()) {
            if let last = cloud.lastPullAt,
               Date().timeIntervalSince(last) * 1000 < Double(EngineLaunchThresholds.cloudPullFreshnessMs) {
                report.record(.cloudTaskPull, .skipped(reason: "fresh"))
            } else if await cloud.runWakePull() {
                report.record(.cloudTaskPull, .ran)
            } else {
                report.record(.cloudTaskPull, .skipped(reason: "disabled"))
            }
        } else {
            report.record(.cloudTaskPull, .skipped(reason: "lease"))
        }

        for step in [ReadySweepStep.botHeldInbox, .missedRoutines, .connectorScan, .approvalReminderSync] {
            report.record(step, .skipped(reason: "lease"))
        }
        return report.ordered()
    }

    private func skippedSweep(reason: String) -> ReadySweepReport {
        ReadySweepReport(steps: ReadySweepStep.allCases.map {
            ReadySweepReport.StepResult(step: $0, outcome: .skipped(reason: reason))
        }).ordered()
    }

    // MARK: - Bot half (ios-bot)

    /// TEMPORARY until ios-bot lands `BotRuntimeComposition.runReadySweep(_:)`
    /// with the frozen PLAN §4 signature. Every Bot step reports `skipped`, so
    /// the native half runs and the merged report shape is exercised. Replace
    /// the body with:
    ///
    ///     await chat.botRuntime?.runReadySweep(context) ?? ReadySweepReport()
    ///
    /// when that unit's commit is in; no contract shape changes.
    private func botReadySweep(_ context: ReadySweepContext) async -> ReadySweepReport {
        var report = ReadySweepReport()
        for step in [ReadySweepStep.botHeldInbox, .missedRoutines, .connectorScan, .approvalReminderSync] {
            report.record(step, .skipped(reason: "bot_runtime_pending"))
        }
        return report
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

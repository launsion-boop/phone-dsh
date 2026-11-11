// SPDX-License-Identifier: MIT

import Foundation

public actor RoutineScheduler {
    public typealias Runner = @Sendable (RoutineRunRequest) async -> RoutineExecutionResult
    public typealias CancelRunner = @Sendable (RoutineCancellation) async -> RoutineCancellationResult
    public typealias Availability = @Sendable (String) async -> Bool
    public typealias Sleeper = @Sendable (Int64) async -> Void

    public let botId: String
    public let machine: RoutineMachine
    public let inbox: WakeInbox
    public let sink: any RoutineResultSink
    public let proactive: (any ProactiveConsidering)?
    public let notifications: (any RoutineNotificationScheduling)?

    private let runner: Runner
    private let cancelRunner: CancelRunner?
    private let available: Availability
    private let busy: Availability
    private let settingsProvider: @Sendable () -> ProactiveSettings
    private let nowProvider: @Sendable () -> Int64
    private let sleeper: Sleeper
    private let tickIntervalMs: Int64
    private let runTimeoutMs: Int64
    private let cancelGraceMs: Int64
    private let leaseOwner: String
    private var timerTask: Task<Void, Never>?
    private var stopped = false
    private var ticking = false
    private var active: Set<String> = []
    private var scheduledNotifications: [String: RoutineScheduledNotification] = [:]

    /// iOS keeps at most 64 pending notifications per application. Leave four
    /// slots for system/other-Bot notifications and keep the earliest 60
    /// routine due times.
    public static let maxScheduledNotifications = 60

    public init(botId: String, machine: RoutineMachine, inbox: WakeInbox,
                sink: any RoutineResultSink, proactive: (any ProactiveConsidering)? = nil,
                notifications: (any RoutineNotificationScheduling)? = nil,
                runner: @escaping Runner, cancelRunner: CancelRunner? = nil,
                available: @escaping Availability,
                busy: @escaping Availability = { _ in false },
                settings: @escaping @Sendable () -> ProactiveSettings = { ProactiveSettings() },
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleep: @escaping Sleeper = { milliseconds in
                    guard milliseconds > 0 else { return }
                    try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                },
                tickIntervalMs: Int64 = 5_000, runTimeoutMs: Int64 = 600_000,
                cancelGraceMs: Int64 = 5_000, leaseOwner: String = "local") {
        self.botId = botId
        self.machine = machine
        self.inbox = inbox
        self.sink = sink
        self.proactive = proactive
        self.notifications = notifications
        self.runner = runner
        self.cancelRunner = cancelRunner
        self.available = available
        self.busy = busy
        self.settingsProvider = settings
        self.nowProvider = now
        self.sleeper = sleep
        self.tickIntervalMs = max(1_000, tickIntervalMs)
        self.runTimeoutMs = max(1, runTimeoutMs)
        self.cancelGraceMs = max(0, cancelGraceMs)
        self.leaseOwner = leaseOwner
    }

    public func start() {
        guard timerTask == nil else { return }
        stopped = false
        let sleeper = self.sleeper
        let interval = tickIntervalMs
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.restoreAndTick()
                await sleeper(interval)
            }
        }
    }

    public func stop() {
        stopped = true
        timerTask?.cancel()
        timerTask = nil
    }

    public func queuedRoutines(now: Int64? = nil) async throws -> [Routine] {
        let at = now ?? nowProvider()
        return try await machine.list(botId: botId).filter {
            $0.enabled && $0.runState?.status != .needsReconciliation &&
            ($0.nextRunAt ?? Int64.max) <= at
        }.sorted { ($0.nextRunAt ?? 0, $0.createdAt, $0.id) < ($1.nextRunAt ?? 0, $1.createdAt, $1.id) }
    }

    private func restoreAndTick() async {
        if let proactive { _ = await proactive.restoreAccounting() }
        _ = try? await recover()
        try? await tick()
    }

    @discardableResult
    public func recover() async throws -> [RoutineRecoveryAction] {
        let now = nowProvider()
        let actions = try await machine.recover(botId: botId, now: now, leaseOwner: leaseOwner)
        try await inbox.recover()
        let pending = try await machine.pendingDeliveries(botId: botId, now: now, includeDelivering: true)
        for item in pending {
            await hold(item)
            if !item.proactiveHandled { await considerInterrupt(item) }
            if let latest = try await machine.delivery(item.deliveryKey, botId: botId) {
                await deliver(latest, force: true)
            }
        }
        await syncNotifications()
        return actions
    }

    public func tick() async throws {
        let now = nowProvider()
        if ticking {
            for routineId in active {
                _ = try await machine.recordSkip(botId: botId, routineId: routineId, at: now)
            }
            return
        }
        guard !stopped else { return }
        ticking = true
        defer { ticking = false }
        let routines = try await machine.list(botId: botId)
        for var routine in routines {
            if !routine.enabled || routine.runState?.status == .needsReconciliation { continue }
            if routine.runState?.status == .started {
                if active.contains(routine.id) {
                    _ = try await machine.recordSkip(botId: botId, routineId: routine.id, at: now)
                }
                continue
            }
            if active.contains(routine.id) {
                _ = try await machine.recordSkip(botId: botId, routineId: routine.id, at: now)
                continue
            }
            if routine.nextRunAt == nil, let repaired = try await machine.repairNextRun(botId: botId, routineId: routine.id, now: now) {
                routine = repaired
            }
            guard let nextRunAt = routine.nextRunAt, nextRunAt <= now else { continue }
            let settings = settingsProvider().normalized()
            let hasValidUrgentReason = !RoutineDeliveryFlags.clean(routine.urgentReason).isEmpty
            let mayBypassQuiet = routine.urgent && hasValidUrgentReason
            if !mayBypassQuiet && RoutineQuietHours.contains(now, settings: settings),
               let until = RoutineQuietHours.nextEnd(now, settings: settings), until > now {
                _ = try await machine.deferForQuiet(botId: botId, routineId: routine.id, until: until, now: now)
                continue
            }
            guard await available(botId), !(await busy(botId)) else { continue }
            let startedAt = nowProvider()
            guard let claim = try await machine.begin(
                botId: botId, routineId: routine.id, startedAt: startedAt,
                scheduledFor: nextRunAt, leaseOwner: leaseOwner,
                leaseTTLMs: runTimeoutMs + cancelGraceMs + 60_000
            ) else { continue }
            if !claim.claimed { continue }
            active.insert(routine.id)
            // The due reminder must not fire while the run is starting.
            await cancelScheduledNotifications(routineId: routine.id)
            await execute(claim, startedAt: startedAt)
            active.remove(routine.id)
        }
        await syncNotifications()
    }

    public func waitForIdle() async {
        while ticking || !active.isEmpty { await sleeper(1) }
    }

    private func execute(_ claim: RoutineClaim, startedAt: Int64) async {
        let routine = claim.routine
        guard let runState = routine.runState else { return }
        let result: RoutineExecutionResult
        do {
            let wake = try RoutineWakeBuilder.build(routine: routine, mode: .due,
                                                    firedAt: startedAt, now: startedAt)
            let request = RoutineRunRequest(botId: botId, routine: routine, runId: runState.runId,
                                            attempt: runState.attempt, startedAt: startedAt,
                                            timeoutMs: runTimeoutMs + cancelGraceMs + 1_000, wake: wake)
            result = await runWithDeadline(request)
        } catch {
            result = .failure("wake build failed: \(error.localizedDescription)")
        }
        var status: RoutineRunStatus
        var text = result.text
        let error = result.error
        var cancelOrigin = result.cancelledBy
        if result.cancelledBy == "timeout" {
            status = result.status == .cancelled ? .timedOut : .needsReconciliation
            cancelOrigin = "timeout"
        } else {
            switch result.status {
            case .succeeded:
                status = .succeeded
            case .failed:
                status = .failed
            case .cancelled:
                status = .cancelled
                cancelOrigin = cancelOrigin ?? "user"
            }
        }
        let reply = status == .succeeded ? RoutineWakeBuilder.normalizeReply(text) : RoutineReply(text: text, quiet: false)
        text = reply.text
        let quiet = status == .succeeded && (result.quiet || reply.quiet)
        if status == .timedOut || status == .needsReconciliation { text = "" }
        guard let finished = try? await machine.finish(
            botId: botId, routineId: routine.id, status: status, text: text, error: error,
            startedAt: startedAt, finishedAt: nowProvider(), attempt: runState.attempt,
            runId: runState.runId, reconcileRequired: status == .needsReconciliation,
            quiet: quiet, cancelOrigin: cancelOrigin
        ), !finished.ignored, let delivery = finished.delivery else { return }
        await hold(delivery)
        await considerInterrupt(delivery)
        if let latest = try? await machine.delivery(delivery.deliveryKey, botId: botId) {
            await deliver(latest)
        }
        await syncNotifications()
    }

    // MARK: - Local notifications and presence

    /// Reconciles the system's pending routine-due notifications with the
    /// current durable routines and the user's DND/quiet-hours authorization.
    /// Safe to call from a tick, after startup recovery, or immediately after
    /// the settings page writes a new value.
    public func syncNotifications() async {
        guard let notifications else { return }
        let now = nowProvider()
        let settings = settingsProvider().normalized()
        let routines = (try? await machine.list(botId: botId)) ?? []
        var desired: [RoutineScheduledNotification] = []
        if !settings.dnd {
            for routine in routines where routine.enabled {
                guard let nextRunAt = routine.nextRunAt else { continue }
                let mayBypassQuiet = routine.urgent
                    && !RoutineDeliveryFlags.clean(routine.urgentReason).isEmpty
                var fireAt = nextRunAt
                if !mayBypassQuiet,
                   RoutineQuietHours.contains(nextRunAt, settings: settings),
                   let until = RoutineQuietHours.nextEnd(nextRunAt, settings: settings) {
                    fireAt = max(nextRunAt, until)
                }
                guard fireAt > now else { continue }
                desired.append(RoutineScheduledNotification(
                    botId: botId, routineId: routine.id,
                    routineTitle: routine.title, fireAt: fireAt))
            }
        }
        desired.sort { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
        desired = Array(desired.prefix(Self.maxScheduledNotifications))
        let desiredIDs = Set(desired.map(\.identifier))

        let prefix = "routine-due:\(botId):"
        let pending = Set(await notifications.pendingIdentifiers(prefix: prefix))
        let existingSignatures = scheduledNotifications
        let stale = pending.subtracting(desiredIDs).union(
            scheduledNotifications.keys.filter { !desiredIDs.contains($0) })
        if !stale.isEmpty {
            await notifications.cancel(identifiers: Array(stale).sorted())
            for identifier in stale { scheduledNotifications.removeValue(forKey: identifier) }
        }

        for notification in desired {
            if scheduledNotifications[notification.identifier] == notification { continue }
            do {
                try await notifications.schedule(notification)
                scheduledNotifications[notification.identifier] = notification
            } catch {
                scheduledNotifications.removeValue(forKey: notification.identifier)
            }
        }
        // A system purge (reboot, user clearing notifications, foreground
        // permission changes) leaves our signature but no pending request.
        // Re-register on the next reconciliation.
        for identifier in desiredIDs where !pending.contains(identifier)
            && existingSignatures[identifier] != nil {
            guard let notification = desired.first(where: { $0.identifier == identifier }) else { continue }
            do { try await notifications.schedule(notification) }
            catch { scheduledNotifications.removeValue(forKey: identifier) }
        }
        scheduledNotifications = scheduledNotifications.filter { desiredIDs.contains($0.key) }
    }

    public func scheduledNotificationsSnapshot() -> [RoutineScheduledNotification] {
        scheduledNotifications.values.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
    }

    public func presenceSnapshot(appActive: Bool, keepingAlive: Bool) async -> RoutinePresence {
        let routines = (try? await machine.list(botId: botId)) ?? []
        let level = RoutinePresencePolicy.level(
            appActive: appActive, keepingAlive: keepingAlive,
            scheduledNotificationCount: scheduledNotifications.count)
        return RoutinePresence(level: level,
                               deferred: RoutinePresencePolicy.deferred(routines),
                               scheduledNotificationCount: scheduledNotifications.count)
    }

    /// Applies a settings edit immediately: quiet-hour deferrals and pending
    /// notifications are recomputed, then a tick runs any routine that just
    /// became eligible. The tick is detached so a long routine cannot block the
    /// settings sheet; the notification/deferral change itself is synchronous
    /// with the save.
    public func applySettingsChange() async {
        await syncNotifications()
        Task { try? await self.tick() }
    }

    private func cancelScheduledNotifications(routineId: String) async {
        guard let notifications else { return }
        let prefix = "routine-due:\(botId):\(routineId):"
        var identifiers = Set(await notifications.pendingIdentifiers(prefix: prefix))
        identifiers.formUnion(scheduledNotifications.keys.filter { $0.hasPrefix(prefix) })
        guard !identifiers.isEmpty else { return }
        await notifications.cancel(identifiers: Array(identifiers).sorted())
        for identifier in identifiers { scheduledNotifications.removeValue(forKey: identifier) }
    }

    private func runWithDeadline(_ request: RoutineRunRequest) async -> RoutineExecutionResult {
        let task = Task { await runner(request) }
        if await settles(task, within: runTimeoutMs) {
            return await task.value
        }
        task.cancel()
        let cancellation = RoutineCancellation(botId: botId, routineId: request.routine.id,
                                               runId: request.runId, timeoutMs: cancelGraceMs)
        let cancelOutcome: RoutineCancellationResult
        if let cancelRunner {
            cancelOutcome = await cancelRunner(cancellation)
        } else {
            cancelOutcome = RoutineCancellationResult(cancelled: false, reason: "no-cancel-handler")
        }
        let settled = await settles(task, within: cancelGraceMs)
        let baseError = "routine run timed out after \(runTimeoutMs)ms"
        if settled && cancelOutcome.cancelled && !cancelOutcome.reconciliationRequired {
            return RoutineExecutionResult(status: .cancelled, error: baseError, cancelledBy: "timeout")
        }
        return RoutineExecutionResult(status: .failed,
                                      error: "\(baseError); cancellation was not confirmed\(cancelOutcome.reason.map { " (\($0))" } ?? "")",
                                      cancelledBy: "timeout")
    }

    private final class DeadlineGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            let next = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                let next = continuation
                continuation = nil
                return next
            }
            next?.resume(returning: value)
        }
    }

    private func settles(_ task: Task<RoutineExecutionResult, Never>, within milliseconds: Int64) async -> Bool {
        if milliseconds <= 0 { return false }
        let sleeper = self.sleeper
        return await withCheckedContinuation { continuation in
            let gate = DeadlineGate(continuation)
            Task { _ = await task.value; gate.resume(true) }
            Task { await sleeper(milliseconds); gate.resume(false) }
        }
    }

    private func hold(_ original: RoutineDelivery) async {
        guard original.resultStatus == .succeeded, !original.quiet else { return }
        let text = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = original.deliveryKey
        do {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let safe = String(original.routineId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).prefix(80)
            let item = try WakeInboxItem(
                id: "routine-result-\(safe)-\(original.attempt)", kind: "routine-result",
                title: original.routineTitle, text: String(text.prefix(1200)),
                requestId: RoutineDelivery.key(routineId: original.routineId, attempt: original.attempt),
                createdAt: original.finishedAt, ranAt: original.startedAt,
                routineId: original.routineId, attempt: original.attempt,
                runId: original.runId, deliveryKey: original.deliveryKey
            )
            _ = try await inbox.enqueue(item)
            _ = try await machine.markHeld(key, botId: botId, delivered: true, now: nowProvider())
        } catch {
            _ = try? await machine.markHeld(key, botId: botId, delivered: false,
                                            error: error.localizedDescription, now: nowProvider())
        }
    }

    private func considerInterrupt(_ original: RoutineDelivery) async {
        guard original.delivery == .interrupt, let proactive else { return }
        let successful = original.resultStatus == .succeeded && !original.quiet &&
            !original.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let userCancelled = original.resultStatus == .cancelled && (original.cancelOrigin ?? "user") == "user"
        let failed = [.failed, .timedOut, .cancelled].contains(original.resultStatus) && !userCancelled
        guard successful || failed else { return }
        let body: String
        if successful {
            body = RoutineScheduleMath.summarize(original.text)
        } else {
            body = "例行任務「\(original.routineTitle)」執行失敗：\(RoutineScheduleMath.summarize(original.error ?? "未知錯誤", max: 80))"
        }
        let rowId = RoutineDelivery.rowId(routineId: original.routineId, attempt: original.attempt)
        let key = "routine-result:\(original.routineId):\(original.runId):\(original.attempt)"
        let candidate = ProactiveCandidate(
            id: key, kind: .routineResult, botId: botId, dedupeKey: key,
            trigger: "routine.run_finished", createdAt: original.finishedAt,
            title: original.routineTitle, body: body, status: original.resultStatus.rawValue,
            routineId: original.routineId, runId: original.runId, attempt: original.attempt,
            delivery: .interrupt, quiet: false, resultExcerpt: String(original.text.prefix(300)),
            deliveryKey: original.deliveryKey, rowId: rowId
        )
        let decision = await proactive.consider(candidate)
        let notified = decision.mode == .on ? (decision.decision == .did ? "sent" : "skipped") : nil
        _ = try? await machine.markNotification(original.deliveryKey, botId: botId, notified: notified,
                                                reason: decision.reason, mode: decision.mode.rawValue,
                                                now: nowProvider())
    }

    private func deliver(_ original: RoutineDelivery, force: Bool = false) async {
        let now = nowProvider()
        do {
            let claim = try await machine.claimDelivery(original.deliveryKey, botId: botId,
                                                        leaseOwner: leaseOwner, now: now, force: force)
            guard claim.state == .claimed, let delivery = claim.delivery else { return }
            do {
                _ = try await sink.deliver(RoutineAutomation(delivery: delivery))
                _ = try await machine.completeDelivery(delivery.deliveryKey, botId: botId, now: nowProvider())
            } catch {
                _ = try await machine.failDelivery(delivery.deliveryKey, botId: botId,
                                                   error: error.localizedDescription, now: nowProvider())
            }
        } catch {
            return
        }
    }
}

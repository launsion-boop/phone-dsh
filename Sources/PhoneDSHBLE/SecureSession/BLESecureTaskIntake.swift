// SPDX-License-Identifier: MIT
// secure-session-v2 §8.1-§9.3: the phone's intake loop for one granted
// connection generation. It owns every request sent through the generation
// (one at a time), renews sessions inside the generation on demand, sends the
// `status` keepalive while a task is accepted or running, and hands offered
// tasks to DeviceTaskExecutor through BLESecureTaskInbox, which installs the
// durable `ble-secure-ops` intent before each transition is sent.
//
// It never grants itself: `grant()` is reached only through
// BLESecureSessionCoordinator after BLEDeviceStore.grantDeviceTasks admitted
// the generation, which every build of this package refuses (GAP-16).
import Foundation
import PhoneDSHDeviceTasks

public actor BLESecureTaskIntake {
    public struct Timing: Sendable {
        /// Keepalive `status` once this long has passed since the previous
        /// response (§8.1: at most 30 s).
        public var keepalive: Duration = .seconds(25)
        /// Idle `next` poll when the board offered nothing.
        public var poll: Duration = .seconds(5)
        /// Wait after a failed session attempt (§5: the board accepts no new
        /// CoC for 2 s after a failed handshake).
        public var renewalBackoff: Duration = .seconds(2)
        /// Scheduler granularity.
        public var tick: Duration = .seconds(1)
        public init() {}
    }

    public enum StopReason: String, Sendable, Equatable {
        case grantEnded = "grant_ended", cancelled, unauthorized
    }

    private let generation: BLESecurePhoneGeneration
    public nonisolated let deviceID: String
    public nonisolated let phoneID: String
    /// Set by the grant; nothing reaches the executor before it.
    private var executor: DeviceTaskExecutor?
    private let openStream: @Sendable () async throws -> BLESecureByteStream
    private let timing: Timing
    private let clock = ContinuousClock()
    private var lastResponse: ContinuousClock.Instant
    private var lockHeld = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    /// The task between an applied `accept` and the start of its report.
    private var active: (id: String, idem: String)?
    private var unresolvedIDs: Set<String> = []
    /// No further `next` in this generation until the user acts (an
    /// unresolved or parentless accepted offer is user-visible).
    private var nextHalted = false
    public private(set) var notices: [String] = []
    private var loop: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    public private(set) var stopReason: StopReason?
    public private(set) var keepalivesSent = 0
    public private(set) var sessionsOpened = 0

    public init(generation: BLESecurePhoneGeneration, deviceID: String, phoneID: String,
                timing: Timing = Timing(),
                openStream: @escaping @Sendable () async throws -> BLESecureByteStream) {
        self.generation = generation
        self.deviceID = deviceID
        self.phoneID = phoneID
        self.timing = timing
        self.openStream = openStream
        self.lastResponse = ContinuousClock().now
    }

    public var inbox: BLESecureDeviceTaskInbox { BLESecureDeviceTaskInbox(intake: self) }
    public var isRunning: Bool { loop != nil && stopReason == nil }
    public var unresolvedTaskIDs: Set<String> { unresolvedIDs }

    // MARK: serialization (one outstanding request, resend as the very next request)

    private func acquire() async {
        if !lockHeld { lockHeld = true; return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func release() {
        if lockWaiters.isEmpty { lockHeld = false } else { lockWaiters.removeFirst().resume() }
    }

    private func notice(_ text: String) {
        notices.append(text)
        if notices.count > 32 { notices.removeFirst() }
    }

    /// Opens a new session in this generation unless one is ready. Lock held.
    private func ensureReady(requireGrant: Bool) async throws {
        if await generation.isEnded { throw BLESecureTaskInboxError.grantEnded }
        if await generation.state == .ready { return }
        if requireGrant, await generation.grant == .none { throw BLESecureTaskInboxError.grantEnded }
        let stream: BLESecureByteStream
        do { stream = try await openStream() } catch {
            await generation.sessionAttemptFailed()
            try? await Task.sleep(for: timing.renewalBackoff)
            throw BLESecureTaskInboxError.retryLater
        }
        do {
            try await generation.openSession(over: stream)
            sessionsOpened += 1
            lastResponse = clock.now
        } catch BLESecurePhoneGeneration.Failure.ended {
            throw BLESecureTaskInboxError.grantEnded
        } catch {
            try? await Task.sleep(for: timing.renewalBackoff)
            throw BLESecureTaskInboxError.retryLater
        }
    }

    /// One request through the generation. Lock held.
    private func send(_ request: BLESecurePhoneSessionCore.Request) async throws -> BLESecurePhoneSessionCore.Output {
        let output: BLESecurePhoneSessionCore.Output
        do { output = try await generation.request(request) }
        catch BLESecurePhoneGeneration.Failure.ended { throw BLESecureTaskInboxError.grantEnded }
        catch { throw BLESecureTaskInboxError.retryLater }
        if !output.result.rawValue.hasPrefix("refused") { lastResponse = clock.now }
        return output
    }

    // MARK: grant

    /// Opens a session if needed (no grant yet) and applies the foreground
    /// user grant to this generation. Called only after the store admitted it.
    public func openInitialSession() async throws {
        await acquire(); defer { release() }
        try await ensureReady(requireGrant: false)
    }

    /// Internal on purpose: only BLESecureSessionCoordinator.grant calls it,
    /// after BLEDeviceStore.grantDeviceTasks admitted this generation (tests
    /// reach it with @testable).
    func grant(executor: DeviceTaskExecutor) async throws {
        await acquire(); defer { release() }
        try await ensureReady(requireGrant: false)
        guard await generation.grantByUser().result == .granted else { throw BLESecureTaskInboxError.grantEnded }
        self.executor = executor
    }

    /// Starts the intake and keepalive loops; `onStopped` runs once.
    func start(onStopped: @escaping @Sendable (StopReason) async -> Void) {
        guard loop == nil else { return }
        loop = Task {
            let reason = await self.runLoop()
            await self.stopped(reason)
            await onStopped(reason)
        }
        keepaliveTask = Task { await self.keepaliveLoop() }
    }

    public func stop() async {
        loop?.cancel()
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let loop { _ = await loop.value }
    }

    private func stopped(_ reason: StopReason) {
        if stopReason == nil { stopReason = reason }
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: transitions (called by DeviceTaskExecutor through the inbox)

    func transition(_ arguments: BLESecureTransitionArguments, intent: BLESecureTaskIntent, fresh: Bool) async throws {
        guard intent.deviceID == deviceID else { throw DeviceTaskError.invalidDeviceIdentity }
        await acquire(); defer { release() }
        if arguments.action != .accept { active = nil }
        try await ensureReady(requireGrant: true)
        if fresh {
            try settle(try await send(.transition(arguments, resend: false)), arguments)
            return
        }
        // §9.3: a pre-existing intent is reconciled through `status` first; a
        // resend is only ever the very next request, inside this lock.
        let status = try await send(.status(id: arguments.id, idem: arguments.idem,
                                            intent: .init(arguments: arguments, phoneID: intent.phoneID)))
        switch status.result {
        case .statusApplied:
            if arguments.action == .accept { active = (arguments.id, arguments.idem) }
        case .statusResend:
            try settle(try await send(.transition(arguments, resend: true)), arguments)
        case .statusUnresolved, .unresolved:
            unresolvedIDs.insert(arguments.id)
            notice("任务 \(arguments.id) 的 \(arguments.action.rawValue) 状态无法确认，需要用户处理")
            throw BLESecureTaskInboxError.unresolved("status")
        case .refusedNoGrant: throw BLESecureTaskInboxError.grantEnded
        default: throw BLESecureTaskInboxError.retryLater
        }
    }

    private func settle(_ output: BLESecurePhoneSessionCore.Output, _ arguments: BLESecureTransitionArguments) throws {
        switch output.result {
        case .applied:
            if arguments.action == .accept { active = (arguments.id, arguments.idem) }
        case .unresolved:
            unresolvedIDs.insert(arguments.id)
            notice("设备拒绝任务 \(arguments.id) 的 \(arguments.action.rawValue)，不会重发，需要用户处理")
            throw BLESecureTaskInboxError.unresolved(arguments.action.rawValue)
        case .refusedWindow: throw BLESecureTaskInboxError.windowClosed
        case .refusedNoGrant: throw BLESecureTaskInboxError.grantEnded
        default: throw BLESecureTaskInboxError.retryLater
        }
    }

    // MARK: loops

    private func fetchNext() async throws -> (DeviceTask, BLESecureTaskPhase)? {
        await acquire(); defer { release() }
        guard let executor else { throw BLESecureTaskInboxError.grantEnded }
        try await ensureReady(requireGrant: true)
        await generation.updateParents(try await executor.tasks(deviceID: deviceID))
        let output = try await send(.next)
        switch output.result {
        case .noTask, .refusedNextSuspended, .refusedWindow: return nil
        case .taskOffered, .acceptedOffer:
            guard let offered = await generation.offered else { return nil }
            return (offered.task, offered.phase)
        case .localConflict:
            notice("设备提供的任务与本机已有任务冲突，未接受")
            return nil
        case .refusedNoGrant: throw BLESecureTaskInboxError.grantEnded
        default: throw BLESecureTaskInboxError.retryLater
        }
    }

    private func runLoop() async -> StopReason {
        while !Task.isCancelled {
            let grant = await generation.grant
            let ended = await generation.isEnded
            if grant == .none || ended { return .grantEnded }
            if grant == .reportOnly || nextHalted {
                try? await Task.sleep(for: timing.poll)
                continue
            }
            let offered: (DeviceTask, BLESecureTaskPhase)?
            do { offered = try await fetchNext() }
            catch BLESecureTaskInboxError.grantEnded { return .grantEnded }
            catch is CancellationError { return .cancelled }
            catch { try? await Task.sleep(for: timing.tick); continue }
            guard let (task, phase) = offered else {
                try? await Task.sleep(for: timing.poll)
                continue
            }
            if unresolvedIDs.contains(task.id) {
                nextHalted = true
                notice("设备再次提供未解决的任务 \(task.id)；已暂停领取新任务")
                continue
            }
            if phase == .accepted {
                // §9.2: an accepted offer without a parent record is never executed.
                let parents = (try? await executor?.tasks(deviceID: deviceID)) ?? []
                guard parents.contains(task) else {
                    unresolvedIDs.insert(task.id)
                    nextHalted = true
                    notice("设备报告任务 \(task.id) 已被本机接受，但本机没有记录；不会执行")
                    continue
                }
            }
            switch await process(task) {
            case .stop(let reason): return reason
            case .done: continue
            }
        }
        return .cancelled
    }

    private enum ProcessOutcome { case done, stop(StopReason) }

    private func process(_ task: DeviceTask) async -> ProcessOutcome {
        guard let executor else { return .stop(.grantEnded) }
        while !Task.isCancelled {
            do {
                try await executor.process(deviceID: deviceID, task: task, authorized: true, inbox: inbox)
                return .done
            } catch BLESecureTaskInboxError.retryLater {
                let grant = await generation.grant
                let ended = await generation.isEnded
                if grant == .none || ended { return .stop(.grantEnded) }
                try? await Task.sleep(for: timing.tick)
            } catch BLESecureTaskInboxError.unresolved {
                return .done
            } catch BLESecureTaskInboxError.windowClosed {
                return .done
            } catch BLESecureTaskInboxError.grantEnded {
                return .stop(.grantEnded)
            } catch is CancellationError {
                return .stop(.cancelled)
            } catch DeviceTaskError.unauthorized {
                return .stop(.unauthorized)
            } catch {
                unresolvedIDs.insert(task.id)
                nextHalted = true
                notice("任务 \(task.id) 无法处理：\(error)")
                return .done
            }
        }
        return .stop(.cancelled)
    }

    private func keepaliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: timing.tick)
            guard !Task.isCancelled, let task = active, !lockHeld,
                  clock.now - lastResponse >= timing.keepalive else { continue }
            await acquire()
            if let current = active, current == task, clock.now - lastResponse >= timing.keepalive,
               await generation.state == .ready {
                // §8.1: `status` is the keepalive, never `next`.
                if let output = try? await send(.status(id: task.id, idem: task.idem, intent: nil)), output.result == .status {
                    keepalivesSent += 1
                }
            }
            release()
        }
    }
}

/// The executor's view of one granted secure generation.
public struct BLESecureDeviceTaskInbox: BLESecureTaskInbox {
    let intake: BLESecureTaskIntake
    public var phoneID: String { intake.phoneID }
    public var deviceID: String { intake.deviceID }

    public func transition(_ arguments: BLESecureTransitionArguments, intent: BLESecureTaskIntent, fresh: Bool) async throws {
        try await intake.transition(arguments, intent: intent, fresh: fresh)
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: the ordered event stream.
//
// PLAN §2.5 / W2-FACADE. The host publishes one ordered event sequence: facade
// state changes, controller transitions, budget actions, WebContent
// terminations/restarts, Worker connections and console lines, and fail-loud
// errors. Consumers (the App UI, the diagnostics screen, the smoke test)
// subscribe with ``PhoneDSHEventBus/stream()``.

import Foundation
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHGateway
import PhoneDSHLoopback
import PhoneDSHWire

/// One Worker HELLO observed by the host.
public struct PhoneDSHWorkerHello: Equatable, Sendable {
    /// 32 lowercase hex characters reported by the Worker.
    public var bootID: String
    /// Highest mseq the Worker process assigned.
    public var lastMseq: UInt64
    /// Fence generation the Worker presented.
    public var generation: UInt64
    /// Fence `wal_seq` the Worker presented.
    public var walSeq: UInt64
    /// 1-based count of HELLOs observed by this host.
    public var count: UInt64

    public init(bootID: String, lastMseq: UInt64, generation: UInt64,
                walSeq: UInt64, count: UInt64) {
        self.bootID = bootID
        self.lastMseq = lastMseq
        self.generation = generation
        self.walSeq = walSeq
        self.count = count
    }
}

/// One bounded reference to an orphan step the host settled. It carries only
/// the D6 session id and the D20 step key; no tool arguments, output or file
/// content is ever part of this diagnostic.
public struct PhoneDSHOrphanStepRef: Equatable, Sendable {
    public var sessionID: String
    public var stepKey: String

    public init(sessionID: String, stepKey: String) {
        self.sessionID = sessionID
        self.stepKey = stepKey
    }
}

/// The terminal settlement of steps left open by a Worker termination
/// (G2-FIX-93). `steps` is capped by the publisher; `count` is the true total.
public struct PhoneDSHOrphanStepSettlement: Equatable, Sendable {
    /// Machine-readable cause (`worker-terminated`, `drain-timeout`, ...).
    public var reason: String
    /// Total number of steps transitioned to `abandoned`.
    public var count: Int
    /// At most ``maximumListedSteps`` references.
    public var steps: [PhoneDSHOrphanStepRef]

    /// The event stays bounded even when a workspace has many orphan steps.
    public static let maximumListedSteps = 16

    public init(reason: String, count: Int, steps: [PhoneDSHOrphanStepRef]) {
        self.reason = reason
        self.count = count
        self.steps = Array(steps.prefix(Self.maximumListedSteps))
    }
}

/// One ordered host event (PLAN W2-FACADE: state changes, budget actions,
/// terminations, restarts, errors).
public enum PhoneDSHEvent: Equatable, Sendable {
    /// The coarse App-facing state changed.
    case stateChanged(from: PhoneDSHState, to: PhoneDSHState)
    /// The controller accepted one D14 transition.
    case hostTransition(HostTransitionRecord)
    /// The budget monitor selected an action or hit a hard cap.
    case budget(BudgetDecision)
    /// A WebContent process terminated; the value is the boot's count.
    case webContentTerminated(UInt64)
    /// A planned or recovery restart finished.
    case restarted(WebEngineRestartReport)
    /// A Worker completed the ordered-channel HELLO handshake.
    case workerHello(PhoneDSHWorkerHello)
    /// A model response reached a durable terminal delivery outcome
    /// (committed to, replayed from, or resumed from the response log).
    ///
    /// The receipt is bounded to key/status/bodyBytes/disposition. The event
    /// never carries the response body, request headers, URLs or credentials.
    case gatewayResponse(GatewayResponseReceipt)
    /// A new ordered-channel WebSocket connected (1-based connection count).
    case channelConnected(UInt64)
    /// The Worker forwarded one console line (`0x60 CONSOLE`).
    case console(ConsolePayload)
    /// Steps left open by a terminated Worker were settled as `abandoned`.
    case orphanStepsSettled(PhoneDSHOrphanStepSettlement)
    /// A fail-loud condition the App must surface.
    case error(String)
}

/// Fan-out of the single ordered event sequence.
///
/// The bus is lock-protected rather than an actor so a channel handler can
/// publish a console line synchronously, in frame order, without another actor
/// hop. Subscribers receive every later event; a subscription created after an
/// event does not replay it (diagnostics is the snapshot API).
public final class PhoneDSHEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PhoneDSHEvent>.Continuation] = [:]
    private var finished = false

    /// Creates an open bus with no subscribers.
    public init() {}

    /// A new independent subscription.
    public func stream() -> AsyncStream<PhoneDSHEvent> {
        AsyncStream { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.finish()
                return
            }
            let id = UUID()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    /// Publishes one event to every subscriber in call order.
    public func send(_ event: PhoneDSHEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        for continuation in targets { continuation.yield(event) }
        lock.unlock()
    }

    /// Ends every subscription. Later calls to ``stream()`` finish at once.
    ///
    /// ``PhoneDSHHost/stop()`` calls this after publishing the `.stopped`
    /// state change; ``PhoneDSHHost/start()`` calls ``reopen()`` so a restarted
    /// host publishes to new subscriptions again.
    public func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }

    /// Reopens a finished bus for a new host incarnation.
    ///
    /// Subscriptions created before ``finish()`` stay ended; every later
    /// ``stream()`` receives the events published after this call.
    public func reopen() {
        lock.lock()
        finished = false
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

/// Engine event source the facade observes when the injected engine exposes
/// one. ``WebEngine`` conforms; test doubles may conform to script termination
/// and restart events.
public protocol PhoneDSHEngineEventSource: Sendable {
    func phoneDSHEvents() -> AsyncStream<WebEngineEvent>
}

extension WebEngine: PhoneDSHEngineEventSource {
    /// The engine's additional event subscription, exposed as the facade's
    /// `AsyncStream` seam (the landed ``WebEngineEvents`` sequence is bridged
    /// without widening the engine module's public surface).
    public nonisolated func phoneDSHEvents() -> AsyncStream<WebEngineEvent> {
        let events = eventStream()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension WebEngineConsoleLine.Level {
    /// Maps an engine console level onto the channel `0x60` vocabulary.
    var channelLevel: ConsolePayload.Level {
        switch self {
        case .debug: return .debug
        case .log, .info: return .info
        case .warning: return .warn
        case .error: return .error
        }
    }
}

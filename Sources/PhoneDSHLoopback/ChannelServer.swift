// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: ordered channel server.
//
// PLAN §2.2 (D1–D3, D8), spec/v1/channel.md §7–§9. One ChannelServer
// exists per WebSocket: it validates HELLO and the fence, enforces the
// per-connection seq space and the host-allocated mseq, dispatches inbound
// frames strictly in order, forwards VFS and journal acknowledgements with the
// 2 ms group commit, and owns the host → worker API request table (no resend
// ring; every pending request is aborted with 0x43 when the connection dies).
//
// Journal ordering is *not* per connection: `(session_id, jseq)` dedupe and the
// forward-gap check read the persisted per-session high-water mark from the
// ``LoopbackJournalLog`` seam. A reconnect with fresh seq counters therefore
// re-sends the unacknowledged journal records and the host accepts them.

import Foundation
import PhoneDSHWire

// MARK: - Host state

/// The values the host HELLO carries (channel.md §4.1, D3/D17).
public struct ChannelHostState: Equatable, Sendable {
    /// 32 lowercase hexadecimal characters.
    public var bootID: String
    public var sessionEpoch: UInt64
    public var fence: Fence
    /// Host capabilities, at least `channel/1`, `wal/1`, `exec/1`, plus
    /// `accelerator:<name>` entries.
    public var caps: [String]
    /// Effective WAL tail: every mseq up to here is level-1 acknowledged.
    public var ackedMseq: UInt64
    /// `durable_upto` of the last closed epoch.
    public var durableMseq: UInt64

    public init(bootID: String = "00000000000000000000000000000000",
                sessionEpoch: UInt64 = 1,
                fence: Fence = Fence(owner: "phone", generation: 1, walSeq: 0),
                caps: [String] = ["channel/1", "wal/1", "exec/1"],
                ackedMseq: UInt64 = 0,
                durableMseq: UInt64 = 0) {
        self.bootID = bootID
        self.sessionEpoch = sessionEpoch
        self.fence = fence
        self.caps = caps
        self.ackedMseq = ackedMseq
        self.durableMseq = durableMseq
    }

    /// `next_mseq = acked_mseq + 1` (D17; the host HELLO validates that).
    public var nextMseq: UInt64 { ackedMseq &+ 1 }
}

/// Supplies the current host HELLO state for each new WebSocket connection.
public typealias ChannelHostStateProvider = @Sendable () async throws -> ChannelHostState

/// A mutable host state for hosts and tests; the loopback server reads it
/// before every HELLO so a reconnect sees the current WAL tail.
public actor MutableChannelHostState {
    public private(set) var state: ChannelHostState

    public init(_ state: ChannelHostState = ChannelHostState()) {
        self.state = state
    }

    public func update(_ state: ChannelHostState) {
        self.state = state
    }

    public func setAckedMseq(_ mseq: UInt64) {
        state.ackedMseq = mseq
        if state.durableMseq > mseq { state.durableMseq = mseq }
    }

    public func setDurableMseq(_ mseq: UInt64) {
        state.durableMseq = min(max(mseq, state.durableMseq), state.ackedMseq)
    }

    public func setFence(_ fence: Fence) {
        state.fence = fence
    }
}

// MARK: - Metrics

/// One non-closing `ERROR VFS_REFUSED` diagnostic observed on a connection
/// (channel.md §4.8).
///
/// A resource refusal is not a connection error: the refused mutation consumed
/// no mseq, the channel stays open, and the host records this for diagnostics
/// instead of entering Failed.
public struct ChannelVFSRefusal: Equatable, Sendable {
    /// The refused VFS path (`/dsh/home/**` or `/dsh/workspace/**`).
    public var path: String
    /// Policy bound in bytes the mutation would have exceeded.
    public var limit: UInt64
    /// Resource class (`file-too-large`, `no-space`, `quota-exceeded`).
    public var reason: PhoneWireRefusalReason
    /// Human-readable detail from the Worker.
    public var message: String

    public init(path: String, limit: UInt64, reason: PhoneWireRefusalReason, message: String) {
        self.path = path
        self.limit = limit
        self.reason = reason
        self.message = message
    }

    /// Reads a validated `VFS_REFUSED` payload; nil for any other ERROR code.
    public init?(payload: ErrorPayload) {
        guard payload.isVFSRefused,
              let path = payload.path,
              let limit = payload.limit,
              let reason = payload.reason
        else { return nil }
        self.init(path: path, limit: limit, reason: reason, message: payload.message)
    }
}

/// One host → worker durability acknowledgement with the timestamps of its
/// hops (G2-FIX-83). The step records carry the tool-call boundary `at_ms`
/// values; these samples make the host side of the same chain reconcilable:
/// when the workspace/journal log's cumulative ack reached the channel and
/// when the `0x11`/`0x31` frame was actually accepted by the transport. A
/// healthy chain has a queue time of the 2 ms coalescing window, not a timer
/// cadence.
public struct ChannelAckTiming: Equatable, Sendable {
    /// Which cumulative sequence the ack confirms.
    public enum Kind: String, Sendable {
        case vfs
        case journal
        case barrier
    }

    public var kind: Kind
    /// `1` = write(), `2` = epoch F_FULLFSYNC.
    public var level: UInt8
    /// `upto_mseq` for VFS acks, `upto_jseq` for journal acks.
    public var upto: UInt64
    /// Session id of a journal ack; `nil` for VFS/barrier acks.
    public var sessionID: String?
    /// Epoch milliseconds when the log ack reached the channel.
    public var queuedAtMilliseconds: Int64
    /// Epoch milliseconds when the socket accepted the frame.
    public var sentAtMilliseconds: Int64

    public init(kind: Kind, level: UInt8, upto: UInt64, sessionID: String? = nil,
                queuedAtMilliseconds: Int64, sentAtMilliseconds: Int64) {
        self.kind = kind
        self.level = level
        self.upto = upto
        self.sessionID = sessionID
        self.queuedAtMilliseconds = queuedAtMilliseconds
        self.sentAtMilliseconds = sentAtMilliseconds
    }

    /// Time between the log ack and the delivered frame, in milliseconds.
    public var queueMilliseconds: Double {
        Double(max(0, sentAtMilliseconds - queuedAtMilliseconds))
    }
}

/// Purely informational channel metrics; no behaviour depends on them.
public struct ChannelMetrics: Equatable, Sendable {
    public var framesIn = 0
    public var framesOut = 0
    public var bytesIn = 0
    public var bytesOut = 0
    /// Host → worker API request round trips (`0x40` sent → `0x42`/`0x43`).
    public var roundTripSamplesMillis: [Double] = []
    /// Bounded window of recent `0x11`/`0x31` acknowledgement hops, oldest
    /// first (G2-FIX-83). The host accepts at most 256 samples.
    public var ackTimings: [ChannelAckTiming] = []
    /// `ERROR VFS_REFUSED` diagnostics received (channel.md §4.8); none of
    /// them closes the connection.
    public var vfsRefusals = 0
    /// `ERROR VFS_REFUSED` replies sent for host-side resource refusals
    /// (channel.md §4.8, §8): each one leaves the connection open and consumes
    /// no mseq.
    public var vfsRefusalsSent = 0
    /// Most recent resource refusal observed on this connection, if any.
    public var lastVFSRefusal: ChannelVFSRefusal?

    public init() {}

    public var p50Milliseconds: Double? { percentile(0.50) }
    public var p95Milliseconds: Double? { percentile(0.95) }

    /// p95 of the log-ack → frame-sent hop over the retained samples.
    public var ackQueueP95Milliseconds: Double? {
        guard !ackTimings.isEmpty else { return nil }
        return Self.percentile(ackTimings.map(\.queueMilliseconds), 0.95)
    }

    /// p50 of the log-ack → frame-sent hop over the retained samples.
    public var ackQueueP50Milliseconds: Double? {
        guard !ackTimings.isEmpty else { return nil }
        return Self.percentile(ackTimings.map(\.queueMilliseconds), 0.50)
    }

    private func percentile(_ fraction: Double) -> Double? {
        guard !roundTripSamplesMillis.isEmpty else { return nil }
        return Self.percentile(roundTripSamplesMillis, fraction)
    }

    private static func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
        return sorted[rank]
    }
}

// MARK: - Outbound and socket protocols

/// What a ``ChannelHandling`` may do on the live connection.
public protocol ChannelOutbound: Sendable {
    /// Encodes and sends one host → worker frame with the next connection seq.
    func sendFrame(_ type: FrameType, payload: Data) async throws
    /// Highest contiguous level-1-acked mseq observed on this connection.
    func currentAckedMseq() async -> UInt64
    /// Waits until the workspace log acked `mseq` at level 1.
    func waitUntilAcked(_ mseq: UInt64, timeout: TimeInterval) async throws
    /// The admission state the host currently advertises.
    func currentAdmission() async -> Admission
    /// Sends `0x13 VFS_RESYNC` for one path (wal.md §5.1).
    func notifyVFSResync(path: String) async
    /// Sends `0x50 LIFECYCLE` (channel.md §4.5).
    func sendLifecycle(_ payload: LifecyclePayload) async throws
    /// Sends `0x70 FENCE` (channel.md §4.7).
    func sendFence(_ payload: FencePayload) async throws
}

extension ChannelOutbound {
    /// Default no-op for test doubles; a live channel overrides it.
    public func notifyVFSResync(path: String) async {}
}

/// The binary-message transport behind a channel. ``WebSocketConnection``
/// conforms; tests use an in-memory implementation.
public protocol ChannelSocket: Sendable {
    func receiveChannelMessage() async throws -> Data?
    func sendChannelMessage(_ data: Data) async throws
    func closeChannel(code: Int) async
    /// Whether the transport still holds bytes of a message it has not
    /// delivered. A drain close may only report a clean end when this is
    /// false: closing a socket with a half-received WebSocket message would
    /// silently drop the rest of it.
    func hasPendingInboundData() async -> Bool
}

extension ChannelSocket {
    /// Test transports that deliver discrete messages have no hidden inbound
    /// buffer; live transports override this.
    public func hasPendingInboundData() async -> Bool { false }
}

extension WebSocketConnection: ChannelSocket {
    public func receiveChannelMessage() async throws -> Data? {
        guard let message = try await receive() else { return nil }
        switch message {
        case .binary(let data): return data
        case .text: throw WebSocketError.protocolViolation("text messages are not part of the ordered channel")
        }
    }

    public func sendChannelMessage(_ data: Data) async throws {
        try await send(binary: data)
    }

    public func closeChannel(code: Int) async {
        await close(code: code)
    }
}

// MARK: - Host → worker API requests

/// One streamed host → worker API request (`0x40` → `0x41`/`0x42`/`0x43`).
public enum ChannelAPIEvent: Equatable, Sendable {
    /// `status`/`headers` are present on the first chunk only.
    case response(reqID: UInt32, status: Int?, headers: [String: String], body: Data)
    case end(reqID: UInt32)
    case abort(reqID: UInt32, reason: String)

    public var reqID: UInt32 {
        switch self {
        case .response(let reqID, _, _, _): return reqID
        case .end(let reqID): return reqID
        case .abort(let reqID, _): return reqID
        }
    }
}

// MARK: - Channel server

/// Bounded delivery policy for host → worker acknowledgements (`0x11`, `0x31`).
///
/// channel.md §3.2/§3.6 make acks cumulative, but a send that failed after the
/// pending entry was cleared used to lose the only frame that could resolve the
/// Worker's durability wait. Every ack send is retried with exponential backoff
/// under this policy; when all attempts fail the channel fails loud instead of
/// leaving the Worker parked.
public struct AckDeliveryPolicy: Equatable, Sendable {
    /// Total send attempts per acknowledgement frame (including the first).
    public var maxAttempts: Int
    /// Backoff before the second attempt, in seconds.
    public var initialDelay: TimeInterval
    /// Backoff ceiling, in seconds.
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 4,
                initialDelay: TimeInterval = 0.01,
                maxDelay: TimeInterval = 0.1) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(self.initialDelay, maxDelay)
    }
}

/// How a ``ChannelServer/beginDrainClose(code:idleTimeout:maxDuration:)``
/// receive loop ended.
///
/// Only ``cleanEOF`` (the peer closed and every delivered frame dispatched)
/// or ``notStarted`` (there was never an inbound stream to lose) prove that
/// the transport no longer holds a message the old Worker accepted. `idle`
/// and `hardDeadline` mean the socket was closed while it might still have
/// queued messages; a protocol/transport failure means the stream is torn.
/// The drain escalation must not repack the overlay on any of those.
public enum ChannelDrainEnd: String, Sendable, Equatable {
    /// The receive loop was never started, so it has no queued inbound data.
    case notStarted
    /// The peer reached EOF after all delivered frames were dispatched.
    case cleanEOF
    /// The idle watchdog closed the socket before the peer reached EOF.
    case idleTimeout
    /// The caller's hard drain deadline closed the socket mid-stream.
    case hardDeadline
    /// A protocol error ended the stream; the tail is not a clean close.
    case protocolFailure
    /// The transport failed or a partial WebSocket message was left behind.
    case transportFailure
    /// A hard ``ChannelServer/close(code:)`` ended a non-draining loop.
    case closed
}

private enum DrainWatchdogDecision: Sendable {
    case stop
    case keepDraining
    case close(ChannelDrainEnd)
}

/// The ordered channel endpoint for one WebSocket connection.
public actor ChannelServer: ChannelOutbound {
    private let socket: any ChannelSocket
    private let state: ChannelHostState
    private var handler: (any ChannelHandling)?
    private let workspaceLog: (any LoopbackWorkspaceLog)?
    private let journalLog: (any LoopbackJournalLog)?
    private let admissionProvider: @Sendable () async -> Admission
    private let ackCoalescingInterval: TimeInterval
    private let ackDeliveryPolicy: AckDeliveryPolicy

    private var started = false
    private var finished = false
    /// Set by ``beginDrainClose(code:)``. While draining the receive loop keeps
    /// reading: messages that already reached the transport but had not been
    /// dispatched are admitted until the socket reaches EOF, the connection is
    /// idle for the drain window, or the bounded drain deadline expires. The
    /// socket is only closed after that, so a queued `VFS_MUT`/`JOURNAL`
    /// message cannot be discarded by an immediate close.
    private var draining = false
    /// Set once the drain has finished reading. It closes the transport but
    /// deliberately leaves already-decoded frames dispatchable: the run loop
    /// still finishes the current message before it tears the channel down.
    private var drainClosing = false
    private var drainCloseCode = 1000
    private var drainIdleTimeout: TimeInterval = 0.2
    private var drainHardDeadline = Date.distantFuture
    /// The last instant a message/frame arrived. The drain watchdog only closes
    /// an *idle* receive, so a burst of already-delivered messages is drained
    /// instead of racing the close.
    private var lastInboundActivity = Date()
    /// Whether the receive loop is currently suspended waiting for the next
    /// WebSocket message. The drain watchdog requires this before it closes, so
    /// it never closes in the middle of an inbound handler.
    private var awaitingReceive = false
    private var drainWatchdogTask: Task<Void, Never>?
    /// How the drain ended. Set before ``receiveLoopFinished`` and never
    /// overwritten, so the coordinator can require a clean EOF instead of
    /// treating an idle/hard socket close as "no inbound writes remain".
    private var drainEnd: ChannelDrainEnd?
    /// Set when `run()` has returned, including its teardown. The drain
    /// escalation waits for this after closing the old connection so it never
    /// repacks an overlay while an already-decoded frame is still dispatching.
    private var receiveLoopFinished = false
    private var receivedHello = false
    private var expectedMseq: UInt64
    private var outboundSeq: UInt64 = 0
    private var ackedMseqValue: UInt64
    private var durableMseqValue: UInt64
    private var metricsValue = ChannelMetrics()

    private var pendingWorkspaceWriteAck: UInt64?
    private var pendingWorkspaceEpochAck: UInt64?
    private var pendingJournalAcks: [String: UInt64] = [:]
    /// Epoch milliseconds when each pending cumulative ack was first observed;
    /// the hop timings of G2-FIX-83 are measured from these.
    private var pendingWorkspaceWriteAckQueuedAt: Int64?
    private var pendingWorkspaceEpochAckQueuedAt: Int64?
    private var pendingJournalAckQueuedAt: [String: Int64] = [:]
    private var barriers: [(want: AckLevel, upto: UInt64, queuedAtMilliseconds: Int64)] = []
    private var ackFlushTask: Task<Void, Never>?
    private var ackFlushInProgress = false
    /// Actor reentrancy guard for outbound frames: a `sendFrameInternal` must
    /// not suspend between picking its seq and committing it, or two senders
    /// would emit the same connection seq.
    private var sendInProgress = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var logAckTask: Task<Void, Never>?
    private var logResyncTask: Task<Void, Never>?
    private var tornDown = false

    private var nextAPIReqID: UInt32 = 1
    private var pendingAPIs: [UInt32: PendingAPI] = [:]

    private struct PendingAPI {
        var continuation: AsyncStream<ChannelAPIEvent>.Continuation
        var sentAt: Date
        var hasHead = false
    }

    public init(socket: any ChannelSocket,
                state: ChannelHostState,
                handler: (any ChannelHandling)? = nil,
                workspaceLog: (any LoopbackWorkspaceLog)? = nil,
                journalLog: (any LoopbackJournalLog)? = nil,
                admission: @escaping @Sendable () async -> Admission = { .open },
                ackCoalescingInterval: TimeInterval = 0.002,
                ackDeliveryPolicy: AckDeliveryPolicy = AckDeliveryPolicy()) {
        self.socket = socket
        self.state = state
        self.handler = handler
        self.workspaceLog = workspaceLog
        self.journalLog = journalLog
        self.admissionProvider = admission
        self.ackCoalescingInterval = ackCoalescingInterval
        self.ackDeliveryPolicy = ackDeliveryPolicy
        self.expectedMseq = state.nextMseq
        self.ackedMseqValue = state.ackedMseq
        self.durableMseqValue = min(state.durableMseq, state.ackedMseq)
    }

    // MARK: - Lifecycle

    /// Sends the host HELLO and consumes inbound frames until the peer closes
    /// or a protocol violation closes the connection.
    /// Installs the dispatch target before ``run()`` starts.
    public func installHandler(_ handler: any ChannelHandling) throws {
        guard !started else { throw LoopbackError.alreadyRunning }
        self.handler = handler
    }

    public func run() async {
        guard !started else { return }
        started = true
        defer { receiveLoopFinished = true }
        guard handler != nil else {
            await teardown(closeCode: 1011)
            return
        }
        do {
            let hello = try makeHostHello()
            try await sendFrame(.hello, payload: hello)
        } catch {
            await teardown(closeCode: 1011)
            return
        }
        startLogForwarding()

        var decoder = FrameDecoder(configuration: .init(enforceMonotonicSequence: true))
        do {
            // A drain close does not end the loop: it keeps admitting messages
            // that are already in the transport until EOF, an idle drain
            // window, or the bounded drain deadline. `finishDrainClose()` then
            // sets both `finished` and `drainClosing`; the current message still
            // dispatches below because it was received before the close.
            while !finished {
                awaitingReceive = true
                let message: Data?
                do {
                    message = try await socket.receiveChannelMessage()
                } catch {
                    awaitingReceive = false
                    throw error
                }
                awaitingReceive = false
                guard let message else {
                    if drainEnd == nil {
                        // A `nil` message is the peer's EOF, whether or not
                        // `beginDrainClose` was armed first. Production
                        // terminates the old page and only then arms the drain
                        // close, so the WebSocket often reaches EOF in that
                        // window; classifying that as `.closed` would make the
                        // first escalation look non-quiescent and burn a
                        // bounded termination for no reason. Only a host
                        // `close()`/teardown has `tornDown` set before the
                        // receive returns. EOF is still clean only when the
                        // channel decoder has no partial frame left and the
                        // socket is not hiding the rest of a WebSocket message.
                        // A self-initiated idle/hard close already recorded its
                        // less-clean reason, so it keeps that verdict.
                        if tornDown {
                            recordDrainEnd(.closed)
                        } else {
                            let pendingChannelBytes = decoder.bufferedByteCount > 0
                            let pendingSocketBytes = await socket.hasPendingInboundData()
                            recordDrainEnd(
                                pendingChannelBytes || pendingSocketBytes
                                    ? .transportFailure : .cleanEOF)
                        }
                    }
                    break
                }
                lastInboundActivity = Date()
                metricsValue.bytesIn += message.count
                let frames = try decoder.feed(message)
                for frame in frames {
                    if tornDown { break }
                    // A protocol failure ends the message immediately. A drain
                    // close, by contrast, must not drop a frame that the socket
                    // already delivered; `drainClosing` keeps them dispatchable.
                    if finished && !drainClosing { break }
                    metricsValue.framesIn += 1
                    try await handle(frame)
                    lastInboundActivity = Date()
                }
            }
        } catch let error as PhoneWireError {
            recordDrainEnd(.protocolFailure)
            await fail(code: error.code, message: error.message, refSeq: error.refSeq)
        } catch LoopbackError.channelUnavailable {
            // Without a workspace log no level-1 ack can be truthful. Close
            // loudly (1011) instead of confirming an unpersisted mutation; the
            // worker's unacked ring then fails loud rather than losing data.
            recordDrainEnd(.transportFailure)
            await teardown(closeCode: 1011)
        } catch let error as WebSocketError {
            recordDrainEnd(.protocolFailure)
            await fail(code: .badPayload, message: "websocket: \(error)", refSeq: nil)
        } catch is LoopbackError {
            recordDrainEnd(.transportFailure)
            await fail(code: .badPayload, message: "channel handler failed", refSeq: nil)
        } catch {
            recordDrainEnd(.transportFailure)
            await fail(code: .badPayload, message: "channel failure", refSeq: nil)
        }
        // A receive loop that ended for a reason not classified above (for
        // example a cancelled task while draining) is never a clean EOF.
        if draining && drainEnd == nil { recordDrainEnd(.transportFailure) }
        await teardown(closeCode: drainClosing ? drainCloseCode : 1000)
    }

    /// Closes the connection and aborts pending API requests.
    public func close(code: Int = 1000) async {
        await teardown(closeCode: code)
    }

    /// Starts a drain close that keeps reading already-delivered messages.
    ///
    /// ``close(code:)`` sets ``finished`` immediately, and any message still
    /// queued in the transport is discarded. A `VFS_MUT`/`JOURNAL` message can
    /// be fully received there while the previous message is still dispatching;
    /// closing the socket would lose the write. This method instead marks the
    /// connection as draining and lets ``run()`` keep receiving and dispatching
    /// until the transport reaches EOF, the receive loop is idle for
    /// `idleTimeout`, or `maxDuration` expires. Only then does the watchdog set
    /// ``drainClosing``/``finished`` and close the socket. A frame decoded from
    /// the message that was in flight at close time still dispatches, because
    /// ``drainClosing`` keeps the run loop's frame guard satisfied.
    ///
    /// The socket close is detached and therefore cannot hold the caller past
    /// its drain deadline. A receive loop that does not end (e.g. a handler
    /// stuck past `maxDuration`) is reported by ``hasFinishedReceiveLoop()``;
    /// the caller then fails the attempt instead of packing a stale overlay.
    ///
    /// - Parameters:
    ///   - code: WebSocket close code used after the drain finishes.
    ///   - idleTimeout: how long the receive loop must be idle before the
    ///     watchdog closes the socket. A queued message resets this window.
    ///   - maxDuration: hard bound that closes the socket even if messages or a
    ///     handler keep the loop busy.
    public func beginDrainClose(code: Int = 1000,
                                idleTimeout: TimeInterval = 0.2,
                                maxDuration: TimeInterval = 1) {
        guard !draining, !tornDown, !finished else { return }
        draining = true
        drainCloseCode = code
        drainIdleTimeout = max(0, idleTimeout)
        // A server whose receive loop never started has nothing to drain; close
        // it now instead of leaving a watchdog alive for the full window.
        if !started {
            recordDrainEnd(.notStarted)
            finishDrainClose()
            return
        }
        let now = Date()
        lastInboundActivity = now
        drainHardDeadline = now.addingTimeInterval(max(0, maxDuration))
        drainWatchdogTask?.cancel()
        drainWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let decision = await self?.drainWatchdogDecision() else { return }
                switch decision {
                case .stop:
                    return
                case .close(let reason):
                    await self?.finishDrainClose(reason: reason)
                    return
                case .keepDraining:
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
        }
    }

    /// The watchdog decision. A running handler keeps the drain alive until
    /// the hard deadline; an idle receive is closed after `idleTimeout`.
    private func drainWatchdogDecision() -> DrainWatchdogDecision {
        guard !tornDown, !finished else { return .stop }
        let now = Date()
        if now >= drainHardDeadline { return .close(.hardDeadline) }
        guard awaitingReceive else { return .keepDraining }
        if now.timeIntervalSince(lastInboundActivity) >= drainIdleTimeout {
            return .close(.idleTimeout)
        }
        return .keepDraining
    }

    /// Ends the drain after EOF/idle/deadline: stop sending, close the
    /// transport, but still dispatch frames decoded from the in-flight message.
    private func finishDrainClose(reason: ChannelDrainEnd = .idleTimeout) {
        guard !tornDown, !finished else { return }
        recordDrainEnd(reason)
        drainClosing = true
        finished = true
        let socket = self.socket
        let closeCode = drainCloseCode
        Task { await socket.closeChannel(code: closeCode) }
    }

    /// Records the first drain-end reason. The watchdog may race the receive
    /// loop's EOF classification; the first verdict wins, and a watchdog close
    /// can never be upgraded to a clean EOF.
    private func recordDrainEnd(_ reason: ChannelDrainEnd) {
        if drainEnd == nil { drainEnd = reason }
    }

    /// How the drain closed. `nil` while it is still running or after a hard
    /// ``close(code:)`` that was never classified.
    public func drainEndReason() -> ChannelDrainEnd? { drainEnd }

    /// Whether the receive loop ended with the peer's clean EOF (or never
    /// started, so there was no inbound stream). Only this permits the
    /// coordinator to report inbound writes quiesced; idle/hard closes and
    /// protocol/transport failures keep the drain fail-loud.
    public func hasCleanDrainEnd() -> Bool {
        drainEnd == .cleanEOF || drainEnd == .notStarted
    }

    /// Whether ``beginDrainClose(code:)`` has been requested. The socket is
    /// not necessarily closed yet: the receive loop may still be dispatching
    /// the message that was in flight, or draining queued messages.
    public func hasBegunDrainClose() -> Bool {
        draining
    }

    /// Whether this server's receive loop has stopped (or never started).
    ///
    /// `close()` sets `finished` immediately and wakes the socket, but a frame
    /// already being handled still runs to completion. The drain escalation
    /// waits for this flag before it materializes the overlay.
    public func hasFinishedReceiveLoop() -> Bool {
        !started || receiveLoopFinished
    }

    /// Whether ``run()`` has ever been entered.
    ///
    /// ``hasFinishedReceiveLoop()`` is true before the loop starts, so a drain
    /// needs this extra bit to tell a connection registered by a previous
    /// incarnation (started and already finished) apart from one that is
    /// registered but not running yet.
    public func hasStartedReceiveLoop() -> Bool {
        started
    }

    /// A snapshot of the connection metrics.
    public func currentMetrics() -> ChannelMetrics {
        metricsValue
    }

    /// Highest mseq accepted on this connection (the next one is expected).
    public func acceptedMseq() -> UInt64 {
        expectedMseq &- 1
    }

    // MARK: - ChannelOutbound

    public func sendFrame(_ type: FrameType, payload: Data) async throws {
        try await sendFrameInternal(type, payload: payload)
    }

    /// Sends one `0x50 LIFECYCLE` (channel.md §4.5). Admission and budget are
    /// owned by the host controller; this only encodes the frame with the next
    /// outbound seq.
    public func sendLifecycle(_ payload: LifecyclePayload) async throws {
        guard !finished else { throw LoopbackError.closed }
        try await sendFrameInternal(.lifecycle, payload: try CanonicalJSON.encode(payload))
    }

    /// Sends one `0x70 FENCE` (channel.md §4.7). A FENCE may advance the
    /// generation on a live connection; the worker applies it to the next
    /// side-effect frame.
    public func sendFence(_ payload: FencePayload) async throws {
        guard !finished else { throw LoopbackError.closed }
        try await sendFrameInternal(.fence, payload: try CanonicalJSON.encode(payload))
    }

    public func currentAckedMseq() async -> UInt64 {
        ackedMseqValue
    }

    public func currentAdmission() async -> Admission {
        await admissionProvider()
    }

    public func waitUntilAcked(_ mseq: UInt64, timeout: TimeInterval) async throws {
        if mseq == 0 || ackedMseqValue >= mseq { return }
        let deadline = Date().addingTimeInterval(timeout)
        while ackedMseqValue < mseq {
            if finished { throw LoopbackError.closed }
            if Date() >= deadline {
                throw LoopbackError.upstreamFailed("timed out waiting for mseq \(mseq)")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    public func notifyVFSResync(path: String) async {
        guard !finished, let payload = try? VfsResyncBody(path: path).encoded() else { return }
        try? await sendFrameInternal(.vfsResync, payload: payload)
    }

    // MARK: - Host → worker API requests

    /// Sends one `0x40 API_REQ` and streams its response. There is no resend
    /// ring (D2): if the connection dies the owner receives `.abort` with
    /// `connection_closed` and re-issues with a fresh req_id.
    public func sendAPIRequest(head: ApiRequestHead, body: Data = Data()) async throws
        -> AsyncStream<ChannelAPIEvent> {
        guard !finished else { throw LoopbackError.closed }
        let reqID = nextAPIReqID
        nextAPIReqID = nextAPIReqID &+ 1
        let (stream, continuation) = AsyncStream<ChannelAPIEvent>.makeStream()
        pendingAPIs[reqID] = PendingAPI(continuation: continuation, sentAt: Date())
        do {
            let frame = ApiRequestFrame(reqID: reqID, head: head, body: body)
            try await sendFrameInternal(.apiRequest, payload: try frame.encoded())
        } catch {
            pendingAPIs[reqID] = nil
            continuation.finish()
            throw error
        }
        return stream
    }

    // MARK: - Frame dispatch

    private static let allowedInbound: Set<FrameType> = [
        .hello, .vfsMutation, .vfsBarrier, .execRequest, .execControl,
        .journal, .apiResponse, .apiEnd, .apiAbort, .console, .error,
    ]

    private func handle(_ frame: Frame) async throws {
        guard let handler else {
            throw PhoneWireError(code: .badPayload, message: "no channel handler is installed")
        }
        guard Self.allowedInbound.contains(frame.type) else {
            throw PhoneWireError(code: .protoMismatch,
                                 message: "\(frame.type.wireName) is not a worker frame",
                                 refSeq: frame.seq)
        }
        if !receivedHello {
            guard frame.type == .hello else {
                throw PhoneWireError(code: .protoMismatch,
                                     message: "the first frame must be HELLO",
                                     refSeq: frame.seq)
            }
        } else if frame.type == .hello {
            throw PhoneWireError(code: .protoMismatch,
                                 message: "a second HELLO is not allowed",
                                 refSeq: frame.seq)
        }

        switch frame.type {
        case .hello:
            let hello: HelloPayload = try decodeJSON(frame.payload, refSeq: frame.seq)
            guard hello.role == .worker else {
                throw PhoneWireError(code: .protoMismatch,
                                     message: "the peer role is not worker",
                                     refSeq: frame.seq)
            }
            guard hello.fence.owner == state.fence.owner,
                  hello.fence.generation >= state.fence.generation else {
                throw PhoneWireError(code: .fenceStale,
                                     message: "the worker fence is stale",
                                     refSeq: frame.seq)
            }
            receivedHello = true
            try await handler.handleHello(hello)

        case .vfsMutation:
            let decoded = try VfsMutationPayload.decode(frame.payload)
            guard decoded.mseq == expectedMseq else {
                throw PhoneWireError(code: .badMseq,
                                     message: "expected mseq \(expectedMseq), got \(decoded.mseq)",
                                     refSeq: frame.seq)
            }
            // Level 1 means the WAL write returned; there is nothing to ack
            // without the log (channel.md §8). Fail loud in the catch below.
            guard workspaceLog != nil else { throw LoopbackError.channelUnavailable }
            do {
                try await handler.handleVFSMutation(decoded.body, mseq: decoded.mseq,
                                                    seq: frame.seq)
            } catch let error as any VFSResourceRefusalProviding {
                guard let refusal = error.vfsResourceRefusal else { throw error }
                // channel.md §4.8, §8: a host resource refusal is a first-class
                // protocol answer, not a protocol error. Answer on the same
                // connection and leave expectedMseq unchanged so the Worker can
                // shrink the mutation and resend this same mseq.
                try await sendResourceRefusal(refusal,
                                              body: decoded.body,
                                              mseq: decoded.mseq,
                                              refSeq: frame.seq)
                return
            }
            // Advance only after the handler accepted (and persisted) the
            // mutation: a refused mutation must not consume an mseq.
            expectedMseq = expectedMseq &+ 1

        case .vfsBarrier:
            let body = try VfsBarrierBody.decode(frame.payload)
            try await handler.handleVFSBarrier(body)
            barriers.append((want: body.wantLevel, upto: body.uptoMseq,
                             queuedAtMilliseconds: Self.epochMilliseconds()))
            await flushSatisfiedBarriers()

        case .execRequest:
            let payload = try ExecRequestPayload.decode(frame.payload)
            try await handler.handleExecRequest(payload)

        case .execControl:
            let payload: ExecControlPayload = try decodeJSON(frame.payload, refSeq: frame.seq)
            try await handler.handleExecControl(payload)

        case .journal:
            let body = try JournalBody.decode(frame.payload)
            if let journalLog {
                // D2, channel.md §3.5/§9.3: deduplicate by (session_id, jseq)
                // against the persisted high-water mark, not against what this
                // connection happened to see. A reconnect re-sends unacked
                // records with their original jseq and must be accepted.
                let highest = await journalLog.lastJseq(sessionID: body.sessionID)
                if body.jseq <= highest {
                    // The durable record already owns this (session, jseq).
                    // Do not trust bytes supplied by a duplicate frame; boot
                    // recovery rebuilds projections from the validated log.
                    noteJournalAck(sessionID: body.sessionID, uptoJseq: highest)
                    return
                }
                guard body.jseq == highest &+ 1 else {
                    throw PhoneWireError(code: .badPayload,
                                         message: "journal jseq gap",
                                         refSeq: frame.seq)
                }
                // Append before ack: level 1 means the record write() returned.
                // The default handler persists through the same seam; the
                // journal ignores the duplicate by (session_id, jseq).
                let appended = try await journalLog.appendJournal(
                    sessionID: body.sessionID, jseq: body.jseq, record: body.record)
                try await handler.handleJournal(body)
                noteJournalAck(sessionID: body.sessionID,
                               uptoJseq: max(appended, body.jseq))
            } else {
                // Without a journal seam there is no persisted high-water mark
                // to derive; the handler owns sequencing and persistence.
                try await handler.handleJournal(body)
                noteJournalAck(sessionID: body.sessionID, uptoJseq: body.jseq)
            }

        case .apiResponse:
            let decoded = try ApiResponseFrame.decode(frame.payload)
            try routeAPIResponse(decoded)
            try await handler.handleAPIResponse(decoded)

        case .apiEnd:
            let decoded = try ApiEndFrame.decode(frame.payload)
            routeAPIEnd(decoded.reqID)
            try await handler.handleAPIEnd(decoded)

        case .apiAbort:
            let decoded = try ApiAbortFrame.decode(frame.payload)
            routeAPIAbort(decoded.reqID, reason: decoded.reason)
            try await handler.handleAPIAbort(decoded)

        case .console:
            let payload: ConsolePayload = try decodeJSON(frame.payload, refSeq: frame.seq)
            try await handler.handleConsole(payload)

        case .error:
            let payload: ErrorPayload = try decodeJSON(frame.payload, refSeq: frame.seq)
            try await handler.handleError(payload)
            // channel.md §4.8/§10: a resource refusal is a diagnostic. It is
            // recorded and the connection stays open; every other ERROR closes
            // after the frame is flushed (§7). Never echo either one.
            guard payload.code.closesConnection else {
                if let refusal = ChannelVFSRefusal(payload: payload) {
                    metricsValue.vfsRefusals += 1
                    metricsValue.lastVFSRefusal = refusal
                }
                return
            }
            await teardown(closeCode: 1000)

        default:
            throw PhoneWireError(code: .protoMismatch,
                                 message: "unexpected inbound frame",
                                 refSeq: frame.seq)
        }
    }

    // MARK: - Host HELLO

    /// The HELLO wire schema carries the WAL marks only (`next_mseq`,
    /// `acked_mseq`, `durable_mseq`); per-session journal high-water marks are
    /// not serialized. The channel derives `acked_jseq` per session from the
    /// persisted ``LoopbackJournalLog`` when each `0x30` arrives (§3.5/§9.3).
    private func makeHostHello() throws -> Data {
        var caps = state.caps
        for required in ["channel/1", "wal/1", "exec/1"] where !caps.contains(required) {
            caps.append(required)
        }
        let durable = min(state.durableMseq, state.ackedMseq)
        let hello = HelloPayload(role: .host,
                                 bootID: state.bootID,
                                 sessionEpoch: state.sessionEpoch,
                                 fence: state.fence,
                                 caps: caps,
                                 nextMseq: state.ackedMseq &+ 1,
                                 ackedMseq: state.ackedMseq,
                                 durableMseq: durable)
        return try CanonicalJSON.encode(hello)
    }

    private func decodeJSON<T: Decodable>(_ payload: Data, refSeq: UInt64) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch let error as PhoneWireError {
            throw PhoneWireError(code: error.code, message: error.message, refSeq: refSeq)
        } catch let error as DecodingError {
            _ = error
            throw PhoneWireError(code: .badPayload,
                                 message: "malformed JSON payload",
                                 refSeq: refSeq)
        } catch {
            throw PhoneWireError(code: .badPayload,
                                 message: "malformed JSON payload",
                                 refSeq: refSeq)
        }
    }

    // MARK: - Sending

    /// Sends one non-closing `ERROR VFS_REFUSED` for a refused VFS_MUT
    /// (channel.md §4.8, §8). Nothing was appended, so no VFS_ACK is emitted
    /// for the refused mseq and the next accepted mutation can reuse it.
    private func sendResourceRefusal(_ refusal: VFSResourceRefusal,
                                     body: VfsMutationBody,
                                     mseq: UInt64,
                                     refSeq: UInt64) async throws {
        // A complete write replaces the file (accepted prefix 0); an appended
        // write keeps everything before `append_from`, bounded by the limit.
        let accepted: UInt64
        if body.mflags.contains(.appended) {
            accepted = min(body.appendFrom, refusal.limitBytes)
        } else {
            accepted = 0
        }
        let payload = ErrorPayload(hostRefusal: refusal,
                                   mseq: mseq,
                                   acceptedBytes: accepted,
                                   refSeq: refSeq)
        try await sendFrameInternal(.error, payload: try CanonicalJSON.encode(payload))
        metricsValue.vfsRefusalsSent += 1
    }

    private func sendFrameInternal(_ type: FrameType, payload: Data) async throws {
        // One frame at a time: the actor may re-enter at the socket await, and
        // two senders must never pick the same connection seq (a duplicate seq
        // would reach the Worker as BAD_SEQ).
        await acquireSendSlot()
        defer { releaseSendSlot() }
        // Consume the outbound seq only after the transport accepted the frame.
        // A failed send is retryable at the same seq: the peer never saw the
        // frame, and skipping a seq would answer the next attempt with BAD_SEQ.
        let seq = outboundSeq &+ 1
        let encoded = try FrameEncoder.encode(type: type, seq: seq, payload: payload)
        try await socket.sendChannelMessage(encoded)
        outboundSeq = seq
        metricsValue.framesOut += 1
        metricsValue.bytesOut += encoded.count
    }

    private func acquireSendSlot() async {
        if !sendInProgress {
            sendInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    private func releaseSendSlot() {
        if sendWaiters.isEmpty {
            sendInProgress = false
        } else {
            // Hand the slot directly to the next sender; `sendInProgress`
            // stays true so a third caller cannot jump the queue.
            let next = sendWaiters.removeFirst()
            next.resume()
        }
    }

    private func fail(code: PhoneWireErrorCode, message: String, refSeq: UInt64?) async {
        guard !finished else { return }
        finished = true
        let payload = (try? CanonicalJSON.encode(
            ErrorPayload(code: code, message: String(message.prefix(512)), refSeq: refSeq)))
            ?? Data("{\"code\":\"BAD_PAYLOAD\",\"message\":\"protocol error\"}".utf8)
        try? await sendFrameInternal(.error, payload: payload)
        await teardown(closeCode: code == .fenceStale ? 1008 : 1002)
    }

    private func teardown(closeCode: Int) async {
        // The first reason wins: a late `teardown(1000)` must not overwrite the
        // close code of the protocol error that ended the channel.
        guard !tornDown else { return }
        tornDown = true
        finished = true
        awaitingReceive = false
        drainWatchdogTask?.cancel()
        drainWatchdogTask = nil
        logAckTask?.cancel()
        logAckTask = nil
        logResyncTask?.cancel()
        logResyncTask = nil
        ackFlushTask?.cancel()
        ackFlushTask = nil
        for (reqID, pending) in pendingAPIs {
            pending.continuation.yield(.abort(reqID: reqID, reason: "connection_closed"))
            pending.continuation.finish()
        }
        pendingAPIs.removeAll()
        barriers.removeAll()
        await socket.closeChannel(code: closeCode)
    }

    // MARK: - Acknowledgements

    private func startLogForwarding() {
        guard let workspaceLog else { return }
        logAckTask = Task { [weak self] in
            for await ack in workspaceLog.acks() {
                if Task.isCancelled { return }
                await self?.noteWorkspaceAck(level: ack.level, uptoMseq: ack.uptoMseq)
            }
        }
        // Base mismatch detection lives in the WAL materializer (channel.md §8
        // "structural validation only"); the seam forwards its signal so the
        // channel emits 0x13 without owning materialization itself.
        logResyncTask = Task { [weak self] in
            for await path in workspaceLog.resyncs() {
                if Task.isCancelled { return }
                await self?.notifyVFSResync(path: path)
            }
        }
    }

    private func noteWorkspaceAck(level: AckLevel, uptoMseq: UInt64) {
        switch level {
        case .write:
            ackedMseqValue = max(ackedMseqValue, uptoMseq)
            let queuedAt = Self.epochMilliseconds()
            if pendingWorkspaceWriteAck == nil { pendingWorkspaceWriteAckQueuedAt = queuedAt }
            pendingWorkspaceWriteAck = max(pendingWorkspaceWriteAck ?? 0, uptoMseq)
        case .epochFsync:
            durableMseqValue = max(durableMseqValue, uptoMseq)
            let queuedAt = Self.epochMilliseconds()
            if pendingWorkspaceEpochAck == nil { pendingWorkspaceEpochAckQueuedAt = queuedAt }
            pendingWorkspaceEpochAck = max(pendingWorkspaceEpochAck ?? 0, uptoMseq)
        }
        scheduleAckFlush()
    }

    private func noteJournalAck(sessionID: String, uptoJseq: UInt64) {
        if pendingJournalAcks[sessionID] == nil {
            pendingJournalAckQueuedAt[sessionID] = Self.epochMilliseconds()
        }
        pendingJournalAcks[sessionID] = max(pendingJournalAcks[sessionID] ?? 0, uptoJseq)
        scheduleAckFlush()
    }

    /// Epoch milliseconds, aligned with the step records' `at_ms`.
    private static func epochMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Retains one ack hop for the diagnostics window. The window is bounded so
    /// a long session cannot grow the metrics without limit.
    private func recordAckTiming(_ timing: ChannelAckTiming) {
        metricsValue.ackTimings.append(timing)
        let overflow = metricsValue.ackTimings.count - 256
        if overflow > 0 {
            metricsValue.ackTimings.removeFirst(overflow)
        }
    }

    private func scheduleAckFlush() {
        guard ackFlushTask == nil, !ackFlushInProgress, !finished, !draining else { return }
        let interval = max(0, ackCoalescingInterval)
        ackFlushTask = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.flushAcks()
        }
    }

    /// Sends every pending acknowledgement without losing one on a transport
    /// failure: the pending value is cleared only after its frame (or a newer
    /// cumulative value) was actually accepted by the socket.
    private func flushAcks() async {
        ackFlushTask = nil
        guard !finished, !draining, !ackFlushInProgress else { return }
        ackFlushInProgress = true
        await drainAckQueue()
        ackFlushInProgress = false
        if !finished, hasPendingAckWork { scheduleAckFlush() }
    }

    private func drainAckQueue() async {
        if let upto = pendingWorkspaceWriteAck {
            let body = VfsAckBody(level: .write, uptoMseq: upto)
            guard let payload = try? body.encoded() else { return }
            let queuedAt = pendingWorkspaceWriteAckQueuedAt ?? Self.epochMilliseconds()
            guard await deliverAck(.vfsAck, payload: payload) else {
                await failAckDelivery("VFS_ACK level 1 for mseq \(upto)")
                return
            }
            if pendingWorkspaceWriteAck == upto {
                pendingWorkspaceWriteAck = nil
                pendingWorkspaceWriteAckQueuedAt = nil
            }
            recordAckTiming(ChannelAckTiming(kind: .vfs, level: 1, upto: upto,
                                             queuedAtMilliseconds: queuedAt,
                                             sentAtMilliseconds: Self.epochMilliseconds()))
        }
        if let upto = pendingWorkspaceEpochAck {
            let body = VfsAckBody(level: .epochFsync, uptoMseq: upto)
            guard let payload = try? body.encoded() else { return }
            let queuedAt = pendingWorkspaceEpochAckQueuedAt ?? Self.epochMilliseconds()
            guard await deliverAck(.vfsAck, payload: payload) else {
                await failAckDelivery("VFS_ACK level 2 for mseq \(upto)")
                return
            }
            if pendingWorkspaceEpochAck == upto {
                pendingWorkspaceEpochAck = nil
                pendingWorkspaceEpochAckQueuedAt = nil
            }
            recordAckTiming(ChannelAckTiming(kind: .vfs, level: 2, upto: upto,
                                             queuedAtMilliseconds: queuedAt,
                                             sentAtMilliseconds: Self.epochMilliseconds()))
        }
        // Snapshot the session ids: noteJournalAck() may add a newer value while
        // a send is in flight, and that value must survive for the next flush.
        for sessionID in Array(pendingJournalAcks.keys) {
            guard let upto = pendingJournalAcks[sessionID] else { continue }
            guard let payload = try? JournalAckBody(level: .write, sessionID: sessionID,
                                                    uptoJseq: upto).encoded() else { continue }
            let queuedAt = pendingJournalAckQueuedAt[sessionID] ?? Self.epochMilliseconds()
            guard await deliverAck(.journalAck, payload: payload) else {
                await failAckDelivery("JOURNAL_ACK level 1 for session \(sessionID) jseq \(upto)")
                return
            }
            if pendingJournalAcks[sessionID] == upto {
                pendingJournalAcks[sessionID] = nil
                pendingJournalAckQueuedAt[sessionID] = nil
            }
            recordAckTiming(ChannelAckTiming(kind: .journal, level: 1, upto: upto,
                                             sessionID: sessionID,
                                             queuedAtMilliseconds: queuedAt,
                                             sentAtMilliseconds: Self.epochMilliseconds()))
        }
        await flushSatisfiedBarriers()
    }

    private var hasPendingAckWork: Bool {
        pendingWorkspaceWriteAck != nil
            || pendingWorkspaceEpochAck != nil
            || !pendingJournalAcks.isEmpty
    }

    /// Attempts one acknowledgement frame with bounded exponential backoff.
    /// @returns `true` once the transport accepted a frame; `false` when every
    ///   attempt failed and the caller must fail the connection loud.
    private func deliverAck(_ type: FrameType, payload: Data) async -> Bool {
        let attempts = max(1, ackDeliveryPolicy.maxAttempts)
        var delay = max(0, ackDeliveryPolicy.initialDelay)
        for attempt in 1...attempts {
            if finished || tornDown || draining { return false }
            do {
                try await sendFrameInternal(type, payload: payload)
                return true
            } catch {
                if attempt >= attempts { return false }
                if delay > 0 {
                    // Clamp before the UInt64 conversion: a policy value is not
                    // allowed to overflow the sleep or stall the actor for long.
                    let seconds = min(max(0, delay), 5.0)
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                delay = min(ackDeliveryPolicy.maxDelay, max(ackDeliveryPolicy.initialDelay, delay * 2))
            }
        }
        return false
    }

    /// Ends the connection when an acknowledgement cannot be delivered at all.
    /// The `0x7F ERROR` is best effort (the same transport is failing); the
    /// close is what fires the Worker's `rejectAll` and ends its hang.
    private func failAckDelivery(_ what: String) async {
        // During a drain close the socket is already gone by design; the WAL
        // write this ack belonged to is still durable. Failing the connection
        // here would set `finished` and could drop the remaining frames of the
        // same message that the drain is still dispatching.
        guard !finished, !draining else { return }
        finished = true
        let message = "host could not deliver \(what) after \(max(1, ackDeliveryPolicy.maxAttempts)) attempts"
        let payload = (try? CanonicalJSON.encode(
            ErrorPayload(code: .ringTimeout, message: String(message.prefix(512)))))
            ?? Data("{\"code\":\"RING_TIMEOUT\",\"message\":\"ack delivery failed\"}".utf8)
        try? await sendFrameInternal(.error, payload: payload)
        await teardown(closeCode: 1011)
    }

    private func flushSatisfiedBarriers() async {
        guard !finished else { return }
        // Take the current queue, then put unsent entries back in front so a
        // barrier appended while a send was in flight is never dropped.
        let current = barriers
        barriers.removeAll()
        var remaining: [(want: AckLevel, upto: UInt64, queuedAtMilliseconds: Int64)] = []
        for barrier in current {
            let satisfied: Bool
            switch barrier.want {
            case .write: satisfied = ackedMseqValue >= barrier.upto
            case .epochFsync: satisfied = durableMseqValue >= barrier.upto
            }
            if satisfied {
                let body = VfsAckBody(level: barrier.want, uptoMseq: barrier.upto)
                guard let payload = try? body.encoded() else { continue }
                guard await deliverAck(.vfsAck, payload: payload) else {
                    await failAckDelivery("VFS_ACK barrier level \(barrier.want) for mseq \(barrier.upto)")
                    return
                }
                recordAckTiming(ChannelAckTiming(kind: .barrier,
                                                 level: barrier.want == .write ? 1 : 2,
                                                 upto: barrier.upto,
                                                 queuedAtMilliseconds: barrier.queuedAtMilliseconds,
                                                 sentAtMilliseconds: Self.epochMilliseconds()))
            } else {
                remaining.append(barrier)
            }
        }
        barriers.insert(contentsOf: remaining, at: 0)
    }

    // MARK: - API routing

    private func routeAPIResponse(_ frame: ApiResponseFrame) throws {
        guard var pending = pendingAPIs[frame.reqID] else {
            throw PhoneWireError(code: .badPayload,
                                 message: "API_RES for an unknown req_id")
        }
        if let head = frame.head {
            guard !pending.hasHead else {
                throw PhoneWireError(code: .badPayload,
                                     message: "API_RES repeats the response head")
            }
            pending.hasHead = true
            pending.continuation.yield(.response(reqID: frame.reqID,
                                                 status: head.status,
                                                 headers: head.headers,
                                                 body: frame.body))
        } else {
            guard pending.hasHead else {
                throw PhoneWireError(code: .badPayload,
                                     message: "the first API_RES must carry a head")
            }
            pending.continuation.yield(.response(reqID: frame.reqID,
                                                 status: nil,
                                                 headers: [:],
                                                 body: frame.body))
        }
        pendingAPIs[frame.reqID] = pending
    }

    private func routeAPIEnd(_ reqID: UInt32) {
        guard let pending = pendingAPIs.removeValue(forKey: reqID) else { return }
        pending.continuation.yield(.end(reqID: reqID))
        pending.continuation.finish()
        metricsValue.roundTripSamplesMillis.append(
            Date().timeIntervalSince(pending.sentAt) * 1000)
    }

    private func routeAPIAbort(_ reqID: UInt32, reason: String) {
        guard let pending = pendingAPIs.removeValue(forKey: reqID) else { return }
        pending.continuation.yield(.abort(reqID: reqID, reason: reason))
        pending.continuation.finish()
        metricsValue.roundTripSamplesMillis.append(
            Date().timeIntervalSince(pending.sentAt) * 1000)
    }
}

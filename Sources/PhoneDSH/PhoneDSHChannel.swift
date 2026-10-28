// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: ordered-channel adapters.
//
// PLAN §2.2 and spec/v1/channel.md §7–§9. One `ChannelServer` exists
// per WebSocket. The facade needs three things the loopback module does not
// own: the API_REQ sender used by ``ChannelDSHTransport``, the HELLO
// handshake the host waits on, and a single place that publishes channel
// events. The registry in this file supplies all three without changing the
// landed loopback API.

import Foundation
import PhoneDSHController
import PhoneDSHLoopback
import PhoneDSHWire

// MARK: - API channel seam

/// How one `0x40 API_REQ` participates in the D14 drain criterion.
///
/// A D23 `/api/remote.mux` `receive` is a *standing* stream: it stays open for
/// the life of the connection and never represents work the drain has to wait
/// for. Every other request (a unary API call, or a mux `send`/`close`) is a
/// finite exchange and keeps the drain open until its response stream ends.
enum PhoneDSHAPIRequestKind: Sendable, Equatable {
    /// A finite request whose `0x41/0x42/0x43` stream must end before the
    /// drain may close the epoch.
    case exchange
    /// The long-lived `remote.mux` receive stream. It is tracked so its token
    /// can be retired with the connection, but it never blocks quiescence.
    case standingReceive

    /// Classifies one API request head. Header names/values are matched
    /// case-insensitively; the contract itself is documented by
    /// ``PhoneDSHMuxProtocol``.
    static func classify(_ head: ApiRequestHead) -> PhoneDSHAPIRequestKind {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name.lowercased()] = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        guard head.path == PhoneDSHMuxProtocol.path,
              headers[PhoneDSHMuxProtocol.operationHeader] ==
                  PhoneDSHMuxProtocol.receiveOperation,
              headers[PhoneDSHMuxProtocol.contentTypeHeader] ==
                  PhoneDSHMuxProtocol.ndjsonContentType
        else { return .exchange }
        return .standingReceive
    }
}

/// The host → worker API request surface of one ordered-channel connection.
///
/// ``PhoneDSHLoopback/ChannelServer`` provides this surface; the
/// protocol is the seam ``ChannelDSHTransport`` and its tests program against.
public protocol PhoneDSHChannel: Sendable {
    /// Stable identity of this WebSocket connection. A reconnect is a new id.
    var id: UUID { get }
    /// Sends one `0x40 API_REQ` and returns the `0x41/0x42/0x43` stream.
    func sendAPIRequest(head: ApiRequestHead, body: Data) async throws
        -> AsyncStream<ChannelAPIEvent>
}

/// Supplies the current ordered channel, excluding connections known dead.
///
/// The implementation waits until a connection outside `excluding` is live or
/// throws ``PhoneDSHError/channelUnavailable`` when the wait times out. This is
/// what makes D2's "the initiator re-issues an in-flight API request on a new
/// connection" possible without a resend ring on the host side.
public typealias PhoneDSHChannelProvider =
    @Sendable (_ excluding: Set<UUID>) async throws -> any PhoneDSHChannel

/// One live ordered-channel connection.
struct PhoneDSHConnection: PhoneDSHChannel, Sendable {
    let id: UUID
    let server: ChannelServer
    /// Tracks the `0x40 API_REQ` exchanges this connection carries so a
    /// background drain can wait for them (PLAN §2.5, D14).
    let coordinator: PhoneDSHChannelCoordinator

    func sendAPIRequest(head: ApiRequestHead, body: Data) async throws
        -> AsyncStream<ChannelAPIEvent> {
        let coordinator = self.coordinator
        // Register before the send: a drain that starts while the server is
        // enqueueing the request must see it, and a failed send retires the
        // token again below.
        let token = await coordinator.apiRequestStarted(
            kind: PhoneDSHAPIRequestKind.classify(head))
        let source: AsyncStream<ChannelAPIEvent>
        do {
            source = try await server.sendAPIRequest(head: head, body: body)
        } catch {
            await coordinator.apiRequestFinished(token)
            throw error
        }
        return AsyncStream { continuation in
            let task = Task {
                for await event in source { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await coordinator.apiRequestFinished(token) }
            }
        }
    }

    func sendFence(_ payload: FencePayload) async throws {
        try await server.sendFence(payload)
    }

    func sendLifecycle(_ payload: LifecyclePayload) async throws {
        try await server.sendLifecycle(payload)
    }
}

// MARK: - HELLO result

struct PhoneDSHHelloResult: Sendable {
    var connection: PhoneDSHConnection
    var hello: HelloPayload
}

// MARK: - Coordinator

/// Tracks ordered-channel connections and the Worker HELLO handshake.
actor PhoneDSHChannelCoordinator {
    private let eventBus: PhoneDSHEventBus
    private var connections: [UUID: PhoneDSHConnection] = [:]
    private var latestConnectionID: UUID?
    private var hellos: [UUID: HelloPayload] = [:]
    private var connectionCount: UInt64 = 0
    private var helloCount: UInt64 = 0
    /// `ERROR VFS_REFUSED` diagnostics observed by this host (channel.md §4.8).
    /// Resource refusals never count as connection errors and never enter Failed.
    private var vfsRefusalCount: UInt64 = 0
    private var lastVFSRefusalValue: PhoneDSHVFSRefusal?
    /// Non-standing `0x40 API_REQ` exchanges whose `0x41/0x42/0x43` stream has
    /// not ended. The D23 `remote.mux` receive stream is tracked in
    /// ``apiRequestTokens`` instead, so it can never hold the drain open.
    private var inFlightAPIRequests = 0
    /// Every API request this incarnation started, keyed by its token. A token
    /// remembers whether it is a finite exchange or the standing receive so a
    /// late/duplicate finish cannot decrement a newer request (G2-FIX-Q4-CHANNEL).
    private var apiRequestTokens: [UUID: PhoneDSHAPIRequestKind] = [:]
    /// Incremented by every new in-flight unit of work so a drain waiter that
    /// was woken by an earlier finish re-checks the actor state before it
    /// reports quiescence.
    private var drainGeneration: UInt64 = 0
    /// `0x10 VFS_MUT`, `0x12 VFS_BARRIER` and `0x30 JOURNAL` handlers that have
    /// not returned. They are write-direction side effects too: a drain that
    /// only waits for API exchanges can close the WAL epoch while one of them
    /// is still appending (G2-B08).
    private var inFlightWriteFrames = 0
    private var drainWaiters: [(id: UUID,
                                continuation: CheckedContinuation<Bool, Never>)] = []
    private var helloWaiters: [(id: UUID, after: UInt64, bootID: String?,
                                continuation: CheckedContinuation<PhoneDSHHelloResult?, Never>)] = []
    private var channelWaiters: [(id: UUID, excluded: Set<UUID>,
                                  continuation: CheckedContinuation<PhoneDSHConnection?, Never>)] = []
    /// Connections whose close in this drain did not quiesce. They stay part of
    /// the drain even after their receive loop finishes, so a Host retry cannot
    /// mistake them for pre-drain history and pack over writes that may already
    /// be lost.
    private var nonQuiescentConnections: Set<UUID> = []
    /// One drain reboot's incarnation barrier. While it is active only a HELLO
    /// from the replacement boot may become the current connection: the prior
    /// Worker's boot ids are retired, and the expected replacement boot id,
    /// session epoch and fence baseline are checked here rather than trusted
    /// from the fact that `helloCount` advanced.
    private var rebootBarrier: RebootBarrier?

    private struct RebootBarrier {
        /// Boot ids of every incarnation this drain has already stopped.
        var retiredBootIDs: Set<String>
        /// Connection ids of every incarnation this drain has already stopped.
        /// A delayed HELLO from an interim page can arrive after
        /// ``prepareForReboot(retiringCurrentIncarnation:)`` cleared the table;
        /// retiring the connection id rejects it even when its boot id was not
        /// known at clear time.
        var retiredConnectionIDs: Set<UUID>
        /// Session epoch from the incarnation being replaced. A replacement is
        /// another process boot of the same host session, so it must echo it.
        var baselineSessionEpoch: UInt64?
        /// Fence the old incarnation reported. The host is the fence
        /// authority; a replacement may be at the same or a newer generation,
        /// but never at an older one or under a different owner.
        var baselineFence: Fence?
        /// Boot id returned by the engine's restart report. Once known, only
        /// this boot id may satisfy the replacement HELLO wait.
        var expectedBootID: String?
    }

    init(eventBus: PhoneDSHEventBus) {
        self.eventBus = eventBus
    }

    // MARK: Registration and HELLO

    func register(_ connection: PhoneDSHConnection) {
        connections[connection.id] = connection
        connectionCount &+= 1
        eventBus.send(.channelConnected(connectionCount))
        // During a drain reboot the connection is not publishable until its
        // HELLO proved it belongs to the replacement incarnation. Otherwise a
        // reconnecting old Worker could become `currentConnection()` and
        // receive the recovery/cancel traffic for the new one.
        guard rebootBarrier == nil else { return }
        latestConnectionID = connection.id
        resumeChannelWaiters(for: connection)
    }

    /// Validates one Worker HELLO against the active drain reboot barrier.
    ///
    /// Throws before the HELLO is recorded, so the caller (ChannelServer) closes
    /// the connection and no VFS/journal frame from that incarnation can be
    /// dispatched. The check is intentionally about incarnation identity, not
    /// only about a HELLO counter: a reconnect of the stopped Worker must not
    /// satisfy ``waitForHello(after:expecting:timeout:)``.
    func helloReceived(connection: PhoneDSHConnection,
                       payload: HelloPayload) throws {
        if let barrier = rebootBarrier {
            if barrier.retiredConnectionIDs.contains(connection.id) {
                reject(connection)
                throw PhoneWireError(
                    code: .fenceStale,
                    message: "the Worker connection belongs to the incarnation "
                        + "this drain stopped")
            }
            if barrier.retiredBootIDs.contains(payload.bootID) {
                reject(connection)
                throw PhoneWireError(
                    code: .fenceStale,
                    message: "the Worker boot \(payload.bootID) belongs to the "
                        + "incarnation this drain stopped")
            }
            if let expectedBootID = barrier.expectedBootID,
               payload.bootID != expectedBootID {
                reject(connection)
                throw PhoneWireError(
                    code: .fenceStale,
                    message: "the Worker boot \(payload.bootID) is not the "
                        + "replacement boot \(expectedBootID)")
            }
            if let baseline = barrier.baselineSessionEpoch,
               payload.sessionEpoch != baseline {
                reject(connection)
                throw PhoneWireError(
                    code: .fenceStale,
                    message: "the Worker session epoch \(payload.sessionEpoch) "
                        + "does not match the replaced session \(baseline)")
            }
            if let baseline = barrier.baselineFence {
                guard payload.fence.owner == baseline.owner,
                      payload.fence.generation >= baseline.generation else {
                    reject(connection)
                    throw PhoneWireError(
                        code: .fenceStale,
                        message: "the replacement Worker fence is older than "
                            + "the incarnation it replaces")
                }
            }
        }
        connections[connection.id] = connection
        latestConnectionID = connection.id
        hellos[connection.id] = payload
        helloCount &+= 1
        eventBus.send(.workerHello(PhoneDSHWorkerHello(bootID: payload.bootID,
                                                       lastMseq: payload.lastMseq ?? 0,
                                                       generation: payload.fence.generation,
                                                       walSeq: payload.fence.walSeq,
                                                       count: helloCount)))
        let result = PhoneDSHHelloResult(connection: connection, hello: payload)
        let waiters = helloWaiters
        helloWaiters.removeAll()
        for waiter in waiters {
            if helloCount >= waiter.after,
               waiter.bootID == nil || waiter.bootID == payload.bootID {
                waiter.continuation.resume(returning: result)
            } else {
                // A caller waiting for a HELLO newer than this one (the drain
                // escalation's replacement Worker) keeps waiting. The same is
                // true when the HELLO does not carry the expected boot id.
                helloWaiters.append(waiter)
            }
        }
        // Under the reboot barrier the connection only becomes visible now,
        // after its HELLO passed the incarnation checks.
        if rebootBarrier != nil { resumeChannelWaiters(for: connection) }
    }

    private func reject(_ connection: PhoneDSHConnection) {
        connections.removeValue(forKey: connection.id)
        hellos.removeValue(forKey: connection.id)
        if latestConnectionID == connection.id { latestConnectionID = nil }
    }

    private func resumeChannelWaiters(for connection: PhoneDSHConnection) {
        var remaining: [(id: UUID, excluded: Set<UUID>,
                         continuation: CheckedContinuation<PhoneDSHConnection?, Never>)] = []
        for waiter in channelWaiters {
            if waiter.excluded.contains(connection.id) {
                remaining.append(waiter)
            } else {
                waiter.continuation.resume(returning: connection)
            }
        }
        channelWaiters = remaining
    }

    /// Waits for the next Worker HELLO. Returns immediately when one was
    /// already observed on the newest connection.
    func waitForHello(timeout: TimeInterval) async throws -> PhoneDSHHelloResult {
        try await waitForHello(after: 0, expecting: nil, timeout: timeout)
    }

    /// Waits for a Worker HELLO newer than `sequence` (the value
    /// ``helloCountValue()`` reported before the caller terminated the Worker).
    ///
    /// The drain escalation (G2-FIX-105) uses this instead of
    /// ``waitForHello(timeout:)``: the ordinary wait returns the *previous*
    /// incarnation's HELLO immediately, while the replacement Worker's VFS has
    /// to be up before the abort can be re-driven at it. When `expecting` is
    /// non-nil, only that boot id can satisfy the wait, so a stale connection
    /// that reconnects during the restart cannot be mistaken for the
    /// replacement even if it is not in the retired set.
    ///
    /// - Parameters:
    ///   - sequence: 1-based HELLO count observed before the termination.
    ///   - bootID: replacement boot id from the engine restart report, if any.
    ///   - timeout: seconds to wait for a newer HELLO.
    /// - Returns: the newer HELLO and its connection.
    func waitForHello(after sequence: UInt64,
                      expecting bootID: String?,
                      timeout: TimeInterval) async throws -> PhoneDSHHelloResult {
        if helloCount > sequence,
           let latestConnectionID,
           let hello = hellos[latestConnectionID],
           let connection = connections[latestConnectionID],
           bootID == nil || hello.bootID == bootID {
            return PhoneDSHHelloResult(connection: connection, hello: hello)
        }
        let waiterID = UUID()
        let result: PhoneDSHHelloResult? = await withCheckedContinuation { continuation in
            helloWaiters.append((waiterID, sequence &+ 1, bootID, continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                await self?.expireHelloWaiter(waiterID)
            }
        }
        guard let result else {
            throw PhoneDSHError.startTimedOut("Worker HELLO")
        }
        return result
    }

    // MARK: Channel lookup

    func currentConnection() -> PhoneDSHConnection? {
        guard let latestConnectionID else { return nil }
        return connections[latestConnectionID]
    }

    func waitForChannel(excluding: Set<UUID>, timeout: TimeInterval) async throws -> PhoneDSHConnection {
        if let connection = currentConnection(), !excluding.contains(connection.id) {
            return connection
        }
        let waiterID = UUID()
        let result: PhoneDSHConnection? = await withCheckedContinuation { continuation in
            channelWaiters.append((waiterID, excluding, continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                await self?.expireChannelWaiter(waiterID)
            }
        }
        guard let result else { throw PhoneDSHError.channelUnavailable }
        return result
    }

    func lastWorkerFence() -> Fence? {
        guard let latestConnectionID, let hello = hellos[latestConnectionID] else { return nil }
        return hello.fence
    }

    func helloCountValue() -> UInt64 { helloCount }
    func connectionCountValue() -> UInt64 { connectionCount }

    /// Snapshot of the connection ids that currently exist. The legacy
    /// combined-restart fallback captures this immediately before its second
    /// restart: any connection that already existed then belongs to the old or
    /// interim page, never to the replacement that restart is about to boot.
    func connectionIDs() -> Set<UUID> { Set(connections.keys) }

    /// Retires connections that existed before the replacement restart.
    ///
    /// A delayed interim HELLO can arrive on a connection opened after
    /// `prepareForReboot` but before the second restart. Retiring its id here,
    /// after the restart returns, removes any HELLO it managed to register so
    /// only a connection created by the restart can satisfy the replacement
    /// wait. A replacement HELLO that raced the restart keeps its own id and is
    /// left untouched.
    func retireReplacementCandidates(_ ids: Set<UUID>) async {
        guard ids.isEmpty == false, var barrier = rebootBarrier else { return }
        barrier.retiredConnectionIDs.formUnion(ids)
        for id in ids {
            if let hello = hellos[id] {
                barrier.retiredBootIDs.insert(hello.bootID)
            }
        }
        rebootBarrier = barrier
        for id in ids {
            hellos.removeValue(forKey: id)
            if latestConnectionID == id { latestConnectionID = nil }
            guard let connection = connections.removeValue(forKey: id) else { continue }
            await connection.server.close(code: 1008)
        }
    }

    // MARK: Resource refusals

    /// Records one `ERROR VFS_REFUSED` diagnostic (channel.md §4.8).
    ///
    /// A resource refusal is not a connection error: the refused mutation
    /// consumed no mseq and the channel stays open, so this only feeds the
    /// diagnostics snapshot. The host never enters Failed on it.
    func noteVFSRefusal(_ payload: ErrorPayload) {
        if let refusal = PhoneDSHVFSRefusal(payload: payload) {
            lastVFSRefusalValue = refusal
        }
        vfsRefusalCount &+= 1
    }

    func vfsRefusalCountValue() -> UInt64 { vfsRefusalCount }
    func lastVFSRefusal() -> PhoneDSHVFSRefusal? { lastVFSRefusalValue }

    // MARK: In-flight work (drain support)

    /// Records that one `0x40 API_REQ` is waiting for its response stream and
    /// returns the token its finish must present.
    ///
    /// Only an ``PhoneDSHAPIRequestKind/exchange`` enters the non-standing
    /// in-flight count; the standing mux receive is tracked for token
    /// retirement but excluded from the drain criterion.
    func apiRequestStarted(kind: PhoneDSHAPIRequestKind = .exchange) -> UUID {
        let token = UUID()
        apiRequestTokens[token] = kind
        if kind == .exchange { inFlightAPIRequests += 1 }
        drainGeneration &+= 1
        return token
    }

    /// Records that one `0x40 API_REQ` response stream ended or was aborted.
    ///
    /// The token must match the one returned by ``apiRequestStarted(kind:)``.
    /// An unknown or already-retired token is ignored, so a stream that ends
    /// twice (or an old stream ending after a new request started) cannot
    /// decrement the newer request's accounting.
    func apiRequestFinished(_ token: UUID) {
        guard let kind = apiRequestTokens.removeValue(forKey: token) else { return }
        if kind == .exchange, inFlightAPIRequests > 0 { inFlightAPIRequests -= 1 }
        // Wake every drain waiter as soon as the last exchange ends; the
        // waiter re-checks the actor state, so this is a hint, not a verdict.
        if drainQuiescent { resumeDrainWaiters(drained: true) }
    }

    /// Records that one write-direction frame (`0x10`/`0x12`/`0x30`) started
    /// being handled.
    func inboundWriteStarted() {
        inFlightWriteFrames += 1
        drainGeneration &+= 1
    }

    /// Records that the handler of one write-direction frame returned.
    func inboundWriteFinished() {
        if inFlightWriteFrames > 0 { inFlightWriteFrames -= 1 }
        if drainQuiescent { resumeDrainWaiters(drained: true) }
    }

    /// Number of non-standing API requests whose response stream is still open.
    func inFlightAPIRequestCount() -> Int { inFlightAPIRequests }

    /// Number of tracked D23 standing `remote.mux` receive streams.
    func standingAPIRequestCount() -> Int {
        apiRequestTokens.values.filter { $0 == .standingReceive }.count
    }

    /// Number of write-direction frames whose handler has not returned.
    func inFlightWriteFrameCount() -> Int { inFlightWriteFrames }

    /// D14 "wait for in-flight": no non-standing API exchange and no write-
    /// direction frame is being handled. A standing mux receive is explicitly
    /// *not* in-flight work (G2-FIX-Q4-CHANNEL).
    private var drainQuiescent: Bool {
        inFlightAPIRequests == 0 && inFlightWriteFrames == 0
    }

    /// Waits until every in-flight `0x40` exchange **and** every write-
    /// direction sink/journal frame has finished, or `timeout` elapses.
    ///
    /// Event driven: the continuations live here and are resumed by
    /// ``apiRequestFinished(_:)`` / ``inboundWriteFinished()``; the deadline
    /// task ends the wait. A finish is only a wake-up: the loop re-checks the
    /// actor state and the generational work counter before it reports
    /// quiescence, so a request that starts while the waiter is being
    /// scheduled keeps the drain waiting instead of receiving a stale `true`.
    ///
    /// - Returns: `true` when the channel is quiescent.
    func waitForDrainQuiescence(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            // The deadline is checked before the quiescent branch. That branch
            // can `continue` for a long time when short requests keep changing
            // `drainGeneration`, and it must not be able to skip the bound.
            if Date() >= deadline { return drainQuiescent }
            if drainQuiescent {
                // Cross a scheduling point and re-check on the actor. This is
                // the generation/deadline recheck: a finish that raced with a
                // new `apiRequestStarted` must not return the old verdict.
                let generation = drainGeneration
                await Task.yield()
                if drainQuiescent && drainGeneration == generation { return true }
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return drainQuiescent }
            let waiterID = UUID()
            let signaled: Bool = await withCheckedContinuation { continuation in
                drainWaiters.append((waiterID, continuation))
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(remaining))
                    await self?.expireDrainWaiter(waiterID)
                }
            }
            if !signaled {
                // Deadline or teardown: report the state observed at that
                // instant instead of waiting for another event.
                return drainQuiescent
            }
        }
    }

    /// Waits for the write-direction handlers to be idle continuously for
    /// `settle` seconds.
    ///
    /// Used only after the loopback listener and every live connection have
    /// been stopped: no new frame can arrive, and the quiet window covers a
    /// frame that was already decoded into a WebSocket message but not yet
    /// dispatched. The wait is bounded and reports the last observed state.
    func waitForInboundWritesToQuiesce(timeout: TimeInterval = 2,
                                       settle: TimeInterval = 0.01) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let quietWindow = max(0, settle)
        var quietSince: Date?
        while true {
            if inFlightWriteFrames == 0 {
                let now = Date()
                if let quietSince {
                    if now.timeIntervalSince(quietSince) >= quietWindow { return true }
                } else {
                    quietSince = now
                }
            } else {
                quietSince = nil
            }
            if Date() >= deadline { return inFlightWriteFrames == 0 }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// IDs of connections that may still accept an inbound write when a drain
    /// starts.
    ///
    /// The coordinator keeps historical connections until a reboot clears the
    /// table, and a reconnect leaves the previous socket entry behind. Only a
    /// connection whose receive loop never started, or whose drain ended with a
    /// peer EOF after every delivered frame was dispatched, proves that no
    /// inbound write can still be hidden in the socket/decoder. Every other
    /// finished connection stays a strict drain participant even when it names
    /// a retired boot or its accepted mseq is at or below the WAL tail:
    /// `acceptedMseq` advances only after a VFS handler persisted a frame, so
    /// it does not cover a `VFS_MUT`/`JOURNAL` message that reached the socket
    /// or decoder but was never dispatched. Treating that connection as
    /// history and packing over it could lose an accepted write. A connection
    /// whose close already failed inside this drain also stays, so a retry
    /// cannot mistake it for history.
    func connectionIDsToDrain() async -> Set<UUID> {
        var ids: Set<UUID> = []
        for (id, connection) in connections {
            if nonQuiescentConnections.contains(id) {
                ids.insert(id)
                continue
            }
            let started = await connection.server.hasStartedReceiveLoop()
            if started {
                let finished = await connection.server.hasFinishedReceiveLoop()
                if !finished {
                    ids.insert(id)
                    continue
                }
            }
            let reason = await connection.server.drainEndReason()
            if reason == .cleanEOF || reason == .notStarted { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Closes every live connection of the old incarnation, then waits for
    /// each receive loop to stop and for the write-direction handlers that
    /// were already dispatching to finish.
    ///
    /// This is the ordering the drain escalation needs before it repacks the
    /// overlay: a frame the old connection had already admitted must reach the
    /// WAL/materialized tree before the replacement mounts that image. The
    /// wait uses the caller's full remaining drain budget; `false` means the
    /// caller must not pack or boot.
    ///
    /// The connections are *drain-closed*, not hard-closed: the server keeps
    /// reading and dispatching messages that already reached the transport,
    /// including messages queued behind the one whose handler triggered the
    /// close. A hard `close()` would set `finished` and drop those VFS/JOURNAL
    /// messages. Only after the transport reaches EOF, the receive loop is idle
    /// for the drain window, or the caller's deadline expires does the server
    /// close the socket. `beginDrainClose` is non-blocking, so a stuck socket
    /// close cannot consume more than this bounded wait either.
    ///
    /// - Parameters:
    ///   - timeout: seconds to wait, bounded by the drain deadline.
    ///   - requiringCleanEnd: IDs captured by ``connectionIDsToDrain()``
    ///     before the old Worker was stopped. They must end with a clean peer
    ///     EOF (or a drain close that never started). A finished connection
    ///     outside this set is history only when its end was clean; a
    ///     non-clean finished connection is kept strict too and fails the
    ///     drain. `nil` keeps the strict behaviour for every connection that
    ///     is still live at call time.
    ///   - requiringCleanEndForUncaptured: the two-phase production path sets
    ///     this. A connection registered while `terminateWorker()` runs is not
    ///     in the pre-terminate snapshot, so it must still reach a clean EOF
    ///     instead of being treated as an interim page that received no host
    ///     RPC. The combined-restart compatibility path keeps `false` for the
    ///     interim page it boots itself.
    /// - Returns: whether every receive loop ended with a clean end and no
    ///   inbound write frame is still dispatching when the wait finished.
    func closeConnectionsAndWaitForInboundWritesToQuiesce(
        timeout: TimeInterval,
        requiringCleanEnd: Set<UUID>? = nil,
        requiringCleanEndForUncaptured: Bool = false
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let snapshot = Array(connections)
        var live: [(connection: PhoneDSHConnection, requireCleanEnd: Bool)] = []
        var optional: [PhoneDSHConnection] = []
        for (id, connection) in snapshot {
            let captured = requiringCleanEnd?.contains(id) ?? true
            var requireCleanEnd = captured
            if !captured {
                let started = await connection.server.hasStartedReceiveLoop()
                if started {
                    let finished = await connection.server.hasFinishedReceiveLoop()
                    // A connection that stopped before this drain can be
                    // dropped only when its end proves no accepted write is
                    // left: a peer EOF with every delivered frame dispatched,
                    // or a drain close that never started the receive loop.
                    // `nil`, `.closed`, idle/hard and transport-failure
                    // verdicts are not history: keep them strict so the drain
                    // fails instead of packing over a possibly lost write.
                    if finished {
                        let clean = await connection.server.hasCleanDrainEnd()
                        if clean {
                            connections.removeValue(forKey: id)
                            hellos.removeValue(forKey: id)
                            if latestConnectionID == id { latestConnectionID = nil }
                            continue
                        }
                        requireCleanEnd = true
                    } else if requiringCleanEndForUncaptured {
                        // A connection that registered during the production
                        // terminate window is not the legacy interim page: it
                        // may be a reconnecting old Worker whose socket still
                        // hides an accepted write.
                        requireCleanEnd = true
                    }
                } else if requiringCleanEndForUncaptured {
                    requireCleanEnd = true
                }
            }
            if requireCleanEnd {
                live.append((connection: connection, requireCleanEnd: true))
            } else {
                // The combined-restart compatibility path boots an interim
                // page of its own. That page received no host RPC, so its
                // socket may be closed immediately: waiting for it to reach a
                // peer EOF would spend the whole remaining drain window (the
                // second restart is what destroys it), leaving no budget to
                // pack and boot the replacement. Closing it before the pack
                // also proves it cannot append a VFS/JOURNAL frame behind the
                // overlay the replacement mounts.
                optional.append(connection)
            }
        }
        for connection in optional {
            await retireOptionalInterimConnection(connection)
        }
        for entry in live {
            // Wait for the peer's EOF for the whole remaining drain window.
            // Closing after a short idle watchdog would turn a merely slow
            // WebKit/WebContent FIN into `.idleTimeout`, and the strict close
            // would then reject an old Worker that really did stop. Only the
            // caller's hard deadline closes a socket that is still open, and
            // that close is deliberately classified as non-clean.
            let remaining = max(0, deadline.timeIntervalSinceNow)
            await entry.connection.server.beginDrainClose(
                code: 1000,
                idleTimeout: remaining,
                maxDuration: remaining)
        }
        while true {
            var loopsFinished = true
            var cleanEnd = true
            for entry in live {
                let finished = await entry.connection.server.hasFinishedReceiveLoop()
                if !finished {
                    loopsFinished = false
                    break
                }
                if entry.requireCleanEnd {
                    // `hasFinishedReceiveLoop()` alone also covers an idle or
                    // hard watchdog close that may have left a queued message
                    // or half a WebSocket message unread. Only a peer EOF
                    // proves the old connection has no more accepted inbound
                    // writes to lose.
                    if !(await entry.connection.server.hasCleanDrainEnd()) {
                        cleanEnd = false
                    }
                }
            }
            if loopsFinished {
                guard cleanEnd else {
                    for entry in live {
                        nonQuiescentConnections.insert(entry.connection.id)
                    }
                    return false
                }
                break
            }
            if Date() >= deadline {
                for entry in live {
                    nonQuiescentConnections.insert(entry.connection.id)
                }
                return false
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let drained = await waitForInboundWritesToQuiesce(
            timeout: max(0, deadline.timeIntervalSinceNow))
        for entry in live {
            if drained {
                nonQuiescentConnections.remove(entry.connection.id)
            } else {
                nonQuiescentConnections.insert(entry.connection.id)
            }
        }
        return drained
    }

    /// Closes one optional interim connection before the overlay pack.
    ///
    /// It is not the old Worker: the compatibility fallback booted it itself
    /// after the stop phase and sent it no host RPC. Waiting for its peer EOF
    /// would make the drain spend its entire budget on a page the second
    /// restart is about to destroy, so it is closed immediately. Its id and
    /// boot id are retired in the barrier as well, so a late HELLO can never
    /// turn it into the replacement after the tables are cleared.
    private func retireOptionalInterimConnection(
        _ connection: PhoneDSHConnection
    ) async {
        if var barrier = rebootBarrier {
            barrier.retiredConnectionIDs.insert(connection.id)
            if let hello = hellos[connection.id] {
                barrier.retiredBootIDs.insert(hello.bootID)
            }
            rebootBarrier = barrier
        }
        connections.removeValue(forKey: connection.id)
        hellos.removeValue(forKey: connection.id)
        if latestConnectionID == connection.id { latestConnectionID = nil }
        await connection.server.close(code: 1008)
    }

    func channelMetrics() async -> ChannelMetrics? {
        guard let connection = currentConnection() else { return nil }
        return await connection.server.currentMetrics()
    }

    /// Installs the drain reboot's incarnation barrier without clearing the
    /// connections. The escalation arms it before it closes the old channel so
    /// a reconnect during that close is registered as untrusted and cannot get
    /// a HELLO accepted; ``prepareForReboot(retiringCurrentIncarnation:)`` then
    /// clears the tables while keeping the barrier.
    func armReplacementBarrier() {
        installReplacementBarrier()
    }

    private func installReplacementBarrier() {
        let previousHellos = hellos
        let latestHello = latestConnectionID.flatMap { previousHellos[$0] }
        let inheritedBootIDs = rebootBarrier?.retiredBootIDs ?? []
        let retiredBootIDs = Set(previousHellos.values.map(\.bootID))
            .union(inheritedBootIDs)
        let inheritedConnectionIDs = rebootBarrier?.retiredConnectionIDs ?? []
        let retiredConnectionIDs = Set(connections.keys)
            .union(inheritedConnectionIDs)
        rebootBarrier = RebootBarrier(
            retiredBootIDs: retiredBootIDs,
            retiredConnectionIDs: retiredConnectionIDs,
            baselineSessionEpoch:
                rebootBarrier?.baselineSessionEpoch ?? latestHello?.sessionEpoch,
            baselineFence: rebootBarrier?.baselineFence ?? latestHello?.fence,
            expectedBootID: nil)
    }

    /// Forgets the previous run's connections before a resume and closes their
    /// sockets. Counters are kept: diagnostics reports how many connections
    /// this host has seen.
    ///
    /// Clearing the tables alone is not enough for the drain escalation: a
    /// connection that already had its HELLO accepted could keep dispatching
    /// `VFS_MUT`/`JOURNAL` frames after the overlay was packed, and the
    /// replacement would then mount an image that lags the WAL. This method
    /// therefore closes every removed connection before returning. A reconnect
    /// can register while those closes suspend, so the clear/close is repeated
    /// in a bounded sweep; each removed id and boot id is retired in the
    /// barrier so a late HELLO is still refused.
    ///
    /// - Parameter retiringCurrentIncarnation: when `true` the previous boot's
    ///   id is retired and a HELLO barrier is installed before the tables are
    ///   cleared. The drain escalation uses this so a reconnecting old Worker
    ///   cannot register as the replacement while the overlay is packed and the
    ///   new page boots. Ordinary restarts pass `false` and keep the historical
    ///   acceptance behaviour: every subsequent HELLO is accepted normally.
    /// - Returns: how many connections were present while the tables were
    ///   cleared and closed before this method returned.
    @discardableResult
    func prepareForReboot(retiringCurrentIncarnation: Bool = false) async -> Int {
        if retiringCurrentIncarnation {
            installReplacementBarrier()
        } else {
            rebootBarrier = nil
        }
        var closed = 0
        // A reconnect may register during a socket close below. Clear and close
        // in a few bounded sweeps so a pre-pack interim socket cannot survive
        // just because it raced the first close. The last sweep is a no-op when
        // the table is already empty.
        for _ in 0..<4 {
            let removed = Array(connections.values)
            let removedHellos = hellos
            connections.removeAll()
            nonQuiescentConnections.removeAll()
            latestConnectionID = nil
            hellos.removeAll()
            guard !removed.isEmpty else { break }
            if retiringCurrentIncarnation, var barrier = rebootBarrier {
                for connection in removed {
                    barrier.retiredConnectionIDs.insert(connection.id)
                    if let hello = removedHellos[connection.id] {
                        barrier.retiredBootIDs.insert(hello.bootID)
                    }
                }
                rebootBarrier = barrier
            }
            for connection in removed {
                await connection.server.close(
                    code: retiringCurrentIncarnation ? 1008 : 1000)
                closed += 1
            }
        }
        let channelWaiters = self.channelWaiters
        self.channelWaiters.removeAll()
        for waiter in channelWaiters { waiter.continuation.resume(returning: nil) }
        let helloWaiters = self.helloWaiters
        self.helloWaiters.removeAll()
        for waiter in helloWaiters { waiter.continuation.resume(returning: nil) }
        // A drain waiter cannot outlive the connection it waited on.
        resumeDrainWaiters(drained: drainQuiescent)
        return closed
    }

    /// Binds the active drain reboot barrier to the boot id in the engine's
    /// restart report.
    ///
    /// A HELLO can arrive while `restart` is still waiting for boot-ready, so
    /// the expected id is only known afterwards. Any connection whose HELLO
    /// does not carry that id is removed and closed instead of being left as
    /// the current connection; the subsequent
    /// ``waitForHello(after:expecting:timeout:)`` then waits only for the real
    /// replacement boot.
    func expectReplacementWorker(bootID: String?) async {
        guard var barrier = rebootBarrier else { return }
        barrier.expectedBootID = bootID
        rebootBarrier = barrier
        guard let bootID else { return }
        if let match = hellos.first(where: { $0.value.bootID == bootID })?.key,
           let connection = connections[match] {
            latestConnectionID = match
            resumeChannelWaiters(for: connection)
            return
        }
        // No accepted HELLO belongs to the replacement yet. Drop any HELLO
        // from a different new incarnation so it cannot satisfy the wait or
        // receive the recovery/cancel RPCs below.
        let stale = connections.filter { hellos[$0.key] != nil }
        latestConnectionID = nil
        for (id, connection) in stale {
            hellos.removeValue(forKey: id)
            connections.removeValue(forKey: id)
            await connection.server.close(code: 1008)
        }
    }

    private func expireHelloWaiter(_ id: UUID) {
        guard let index = helloWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = helloWaiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func expireChannelWaiter(_ id: UUID) {
        guard let index = channelWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = channelWaiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func expireDrainWaiter(_ id: UUID) {
        guard let index = drainWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = drainWaiters.remove(at: index)
        waiter.continuation.resume(returning: drainQuiescent)
    }

    private func resumeDrainWaiters(drained: Bool) {
        guard drainWaiters.isEmpty == false else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: drained) }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}

// MARK: - Facade channel handler

/// Wraps the landed ``DefaultChannelHandling`` with the facade's observations:
/// HELLO registration, journal evidence for the step machine, and console
/// forwarding. Persistence of VFS and journal bytes stays in the landed
/// handler and log adapters; this wrapper never weakens their checks.
actor PhoneDSHChannelHandler: ChannelHandling {
    private let connection: PhoneDSHConnection
    private let delegate: any ChannelHandling
    private let coordinator: PhoneDSHChannelCoordinator
    private let stepMachine: StepMachine
    private let eventBus: PhoneDSHEventBus

    init(connection: PhoneDSHConnection,
         delegate: any ChannelHandling,
         coordinator: PhoneDSHChannelCoordinator,
         stepMachine: StepMachine,
         eventBus: PhoneDSHEventBus) {
        self.connection = connection
        self.delegate = delegate
        self.coordinator = coordinator
        self.stepMachine = stepMachine
        self.eventBus = eventBus
    }

    func handleHello(_ payload: HelloPayload) async throws {
        try await coordinator.helloReceived(connection: connection, payload: payload)
        try await delegate.handleHello(payload)
    }

    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {
        await coordinator.inboundWriteStarted()
        do {
            try await delegate.handleVFSMutation(body, seq: seq)
        } catch {
            await coordinator.inboundWriteFinished()
            throw error
        }
        await coordinator.inboundWriteFinished()
    }

    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64, seq: UInt64) async throws {
        await coordinator.inboundWriteStarted()
        do {
            try await delegate.handleVFSMutation(body, mseq: mseq, seq: seq)
        } catch {
            await coordinator.inboundWriteFinished()
            throw error
        }
        await coordinator.inboundWriteFinished()
    }

    func handleVFSBarrier(_ body: VfsBarrierBody) async throws {
        await coordinator.inboundWriteStarted()
        do {
            try await delegate.handleVFSBarrier(body)
        } catch {
            await coordinator.inboundWriteFinished()
            throw error
        }
        await coordinator.inboundWriteFinished()
    }

    func handleExecRequest(_ payload: ExecRequestPayload) async throws {
        try await delegate.handleExecRequest(payload)
    }

    func handleExecControl(_ payload: ExecControlPayload) async throws {
        try await delegate.handleExecControl(payload)
    }

    func handleJournal(_ body: JournalBody) async throws {
        await coordinator.inboundWriteStarted()
        do {
            _ = try await stepMachine.observeJournal(body)
            try await delegate.handleJournal(body)
        } catch {
            await coordinator.inboundWriteFinished()
            throw error
        }
        await coordinator.inboundWriteFinished()
    }

    func handleAPIResponse(_ frame: ApiResponseFrame) async throws {
        try await delegate.handleAPIResponse(frame)
    }

    func handleAPIEnd(_ frame: ApiEndFrame) async throws {
        try await delegate.handleAPIEnd(frame)
    }

    func handleAPIAbort(_ frame: ApiAbortFrame) async throws {
        try await delegate.handleAPIAbort(frame)
    }

    func handleConsole(_ payload: ConsolePayload) async throws {
        eventBus.send(.console(payload))
        try await delegate.handleConsole(payload)
    }

    func handleError(_ payload: ErrorPayload) async throws {
        if payload.isVFSRefused {
            // channel.md §4.8/§10: a resource refusal is a diagnostic, not the
            // fail-loud connection error `PhoneDSHEvent.error` represents. It
            // is recorded for diagnostics and the channel stays open; the
            // Worker's own CONSOLE audit line reaches the App as an event.
            await coordinator.noteVFSRefusal(payload)
            try await delegate.handleError(payload)
            return
        }
        eventBus.send(.error("\(payload.code.rawValue): \(payload.message)"))
        try await delegate.handleError(payload)
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — drain recovery ordering and terminal-record contract.
//
// The real `park_resume` escalation must not repack the overlay while the old
// connection still has an inbound write handler, and a terminated Worker must
// not be treated as a completed turn merely because its journal no longer has
// an open turn. These unit regressions pin both predicates without a WebKit
// process.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHLoopback
import PhoneDSHWire

/// A channel socket whose receive loop is never entered by this test; closing
/// it must still be observable to the coordinator.
private final class DrainQuiesceSocket: ChannelSocket, @unchecked Sendable {
    func receiveChannelMessage() async throws -> Data? { nil }
    func sendChannelMessage(_ data: Data) async throws {}
    func closeChannel(code: Int) async {}
}

/// A socket that delivers preloaded WebSocket messages (each containing one or
/// more encoded channel frames), then stays blocked until the server
/// drain-closes it.
private actor DrainMultiFrameSocket: ChannelSocket {
    private var messages: [Data]
    private let eofAfterMessages: Bool
    /// Simulates a WebKit/WebContent FIN that arrives after the old 200 ms
    /// idle watchdog would have closed the socket but still inside the drain
    /// budget. Such an EOF is a clean peer end, not an idle close.
    private let eofDelay: TimeInterval
    /// Set by a fixture whose transport is still hiding undelivered inbound
    /// bytes after EOF, so the drain must classify the end as non-quiescent.
    private let pendingInboundData: Bool
    private var closed = false
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []

    init(message: Data, eofAfterMessages: Bool = false,
         eofDelay: TimeInterval = 0, pendingInboundData: Bool = false) {
        self.messages = [message]
        self.eofAfterMessages = eofAfterMessages
        self.eofDelay = eofDelay
        self.pendingInboundData = pendingInboundData
    }

    init(messages: [Data], eofAfterMessages: Bool = false,
         eofDelay: TimeInterval = 0, pendingInboundData: Bool = false) {
        self.messages = messages
        self.eofAfterMessages = eofAfterMessages
        self.eofDelay = eofDelay
        self.pendingInboundData = pendingInboundData
    }

    func receiveChannelMessage() async throws -> Data? {
        if messages.isEmpty == false { return messages.removeFirst() }
        if eofAfterMessages {
            if eofDelay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(eofDelay * 1_000_000_000))
            }
            return nil
        }
        if closed { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func sendChannelMessage(_ data: Data) async throws {}

    func closeChannel(code: Int) async {
        guard !closed else { return }
        closed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func hasPendingInboundData() async -> Bool { pendingInboundData }

    func isClosed() -> Bool { closed }
}

/// A workspace log that acknowledges appended mutations, so the drain-close
/// test also covers an acknowledgement that can no longer reach the old
/// socket while the remaining frames of the same message are still dispatching.
private actor DrainAckingWorkspaceLog: LoopbackWorkspaceLog {
    private var nextMseq: UInt64 = 1
    private var appendedPathsValue: [String] = []
    private var ackContinuations: [UUID: AsyncStream<LoopbackWorkspaceAck>.Continuation] = [:]

    func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        let mseq = nextMseq
        nextMseq += 1
        appendedPathsValue.append(mutation.path)
        for continuation in ackContinuations.values {
            continuation.yield(LoopbackWorkspaceAck(level: .write, uptoMseq: mseq))
        }
        return mseq
    }

    func appendedPaths() -> [String] { appendedPathsValue }

    nonisolated func acks() -> AsyncStream<LoopbackWorkspaceAck> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.store(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.remove(id) }
            }
        }
    }

    private func store(_ continuation: AsyncStream<LoopbackWorkspaceAck>.Continuation,
                       id: UUID) {
        ackContinuations[id] = continuation
    }

    private func remove(_ id: UUID) {
        ackContinuations.removeValue(forKey: id)
    }
}

/// Blocks the first VFS frame so the test can start the drain close while the
/// server is between frames of the same message.
private actor DrainFrameGateHandler: ChannelHandling {
    private let workspaceLog: any LoopbackWorkspaceLog
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var mutationMseqsValue: [UInt64] = []

    init(workspaceLog: any LoopbackWorkspaceLog) {
        self.workspaceLog = workspaceLog
    }

    func mutationMseqs() -> [UInt64] { mutationMseqsValue }

    func waitForFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirst() {
        guard let waiter = releaseWaiter else { return }
        releaseWaiter = nil
        waiter.resume()
    }

    func handleHello(_ payload: HelloPayload) async throws {}

    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {}

    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64,
                           seq: UInt64) async throws {
        mutationMseqsValue.append(mseq)
        _ = try await workspaceLog.append(body)
        guard mseq == 1 else { return }
        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func handleVFSBarrier(_ body: VfsBarrierBody) async throws {}
    func handleExecRequest(_ payload: ExecRequestPayload) async throws {}
    func handleExecControl(_ payload: ExecControlPayload) async throws {}
    func handleJournal(_ body: JournalBody) async throws {}
    func handleAPIResponse(_ frame: ApiResponseFrame) async throws {}
    func handleAPIEnd(_ frame: ApiEndFrame) async throws {}
    func handleAPIAbort(_ frame: ApiAbortFrame) async throws {}
    func handleConsole(_ payload: ConsolePayload) async throws {}
    func handleError(_ payload: ErrorPayload) async throws {}
}

/// Binds the server after construction so a handler can trigger the drain close
/// from inside the first VFS callback and then let the queued message run.
private actor DrainCloseTrigger {
    private var server: ChannelServer?

    func bind(_ server: ChannelServer) {
        self.server = server
    }

    func trigger() async {
        await server?.beginDrainClose(code: 1000)
    }
}

/// A socket whose outbound path never completes until the channel is closed.
/// Used to prove a best-effort drain LIFECYCLE send is abandoned at its
/// deadline instead of holding the fixed drain window.
private actor DrainBlockingSendSocket: ChannelSocket {
    private var closed = false
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []

    func receiveChannelMessage() async throws -> Data? { nil }

    func sendChannelMessage(_ data: Data) async throws {
        if closed { throw LoopbackError.closed }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            sendWaiters.append(continuation)
        }
    }

    func closeChannel(code: Int) async {
        guard !closed else { return }
        closed = true
        let waiters = sendWaiters
        sendWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: LoopbackError.closed) }
    }
}

/// A two-phase engine whose restart must never run when the old connection did
/// not quiesce. It records the calls so the regression can prove no overlay
/// was packed and no replacement was booted.
private final class DrainTerminatingEngine: WebEngineControlling,
                                           WebEngineWorkerTerminating,
                                           WebEngineRestartRequesting,
                                           @unchecked Sendable {
    private let lock = NSLock()
    private var terminateCount = 0
    private var restartCount = 0
    /// Optional transport hook: a real termination closes the old socket too.
    /// The regression uses it to end a live drain participant with hidden bytes.
    private let onTerminate: (@Sendable () async -> Void)?

    init(onTerminate: (@Sendable () async -> Void)? = nil) {
        self.onTerminate = onTerminate
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}
    func bootWorker(_ configuration: WebEngineConfiguration) async throws {}

    func terminateWorker() async throws {
        lock.lock()
        terminateCount += 1
        lock.unlock()
        await onTerminate?()
    }

    func restart() async throws {
        _ = try await restart(reason: .webContentTerminated)
    }

    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        lock.lock()
        restartCount += 1
        lock.unlock()
        return WebEngineRestartReport(reason: reason,
                                      bootID: String(repeating: "d", count: 32),
                                      duration: .zero)
    }

    func counts() -> (terminate: Int, restart: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (terminateCount, restartCount)
    }
}

private struct DrainTransportUnavailable: Error {}

/// The escalation never reaches this transport when the quiesce wait fails;
/// the stub keeps the regression from needing a live Worker.
private final class DrainUnusedTransport: DSHRemoteTransport, @unchecked Sendable {
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        throw DrainTransportUnavailable()
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw DrainTransportUnavailable()
    }
}

/// Triggers a drain close from the first VFS handler and records the later
/// message's VFS/JOURNAL deliveries. This is the multi-message counterpart of
/// `DrainFrameGateHandler`: the second message is already queued in the socket
/// before the first handler starts the close.
private actor DrainQueuedMessageHandler: ChannelHandling {
    private let workspaceLog: any LoopbackWorkspaceLog
    private let close: @Sendable () async -> Void
    private var triggeredClose = false
    private var mutationMseqsValue: [UInt64] = []
    private var journalJseqsValue: [UInt64] = []

    init(workspaceLog: any LoopbackWorkspaceLog,
         close: @escaping @Sendable () async -> Void) {
        self.workspaceLog = workspaceLog
        self.close = close
    }

    func mutationMseqs() -> [UInt64] { mutationMseqsValue }
    func journalJseqs() -> [UInt64] { journalJseqsValue }

    func handleHello(_ payload: HelloPayload) async throws {}

    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {}

    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64,
                           seq: UInt64) async throws {
        mutationMseqsValue.append(mseq)
        _ = try await workspaceLog.append(body)
        guard !triggeredClose else { return }
        triggeredClose = true
        await close()
    }

    func handleVFSBarrier(_ body: VfsBarrierBody) async throws {}
    func handleExecRequest(_ payload: ExecRequestPayload) async throws {}
    func handleExecControl(_ payload: ExecControlPayload) async throws {}
    func handleJournal(_ body: JournalBody) async throws {
        journalJseqsValue.append(body.jseq)
    }
    func handleAPIResponse(_ frame: ApiResponseFrame) async throws {}
    func handleAPIEnd(_ frame: ApiEndFrame) async throws {}
    func handleAPIAbort(_ frame: ApiAbortFrame) async throws {}
    func handleConsole(_ payload: ConsolePayload) async throws {}
    func handleError(_ payload: ErrorPayload) async throws {}
}

final class PhoneDSHDrainRecoveryContractTests: XCTestCase {
    /// A journal with only a header has no open turn, but it also has no
    /// `turn/end`: `isTurnOpen == false` is not terminal evidence.
    func testHeaderOnlyJournalIsNotATerminalTurn() {
        let header = """
        {"type":"session","version":4,"id":"session-header-only","cwd":"/dsh/workspace","createdAt":0,"isSeeded":false,"delegationDepth":0}
        """ + "\n"
        let state = PhoneDSHSessionLog.state(of: Data(header.utf8))
        XCTAssertFalse(state.isTurnOpen)
        XCTAssertFalse(state.sawTurnStart)
        XCTAssertFalse(state.sawTurnEnd)
        XCTAssertFalse(state.hasTerminalTurn,
                       "a header-only journal must never settle a drain")
    }

    /// A `turn/start` with a lost `turn/end` is open and cannot settle; only a
    /// journaled `turn/end` after it makes the turn terminal.
    func testTurnIsTerminalOnlyAfterTurnEnd() {
        let open = """
        {"type":"session","version":4,"id":"session-open","cwd":"/dsh/workspace","createdAt":0,"isSeeded":false,"delegationDepth":0}
        {"type":"turn/start","seq":0,"time":1,"data":{"turn":1}}
        """ + "\n"
        let openState = PhoneDSHSessionLog.state(of: Data(open.utf8))
        XCTAssertTrue(openState.isTurnOpen)
        XCTAssertFalse(openState.hasTerminalTurn)

        let closed = open + """
        {"type":"turn/end","seq":1,"time":2,"data":{"turn":1,"reason":{"kind":"interrupted"}}}
        """ + "\n"
        let closedState = PhoneDSHSessionLog.state(of: Data(closed.utf8))
        XCTAssertFalse(closedState.isTurnOpen)
        XCTAssertTrue(closedState.sawTurnEnd)
        XCTAssertTrue(closedState.hasTerminalTurn)
    }

    /// The terminal record must close the turn the drain observed open. A
    /// journal truncated back to turn 1's completed `turn/end` still reports
    /// `hasTerminalTurn == true`, but it is not evidence for interrupted
    /// turn 2.
    func testTerminalRecordMustCloseTheTurnObservedOpen() {
        let header = """
        {"type":"session","version":4,"id":"session-regressed","cwd":"/dsh/workspace","createdAt":0,"isSeeded":false,"delegationDepth":0}
        """ + "\n"
        let turnOne = """
        {"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}
        {"type":"turn/end","seq":1,"time":1001,"data":{"turn":1,"reason":{"kind":"completed"}}}
        """ + "\n"
        let openTurnTwo = header + turnOne + """
        {"type":"turn/start","seq":2,"time":1002,"data":{"turn":2}}
        """ + "\n"
        let openState = PhoneDSHSessionLog.state(of: Data(openTurnTwo.utf8))
        XCTAssertEqual(openState.openTurn, 2)
        XCTAssertEqual(openState.lastTurnBoundaryTimeMillis, 1002)
        let expected = PhoneDSHExpectedTerminalTurn(
            turn: 2, openedAtMillis: openState.lastTurnBoundaryTimeMillis)

        // The torn tail dropped turn 2's `turn/start`, so the parse falls back
        // to turn 1's terminal record. It looks terminal, but it closed the
        // wrong turn.
        let truncated = header + turnOne
        let truncatedState = PhoneDSHSessionLog.state(of: Data(truncated.utf8))
        XCTAssertTrue(truncatedState.hasTerminalTurn)
        XCTAssertEqual(truncatedState.lastTurnEndTurn, 1)
        XCTAssertFalse(expected.isClosed(by: truncatedState),
                       "an older turn/end must not settle the interrupted turn")

        // DSH's own interrupted repair closes turn 2.
        let repaired = openTurnTwo + """
        {"type":"turn/end","seq":3,"time":1003,"data":{"turn":2,"reason":{"kind":"interrupted"}}}
        """ + "\n"
        let repairedState = PhoneDSHSessionLog.state(of: Data(repaired.utf8))
        XCTAssertEqual(repairedState.lastTurnEndTurn, 2)
        XCTAssertEqual(repairedState.lastTurnEndReason, "interrupted")
        XCTAssertTrue(expected.isClosed(by: repairedState))

        // Older journals without a turn number on `turn/end` use the observed
        // start timestamp: a terminal boundary before it is still rejected.
        let oldEarlierEnd = header + """
        {"type":"turn/end","time":1001,"data":{"reason":{"kind":"completed"}}}
        """ + "\n"
        XCTAssertFalse(expected.isClosed(
            by: PhoneDSHSessionLog.state(of: Data(oldEarlierEnd.utf8))))
        let oldLaterEnd = openTurnTwo + """
        {"type":"turn/end","time":1003,"data":{"reason":{"kind":"interrupted"}}}
        """ + "\n"
        XCTAssertTrue(expected.isClosed(
            by: PhoneDSHSessionLog.state(of: Data(oldLaterEnd.utf8))))
    }

    /// The drain can observe turn 2 open, then the Worker finishes turn 2 and
    /// consumes the pending inbox prompt into turn 3 before escalation reads
    /// the journal. Both `turn/end` records exist; the tail names turn 3. The
    /// expected turn 2 must still settle, while a tail regressed to an older
    /// turn (covered above) must not.
    func testLaterClosedTurnStillSettlesTheEarlierObservedTurn() {
        let journal = """
        {"type":"session","version":4,"id":"session-later-turn","cwd":"/dsh/workspace","createdAt":0,"isSeeded":false,"delegationDepth":0}
        {"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}
        {"type":"turn/end","seq":1,"time":1001,"data":{"turn":1,"reason":{"kind":"completed"}}}
        {"type":"turn/start","seq":2,"time":1002,"data":{"turn":2}}
        {"type":"turn/end","seq":3,"time":1003,"data":{"turn":2,"reason":{"kind":"interrupted"}}}
        {"type":"turn/start","seq":4,"time":1004,"data":{"turn":3}}
        {"type":"turn/end","seq":5,"time":1005,"data":{"turn":3,"reason":{"kind":"completed"}}}
        """ + "\n"
        let state = PhoneDSHSessionLog.state(of: Data(journal.utf8))
        XCTAssertFalse(state.isTurnOpen)
        XCTAssertTrue(state.hasTerminalTurn)
        XCTAssertEqual(state.lastTurnEndTurn, 3)
        XCTAssertEqual(state.closedTurnNumbers, [1, 2, 3])
        XCTAssertTrue(state.closedTurnNumbers.contains(2))

        let expected = PhoneDSHExpectedTerminalTurn(turn: 2, openedAtMillis: 1002)
        XCTAssertTrue(expected.isClosed(by: state),
                      "turn 2's durable turn/end must settle even when turn 3 is the tail")

        // A state built without the closed-turn set still follows the journal's
        // monotonic turn numbers: a terminal tail naming a later turn proves
        // the earlier observed turn closed.
        let monotonic = PhoneDSHSessionTurnState(
            openTurn: nil,
            lastRecordType: "turn/end",
            lastTurnEndReason: "completed",
            lastTurnEndTurn: 3,
            sawTurnStart: true,
            sawTurnEnd: true)
        XCTAssertTrue(expected.isClosed(by: monotonic))
    }

    /// The escalation's close-and-wait reports the truth: with one inbound
    /// write handler still dispatching it waits the full bound and returns
    /// false, so the caller cannot pack or boot.
    func testInboundWriteStillDispatchingIsNotQuiescent() async {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let server = ChannelServer(socket: DrainQuiesceSocket(),
                                   state: ChannelHostState())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        await coordinator.inboundWriteStarted()
        let started = Date()
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.2)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(quiet, "an in-flight write handler is not quiescent")
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
                                    "the wait must use its full bound, not a 1 s shortcut")
        await coordinator.inboundWriteFinished()
    }

    /// With no handler dispatching, closing the old connection is reported
    /// quiescent (the receive loop never started in this fixture).
    func testClosedIdleConnectionIsQuiescent() async {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let server = ChannelServer(socket: DrainQuiesceSocket(),
                                   state: ChannelHostState())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 1)
        XCTAssertTrue(quiet)
        let finished = await server.hasFinishedReceiveLoop()
        XCTAssertTrue(finished)
    }

    /// The drain close must not drop frames already decoded from the same
    /// WebSocket message. The first VFS frame is still dispatching when the
    /// coordinator starts the close; the second frame of that message must
    /// still reach the handler before the receive loop ends.
    func testDrainCloseKeepsFramesDecodedFromTheSameMessage() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "a", count: 32)))
        let first = try Self.vfsFrame(mseq: 1, seq: 2, path: "/dsh/workspace/first")
        let second = try Self.vfsFrame(mseq: 2, seq: 3, path: "/dsh/workspace/second")
        var message = Data()
        message.append(try FrameEncoder.encode(type: .hello, seq: 1, payload: hello))
        message.append(first)
        message.append(second)

        let socket = DrainMultiFrameSocket(message: message, eofAfterMessages: true)
        let workspaceLog = DrainAckingWorkspaceLog()
        let handler = DrainFrameGateHandler(workspaceLog: workspaceLog)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: handler,
                                   workspaceLog: workspaceLog)
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        await handler.waitForFirstStarted()
        let drain = Task {
            await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
                timeout: 2)
        }
        // Wait until the server has actually entered the drain-close state;
        // releasing the first handler earlier would not exercise the race. The
        // socket stays open while the handler dispatches, so draining is the
        // observable state here.
        while !(await server.hasBegunDrainClose()) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await handler.releaseFirst()

        let quiet = await drain.value
        XCTAssertTrue(quiet, "the drain must finish after the decoded frames")
        let mseqs = await handler.mutationMseqs()
        XCTAssertEqual(mseqs, [1, 2],
                       "the second frame of the same message must not be dropped")
    }

    /// The drain close must also keep a *message* already queued behind the
    /// one whose handler starts the close. The Worker's VFS pump can send
    /// several WebSocket messages inside its unconfirmed window; reading only
    /// the current message and then closing would drop the rest.
    func testDrainCloseKeepsMessagesAlreadyQueuedBehindTheCurrentOne() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "b", count: 32)))
        let first = try Self.vfsFrame(mseq: 1, seq: 2,
                                      path: "/dsh/workspace/queued-first")
        var firstMessage = Data()
        firstMessage.append(try FrameEncoder.encode(type: .hello, seq: 1, payload: hello))
        firstMessage.append(first)

        let second = try Self.vfsFrame(mseq: 2, seq: 3,
                                       path: "/dsh/workspace/queued-second")
        let journal = try Self.journalFrame(jseq: 1, seq: 4,
                                            sessionID: "session-queued")
        var secondMessage = Data()
        secondMessage.append(second)
        secondMessage.append(journal)

        let socket = DrainMultiFrameSocket(messages: [firstMessage, secondMessage],
                                           eofAfterMessages: true)
        let workspaceLog = DrainAckingWorkspaceLog()
        let journalLog = InMemoryJournalLog()
        let trigger = DrainCloseTrigger()
        let handler = DrainQueuedMessageHandler(
            workspaceLog: workspaceLog,
            close: { await trigger.trigger() })
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: handler,
                                   workspaceLog: workspaceLog,
                                   journalLog: journalLog)
        await trigger.bind(server)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        let deadline = Date().addingTimeInterval(2)
        // An unstarted server is already quiescent, so observing only the
        // receive-loop flag can finish before `run` has been scheduled.
        while !(await server.hasBegunDrainClose()) {
            if Date() >= deadline {
                XCTFail("the first queued mutation never began the drain")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var finished = await server.hasFinishedReceiveLoop()
        while !finished {
            if Date() >= deadline {
                XCTFail("the drained receive loop did not finish")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            finished = await server.hasFinishedReceiveLoop()
        }

        let mseqs = await handler.mutationMseqs()
        let jseqs = await handler.journalJseqs()
        let paths = await workspaceLog.appendedPaths()
        let lastJseq = await journalLog.lastJseq(sessionID: "session-queued")
        XCTAssertTrue(finished)
        XCTAssertEqual(mseqs, [1, 2],
                       "the VFS frame of the queued message must reach the handler")
        XCTAssertEqual(jseqs, [1],
                       "the JOURNAL frame of the queued message must reach the handler")
        XCTAssertEqual(paths,
                       ["/dsh/workspace/queued-first", "/dsh/workspace/queued-second"],
                       "both VFS mutations must be appended to the WAL")
        XCTAssertEqual(lastJseq, 1,
                       "the queued JOURNAL record must be persisted")
    }

    /// The blocked-handler regression: the first VFS frame never returns, the
    /// socket already has a second message queued, and the caller's deadline
    /// expires. The close-and-wait must report false (the hard close may have
    /// left the queued message unread) and the escalation must not repack the
    /// overlay or boot a replacement on top of that old incarnation.
    func testBlockedHandlerBeyondCallerDeadlineDoesNotPackOverlay() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "e", count: 32)))
        let first = try Self.vfsFrame(mseq: 1, seq: 2,
                                      path: "/dsh/workspace/blocked-first")
        var firstMessage = Data()
        firstMessage.append(try FrameEncoder.encode(type: .hello, seq: 1, payload: hello))
        firstMessage.append(first)

        let second = try Self.vfsFrame(mseq: 2, seq: 3,
                                       path: "/dsh/workspace/blocked-second")
        let journal = try Self.journalFrame(jseq: 1, seq: 4,
                                            sessionID: "session-blocked")
        var secondMessage = Data()
        secondMessage.append(second)
        secondMessage.append(journal)

        let socket = DrainMultiFrameSocket(messages: [firstMessage, secondMessage],
                                           eofAfterMessages: true)
        let workspaceLog = DrainAckingWorkspaceLog()
        let journalLog = InMemoryJournalLog()
        let handler = DrainFrameGateHandler(workspaceLog: workspaceLog)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: handler,
                                   workspaceLog: workspaceLog,
                                   journalLog: journalLog)
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await handler.releaseFirst()
            await server.close()
            run.cancel()
        }
        await handler.waitForFirstStarted()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-drain-pack-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x42, count: 16))
        let engine = DrainTerminatingEngine()
        let escalator = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: DrainUnusedTransport(),
            maximumTerminations: 1)

        let outcome = await escalator.terminateAndReboot(
            sessionIDs: ["session-blocked"],
            deadline: Date().addingTimeInterval(0.3),
            hasTerminalTurn: { false })

        XCTAssertFalse(outcome.settled,
                       "a blocked old connection must not settle a drain")
        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertTrue(attempt.workerTerminated,
                      "the old Worker still has to be stopped")
        XCTAssertFalse(attempt.packedOverlay,
                       "the escalation must not pack while inbound writes may be lost")
        XCTAssertFalse(attempt.freshWorkerReady,
                       "no replacement may boot on a non-quiescent old connection")
        let counts = engine.counts()
        XCTAssertEqual(counts.terminate, 1)
        XCTAssertEqual(counts.restart, 0,
                       "a blocked quiesce must not boot the replacement")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains {
            $0.hasPrefix("overlay-") && $0.hasSuffix(".tar")
        }, "a blocked quiesce must not execute the overlay pack")

        var reason = await server.drainEndReason()
        let reasonDeadline = Date().addingTimeInterval(0.5)
        while reason != .hardDeadline && Date() < reasonDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            reason = await server.drainEndReason()
        }
        XCTAssertEqual(reason, .hardDeadline,
                       "the blocked handler ended only at the hard deadline")
        let cleanAtHardDeadline = await server.hasCleanDrainEnd()
        XCTAssertFalse(cleanAtHardDeadline)
    }

    /// An idle drain close is not an EOF: the socket may still have a queued
    /// message that the watchdog did not read. It must report non-quiescent so
    /// the escalation cannot pack.
    func testIdleDrainCloseIsNotCleanEOF() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "a", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        let socket = DrainMultiFrameSocket(message: message)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let helloDeadline = Date().addingTimeInterval(1)
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= helloDeadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }

        // Production now passes the full remaining drain budget as the idle
        // window. This test pins the lower-level verdict by arming the idle
        // watchdog explicitly: an idle close must never be mistaken for EOF.
        await server.beginDrainClose(code: 1000, idleTimeout: 0.2, maxDuration: 1)
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 1)
        XCTAssertFalse(quiet,
                       "an idle watchdog close is not a clean peer EOF")
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .idleTimeout)
        let clean = await server.hasCleanDrainEnd()
        XCTAssertFalse(clean)
    }

    /// The coordinator must wait for the peer's EOF for the caller's whole
    /// remaining budget. A 200 ms idle close would reject a slow but entirely
    /// healthy WebKit/WebContent FIN before the replacement is even packed.
    func testDrainCloseUsesFullRemainingBudgetNotAnIdleWatchdog() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "d", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        let socket = DrainMultiFrameSocket(message: message)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let helloDeadline = Date().addingTimeInterval(1)
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= helloDeadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }

        let started = Date()
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.4)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(quiet, "a socket that never reaches EOF is not quiescent")
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.3,
            "the drain must not close the old socket after the former 200 ms idle window")
        var reason = await server.drainEndReason()
        let reasonDeadline = Date().addingTimeInterval(1)
        while reason != .hardDeadline && Date() < reasonDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            reason = await server.drainEndReason()
        }
        XCTAssertEqual(reason, .hardDeadline,
                       "only the caller's hard deadline may close the old socket")
        let clean = await server.hasCleanDrainEnd()
        XCTAssertFalse(clean)
    }

    /// A peer EOF that arrives after the former 200 ms idle window but still
    /// inside the drain budget is clean: the old Worker really stopped, so the
    /// escalation must be allowed to pack and boot the replacement.
    func testSlowPeerEOFInsideDrainBudgetIsClean() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "e", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        let socket = DrainMultiFrameSocket(
            message: message, eofAfterMessages: true, eofDelay: 0.35)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let helloDeadline = Date().addingTimeInterval(1)
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= helloDeadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }

        let started = Date()
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 2)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(quiet, "a peer EOF inside the drain budget is clean")
        XCTAssertGreaterThanOrEqual(elapsed, 0.3,
                                    "the test must exercise the slow-FIN window")
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .cleanEOF)
        let clean = await server.hasCleanDrainEnd()
        XCTAssertTrue(clean)
    }

    /// Production stops the old page and only then arms the drain close, so the
    /// peer WebSocket can reach EOF before `beginDrainClose`. That EOF is a
    /// clean end: it must not be recorded as a host close or burn one of the
    /// two bounded terminations.
    func testPeerEOFBeforeDrainCloseIsClean() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "c", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        let socket = DrainMultiFrameSocket(message: message, eofAfterMessages: true)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let deadline = Date().addingTimeInterval(1)
        // `hasFinishedReceiveLoop()` is also true before `run()` starts; wait
        // for the HELLO to prove this task actually entered the receive loop.
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= deadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }
        var finished = await server.hasFinishedReceiveLoop()
        while !finished {
            if Date() >= deadline {
                XCTFail("the server never reached peer EOF")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            finished = await server.hasFinishedReceiveLoop()
        }
        // This is the production race: the peer is already gone before the
        // escalation arms its drain close.
        await server.beginDrainClose(code: 1000, idleTimeout: 0.2, maxDuration: 1)
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .cleanEOF)
        let clean = await server.hasCleanDrainEnd()
        XCTAssertTrue(clean, "a peer EOF before the drain close is still clean")
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.2)
        XCTAssertTrue(quiet)
    }

    /// A host `close()` is not a peer EOF: it may have dropped queued inbound
    /// messages, so it must never report a clean drain end.
    func testHostCloseBeforeDrainCloseIsNotClean() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "d", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        let socket = DrainMultiFrameSocket(message: message)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let run = Task { await server.run() }
        addTeardownBlock { run.cancel() }
        let helloDeadline = Date().addingTimeInterval(1)
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= helloDeadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }
        await server.close()
        let deadline = Date().addingTimeInterval(1)
        var finished = await server.hasFinishedReceiveLoop()
        while !finished {
            if Date() >= deadline {
                XCTFail("the host close did not end the receive loop")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            finished = await server.hasFinishedReceiveLoop()
        }
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .closed)
        let clean = await server.hasCleanDrainEnd()
        XCTAssertFalse(clean, "a host close is not a peer EOF")
    }

    /// A non-quiescent close is terminal for the whole drain. The Host retries
    /// escalation after the first failed attempt, and that retry must not see an
    /// emptied connection table and pack an overlay after inbound writes may
    /// already have been lost.
    func testNonQuiescentEscalationIsTerminalAcrossHostRetry() async throws {
        let hello = try CanonicalJSON.encode(Self.workerHello(
            bootID: String(repeating: "a", count: 32)))
        let message = try FrameEncoder.encode(type: .hello, seq: 1, payload: hello)
        // The connection is still receiving when the drain starts. The engine's
        // termination then ends it while the transport still hides undelivered
        // bytes, so the receive loop finishes but the drain must report a
        // non-clean, non-quiescent end.
        let socket = DrainMultiFrameSocket(message: message,
                                           eofAfterMessages: false,
                                           pendingInboundData: true)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: DrainFrameGateHandler(
                                       workspaceLog: DrainAckingWorkspaceLog()))
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let deadline = Date().addingTimeInterval(1)
        // As above, do not mistake "never started" for "already receiving".
        var framesIn = await server.currentMetrics().framesIn
        while framesIn == 0 {
            if Date() >= deadline {
                XCTFail("the server never read the HELLO")
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            framesIn = await server.currentMetrics().framesIn
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-drain-retry-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x24, count: 16))
        let engine = DrainTerminatingEngine {
            await socket.closeChannel(code: 1000)
        }
        let first = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: DrainUnusedTransport(),
            maximumTerminations: 1)
        let firstOutcome = await first.terminateAndReboot(
            sessionIDs: ["session-retry"],
            deadline: Date().addingTimeInterval(1),
            hasTerminalTurn: { false })

        XCTAssertFalse(firstOutcome.retryable,
                       "a non-quiescent close must end the whole drain")
        XCTAssertFalse(firstOutcome.settled)
        XCTAssertEqual(firstOutcome.attempts.first?.packedOverlay, false)
        let retained = await coordinator.currentConnection()
        XCTAssertNotNil(retained,
                        "the failed close must not retire the old incarnation")
        XCTAssertEqual(engine.counts().terminate, 1)
        XCTAssertEqual(engine.counts().restart, 0)

        // Simulate the Host retry the old code allowed. It must still not pack
        // or boot now that the connection table was not cleared.
        let second = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: DrainUnusedTransport(),
            maximumTerminations: 1)
        let secondOutcome = await second.terminateAndReboot(
            sessionIDs: ["session-retry"],
            deadline: Date().addingTimeInterval(1),
            hasTerminalTurn: { false })

        XCTAssertFalse(secondOutcome.retryable)
        XCTAssertFalse(secondOutcome.settled)
        XCTAssertEqual(secondOutcome.attempts.first?.packedOverlay, false,
                       "the retry must not pack after a non-quiescent close")
        XCTAssertEqual(secondOutcome.attempts.first?.freshWorkerReady, false)
        let counts = engine.counts()
        XCTAssertEqual(counts.terminate, 2)
        XCTAssertEqual(counts.restart, 0,
                       "the retry must not boot a replacement on a non-quiescent old connection")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains {
            $0.hasPrefix("overlay-") && $0.hasSuffix(".tar")
        }, "neither attempt may execute the overlay pack")
    }

    /// The teardown LIFECYCLE send is best effort. A half-dead socket that
    /// never completes the send must not hold the caller past its budget.
    func testDrainLifecycleSendIsAbandonedAtDeadline() async {
        let socket = DrainBlockingSendSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let started = Date()
        let result = await phoneDSHResultWithinDeadline(0.15) {
            try await connection.sendLifecycle(
                LifecyclePayload(state: .stop, budget: 0,
                                 admission: .closed, reason: "drain"))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(result, "a stuck LIFECYCLE send must not block the drain")
        XCTAssertGreaterThanOrEqual(elapsed, 0.1)
        XCTAssertLessThan(elapsed, 1.0,
                          "the send must use its explicit budget, not the drain window")
        await server.close()
    }

    /// A stale Worker reconnect carries the old boot id and must never satisfy
    /// the replacement HELLO wait. Once the engine reports the replacement boot
    /// id, a different new incarnation cannot satisfy it either, and the
    /// session epoch/fence are checked as part of the same barrier.
    func testReplacementHelloMustMatchRetiredBootEpochAndFence() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let oldHello = Self.workerHello(bootID: String(repeating: "1", count: 32))
        let oldConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(oldConnection)
        try await coordinator.helloReceived(connection: oldConnection,
                                            payload: oldHello)
        let oldCount = await coordinator.helloCountValue()

        await coordinator.prepareForReboot(retiringCurrentIncarnation: true)

        // A reconnect of the stopped incarnation is rejected before it can be
        // recorded, so it cannot become current or satisfy the HELLO wait.
        let staleConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(staleConnection)
        let currentBeforeHello = await coordinator.currentConnection()
        XCTAssertNil(currentBeforeHello,
                     "an unvalidated reconnect must not receive host RPCs")
        do {
            try await coordinator.helloReceived(connection: staleConnection,
                                                payload: oldHello)
            XCTFail("the retired Worker boot must be rejected")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }

        // A different new incarnation that connected before the restart report
        // arrived is not the reported replacement and is removed.
        let expectedBootID = String(repeating: "2", count: 32)
        let wrongBootID = String(repeating: "3", count: 32)
        let wrongConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(wrongConnection)
        try await coordinator.helloReceived(
            connection: wrongConnection,
            payload: Self.workerHello(bootID: wrongBootID))
        await coordinator.expectReplacementWorker(bootID: expectedBootID)
        do {
            _ = try await coordinator.waitForHello(after: oldCount,
                                                   expecting: expectedBootID,
                                                   timeout: 0.1)
            XCTFail("a different boot id must not satisfy the replacement wait")
        } catch {
            XCTAssertTrue(error is PhoneDSHError)
        }

        // The expected boot id still has to echo the old session epoch and a
        // fence that is not older than the replaced incarnation.
        let wrongEpochConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(wrongEpochConnection)
        do {
            try await coordinator.helloReceived(
                connection: wrongEpochConnection,
                payload: Self.workerHello(bootID: expectedBootID,
                                          sessionEpoch: oldHello.sessionEpoch + 1))
            XCTFail("a different session epoch must be rejected")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }

        let wrongFenceConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(wrongFenceConnection)
        do {
            try await coordinator.helloReceived(
                connection: wrongFenceConnection,
                payload: Self.workerHello(
                    bootID: expectedBootID,
                    fence: Fence(owner: oldHello.fence.owner,
                                 generation: oldHello.fence.generation - 1,
                                 walSeq: 0)))
            XCTFail("an older fence generation must be rejected")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }

        let replacement = Self.connection(coordinator: coordinator)
        await coordinator.register(replacement)
        try await coordinator.helloReceived(
            connection: replacement,
            payload: Self.workerHello(bootID: expectedBootID))
        let hello = try await coordinator.waitForHello(after: oldCount,
                                                       expecting: expectedBootID,
                                                       timeout: 0.5)
        XCTAssertEqual(hello.hello.bootID, expectedBootID)
        XCTAssertEqual(hello.hello.sessionEpoch, oldHello.sessionEpoch)
        XCTAssertEqual(hello.connection.id, replacement.id)
    }

    private static func connection(
        coordinator: PhoneDSHChannelCoordinator
    ) -> PhoneDSHConnection {
        let server = ChannelServer(socket: DrainQuiesceSocket(),
                                   state: ChannelHostState())
        return PhoneDSHConnection(id: UUID(), server: server,
                                  coordinator: coordinator)
    }

    private static func workerHello(
        bootID: String,
        sessionEpoch: UInt64 = 1,
        fence: Fence = Fence(owner: "phone", generation: 3, walSeq: 0)
    ) -> HelloPayload {
        HelloPayload(role: .worker,
                     bootID: bootID,
                     sessionEpoch: sessionEpoch,
                     fence: fence,
                     caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
                     lastMseq: 0)
    }

    private static func vfsFrame(mseq: UInt64, seq: UInt64,
                                 path: String) throws -> Data {
        let body = VfsMutationBody(op: .write, mode: 0o644,
                                   mflags: [.entryChanged],
                                   path: path, data: Data("drain".utf8))
        return try FrameEncoder.encode(
            type: .vfsMutation, seq: seq,
            payload: try VfsMutationPayload.encode(mseq: mseq, body: body))
    }

    private static func journalFrame(jseq: UInt64, seq: UInt64,
                                     sessionID: String) throws -> Data {
        let body = JournalBody(jseq: jseq, sessionID: sessionID,
                               record: Data("{\"type\":\"drain\"}".utf8))
        return try FrameEncoder.encode(type: .journal, seq: seq,
                                       payload: try body.encoded())
    }
}

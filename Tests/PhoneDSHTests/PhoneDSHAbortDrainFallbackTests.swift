// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — drain compatibility and connection-history regressions.
//
// The real drain path stops a Worker that implements the two-phase protocol.
// Engines that only expose the combined `restart` lever still have to reach
// the overlay repack and the replacement boot, but only after the old
// connection reaches a clean peer EOF. A connection left behind by an earlier
// incarnation is history only when its end was clean; a host/idle/transport
// end must fail the drain rather than let it pack. These tests pin both
// behaviours without WebKit.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHLoopback
import PhoneDSHWire

/// A socket whose receive loop stays blocked until either a host close or a
/// simulated peer disconnect ends it. The tests use the distinction to pin a
/// clean historical EOF against a host close that may have dropped queued
/// inbound messages.
private actor BlockingDrainSocket: ChannelSocket {
    private var closed = false
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    func receiveChannelMessage() async throws -> Data? {
        if closed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func sendChannelMessage(_ data: Data) async throws {}

    func closeChannel(code: Int) async {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    /// Simulates the old page's WebSocket disappearing because a legacy
    /// combined-restart engine tore that page down. Unlike ``closeChannel``,
    /// this is a peer end, not a host teardown, so the receive loop records a
    /// clean EOF rather than a host `.closed` verdict.
    func peerDisconnected() async {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

private enum LegacyCombinedRestartError: Error {
    case oldReceiveLoopDidNotStop
}

private enum LegacyStopMode {
    /// The old page really went away: its WebSocket reaches a peer EOF.
    case peerEOF
    /// The host only force-closes the connection, as a buggy/undrained legacy
    /// engine would; the old page may still have accepted inbound writes.
    case hostClose
}

/// An engine with only the original combined restart lever. Its first restart
/// is the stop phase (closing the old connection), and the second is the boot
/// of the replacement that must mount the freshly packed overlay.
private final class LegacyCombinedRestartEngine: WebEngineControlling,
                                                @unchecked Sendable {
    private let server: ChannelServer
    private let socket: BlockingDrainSocket
    private let stopMode: LegacyStopMode
    private let lock = NSLock()
    private var restarts = 0

    init(server: ChannelServer, socket: BlockingDrainSocket,
         stopMode: LegacyStopMode = .peerEOF) {
        self.server = server
        self.socket = socket
        self.stopMode = stopMode
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {}

    func restart() async throws {
        lock.lock()
        restarts += 1
        let count = restarts
        lock.unlock()
        if count == 1 {
            // A real engine's navigation destroys the old Worker and its
            // ordered-channel WebSocket reaches a peer EOF. The host-close
            // fixture models a legacy engine that only force-closes the socket,
            // which cannot prove that queued inbound writes were dispatched.
            switch stopMode {
            case .peerEOF:
                await socket.peerDisconnected()
            case .hostClose:
                await server.close()
            }
            let deadline = Date().addingTimeInterval(1)
            while !(await server.hasFinishedReceiveLoop()) {
                guard Date() < deadline else {
                    throw LegacyCombinedRestartError.oldReceiveLoopDidNotStop
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    func restartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return restarts
    }
}

/// A combined-restart engine that also implements the restart-report lever.
/// The fallback still uses two restarts (stop, then replacement boot), but the
/// second report gives the coordinator a post-pack boot id to bind to the
/// replacement HELLO. Without that proof the fallback must fail loud.
private final class ReportedLegacyCombinedRestartEngine: WebEngineControlling,
                                                           WebEngineRestartRequesting,
                                                           @unchecked Sendable {
    private let server: ChannelServer
    private let socket: BlockingDrainSocket
    private let coordinator: PhoneDSHChannelCoordinator
    private let interimBootID: String
    private let replacementConnection: PhoneDSHConnection
    private let replacementHello: HelloPayload
    private let lock = NSLock()
    private var restarts = 0

    init(server: ChannelServer, socket: BlockingDrainSocket,
         coordinator: PhoneDSHChannelCoordinator,
         interimBootID: String,
         replacementConnection: PhoneDSHConnection,
         replacementHello: HelloPayload) {
        self.server = server
        self.socket = socket
        self.coordinator = coordinator
        self.interimBootID = interimBootID
        self.replacementConnection = replacementConnection
        self.replacementHello = replacementHello
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}
    func bootWorker(_ configuration: WebEngineConfiguration) async throws {}

    func restart() async throws {
        _ = try await restart(reason: .webContentTerminated)
    }

    func restart(reason: WebEngineRestartReason) async throws
        -> WebEngineRestartReport {
        lock.lock()
        restarts += 1
        let count = restarts
        lock.unlock()
        if count == 1 {
            // The stop phase destroys the old page and may boot an interim
            // page. It gets a distinct boot id, but its HELLO is irrelevant:
            // the second restart is the replacement this attempt adopts.
            await socket.peerDisconnected()
            let deadline = Date().addingTimeInterval(1)
            while !(await server.hasFinishedReceiveLoop()) {
                guard Date() < deadline else {
                    throw LegacyCombinedRestartError.oldReceiveLoopDidNotStop
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return WebEngineRestartReport(reason: reason,
                                          bootID: interimBootID,
                                          duration: .zero)
        }
        await coordinator.register(replacementConnection)
        try await coordinator.helloReceived(connection: replacementConnection,
                                            payload: replacementHello)
        return WebEngineRestartReport(reason: reason,
                                      bootID: replacementHello.bootID,
                                      duration: .zero)
    }

    func restartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return restarts
    }
}

/// A legacy engine whose first combined restart also opens the interim page
/// before the overlay pack. The interim page is a real, running
/// ``ChannelServer`` whose HELLO is accepted before `prepareForReboot` clears
/// the table. Closing it must not wait for a peer EOF (the second restart is
/// what destroys the page) but it must be closed and retired before the
/// replacement boots; its late HELLO is then refused by connection id.
private final class InterimLegacyRestartEngine: WebEngineControlling,
                                                WebEngineRestartRequesting,
                                                @unchecked Sendable {
    private let server: ChannelServer
    private let socket: BlockingDrainSocket
    private let coordinator: PhoneDSHChannelCoordinator
    private let interimConnection: PhoneDSHConnection
    private let interimHello: HelloPayload
    private let replacementConnection: PhoneDSHConnection
    private let replacementHello: HelloPayload
    private let lock = NSLock()
    private var restarts = 0
    private var rejectedInterimHello = false
    private var interimClosedBeforeReplacement = false
    private var interimHelloAcceptedBeforePrepare = false

    init(server: ChannelServer, socket: BlockingDrainSocket,
         coordinator: PhoneDSHChannelCoordinator,
         interimConnection: PhoneDSHConnection,
         interimHello: HelloPayload,
         replacementConnection: PhoneDSHConnection,
         replacementHello: HelloPayload) {
        self.server = server
        self.socket = socket
        self.coordinator = coordinator
        self.interimConnection = interimConnection
        self.interimHello = interimHello
        self.replacementConnection = replacementConnection
        self.replacementHello = replacementHello
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}
    func bootWorker(_ configuration: WebEngineConfiguration) async throws {}

    func restart() async throws {
        _ = try await restart(reason: .webContentTerminated)
    }

    func restart(reason: WebEngineRestartReason) async throws
        -> WebEngineRestartReport {
        lock.lock()
        restarts += 1
        let count = restarts
        lock.unlock()
        if count == 1 {
            // The stop phase destroys the old page and boots the interim page.
            // Registering its connection here is what a real WebSocket upgrade
            // does before its HELLO; the HELLO itself is delayed.
            await socket.peerDisconnected()
            let deadline = Date().addingTimeInterval(1)
            while !(await server.hasFinishedReceiveLoop()) {
                guard Date() < deadline else {
                    throw LegacyCombinedRestartError.oldReceiveLoopDidNotStop
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await coordinator.register(interimConnection)
            // A real interim page completes its HELLO before the overlay is
            // packed. Pre-fix, prepareForReboot cleared the table without
            // closing this accepted socket, so it could keep dispatching
            // VFS/JOURNAL frames behind the replacement's overlay.
            try await coordinator.helloReceived(connection: interimConnection,
                                                payload: interimHello)
            lock.lock()
            interimHelloAcceptedBeforePrepare = true
            lock.unlock()
            return WebEngineRestartReport(reason: reason,
                                          bootID: interimHello.bootID,
                                          duration: .zero)
        }
        if count == 2 {
            // The interim socket was live and never reached a peer EOF. The
            // drain must have closed it rather than spend its whole budget
            // waiting; give the receive loop a bounded moment to observe that
            // close, then record it before the replacement is registered.
            let closedDeadline = Date().addingTimeInterval(1)
            while !(await interimConnection.server.hasFinishedReceiveLoop()) {
                if Date() >= closedDeadline { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let closed = await interimConnection.server.hasFinishedReceiveLoop()
            lock.lock()
            interimClosedBeforeReplacement = closed
            lock.unlock()
            // A late HELLO on the retired interim connection must be refused
            // instead of becoming the replacement.
            do {
                try await coordinator.helloReceived(connection: interimConnection,
                                                    payload: interimHello)
            } catch {
                lock.lock()
                rejectedInterimHello = true
                lock.unlock()
            }
            await coordinator.register(replacementConnection)
            try await coordinator.helloReceived(connection: replacementConnection,
                                                payload: replacementHello)
        }
        return WebEngineRestartReport(reason: reason,
                                      bootID: replacementHello.bootID,
                                      duration: .zero)
    }

    func restartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return restarts
    }

    func interimHelloWasRejected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedInterimHello
    }

    func interimWasAcceptedBeforePrepare() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interimHelloAcceptedBeforePrepare
    }

    func interimWasClosedBeforeReplacement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interimClosedBeforeReplacement
    }
}

/// The compatibility path never reaches the transport because no HELLO is
/// installed; it only has to prove the stop/drain/pack/boot sequence runs.
private final class UnusedLegacyTransport: DSHRemoteTransport, @unchecked Sendable {
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        throw PhoneDSHError.channelUnavailable
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw PhoneDSHError.channelUnavailable
    }
}

final class PhoneDSHAbortDrainFallbackTests: XCTestCase {
    /// A connection from an earlier incarnation that ended in a clean peer EOF
    /// before this drain and still sits in the coordinator is history. Only
    /// connections that were receiving when the drain started (or whose end
    /// was not clean) need to participate.
    func testHistoricalConnectionDoesNotFailDrainQuiescence() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let socket = BlockingDrainSocket()
        let historical = ChannelServer(socket: socket,
                                       state: ChannelHostState())
        try await historical.installHandler(DefaultChannelHandling(outbound: historical))
        // The peer is already gone when the receive loop starts, so the server
        // records `.cleanEOF` after dispatching every delivered frame.
        await socket.peerDisconnected()
        await historical.run()
        let finished = await historical.hasFinishedReceiveLoop()
        XCTAssertTrue(finished)
        let reason = await historical.drainEndReason()
        XCTAssertEqual(reason, .cleanEOF)
        let historicalConnection = PhoneDSHConnection(id: UUID(), server: historical,
                                                      coordinator: coordinator)
        await coordinator.register(historicalConnection)

        let drainIDs = await coordinator.connectionIDsToDrain()
        XCTAssertTrue(drainIDs.isEmpty,
                      "a cleanly ended connection is not a drain participant")
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.3, requiringCleanEnd: drainIDs)
        XCTAssertTrue(quiet,
                      "the clean historical connection must not fail the drain")
        let current = await coordinator.currentConnection()
        XCTAssertNil(current, "the historical connection is forgotten after the drain")
    }

    /// A connection that already stopped but ended in a host close is *not*
    /// history: its queue may have been discarded. It must stay a drain
    /// participant and make the close fail loud, even if the caller captured an
    /// empty set before the drain.
    func testNonCleanFinishedConnectionIsNotHistorical() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the server never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await server.close()
        let finishedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasFinishedReceiveLoop()) {
            guard Date() < finishedDeadline else {
                XCTFail("the host close did not end the receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .closed)

        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let drainIDs = await coordinator.connectionIDsToDrain()
        XCTAssertEqual(drainIDs, [connection.id],
                       "a non-clean finished connection still carries drain risk")
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.3, requiringCleanEnd: [])
        XCTAssertFalse(quiet,
                       "an empty captured set must not accept a non-clean historical end")
        let current = await coordinator.currentConnection()
        XCTAssertNotNil(current, "a failed close must retain the risky connection")
    }

    /// The production two-phase path arms its barrier before `terminateWorker()`
    /// and then takes a fresh snapshot. A connection that registered during the
    /// terminate window is not in the pre-terminate set, but it is still a live
    /// old socket: it must reach a clean EOF instead of inheriting the legacy
    /// interim-page exemption.
    func testUncapturedConnectionStillRequiresCleanEndInProduction() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the connection never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)

        // The empty capture represents a socket that appeared after the
        // pre-terminate snapshot. Without the production flag it would be
        // treated as the legacy interim page and a hard close would pass.
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.2,
            requiringCleanEnd: [],
            requiringCleanEndForUncaptured: true)
        XCTAssertFalse(quiet,
                       "an uncaptured old socket may not be silently closed")
        let current = await coordinator.currentConnection()
        XCTAssertNotNil(current,
                        "a non-quiescent close must retain the risky connection")
    }

    /// The combined-restart fallback boots its own interim page after the stop
    /// phase. That page is not a captured old connection and it never produces
    /// a peer EOF (the second restart destroys it), so the drain must close it
    /// immediately instead of spending the whole remaining window waiting.
    /// Before that fix this call blocked for the full timeout and returned
    /// non-quiescent, leaving no budget to pack and boot the replacement.
    func testUncapturedOptionalInterimIsClosedWithoutWaitingForEOF() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the interim server never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)

        let started = Date()
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 1,
            requiringCleanEnd: [])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(quiet,
                      "an optional interim that received no host traffic must close cleanly")
        XCTAssertLessThan(elapsed, 0.5,
                          "the interim page must not consume the full drain window")
        let finished = await server.hasFinishedReceiveLoop()
        XCTAssertTrue(finished, "the interim socket must be closed before the pack")
        let current = await coordinator.currentConnection()
        XCTAssertNil(current)
    }

    /// A legacy engine without the restart-report lever can stop the old page,
    /// drain it and repack the overlay, but it cannot prove the identity of a
    /// second page. The fallback must fail loud instead of booting a page whose
    /// HELLO could only be accepted with `expecting: nil`.
    func testCombinedRestartWithoutBootReportFailsBeforeAdoptingReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-legacy-restart-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x5a, count: 16))

        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)

        let engine = LegacyCombinedRestartEngine(server: server, socket: socket)
        let escalator = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: UnusedLegacyTransport(),
            maximumTerminations: 1)

        let outcome = await escalator.terminateAndReboot(
            sessionIDs: ["session-legacy"],
            deadline: Date().addingTimeInterval(2),
            hasTerminalTurn: { false })

        XCTAssertTrue(outcome.nonRetryable,
                      "an unverifiable replacement must stop the drain")
        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertTrue(attempt.workerTerminated,
                      "a successful combined restart is the stop proof")
        XCTAssertTrue(attempt.packedOverlay,
                      "the overlay is repacked only after the old Worker stopped")
        XCTAssertFalse(attempt.freshWorkerReady)
        XCTAssertEqual(engine.restartCount(), 1,
                       "the fallback must not boot a page it cannot identify")
        XCTAssertFalse(outcome.settled)
        XCTAssertTrue(outcome.lastError?.contains("boot id") == true,
                      "the failure must name the missing boot identity")
    }

    /// With a restart report, the legacy stop/pack/second-boot sequence can
    /// still run: the second report binds the replacement boot id and only the
    /// matching HELLO becomes current.
    func testReportedCombinedRestartStopsDrainsPacksAndBoots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-legacy-reported-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x5c, count: 16))

        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)

        let replacementConnection = PhoneDSHConnection(
            id: UUID(),
            server: ChannelServer(socket: BlockingDrainSocket(),
                                  state: ChannelHostState()),
            coordinator: coordinator)
        let replacementHello = Self.workerHello(
            bootID: String(repeating: "d", count: 32))
        let engine = ReportedLegacyCombinedRestartEngine(
            server: server,
            socket: socket,
            coordinator: coordinator,
            interimBootID: String(repeating: "c", count: 32),
            replacementConnection: replacementConnection,
            replacementHello: replacementHello)
        let escalator = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: UnusedLegacyTransport(),
            maximumTerminations: 1)

        let outcome = await escalator.terminateAndReboot(
            sessionIDs: ["session-legacy-reported"],
            deadline: Date().addingTimeInterval(2),
            hasTerminalTurn: { false })

        XCTAssertFalse(outcome.nonRetryable)
        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertTrue(attempt.workerTerminated)
        XCTAssertTrue(attempt.packedOverlay)
        XCTAssertTrue(attempt.freshWorkerReady,
                      "the reported replacement boot id must satisfy the HELLO wait")
        XCTAssertEqual(engine.restartCount(), 2,
                       "the combined lever stops the old Worker and then boots the replacement")
        XCTAssertFalse(outcome.settled,
                       "without a terminal journal this drain still fails loud")
        let current = await coordinator.currentConnection()
        XCTAssertEqual(current?.id, replacementConnection.id)
    }

    /// A combined restart that only manages a host close (or any non-clean end)
    /// for the old connection is not proof that the old Worker stopped. The
    /// fallback must fail loud before packing or booting the replacement.
    func testCombinedRestartDoesNotPackWhenOldConnectionOnlyHostCloses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-legacy-host-close-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x5b, count: 16))

        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)

        let engine = LegacyCombinedRestartEngine(server: server, socket: socket,
                                                 stopMode: .hostClose)
        let escalator = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: UnusedLegacyTransport(),
            maximumTerminations: 1)

        let outcome = await escalator.terminateAndReboot(
            sessionIDs: ["session-legacy"],
            deadline: Date().addingTimeInterval(2),
            hasTerminalTurn: { false })

        XCTAssertTrue(outcome.nonRetryable,
                      "a non-clean old connection must terminate the whole drain")
        XCTAssertFalse(outcome.settled)
        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertTrue(attempt.workerTerminated)
        XCTAssertFalse(attempt.packedOverlay,
                       "a host close cannot prove the old Worker's inbound writes were drained")
        XCTAssertFalse(attempt.freshWorkerReady)
        XCTAssertEqual(engine.restartCount(), 1,
                       "the fallback must not boot a replacement after a failed quiesce")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(entries.contains {
            $0.hasPrefix("overlay-") && $0.hasSuffix(".tar")
        }, "the failed drain must not pack an overlay")
    }

    /// A finished `.closed` connection stays a strict drain participant even
    /// when it names a retired boot whose accepted mseq is below the WAL tail.
    /// `acceptedMseq` does not cover frames still queued in the socket or
    /// decoder, so age/boot id is not proof that no inbound write was lost.
    func testRetiredNonCleanConnectionBelowWALTailStaysStrict() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())

        let socket = BlockingDrainSocket()
        let historicalServer = ChannelServer(socket: socket,
                                             state: ChannelHostState())
        try await historicalServer.installHandler(
            DefaultChannelHandling(outbound: historicalServer))
        let historicalRun = Task { await historicalServer.run() }
        addTeardownBlock {
            await historicalServer.close()
            historicalRun.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await historicalServer.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the historical server never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await historicalServer.close()
        let finishedDeadline = Date().addingTimeInterval(1)
        while !(await historicalServer.hasFinishedReceiveLoop()) {
            guard Date() < finishedDeadline else {
                XCTFail("the historical host close did not end its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let historicalReason = await historicalServer.drainEndReason()
        XCTAssertEqual(historicalReason, .closed)

        let historicalBootID = String(repeating: "6", count: 32)
        let historical = PhoneDSHConnection(id: UUID(),
                                            server: historicalServer,
                                            coordinator: coordinator)
        await coordinator.register(historical)
        try await coordinator.helloReceived(
            connection: historical,
            payload: Self.workerHello(bootID: historicalBootID))

        // A newer incarnation owns the durable WAL tail (accepted mseq 4), but
        // the old socket ended `.closed`: it may still have had a frame in the
        // socket/decoder that never advanced acceptedMseq.
        let currentBootID = String(repeating: "7", count: 32)
        let currentServer = ChannelServer(socket: BlockingDrainSocket(),
                                          state: ChannelHostState())
        let current = PhoneDSHConnection(id: UUID(), server: currentServer,
                                         coordinator: coordinator)
        await coordinator.register(current)
        try await coordinator.helloReceived(
            connection: current,
            payload: Self.workerHello(bootID: currentBootID))

        let drainIDs = await coordinator.connectionIDsToDrain()
        XCTAssertTrue(drainIDs.contains(historical.id),
                      "a retired non-clean socket is not history without a clean EOF")
        XCTAssertTrue(drainIDs.contains(current.id),
                      "the current incarnation still participates in the drain")
        let quiet = await coordinator.closeConnectionsAndWaitForInboundWritesToQuiesce(
            timeout: 0.3, requiringCleanEnd: drainIDs)
        XCTAssertFalse(quiet,
                       "the stale retired verdict must fail the new drain")
        let retained = await coordinator.currentConnection()
        XCTAssertEqual(retained?.id, current.id,
                       "a failed close keeps the risky connections")
    }

    /// An interim page can open its socket after `prepareForReboot` cleared the
    /// table but before the replacement restart. The fallback captures those
    /// connection ids and retires them after the restart, so a late HELLO on
    /// that connection is still refused.
    func testConnectionOpenedAfterPrepareIsRetiredBeforeReplacementWait() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let oldConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(oldConnection)
        try await coordinator.helloReceived(
            connection: oldConnection,
            payload: Self.workerHello(bootID: String(repeating: "a", count: 32)))
        await coordinator.prepareForReboot(retiringCurrentIncarnation: true)

        // This is the race the fallback's pre-restart snapshot covers: the
        // interim connection appears after the table clear.
        let lateInterim = Self.connection(coordinator: coordinator)
        await coordinator.register(lateInterim)
        let preRestart = await coordinator.connectionIDs()
        XCTAssertEqual(preRestart, [lateInterim.id])
        await coordinator.retireReplacementCandidates(preRestart)

        do {
            try await coordinator.helloReceived(
                connection: lateInterim,
                payload: Self.workerHello(bootID: String(repeating: "b", count: 32)))
            XCTFail("a connection opened before the replacement restart must be retired")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }
        let current = await coordinator.currentConnection()
        XCTAssertNil(current)
    }

    /// Clearing the coordinator table is not enough: a connection whose HELLO
    /// was already accepted must have its socket closed by `prepareForReboot`
    /// itself, before the caller packs the overlay or boots a replacement.
    func testPrepareForRebootClosesLivePreExistingConnection() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the connection never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let connection = PhoneDSHConnection(id: UUID(), server: server,
                                            coordinator: coordinator)
        await coordinator.register(connection)
        let hello = Self.workerHello(bootID: String(repeating: "5", count: 32))
        try await coordinator.helloReceived(connection: connection, payload: hello)

        let closed = await coordinator.prepareForReboot(
            retiringCurrentIncarnation: true)
        XCTAssertGreaterThanOrEqual(closed, 1,
                                    "prepareForReboot must close the cleared connection")
        let finishedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasFinishedReceiveLoop()) {
            guard Date() < finishedDeadline else { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finished = await server.hasFinishedReceiveLoop()
        XCTAssertTrue(finished,
                      "the pre-existing socket must stop before the overlay pack")
        let reason = await server.drainEndReason()
        XCTAssertEqual(reason, .closed)
        do {
            try await coordinator.helloReceived(connection: connection,
                                                payload: hello)
            XCTFail("a connection cleared by prepareForReboot must be retired")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }
        let current = await coordinator.currentConnection()
        XCTAssertNil(current)
    }

    /// A live interim page can open its WebSocket after `prepareForReboot`
    /// cleared the table but before the replacement restart. The fallback
    /// snapshots those ids immediately before the restart and retires them:
    /// the socket is closed and a late HELLO is refused by id instead of
    /// becoming the replacement that receives resume/cancel.
    func testLiveConnectionOpenedAfterPrepareIsClosedBeforeReplacementWait() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let oldConnection = Self.connection(coordinator: coordinator)
        await coordinator.register(oldConnection)
        try await coordinator.helloReceived(
            connection: oldConnection,
            payload: Self.workerHello(bootID: String(repeating: "a", count: 32)))
        await coordinator.prepareForReboot(retiringCurrentIncarnation: true)

        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }
        let startedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasStartedReceiveLoop()) {
            guard Date() < startedDeadline else {
                XCTFail("the interim server never entered its receive loop")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let lateInterim = PhoneDSHConnection(id: UUID(), server: server,
                                             coordinator: coordinator)
        await coordinator.register(lateInterim)
        let interimHello = Self.workerHello(
            bootID: String(repeating: "b", count: 32))
        try await coordinator.helloReceived(connection: lateInterim,
                                            payload: interimHello)
        let preRestart = await coordinator.connectionIDs()
        XCTAssertEqual(preRestart, [lateInterim.id])
        await coordinator.retireReplacementCandidates(preRestart)

        let closedDeadline = Date().addingTimeInterval(1)
        while !(await server.hasFinishedReceiveLoop()) {
            guard Date() < closedDeadline else { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finished = await server.hasFinishedReceiveLoop()
        XCTAssertTrue(finished,
                      "a live connection opened after prepare must be closed by retire")
        do {
            try await coordinator.helloReceived(connection: lateInterim,
                                                payload: interimHello)
            XCTFail("a live interim connection must not be adopted after retirement")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }
        let current = await coordinator.currentConnection()
        XCTAssertNil(current)
    }

    /// The first combined restart boots a live interim page whose HELLO is
    /// accepted before `prepareForReboot`. Its socket never reaches a peer EOF,
    /// so the fallback must close it without burning the drain window; a later
    /// HELLO on the retired connection must not be accepted as the replacement
    /// that receives resume/cancel.
    func testLegacyInterimHelloAfterPrepareCannotSatisfyReplacementWait() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-legacy-interim-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x6a, count: 16))

        let socket = BlockingDrainSocket()
        let server = ChannelServer(socket: socket, state: ChannelHostState())
        try await server.installHandler(DefaultChannelHandling(outbound: server))
        let run = Task { await server.run() }
        addTeardownBlock {
            await server.close()
            run.cancel()
        }

        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let oldConnection = PhoneDSHConnection(id: UUID(), server: server,
                                               coordinator: coordinator)
        await coordinator.register(oldConnection)

        // The interim page is live: its receive loop stays blocked on an open
        // socket and never produces a peer EOF before the second restart. The
        // fallback must close it without spending the drain window waiting.
        let interimSocket = BlockingDrainSocket()
        let interimServer = ChannelServer(socket: interimSocket,
                                          state: ChannelHostState())
        try await interimServer.installHandler(
            DefaultChannelHandling(outbound: interimServer))
        let interimRun = Task { await interimServer.run() }
        addTeardownBlock {
            await interimServer.close()
            interimRun.cancel()
        }
        let interimConnection = PhoneDSHConnection(
            id: UUID(),
            server: interimServer,
            coordinator: coordinator)
        let interimHello = Self.workerHello(
            bootID: String(repeating: "8", count: 32))
        let replacementConnection = PhoneDSHConnection(
            id: UUID(),
            server: ChannelServer(socket: BlockingDrainSocket(),
                                  state: ChannelHostState()),
            coordinator: coordinator)
        let replacementHello = Self.workerHello(
            bootID: String(repeating: "9", count: 32))
        let engine = InterimLegacyRestartEngine(
            server: server,
            socket: socket,
            coordinator: coordinator,
            interimConnection: interimConnection,
            interimHello: interimHello,
            replacementConnection: replacementConnection,
            replacementHello: replacementHello)
        let escalator = PhoneDSHAbortEscalator(
            bootID: String(repeating: "f", count: 32),
            engine: engine,
            log: log,
            coordinator: coordinator,
            transport: UnusedLegacyTransport(),
            maximumTerminations: 1)

        let outcome = await escalator.terminateAndReboot(
            sessionIDs: ["session-legacy-interim"],
            deadline: Date().addingTimeInterval(2),
            hasTerminalTurn: { false })

        XCTAssertTrue(engine.interimWasAcceptedBeforePrepare(),
                      "the fixture must model an accepted interim HELLO before prepare")
        XCTAssertTrue(engine.interimWasClosedBeforeReplacement(),
                      "the live interim socket must be closed before the replacement boots")
        XCTAssertTrue(engine.interimHelloWasRejected(),
                      "a late interim HELLO must not be accepted after prepareForReboot")
        XCTAssertFalse(outcome.nonRetryable)
        XCTAssertEqual(engine.restartCount(), 2)
        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertTrue(attempt.packedOverlay)
        XCTAssertTrue(attempt.freshWorkerReady,
                      "only the actual replacement HELLO may satisfy the wait")
        XCTAssertFalse(outcome.settled,
                       "without a terminal journal this drain still fails loud")
        let current = await coordinator.currentConnection()
        XCTAssertEqual(current?.id, replacementConnection.id,
                       "the replacement connection, not the interim page, owns the channel")
    }

    private static func connection(
        coordinator: PhoneDSHChannelCoordinator
    ) -> PhoneDSHConnection {
        PhoneDSHConnection(
            id: UUID(),
            server: ChannelServer(socket: BlockingDrainSocket(),
                                  state: ChannelHostState()),
            coordinator: coordinator)
    }

    private static func workerHello(bootID: String) -> HelloPayload {
        HelloPayload(role: .worker,
                     bootID: bootID,
                     sessionEpoch: 1,
                     fence: Fence(owner: "phone", generation: 3, walSeq: 0),
                     caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"])
    }
}

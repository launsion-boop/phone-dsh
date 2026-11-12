// SPDX-License-Identifier: MIT
// budgets.md §7: the host produces `fsync_calls_per_turn` and
// `bytes_written_per_turn` at its real turn boundary.
//
// The regression drives the real facade over the loopback origin: a scripted
// Worker answers `session/create`/`session/prompt`, accepts real `0x10
// VFS_MUT` frames and serves the remote.mux follow stream. A user turn is
// opened by the real `harness.send(.prompt)` path, the turn does real
// persistence work (a WAL append plus the D18 epoch close the periodic tick
// performs while the turn is open), and the turn closes on the terminal
// `turn/end` event. Only then may `PhoneDSHHost.lastTurnPersistenceIO()`
// report the settled window.
//
// The second half proves the next turn starts a fresh window: the second turn
// performs no persistence work, so its settled counters must be zero.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLog
@testable import PhoneDSH

final class PhoneDSHTurnPersistenceIOTests: XCTestCase {
    /// Thread-safe sink for the harness pump.
    private final class TurnEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HarnessEvent] = []
        private var errorStorage: String?

        func append(_ event: HarnessEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        func appendError(_ error: Error) {
            lock.lock()
            errorStorage = String(describing: error)
            lock.unlock()
        }

        var events: [HarnessEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var failures: [String] {
            lock.lock()
            defer { lock.unlock() }
            guard let errorStorage else { return [] }
            return [errorStorage]
        }

        /// Number of `.turnStarted` events the consumer observed.
        var starts: Int {
            events.filter {
                if case .turnStarted = $0.kind { return true }
                return false
            }.count
        }

        /// Number of terminal `.turnEnded` events the consumer observed.
        var terminals: Int {
            events.filter {
                if case .turnEnded = $0.kind { return true }
                return false
            }.count
        }
    }

    private func waitForMux(_ worker: MockWorker,
                            timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let id = await worker.latestMuxID() { return id }
            if Date() >= deadline { throw FacadeTestError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func followFrame(_ event: JSONValue) -> JSONValue {
        JSONValue.object([
            "type": .string("item"),
            "streamId": .string("follow"),
            "value": .object(["type": .string("event"), "event": event]),
        ])
    }

    private func turnStart(turn: Int, seq: Int) -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("turn/start"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object(["turn": .number(Double(turn))]),
        ]))
    }

    private func turnEnd(turn: Int, seq: Int, kind: String = "completed") -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("turn/end"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "turn": .number(Double(turn)),
                "reason": .object(["kind": .string(kind)]),
            ]),
        ]))
    }

    private func makeHost(_ fixture: FacadeFixture,
                          engine: MockEngine) throws -> PhoneDSHHost {
        // A long periodic interval keeps the tick out of the way; the test
        // drives the same epoch-close path through its existing seam.
        let configuration = try fixture.configuration(drainDeadline: 1)
        return PhoneDSHHost(configuration: configuration,
                            engineFactory: { _ in engine })
    }

    private func startEventPump(_ harness: any AgentHarness,
                                sessionID: String) -> (Task<Void, Never>, TurnEventLog) {
        let log = TurnEventLog()
        let task = Task {
            do {
                for try await event in harness.events(sessionID: sessionID, after: nil) {
                    log.append(event)
                }
            } catch {
                log.appendError(error)
            }
        }
        return (task, log)
    }

    /// One ordinary user turn over the real host path: prompt, a real WAL
    /// append, the D18 epoch close while the turn is open, then the terminal
    /// `turn/end`.
    func testTurnEndSettlesRealPersistenceCountersAndNextTurnStartsFresh() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        await host.setPeriodicEpochCloseIntervalForTesting(600)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }
        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)

        let beforeAnyTurn = await host.lastTurnPersistenceIO()
        XCTAssertNil(beforeAnyTurn, "no turn has settled yet")

        let payload = Data(String(repeating: "persist-me ", count: 64).utf8)
        try await harness.send(
            .prompt(text: "write a file", attachments: [], requestID: "turn-1"),
            to: session.id)
        try await engine.worker.writeFile(path: "/dsh/workspace/turn-io.txt",
                                          data: payload)
        try await engine.worker.waitForAck(1)
        // The epoch close is D18's fsync pass and runs inside the open turn.
        let close = await host.performPeriodicEpochCloseForTesting()
        guard case .closed = close else {
            return XCTFail("expected a closed periodic epoch, got \(close)")
        }

        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: muxID)
        try await engine.worker.pushMuxFrame(turnEnd(turn: 1, seq: 2), muxID: muxID)
        try await waitUntil { log.terminals >= 1 }

        // The terminal event was observed and settled before it was yielded,
        // so the whole turn is accounted for here.
        let lastCounters = await host.lastTurnPersistenceIO()
        let settled = try XCTUnwrap(lastCounters)
        XCTAssertGreaterThan(settled.fsyncCalls, 0,
                             "the D18 epoch close inside the turn is counted")
        XCTAssertGreaterThanOrEqual(settled.bytesWritten, payload.count,
                                    "the WAL append's bytes are counted")

        let lastSample = await host.lastTurnPersistenceIOSample()
        let sample = try XCTUnwrap(lastSample)
        XCTAssertEqual(sample.sessionID, session.id)
        XCTAssertEqual(sample.turnID, "1")
        XCTAssertEqual(sample.outcome, "completed")

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.lastTurnPersistenceIO, settled,
                       "the diagnostics snapshot carries the same settled window")

        // The existing diagnostic log records the settled numbers, so an App
        // bug report (and scripts/perf on a device build) has the evidence.
        let logURL = fixture.root.appendingPathComponent("boot-timings.log")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("turn-io "), text)
        XCTAssertTrue(text.contains("session=\(session.id)"), text)
        XCTAssertTrue(text.contains("outcome=completed"), text)
        XCTAssertTrue(text.contains("fsync_calls=\(settled.fsyncCalls)"), text)
        XCTAssertTrue(text.contains("bytes_written=\(settled.bytesWritten)"), text)

        // The next prompt opens a new window: this turn writes nothing.
        try await harness.send(
            .prompt(text: "say nothing", attachments: [], requestID: "turn-2"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 2, seq: 3), muxID: muxID)
        try await engine.worker.pushMuxFrame(turnEnd(turn: 2, seq: 4), muxID: muxID)
        try await waitUntil {
            let sample = await host.lastTurnPersistenceIOSample()
            return sample?.turnID == "2"
        }
        let nextCounters = await host.lastTurnPersistenceIO()
        let second = try XCTUnwrap(nextCounters)
        XCTAssertEqual(second, WorkspaceLogIOCounters(),
                       "a new turn starts a fresh window instead of inheriting "
                           + "the previous turn's numbers")
        XCTAssertTrue(log.failures.isEmpty, "\(log.failures)")
        try await host.stop()
    }

    /// An aborted turn settles through the same terminal boundary: the cancel
    /// RPC is the real command path and DSH's own `turn/end` (reason aborted)
    /// closes the window.
    func testCancelledTurnSettlesTheWritesItMade() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        await host.setPeriodicEpochCloseIntervalForTesting(600)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }
        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)

        let payload = Data(String(repeating: "aborted-write ", count: 32).utf8)
        try await harness.send(
            .prompt(text: "long task", attachments: [], requestID: "turn-abort"),
            to: session.id)
        try await engine.worker.writeFile(path: "/dsh/workspace/turn-abort.txt",
                                          data: payload)
        try await engine.worker.waitForAck(1)

        try await harness.send(.cancel, to: session.id)
        let methods = await engine.worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the cancel took the real harness command path: \(methods)")

        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: muxID)
        try await engine.worker.pushMuxFrame(turnEnd(turn: 1, seq: 2, kind: "aborted"),
                                             muxID: muxID)
        try await waitUntil { log.terminals >= 1 }

        let lastSample = await host.lastTurnPersistenceIOSample()
        let sample = try XCTUnwrap(lastSample)
        XCTAssertEqual(sample.turnID, "1")
        XCTAssertEqual(sample.outcome, "cancelled")
        XCTAssertGreaterThan(sample.counters.bytesWritten, 0,
                             "the writes the aborted turn made are still reported")
        XCTAssertTrue(log.failures.isEmpty, "\(log.failures)")
        try await host.stop()
    }

    /// A prompt queued behind the running turn is a *new* turn that DSH starts
    /// itself. Its window begins at DSH's `turn/start`, so a queued turn is
    /// measured instead of being folded into the previous turn's sample.
    func testQueuedPromptGetsItsOwnTurnWindow() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine)
        await host.setPeriodicEpochCloseIntervalForTesting(600)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }
        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)

        // Turn 1: a real write, then the queued prompt arrives while it runs.
        let firstPayload = Data(String(repeating: "queued-first ", count: 32).utf8)
        try await harness.send(
            .prompt(text: "first", attachments: [], requestID: "queued-1"),
            to: session.id)
        try await engine.worker.writeFile(path: "/dsh/workspace/queued-1.txt",
                                          data: firstPayload)
        try await engine.worker.waitForAck(1)
        try await harness.send(
            .prompt(text: "second", attachments: [], requestID: "queued-2"),
            to: session.id)

        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: muxID)
        try await engine.worker.pushMuxFrame(turnEnd(turn: 1, seq: 2), muxID: muxID)
        try await waitUntil {
            let sample = await host.lastTurnPersistenceIOSample()
            return sample?.turnID == "1"
        }
        let firstSample = await host.lastTurnPersistenceIOSample()
        let firstBytes = firstSample?.counters.bytesWritten ?? 0
        XCTAssertGreaterThanOrEqual(firstBytes, firstPayload.count,
                                    "the first turn reports its own write")

        // Turn 2 starts after the first terminal, does its own write and
        // settles on its own terminal with only its own window.
        let secondPayload = Data(String(repeating: "queued-second ", count: 16).utf8)
        try await engine.worker.pushMuxFrame(turnStart(turn: 2, seq: 3), muxID: muxID)
        // The host opens the queued turn's window when it observes DSH's
        // `turn/start`; write only after the consumer has seen it.
        try await waitUntil { log.starts >= 2 }
        try await engine.worker.writeFile(path: "/dsh/workspace/queued-2.txt",
                                          data: secondPayload)
        try await engine.worker.waitForAck(2)
        try await engine.worker.pushMuxFrame(turnEnd(turn: 2, seq: 4), muxID: muxID)
        try await waitUntil {
            let sample = await host.lastTurnPersistenceIOSample()
            return sample?.turnID == "2"
        }
        let secondSample = await host.lastTurnPersistenceIOSample()
        let secondBytes = secondSample?.counters.bytesWritten ?? 0
        XCTAssertGreaterThanOrEqual(secondBytes, secondPayload.count)
        XCTAssertLessThan(secondBytes, firstBytes + secondPayload.count,
                          "the queued turn's window does not still carry the "
                              + "first turn's bytes: \(String(describing: secondSample))")
        XCTAssertEqual(secondSample?.outcome, "completed")
        XCTAssertTrue(log.failures.isEmpty, "\(log.failures)")
        try await host.stop()
    }
}

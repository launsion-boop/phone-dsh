// SPDX-License-Identifier: MIT
// G2-FIX-12: turn-level session event silence must fail loud instead of
// burning the runner's wall-clock budget.
//
// The regression drives the real facade over the loopback origin: a scripted
// Worker answers `session/create`/`session/prompt` and serves the remote.mux
// follow stream. The test pushes a real turn/start event and streaming deltas,
// then stops producing events. Before the fix no layer owns event silence, so
// the stream simply waits forever (the unfixed test times out); after the fix
// the supervisor publishes a terminal `.turnEnded(..., reason: .failed)`
// carrying the stall diagnostic within the configured timeout plus a small
// grace, and diagnostics increments its stall counter.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH

final class PhoneDSHTurnInactivityTests: XCTestCase {
    /// Thread-safe event sink for the harness pump.
    private final class EventLog: @unchecked Sendable {
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

        var failures: [HarnessEvent] {
            events.filter {
                if case .turnEnded(_, .failed) = $0.kind { return true }
                return false
            }
        }

        var completed: Bool {
            events.contains {
                if case .turnEnded(_, .completed) = $0.kind { return true }
                return false
            }
        }
    }

    private func waitForMux(_ worker: MockWorker, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let id = await worker.latestMuxID() { return id }
            if Date() >= deadline { throw FacadeTestError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func followFrame(_ event: JSONValue, streamID: String = "follow") -> JSONValue {
        JSONValue.object([
            "type": .string("item"),
            "streamId": .string(streamID),
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

    private func turnEnd(turn: Int, seq: Int) -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("turn/end"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "turn": .number(Double(turn)),
                "reason": .object(["kind": .string("completed")]),
            ]),
        ]))
    }

    private func delta(_ text: String) -> JSONValue {
        JSONValue.object([
            "type": .string("item"),
            "streamId": .string("follow"),
            "value": .object([
                "type": .string("assistant-stream"),
                "frame": .object([
                    "type": .string("chunk"),
                    "chunk": .object([
                        "type": .string("text-delta"),
                        "text": .string(text),
                    ]),
                ]),
            ]),
        ])
    }

    /// A durable `assistant/message` event carrying provider usage. The only
    /// difference from a plain text delta for the supervisor is the mapped
    /// `usage` kind; the turn-inactivity test uses it to prove usage renews
    /// the silence timer.
    private func usageEvent(seq: Int) -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("assistant/message"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([
                        .object(["type": .string("text"),
                                 "text": .string("still working \(seq)")]),
                    ]),
                ]),
                "usage": .object([
                    "inputTokens": .number(3),
                    "outputTokens": .number(5),
                ]),
            ]),
        ]))
    }

    private func toolCallEvent(seq: Int, callID: String) -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("tool/call"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "turn": .number(2),
                "callId": .string(callID),
                "name": .string("bash"),
                "arguments": .string(#"{"command":"true"}"#),
            ]),
        ]))
    }

    private func toolResultEvent(seq: Int, callID: String) -> JSONValue {
        followFrame(JSONValue.object([
            "type": .string("tool/result"),
            "seq": .number(Double(seq)),
            "time": .number(Date().timeIntervalSince1970 * 1000),
            "data": .object([
                "turn": .number(2),
                "message": .object([
                    "role": .string("tool"),
                    "toolCallId": .string(callID),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("ok")]),
                    ]),
                ]),
            ]),
        ]))
    }

    private func makeHost(_ fixture: FacadeFixture, engine: MockEngine,
                          timeout: TimeInterval) throws -> PhoneDSHHost {
        // The tests keep a long-lived follow stream open; a short drain
        // deadline keeps teardown fast without changing the watchdog.
        let configuration = try fixture.configuration(drainDeadline: 1,
                                                      turnInactivityTimeout: timeout)
        return PhoneDSHHost(configuration: configuration,
                            engineFactory: { _ in engine })
    }

    private func startEventPump(_ harness: any AgentHarness,
                                sessionID: String) -> (Task<Void, Never>, EventLog) {
        let log = EventLog()
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

    func testSilentTurnIsAbortedWithStallDiagnostic() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)

        try await harness.send(
            .prompt(text: "hello", attachments: [], requestID: "stall-test-turn"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: muxID)
        try await engine.worker.pushMuxFrame(delta("first"), muxID: muxID)
        try await engine.worker.pushMuxFrame(delta("second"), muxID: muxID)

        // The observable events arrived; from here on the stream is silent.
        try await waitUntil {
            let events = log.events
            let started = events.contains {
                if case .turnStarted = $0.kind { return true }
                return false
            }
            let deltas = events.filter {
                if case .assistantDelta = $0.kind { return true }
                return false
            }
            return started && deltas.count >= 2
        }
        let silenceStart = Date()

        // The only termination for this turn must be the watchdog abort,
        // inside the configured timeout plus a small grace. On the unfixed
        // tree no layer escalates silence, so this assertion is where the
        // regression fails instead of timing out the whole test.
        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline, log.failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard log.failures.isEmpty == false else {
            XCTFail("a silent turn produced no terminal error event")
            pump.cancel()
            try? await host.stop()
            return
        }
        let elapsed = Date().timeIntervalSince(silenceStart)
        XCTAssertLessThan(elapsed, timeout + 1.5,
                          "the abort must arrive within timeout plus a small grace")

        let terminal = try XCTUnwrap(log.failures.first)
        guard case .turnEnded(let turnID, .failed(let detail)) = terminal.kind else {
            return XCTFail("unexpected terminal event \(terminal)")
        }
        XCTAssertEqual(turnID, "1")
        XCTAssertTrue(detail.contains("stalled"), "detail: \(detail)")
        XCTAssertTrue(detail.contains("last event: assistantDelta"),
                      "the terminal event must name the last event kind: \(detail)")
        XCTAssertTrue(detail.contains("timeout 0.5"),
                      "the terminal event must carry the threshold: \(detail)")
        XCTAssertTrue(detail.contains("no session event for"),
                      "the terminal event must carry the silence age: \(detail)")

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 1)
        XCTAssertEqual(diagnostics.turnInactivityTimeout, timeout)
        let reason = try XCTUnwrap(diagnostics.turnInactivityReason)
        XCTAssertTrue(reason.contains("last event: assistantDelta"))
        XCTAssertTrue(reason.contains("stalled"))

        // End the long-lived follow stream before the drain, so `stop()` sees
        // the in-flight mux request finish instead of waiting its deadline.
        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    func testSilentTurnBeforeFirstEventStillTerminatesTheTurnPair() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.4
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)
        try await harness.send(
            .prompt(text: "never delivered", attachments: [],
                    requestID: "no-first-event-turn"),
            to: session.id)

        // No session event at all: a consumer that pairs turnStarted with
        // turnEnded must still see a complete terminal pair.
        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline, log.failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard log.failures.isEmpty == false else {
            XCTFail("a turn with no first event produced no terminal error event")
            pump.cancel()
            try? await host.stop()
            return
        }
        let events = log.events
        let started = events.contains {
            if case .turnStarted = $0.kind { return true }
            return false
        }
        XCTAssertTrue(started, "the abort must publish the missing turnStarted first")
        guard case .turnEnded(let turnID, .failed(let detail)) = log.failures.first?.kind else {
            return XCTFail("unexpected terminal event")
        }
        XCTAssertEqual(turnID, "no-first-event-turn")
        XCTAssertTrue(detail.contains("last event: none"), "detail: \(detail)")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 1)

        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    func testSteadyEventStreamNeverTripsTheWatchdog() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)

        try await harness.send(
            .prompt(text: "long healthy turn", attachments: [],
                    requestID: "healthy-test-turn"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 2, seq: 1), muxID: muxID)
        // Renew the silence timer well past the threshold with periodic
        // streaming deltas: the watchdog measures silence, not duration.
        for index in 0..<12 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await engine.worker.pushMuxFrame(delta("chunk-\(index)"), muxID: muxID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(log.failures.isEmpty,
                      "a turn with periodic events must not be aborted")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 0)
        XCTAssertNil(diagnostics.turnInactivityReason)

        // End the turn normally so the watchdog is not armed during teardown.
        try await engine.worker.pushMuxFrame(turnEnd(turn: 2, seq: 2), muxID: muxID)
        try await waitUntil { log.completed }
        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    // G2-FIX-12 repair (integration audit P0): the scenario runner rebinds its
    // harness after a recovery. The abandoned supervisor must disarm when its
    // last subscriber goes away; otherwise its still-running timer later
    // records a phantom stall in the host's shared ledger and sends
    // `session/cancel` into the recovered session.
    func testRebindDisarmsTheAbandonedWatchdog() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        // The pre-recovery harness opens a turn and is observed.
        let firstHarness = try await host.harness()
        let session = try await firstHarness.openSession(HarnessSessionRequest())
        let (firstPump, firstLog) = startEventPump(firstHarness, sessionID: session.id)
        let firstMux = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: firstMux)
        try await firstHarness.send(
            .prompt(text: "before the recovery", attachments: [],
                    requestID: "rebind-turn-1"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: firstMux)
        try await engine.worker.pushMuxFrame(delta("before"), muxID: firstMux)
        try await waitUntil {
            firstLog.events.contains {
                if case .turnStarted = $0.kind { return true }
                return false
            }
        }

        // Recovery: the runner cancels the old pump and binds a fresh harness
        // to the same remote session.
        firstPump.cancel()
        try await waitUntil {
            await engine.worker.closedMuxIDs().contains(firstMux)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let secondHarness = try await host.harness()
        let (secondPump, secondLog) = startEventPump(secondHarness, sessionID: session.id)
        try await waitUntil {
            await engine.worker.latestMuxID() != firstMux
        }
        let secondMux = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: secondMux)
        try await secondHarness.send(
            .prompt(text: "after the recovery", attachments: [],
                    requestID: "rebind-turn-2"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 2, seq: 1), muxID: secondMux)
        for index in 0..<10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await engine.worker.pushMuxFrame(delta("current-\(index)"), muxID: secondMux)
        }

        // The abandoned timer expired inside this window. It must have been
        // disarmed by the subscriber going away.
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 0,
                       "an abandoned supervisor must not record a phantom stall")
        XCTAssertNil(diagnostics.turnInactivityReason)
        let unary = await engine.worker.unaryMethods()
        XCTAssertFalse(unary.contains("session/cancel"),
                       "an abandoned supervisor must not cancel the rebound session")
        XCTAssertTrue(secondLog.failures.isEmpty,
                      "the live observed turn must stay healthy")

        try await engine.worker.pushMuxFrame(turnEnd(turn: 2, seq: 2), muxID: secondMux)
        try await waitUntil { secondLog.completed }
        secondPump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    // G2-FIX-12 repair (P1): usage and tool events arrive through the same
    // branchless `observe` entrance as deltas, but only the delta path had an
    // explicit renewal test. A turn that lasts several thresholds while
    // emitting only usage/tool frames must not be aborted.
    func testUsageAndToolEventsRenewTheWatchdog() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)
        try await harness.send(
            .prompt(text: "long healthy turn with tools", attachments: [],
                    requestID: "healthy-usage-tool-turn"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 2, seq: 1), muxID: muxID)

        // Six events at 150 ms renew the 0.5 s timer for ~0.9 s, well past
        // the threshold, without a single assistant-stream delta.
        let frames = [
            usageEvent(seq: 2),
            toolCallEvent(seq: 3, callID: "call-1"),
            toolResultEvent(seq: 4, callID: "call-1"),
            usageEvent(seq: 5),
            toolCallEvent(seq: 6, callID: "call-2"),
            toolResultEvent(seq: 7, callID: "call-2"),
        ]
        for frame in frames {
            try await Task.sleep(nanoseconds: 150_000_000)
            try await engine.worker.pushMuxFrame(frame, muxID: muxID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let recorded = log.events
        XCTAssertTrue(recorded.contains {
            if case .usage = $0.kind { return true }
            return false
        }, "the usage events must reach the subscriber; events: \(recorded)")
        XCTAssertTrue(recorded.contains {
            if case .toolCall = $0.kind { return true }
            return false
        }, "the tool-call events must reach the subscriber; events: \(recorded)")
        XCTAssertTrue(recorded.contains {
            if case .toolResult = $0.kind { return true }
            return false
        }, "the tool-result events must reach the subscriber; events: \(recorded)")
        XCTAssertTrue(log.failures.isEmpty,
                      "usage/tool traffic is event progress and must renew the timer")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 0)
        XCTAssertNil(diagnostics.turnInactivityReason)

        try await engine.worker.pushMuxFrame(turnEnd(turn: 2, seq: 8), muxID: muxID)
        try await waitUntil { log.completed }
        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    // G2-FIX-12 repair (P1): after the watchdog aborts a turn, the underlying
    // harness can still deliver its own terminal for that same turn. The first
    // (diagnosed) terminal must be frozen: a late turnEnded must not be
    // forwarded, because consumers such as the scenario recorder take the last
    // terminal reason.
    func testLateUnderlyingTurnEndDoesNotOverwriteTheAbortTerminal() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)
        try await harness.send(
            .prompt(text: "stall with a late terminal", attachments: [],
                    requestID: "late-terminal-turn"),
            to: session.id)
        try await engine.worker.pushMuxFrame(turnStart(turn: 1, seq: 1), muxID: muxID)
        try await engine.worker.pushMuxFrame(delta("first"), muxID: muxID)
        try await waitUntil {
            log.events.contains {
                if case .assistantDelta = $0.kind { return true }
                return false
            }
        }

        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline, log.failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard log.failures.isEmpty == false else {
            XCTFail("a silent turn produced no terminal error event")
            pump.cancel()
            try? await host.stop()
            return
        }

        // DSH reports the turn it cancelled after our abort; the reader takes
        // the current/last terminal reason, so this must stay suppressed.
        try await engine.worker.pushMuxFrame(turnEnd(turn: 1, seq: 2), muxID: muxID)
        try await Task.sleep(nanoseconds: 300_000_000)

        let terminals = log.events.filter {
            if case .turnEnded = $0.kind { return true }
            return false
        }
        XCTAssertEqual(terminals.count, 1,
                       "a turn must produce exactly one terminal event, got \(terminals)")
        XCTAssertFalse(log.completed,
                       "the late completed terminal must not be forwarded after the abort")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 1)
        let reason = try XCTUnwrap(diagnostics.turnInactivityReason)
        XCTAssertTrue(reason.contains("stalled"), "reason: \(reason)")

        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }

    // The same freeze must hold when the aborted turn never announced its DSH
    // id: the synthetic terminal carries the request id, while the late
    // underlying terminal carries the DSH turn number.
    func testLateUnderlyingTurnEndAfterUnannouncedTurnIsSuppressed() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let timeout: TimeInterval = 0.5
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine: engine, timeout: timeout)
        try await host.start()

        let harness = try await host.harness()
        let session = try await harness.openSession(HarnessSessionRequest())
        let (pump, log) = startEventPump(harness, sessionID: session.id)
        defer { pump.cancel() }

        let muxID = try await waitForMux(engine.worker)
        try await engine.worker.waitForMuxReceive(muxID: muxID)
        try await harness.send(
            .prompt(text: "never announced", attachments: [],
                    requestID: "unannounced-turn"),
            to: session.id)

        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline, log.failures.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard log.failures.isEmpty == false else {
            XCTFail("a turn with no first event produced no terminal error event")
            pump.cancel()
            try? await host.stop()
            return
        }

        // The late terminal only exists underneath; it belongs to the turn
        // the watchdog already failed.
        try await engine.worker.pushMuxFrame(turnEnd(turn: 1, seq: 1), muxID: muxID)
        try await Task.sleep(nanoseconds: 300_000_000)

        let terminals = log.events.filter {
            if case .turnEnded = $0.kind { return true }
            return false
        }
        XCTAssertEqual(terminals.count, 1,
                       "a turn must produce exactly one terminal event, got \(terminals)")
        XCTAssertFalse(log.completed,
                       "the late terminal of the unannounced turn must be suppressed")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.turnInactivityStalls, 1)

        pump.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await host.stop()
    }
}

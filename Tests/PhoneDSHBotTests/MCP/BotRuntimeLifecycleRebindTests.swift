// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBot

/// Regressions for "switching Bots disconnected the other Bot".
///
/// The production composition served the whole roster from one Worker, and
/// every bind re-attached *every* unit's transport. `attachTransport` then
/// cancelled each in-flight turn, so a rebind caused by an unrelated action
/// surfaced as "the other Bot stopped". These tests pin the two mechanisms that
/// make a rebind safe:
///
/// 1. a replacement transport is adopted (the running turn is marked
///    `interrupted`, never cancelled), and
/// 2. a bind restarts only units that have no live transport / no completed
///    start, and only treats a *replaced Worker incarnation* as a reason to
///    restart a live unit.
///
/// The rebind-scope regressions use actor-isolated `Sendable` fixtures. The
/// focused isolation regression is `nonisolated` (the rest of this class keeps
/// its pre-existing main-actor isolation for the transport fixtures), so it
/// proves the frozen PC-20261116 helper's `@Sendable` callbacks enter their own
/// actor instead of requiring main-actor isolation.
@MainActor
final class BotRuntimeLifecycleRebindTests: XCTestCase {
    // MARK: - In-flight turn across a transport replacement

    /// A bind that decided a unit needs a new transport must not send
    /// `session/cancel`: the turn may still be running on the Worker. It marks
    /// the attempt `interrupted`, keeps the partial answer, and writes one
    /// durable "被打断" marker so the turn is not silently dropped.
    func testAttachTransportAdoptsAReplacementWithoutCancellingTheInFlightTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let old = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("partial answer"), .end()]],
        ])
        old.pause("gb-main")
        let remote = try await BotDSHRemoteRuntime(transport: old, runtime: fixture.runtime)

        let send = Task { try await remote.sendUserMessage("long task") }
        try await waitUntil { old.promptHistory.count == 1 }
        let busyBefore = await remote.isMainTurnBusy()
        XCTAssertTrue(busyBefore,
                      "the turn must be in flight before the replacement is attached")

        // The replacement is adopted while the old turn is collecting. A real
        // dead connection ends the old stream; the fake does the same once the
        // attempt was marked. `attachTransport` must not wait on the orphaned
        // collector forever, and must never send `session/cancel`.
        let replacement = BotScriptedRemoteTransport(scripts: [:])
        let attach = Task { await remote.attachTransport(replacement) }
        try await waitUntil {
            let interrupted = await remote.interruptedSessionIDs()
            return interrupted.contains("gb-main")
        }
        old.closeMuxes()
        await attach.value

        XCTAssertTrue(old.cancellations.isEmpty,
                      "adopting a replacement must not cancel the running turn")
        XCTAssertTrue(replacement.cancellations.isEmpty)
        let liveAfter = await remote.hasLiveTransport()
        XCTAssertTrue(liveAfter, "the unit must report the adopted transport as live")

        let result = try await send.value
        XCTAssertEqual(result.status, "interrupted", result.error ?? "no error")
        XCTAssertEqual(result.error, "transport_replaced")
        // The fake cut the stream before the first assistant message, so the
        // collected text is empty here; the partial-answer path is the same
        // `texts.joined()` the collector already uses for a real interruption.
        let busyAfter = await remote.isMainTurnBusy()
        XCTAssertFalse(busyAfter,
                       "the interrupted attempt must settle, not hang the coordinator")

        let events = try await botEvents(fixture.store)
        let markers = events.filter {
            $0.type == "ui.notice" && $0.data["interrupted"] == .bool(true)
        }
        let notice = try XCTUnwrap(markers.first, "one durable interrupted marker is required")
        XCTAssertEqual(markers.count, 1, "the marker must be written once per interrupted turn")
        XCTAssertEqual(notice.data["reason"]?.stringValue, "transport_replaced")
        XCTAssertEqual(notice.principal.sessionId, "gb-main")
    }

    /// A teardown still cancels: a placeholder transport means nothing can
    /// carry the answer, and the caller is deleting/detaching the unit.
    func testAttachTransportWithAPlaceholderCancelsTheInFlightTurn() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("ignored"), .end()]],
        ])
        transport.pause("gb-main")
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        let send = Task { try await remote.sendUserMessage("delete me") }
        try await waitUntil { transport.promptHistory.count == 1 }

        await remote.attachTransport(BotUnattachedTestTransport())
        let live = await remote.hasLiveTransport()
        XCTAssertFalse(live)
        let busy = await remote.isMainTurnBusy()
        XCTAssertFalse(busy, "a detach must drop the in-flight coordinator")

        transport.resume("gb-main")
        let result = try await send.value
        XCTAssertEqual(result.status, "cancelled", result.error ?? "no error")
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.allSatisfy {
            $0.type != "ui.notice" || $0.data["interrupted"] != .bool(true)
        }, "a teardown is not an interruption and must not write the marker")
    }

    // MARK: - Bind restart scope

    func testABindRestartsOnlyTheUnitWithoutALiveTransport() async {
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let dead = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        let restarted = await BotRebindScope.apply(
            [live, dead], forceRestart: false,
            state: { await $0.state() },
            restart: { await $0.restart() })

        XCTAssertEqual(restarted.kept, ["main"])
        XCTAssertEqual(restarted.restarted, ["agent-99"])
        let liveRestartCount = await live.restartCount
        XCTAssertEqual(liveRestartCount, 0,
                       "a live unit must keep its transport and running turn")
        let deadRestartCount = await dead.restartCount
        XCTAssertEqual(deadRestartCount, 1)
        let liveStateReads = await live.stateReadCount
        let deadStateReads = await dead.stateReadCount
        XCTAssertEqual(liveStateReads, 1, "the bind reads each candidate's state exactly once")
        XCTAssertEqual(deadStateReads, 1, "the bind reads each candidate's state exactly once")
        XCTAssertTrue(restarted.failed.isEmpty)
    }

    func testAFailedOrNeverStartedUnitIsRestartedEvenWithATransport() async {
        let failedStart = RebindUnitDouble(botID: "half", hasLiveTransport: true, isStarted: false)
        let restarted = await BotRebindScope.apply(
            [failedStart], forceRestart: false,
            state: { await $0.state() },
            restart: { await $0.restart() })
        XCTAssertEqual(restarted.restarted, ["half"],
                       "a start that never completed must be retried")
        let stateReads = await failedStart.stateReadCount
        XCTAssertEqual(stateReads, 1)
    }

    func testAReplacedWorkerIncarnationRestartsEveryUnit() async {
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let other = RebindUnitDouble(botID: "agent-99", hasLiveTransport: true, isStarted: true)
        let restarted = await BotRebindScope.apply(
            [live, other], forceRestart: true,
            state: { await $0.state() },
            restart: { await $0.restart() })
        XCTAssertEqual(restarted.kept, [])
        XCTAssertEqual(Set(restarted.restarted), ["main", "agent-99"])
        XCTAssertEqual(restarted.restarted, ["main", "agent-99"],
                       "forced restarts keep the candidate order")
        let liveRestarts = await live.restartCount
        let otherRestarts = await other.restartCount
        XCTAssertEqual(liveRestarts + otherRestarts, 2)
        XCTAssertEqual(liveRestarts, 1)
        XCTAssertEqual(otherRestarts, 1)
    }

    func testANonSelectedUnitFailureIsSkippedNotFatal() async {
        let trace = RebindEventLog()
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let broken = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        await broken.setFailure(.mcp("transport creation failed"))
        let restarted = await BotRebindScope.apply(
            [live, broken], forceRestart: false,
            state: { unit in
                await trace.record("state:\(unit.botID)")
                return await unit.state()
            },
            restart: { unit in
                await trace.record("restart:\(unit.botID)")
                try await unit.restartThrowing()
            })
        XCTAssertEqual(restarted.kept, ["main"])
        XCTAssertEqual(restarted.restarted, [])
        XCTAssertTrue(restarted.failed.keys.contains("agent-99"))
        XCTAssertTrue(restarted.failed["agent-99"]?.contains("transport creation failed") == true)
        let events = await trace.entries
        XCTAssertEqual(events, ["state:main", "state:agent-99", "restart:agent-99"],
                       "the failed unit's callback is recorded once")
    }

    /// A per-unit failure is recorded and does not stop the units after it;
    /// the driver still finishes the sequential candidate order.
    func testAPerUnitFailureDoesNotStopTheLaterCandidates() async {
        let trace = RebindEventLog()
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let broken = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        let later = RebindUnitDouble(botID: "agent-100", hasLiveTransport: false, isStarted: true)
        await broken.setFailure(.mcp("transport creation failed"))
        let restarted = await BotRebindScope.apply(
            [live, broken, later], forceRestart: false,
            state: { unit in
                await trace.record("state:\(unit.botID)")
                return await unit.state()
            },
            restart: { unit in
                await trace.record("restart:\(unit.botID)")
                try await unit.restartThrowing()
            })
        XCTAssertEqual(restarted.kept, ["main"])
        XCTAssertEqual(restarted.restarted, ["agent-100"])
        XCTAssertTrue(restarted.failed.keys.contains("agent-99"))
        let events = await trace.entries
        XCTAssertEqual(events, [
            "state:main", "state:agent-99", "restart:agent-99",
            "state:agent-100", "restart:agent-100",
        ], "the recorded failure must not short-circuit the remaining candidates")
    }

    func testBindCancellationStopsTheRemainingUnits() async {
        let trace = RebindEventLog()
        let first = RebindUnitDouble(botID: "main", hasLiveTransport: false, isStarted: true)
        let second = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        await first.setFailure(.cancellation)
        let restarted = await BotRebindScope.apply(
            [first, second], forceRestart: true,
            state: { unit in
                await trace.record("state:\(unit.botID)")
                return await unit.state()
            },
            restart: { unit in
                await trace.record("restart:\(unit.botID)")
                try await unit.restartThrowing()
            })
        XCTAssertTrue(restarted.wasCancelled)
        XCTAssertTrue(restarted.restarted.isEmpty,
                      "the cancelled unit must not be reported as restarted")
        XCTAssertTrue(restarted.failed.isEmpty,
                      "cancellation is a short-circuit, not a per-unit failure")
        let secondRestartCount = await second.restartCount
        XCTAssertEqual(secondRestartCount, 0,
                       "a cancelled bind must not keep attaching units")
        let secondStateReads = await second.stateReadCount
        XCTAssertEqual(secondStateReads, 0,
                       "the first cancellation must short-circuit before the next state read")
        let events = await trace.entries
        XCTAssertEqual(events, ["state:main", "restart:main"],
                       "the cancelled callback is the last one the driver runs")
    }

    /// The frozen helper is actor-neutral: these callbacks are `@Sendable` and
    /// run from this `nonisolated` test task, while every state read/restart
    /// enters the fixture's own actor. The trace also pins the sequential
    /// decision order to the candidate order (not the Bot-id order).
    nonisolated func testRebindScopeRunsIsolatedCallbacksSequentiallyInCandidateOrder() async {
        let trace = RebindEventLog()
        let live = RebindUnitDouble(botID: "a-live", hasLiveTransport: true, isStarted: true)
        let dead = RebindUnitDouble(botID: "b-dead", hasLiveTransport: false, isStarted: true)
        let outcome = await BotRebindScope.apply(
            [dead, live], forceRestart: false,
            state: { unit in
                await trace.record("state:\(unit.botID)")
                return await unit.state()
            },
            restart: { unit in
                await trace.record("restart:\(unit.botID)")
                await unit.restart()
            })

        XCTAssertEqual(outcome.kept, ["a-live"])
        XCTAssertEqual(outcome.restarted, ["b-dead"])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.wasCancelled)
        let events = await trace.entries
        XCTAssertEqual(events, ["state:b-dead", "restart:b-dead", "state:a-live"],
                       "each candidate is decided fully before the next state read")
        let deadStateReads = await dead.stateReadCount
        let liveStateReads = await live.stateReadCount
        XCTAssertEqual(deadStateReads, 1)
        XCTAssertEqual(liveStateReads, 1)
        let deadRestarts = await dead.restartCount
        let liveRestarts = await live.restartCount
        XCTAssertEqual(deadRestarts, 1)
        XCTAssertEqual(liveRestarts, 0)
    }

    // MARK: - Worker incarnation

    func testWorkerIncarnationComparison() {
        XCTAssertTrue(BotWorkerIncarnation.isReplaced(previousBootID: nil,
                                                      currentBootID: "boot-1"),
                      "the first bind is a replacement by definition")
        XCTAssertTrue(BotWorkerIncarnation.isReplaced(previousBootID: "",
                                                      currentBootID: "boot-1"))
        XCTAssertTrue(BotWorkerIncarnation.isReplaced(previousBootID: "boot-1",
                                                      currentBootID: "boot-2"))
        XCTAssertFalse(BotWorkerIncarnation.isReplaced(previousBootID: "boot-1",
                                                       currentBootID: "boot-1"),
                       "a bind that is not for a new Worker must keep live units")
    }

    // MARK: - Selection invariant

    /// `BotRuntimeComposition.select` is the user's Bot switch. Selection must
    /// never reach a bind/rebind: those replace every unit's transport, so a
    /// switch would cancel the *other* Bot's running turn (the reported bug).
    /// The composition is an App target, not a SwiftPM module, so this guard
    /// scans its source and pins both halves of the rule.
    func testSelectionNeverBindsTheWorkerLifecycle() throws {
        let source = try Self.productionCompositionSource()
        let select = try Self.functionBody("func select(", in: source)
        for forbidden in ["bind(", "workerRecovery", "makeTransport",
                          "attachTransport", "retry()"] {
            XCTAssertFalse(select.contains(forbidden),
                           "select() must not \(forbidden); it is a page switch, not a Worker rebind")
        }
        XCTAssertTrue(select.contains("ensureUnit"),
                      "select() may only ensure the unit exists")

        let bind = try Self.functionBody("private func bind(", in: source)
        XCTAssertTrue(bind.contains("BotWorkerIncarnation.isReplaced"),
                      "the bind must compare Worker incarnations before restarting live units")
        let rebindUnits = try Self.functionBody("private func rebindUnits(", in: source)
        XCTAssertTrue(rebindUnits.contains("BotRebindScope.apply"),
                      "the bind must route unit restarts through the scope")
        XCTAssertTrue(rebindUnits.contains("forceRestart: workerReplaced") ||
                      rebindUnits.contains("forceRestart: forceRestart"),
                      "a replaced Worker incarnation is the only reason a live unit restarts")
    }

    // MARK: - Actor-neutral helper

    /// PC-20261116 freezes an actor-neutral helper: `T: Sendable`, async
    /// `@Sendable` callbacks, and no main-actor isolation in the runtime
    /// module. The App keeps its composition and units actor-owned, so its
    /// callbacks must hop explicitly and still rethrow the selected Bot's
    /// original `Error` (the other Bots' failures stay reported, not thrown).
    func testRebindScopeIsActorNeutralAndTheAppHopsExplicitly() throws {
        let scope = try Self.productionRebindScopeSource()
        XCTAssertFalse(scope.contains("@MainActor"),
                       "BotRebindScope must not require the main actor")
        XCTAssertTrue(scope.contains("public static func apply<T: Sendable>("),
                      "candidates must be Sendable for the actor-neutral callbacks")
        XCTAssertTrue(scope.contains("state: @Sendable (T) async -> BotRebindUnit"),
                      "the state callback must be async and Sendable")
        XCTAssertTrue(scope.contains("restart: @Sendable (T) async throws -> Void"),
                      "the restart callback must be async, throwing and Sendable")

        let source = try Self.productionCompositionSource()
        let rebindUnits = try Self.functionBody("private func rebindUnits(", in: source)
        XCTAssertTrue(rebindUnits.contains("await entry.value.rebindState()"),
                      "the App must hop to its actor for a unit's state")
        XCTAssertTrue(rebindUnits.contains("await self.startUnit("),
                      "the App must hop to its actor to restart a unit")
        XCTAssertTrue(rebindUnits.contains("actor RebindErrorBox"),
                      "the Sendable restart callback must not mutate a captured dictionary")
        XCTAssertTrue(rebindUnits.contains("await errors.record(error, for: entry.key)"),
                      "the original Error is recorded through the actor-owned box")
        XCTAssertTrue(rebindUnits.contains("throw error"),
                      "the selected Bot's original Error is rethrown, not formatted")
        XCTAssertTrue(rebindUnits.contains("where botID != selected"),
                      "non-selected failures are skipped and logged, not rethrown")
    }

    // MARK: - Partial restart

    /// A restart that fails midway must be retried by the next bind.
    ///
    /// `BotRebindScope` keeps a unit only when `hasLiveTransport && isStarted`.
    /// A restart of an already-started unit attaches the new transport first
    /// and only then rebuilds the main session/scheduler; if one of those steps
    /// throws, the unit is half-attached with no main session. Unless `start`
    /// clears `started` before its first throwing step, the stale `started`
    /// from the previous successful start makes the *next* bind keep the broken
    /// unit forever. The unit is App target code, so this guard scans its
    /// source (same mechanism as `testSelectionNeverBindsTheWorkerLifecycle`).
    func testAUnitRestartThatFailsIsNotReportedAsStarted() throws {
        let source = try Self.productionUnitSource()
        let start = try Self.functionBody("func start(transport:", in: source)
        guard let reset = start.range(of: "started = false") else {
            XCTFail("unit.start must reset `started` so a failed restart is retried")
            return
        }
        let beforeReset = start[start.startIndex..<reset.lowerBound]
        XCTAssertFalse(
            beforeReset.contains("try await"),
            "the reset must precede the first throwing step of start(), otherwise a mid-restart failure keeps the stale started flag")
        XCTAssertTrue(start.contains("started = true"),
                      "a successful start still sets `started` at the end")
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }
}

// MARK: - Doubles

private struct BotUnattachedTestTransport: BotUnattachedTransport {
    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        throw BotMCPError.unavailable("the unit is detached")
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw BotMCPError.unavailable("the unit is detached")
    }

    func authenticationFailed() async {}
}

/// What a fixture restart does: throw `CancellationError`, throw a Bot error,
/// or succeed. `Sendable`, so the actor fixture needs no unchecked box.
private enum RebindFixtureFailure: Sendable {
    case cancellation
    case mcp(String)
}

/// Actor-owned unit double. `BotRebindScope.apply` accepts Sendable candidates
/// and `@Sendable` callbacks, so the rebind fixtures are isolated to their own
/// actor instead of the main actor; every test access must hop.
private actor RebindUnitDouble {
    let botID: String
    private let hasLiveTransport: Bool
    private let isStarted: Bool
    private(set) var restartCount = 0
    private(set) var stateReadCount = 0
    private var failure: RebindFixtureFailure?

    init(botID: String, hasLiveTransport: Bool, isStarted: Bool) {
        self.botID = botID
        self.hasLiveTransport = hasLiveTransport
        self.isStarted = isStarted
    }

    func setFailure(_ failure: RebindFixtureFailure?) {
        self.failure = failure
    }

    func state() -> BotRebindUnit {
        stateReadCount += 1
        return BotRebindUnit(botID: botID, hasLiveTransport: hasLiveTransport,
                             isStarted: isStarted)
    }

    func restart() {
        restartCount += 1
    }

    func restartThrowing() throws {
        restartCount += 1
        switch failure {
        case .cancellation:
            throw CancellationError()
        case .mcp(let message):
            throw BotMCPError.unavailable(message)
        case .none:
            return
        }
    }
}

/// Actor-owned callback trace: the driver promises sequential callbacks, so
/// these entries are the order the driver actually observed.
private actor RebindEventLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

// MARK: - Source helpers

private extension BotRuntimeLifecycleRebindTests {
    nonisolated static func productionCompositionSource() throws -> String {
        // Tests/PhoneDSHBotTests/MCP/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    nonisolated static func productionUnitSource() throws -> String {
        // Tests/PhoneDSHBotTests/MCP/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeUnit.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    nonisolated static func productionRebindScopeSource() throws -> String {
        // Tests/PhoneDSHBotTests/MCP/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Sources/PhoneDSHBot/MCP/BotRebindScope.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts a function body by brace balance; the first `{` after the
    /// signature opens it, and nested closures/`if` bodies stay inside.
    nonisolated static func functionBody(_ signature: String, in source: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw NSError(domain: "lifecycle-test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "missing \(signature)",
            ])
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "lifecycle-test", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(signature) has no body",
            ])
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open...index])
                }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "lifecycle-test", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "\(signature) body is not balanced",
        ])
    }
}

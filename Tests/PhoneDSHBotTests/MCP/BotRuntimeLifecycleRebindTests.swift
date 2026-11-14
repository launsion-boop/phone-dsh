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
            state: { $0.state },
            restart: { $0.restart() })

        XCTAssertEqual(restarted.kept, ["main"])
        XCTAssertEqual(restarted.restarted, ["agent-99"])
        XCTAssertEqual(live.restartCount, 0,
                       "a live unit must keep its transport and running turn")
        XCTAssertEqual(dead.restartCount, 1)
        XCTAssertTrue(restarted.failed.isEmpty)
    }

    func testAFailedOrNeverStartedUnitIsRestartedEvenWithATransport() async {
        let failedStart = RebindUnitDouble(botID: "half", hasLiveTransport: true, isStarted: false)
        let restarted = await BotRebindScope.apply(
            [failedStart], forceRestart: false,
            state: { $0.state },
            restart: { $0.restart() })
        XCTAssertEqual(restarted.restarted, ["half"],
                       "a start that never completed must be retried")
    }

    func testAReplacedWorkerIncarnationRestartsEveryUnit() async {
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let other = RebindUnitDouble(botID: "agent-99", hasLiveTransport: true, isStarted: true)
        let restarted = await BotRebindScope.apply(
            [live, other], forceRestart: true,
            state: { $0.state },
            restart: { $0.restart() })
        XCTAssertEqual(restarted.kept, [])
        XCTAssertEqual(Set(restarted.restarted), ["main", "agent-99"])
        XCTAssertEqual(live.restartCount + other.restartCount, 2)
    }

    func testANonSelectedUnitFailureIsSkippedNotFatal() async {
        let live = RebindUnitDouble(botID: "main", hasLiveTransport: true, isStarted: true)
        let broken = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        broken.restartError = BotMCPError.unavailable("transport creation failed")
        let restarted = await BotRebindScope.apply(
            [live, broken], forceRestart: false,
            state: { $0.state },
            restart: { try $0.restartThrowing() })
        XCTAssertEqual(restarted.kept, ["main"])
        XCTAssertEqual(restarted.restarted, [])
        XCTAssertTrue(restarted.failed.keys.contains("agent-99"))
        XCTAssertTrue(restarted.failed["agent-99"]?.contains("transport creation failed") == true)
    }

    func testBindCancellationStopsTheRemainingUnits() async {
        let first = RebindUnitDouble(botID: "main", hasLiveTransport: false, isStarted: true)
        let second = RebindUnitDouble(botID: "agent-99", hasLiveTransport: false, isStarted: true)
        first.restartError = CancellationError()
        let restarted = await BotRebindScope.apply(
            [first, second], forceRestart: true,
            state: { $0.state },
            restart: { try $0.restartThrowing() })
        XCTAssertTrue(restarted.wasCancelled)
        XCTAssertEqual(second.restartCount, 0,
                       "a cancelled bind must not keep attaching units")
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

@MainActor
private final class RebindUnitDouble {
    let botID: String
    var hasLiveTransport: Bool
    var isStarted: Bool
    var restartCount = 0
    var restartError: Error?

    init(botID: String, hasLiveTransport: Bool, isStarted: Bool) {
        self.botID = botID
        self.hasLiveTransport = hasLiveTransport
        self.isStarted = isStarted
    }

    var state: BotRebindUnit {
        BotRebindUnit(botID: botID, hasLiveTransport: hasLiveTransport,
                      isStarted: isStarted)
    }

    func restart() {
        restartCount += 1
    }

    func restartThrowing() throws {
        restartCount += 1
        if let restartError { throw restartError }
    }
}

// MARK: - Source helpers

private extension BotRuntimeLifecycleRebindTests {
    static func productionCompositionSource() throws -> String {
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

    /// Extracts a function body by brace balance; the first `{` after the
    /// signature opens it, and nested closures/`if` bodies stay inside.
    static func functionBody(_ signature: String, in source: String) throws -> String {
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

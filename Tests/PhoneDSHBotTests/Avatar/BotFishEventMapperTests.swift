// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishEventMapperTests: XCTestCase {
    // MARK: - The complete upstream director table

    func testEveryUpstreamDirectorEventHasARealMobileSource() throws {
        let cases: [(name: String, event: BotFishEvent, expected: BotFishLifecycle,
                     oneShot: Bool, ttl: Int64?)] = try [
            ("turn.start", mapped(session("turn/start", data: ["turn": .number(1)])),
             .thinking, false, nil),
            ("user.message", mapped(session("user/message", data: ["role": .string("user")])),
             .listening, false, nil),
            ("model.delta", mapped(session("assistant/stream", data: ["channel": .string("text")])),
             .speaking, false, nil),
            ("model.delta reasoning", mapped(session("assistant/stream", data: ["channel": .string("reasoning")])),
             .thinking, false, nil),
            ("tool.start", mapped(session("tool/call", data: ["name": .string("read")])),
             .working, false, nil),
            ("approval.requested", mapped(bot("approval.requested", identity())),
             .alerting, false, nil),
            ("approval.resolved allowed", mapped(bot("approval.decided", identity(),
                                                      ["decision": .string("always")])),
             .working, false, nil),
            ("approval.resolved denied", mapped(bot("approval.decided", identity(),
                                                     ["decision": .string("deny")])),
             .sad, true, 3_200),
            ("task.done ok", mapped(bot("task.settled", identity(), ["status": .string("completed")])),
             .celebrate, true, 2_200),
            ("task.done error", mapped(bot("task.settled", identity(), ["status": .string("failed")])),
             .sad, true, 3_600),
            ("error", mapped(bot("error", identity(), ["message": .string("boom")])),
             .sad, true, 3_600),
            ("memory.written agent", mapped(bot("memory.written", identity(), ["scope": .string("agent")])),
             .nod, true, 2_000),
            ("memory.written user", mapped(bot("memory.written", identity(), ["scope": .string("user")])),
             .love, true, 2_000),
            ("turn.end", mapped(session("turn/end", data: ["reason": .object(["kind": .string("completed")])])),
             .idle, false, nil),
            ("watchdog.flagged", mapped(bot("watchdog.flagged", identity(), ["check": .string("heartbeat")])),
             .alerting, false, nil),
        ]

        for item in cases {
            XCTAssertEqual(item.event.type, canonical(item.name), item.name)
            let result = BotFishDirector.reduce(BotFishDirectorState(), event: item.event)
            XCTAssertEqual(result.directorState.current, item.expected, item.name)
            XCTAssertEqual(result.directorState.oneShot != nil, item.oneShot, item.name)
            if let ttl = item.ttl {
                XCTAssertEqual(result.directorState.oneShot?.endsAt,
                               item.event.time + ttl, item.name)
                XCTAssertEqual(result.command?.ttlMs, ttl, item.name)
            }
        }
    }

    func testSessionAliasesMapToTheCanonicalDirectorTypes() {
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("turn/start"))?.type, "turn.start")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("turn/end"))?.type, "turn.end")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("tool/call"))?.type, "tool.start")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("approval/requested"))?.type,
                       "approval.requested")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("approval/decided"))?.type,
                       "approval.resolved")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: session("error"))?.type, "error")
    }

    func testDurableBotEventAliasesMapToTheCanonicalDirectorTypes() {
        for type in ["turn.start", "turn.started", "turn_start", "conversation.turn_started"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "turn.start", type)
        }
        for type in ["turn.end", "turn.ended", "turn_end", "conversation.turn_ended"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "turn.end", type)
        }
        for type in ["model.delta", "model.stream", "stream.delta"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "model.delta", type)
        }
        for type in ["tool.start", "tool.started", "tool_start", "conversation.tool_call"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "tool.start", type)
        }
        for type in ["approval.requested", "approval_requested"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "approval.requested", type)
        }
        for type in ["approval.resolved", "approval.decided", "approval_resolved"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "approval.resolved", type)
        }
        for type in ["task.done", "task.settled", "task_done"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "task.done", type)
        }
        for type in ["error", "conversation.error", "runtime.error"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "error", type)
        }
        for type in ["memory.written", "memory_written"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "memory.written", type)
        }
        for type in ["user.message", "user-message", "conversation.user_message"] {
            XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot(type, identity()))?.type,
                           "user.message", type)
        }
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: bot("watchdog.flagged", identity()))?.type,
                       "watchdog.flagged")
    }

    func testNonStateEventsAndNonUserMessagesAreIgnored() {
        XCTAssertNil(BotFishDirectorEventMapper.event(from: session("step/start")))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: session("assistant/message")))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: session("user/message",
                                                                     data: ["role": .string("assistant")])))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: bot("model.started", identity())))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: bot("agent.status", identity())))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: bot("fish.action", identity())))
        XCTAssertNil(BotFishDirectorEventMapper.event(from: bot("runtime.exited", identity())))
    }

    func testSourceEnumForwardsToTheSameMapping() {
        let sessionSource = BotFishEventSource.dshSession(session("tool/call"))
        let eventSource = BotFishEventSource.botEvent(bot("watchdog.flagged", identity()))
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: sessionSource)?.type, "tool.start")
        XCTAssertEqual(BotFishDirectorEventMapper.event(from: eventSource)?.type, "watchdog.flagged")
    }

    func testLifecycleFactsMatchUpstreamPhases() {
        XCTAssertEqual(BotFishDirectorEventMapper.lifecycle(from: session("turn/start")), .thinking)
        XCTAssertEqual(BotFishDirectorEventMapper.lifecycle(from: session("tool/call")), .working)
        XCTAssertEqual(BotFishDirectorEventMapper.lifecycle(from: session("assistant/stream")), .streaming)
        XCTAssertEqual(BotFishDirectorEventMapper.lifecycle(
            from: bot("approval.requested", identity())), .alerting)
        XCTAssertEqual(BotFishDirectorEventMapper.lifecycle(
            from: bot("conversation.turn_ended", identity())), .idle)
        // 60 s idle → sleeping is not an event; it is the App's existing
        // `BotChatModel.idleSleeping` clock and is applied with
        // `BotFishDirector.setLifecycle`, never invented by this mapper.
        let idle = BotFishDirector.setLifecycle(BotFishDirectorState(), lifecycle: .sleeping, now: 60_000)
        XCTAssertEqual(idle.directorState.current, .sleeping)
        XCTAssertEqual(idle.command?.state, .sleeping)
    }

    // MARK: - Helpers

    private func session(_ type: String, data: [String: BotJSONValue] = [:]) -> BotDSHSessionEvent {
        BotDSHSessionEvent(type: type, seq: 1, time: 100, data: data)
    }

    private func identity() -> BotPrincipal {
        BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat")
    }

    private func bot(_ type: String, _ principal: BotPrincipal,
                     _ data: [String: BotJSONValue] = [:]) -> BotEvent {
        BotEvent(type: type, eventId: "event-\(type)", time: 100,
                 origin: .local(source: "projector"), traceId: "trace-\(type)",
                 principal: principal, causationId: nil, correlationId: nil,
                 data: .object(data))
    }

    private func mapped(_ session: BotDSHSessionEvent) throws -> BotFishEvent {
        try XCTUnwrap(BotFishDirectorEventMapper.event(from: session))
    }

    private func mapped(_ event: BotEvent) throws -> BotFishEvent {
        try XCTUnwrap(BotFishDirectorEventMapper.event(from: event))
    }

    private func canonical(_ name: String) -> String {
        if name.hasPrefix("model.delta") { return "model.delta" }
        if name.hasPrefix("approval.resolved") { return "approval.resolved" }
        if name.hasPrefix("task.done") { return "task.done" }
        if name.hasPrefix("memory.written") { return "memory.written" }
        return name
    }
}

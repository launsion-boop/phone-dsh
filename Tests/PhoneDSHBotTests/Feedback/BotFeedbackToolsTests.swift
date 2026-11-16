// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFeedbackToolsTests: XCTestCase {
    private func principal(kind: BotSessionKind, botID: String = "bot-1") -> BotGatewayPrincipal {
        BotGatewayPrincipal(
            botId: botID, sessionId: "session-\(kind.rawValue)", kind: kind,
            expiresAt: FeedbackFixtures.baseNow + 3_600_000)
    }

    private func arguments(action: String, kind: String, id: String,
                           scope: String? = nil, version: Int? = nil,
                           deliveryKey: String? = nil) -> BotJSONValue {
        var target: [String: BotJSONValue] = [
            "kind": .string(kind), "id": .string(id),
        ]
        if let version { target["version"] = .number(Double(version)) }
        if let deliveryKey { target["delivery_key"] = .string(deliveryKey) }
        var fields: [String: BotJSONValue] = [
            "action": .string(action), "target": .object(target),
        ]
        if let scope { fields["scope"] = .string(scope) }
        return .object(fields)
    }

    private func makeCenterAndDecision(_ clock: WP6Clock,
                                       store: InMemoryBotFeedbackStore)
        async -> (BotFeedbackCenter, ProactiveDecision) {
        let center = BotFeedbackCenter(store: store, eventLog: nil, memory: nil,
                                       now: { clock.now })
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        return (center, decision)
    }

    func testChatPrincipalCanRecordAdoption() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, decision) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        XCTAssertTrue(tools.handles("RecordFeedback"))
        XCTAssertTrue(tools.handles("mcp__dshbot__RecordFeedback"))
        let result = await tools.execute(
            name: "RecordFeedback",
            arguments: arguments(action: "adopt", kind: "proactive", id: decision.id,
                                 deliveryKey: decision.dedupeKey),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "call-1"))
        XCTAssertNotEqual(result.isError, true)
        guard case .object(let body)? = result.structuredContent else {
            return XCTFail("adoption needs structured content")
        }
        XCTAssertEqual(body["ok"], .bool(true))
        XCTAssertEqual(body["status"], .string("accepted"))
        let index = await store.currentIndex()
        XCTAssertEqual(index?.records.filter { $0.action == .adopt }.count, 1)
    }

    func testNonChatPrincipalIsRefusedWithoutStateChange() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, decision) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        for kind in [BotSessionKind.routine, .task, .verifier, .maintainer, .team] {
            let result = await tools.execute(
                name: "RecordFeedback",
                arguments: arguments(action: "suppress", kind: "proactive",
                                     id: decision.id, scope: "class"),
                principal: principal(kind: kind),
                context: BotMCPRequestContext(callId: "call-\(kind.rawValue)"))
            XCTAssertEqual(result.isError, true, "\(kind)")
        }
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    func testCallIdIsTheIdempotencyKey() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, decision) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        let request = arguments(action: "adopt", kind: "proactive", id: decision.id,
                                deliveryKey: decision.dedupeKey)
        let first = await tools.execute(name: "RecordFeedback", arguments: request,
                                        principal: principal(kind: .chat),
                                        context: BotMCPRequestContext(callId: "call-9"))
        let second = await tools.execute(name: "RecordFeedback", arguments: request,
                                         principal: principal(kind: .chat),
                                         context: BotMCPRequestContext(callId: "call-9"))
        func status(_ result: BotMCPCallResult) -> String? {
            guard case .object(let body)? = result.structuredContent else { return nil }
            return body["status"].flatMap { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
        }
        XCTAssertEqual(status(first), "accepted")
        XCTAssertEqual(status(second), "duplicated")
        let index = await store.currentIndex()
        XCTAssertEqual(index?.records.filter { $0.action == .adopt }.count, 1)
    }

    func testRejectionCarriesDiscoverableTargetKindsAndHint() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, _) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        let result = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: arguments(action: "suppress", kind: "routine",
                                 id: "routine-does-not-exist", scope: "class"),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "call-hint"))
        guard case .object(let body)? = result.structuredContent else {
            return XCTFail("rejection must be structured")
        }
        XCTAssertEqual(body["ok"], .bool(false))
        XCTAssertEqual(body["reason"], .string("target-unresolved"))
        guard case .string(let hint)? = body["hint"], !hint.isEmpty else {
            return XCTFail("rejection needs a generic hint")
        }
        guard case .array(let kinds)? = body["accepted_target_kinds"] else {
            return XCTFail("rejection needs accepted target kinds")
        }
        XCTAssertTrue(kinds.contains(.string("routine")))
        XCTAssertTrue(kinds.contains(.string("memory")))
    }

    func testBotLocalUserScopeIsRejectedInTheResult() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, _) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        let candidate = FeedbackFixtures.candidate("routine-a", kind: .routineResult,
                                                   routineId: "r-a")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        let result = await tools.execute(
            name: "RecordFeedback",
            arguments: arguments(action: "suppress", kind: "proactive", id: decision.id,
                                 scope: "user", deliveryKey: decision.dedupeKey),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "call-user-scope"))
        guard case .object(let body)? = result.structuredContent else {
            return XCTFail("scope rejection needs structured content")
        }
        XCTAssertEqual(body["ok"], .bool(false))
        XCTAssertEqual(body["code"], .string("scope-requires-confirmation"))
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    func testInvalidArgumentsFailClosed() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, _) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        let result = await tools.execute(
            name: "RecordFeedback",
            arguments: .object(["action": .string("clap"),
                                "target": .object(["kind": .string("proactive"),
                                                   "id": .string("x")])]),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "call-bad"))
        XCTAssertEqual(result.isError, true)
    }

    // JSON numbers are Doubles: legal JSON such as 1e300, Int64.max+1, 1.5,
    // NaN or infinity must become invalid_arguments, never a trap. No write
    // happens before validation; normal version/timestamp values still work.
    func testNumericArgumentsNeverTrapAndNeverWriteOnInvalidInput() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let (center, decision) = await makeCenterAndDecision(clock, store: store)
        let tools = BotFeedbackTools(center: center)
        let invalid: [Double] = [
            1e300, Double.greatestFiniteMagnitude, Double(Int64.max) + 2_048,
            1.5, -1, .nan, .infinity, -.infinity,
        ]
        for (index, number) in invalid.enumerated() {
            let versionArgs = BotJSONValue.object([
                "action": .string("suppress"),
                "scope": .string("class"),
                "target": .object([
                    "kind": .string("routine"), "id": .string("routine-1"),
                    "version": .number(number),
                ]),
            ])
            let versionResult = await tools.execute(
                name: "RecordFeedback", arguments: versionArgs,
                principal: principal(kind: .chat),
                context: BotMCPRequestContext(callId: "bad-version-\(index)"))
            XCTAssertEqual(versionResult.isError, true, "version \(number) must fail")

            let expiresArgs = BotJSONValue.object([
                "action": .string("adopt"),
                "target": .object([
                    "kind": .string("proactive"), "id": .string(decision.id),
                    "delivery_key": .string(decision.dedupeKey ?? ""),
                ]),
                "expires_at_ms": .number(number),
            ])
            let expiresResult = await tools.execute(
                name: "RecordFeedback", arguments: expiresArgs,
                principal: principal(kind: .chat),
                context: BotMCPRequestContext(callId: "bad-expires-\(index)"))
            XCTAssertEqual(expiresResult.isError, true, "expires \(number) must fail")
        }
        let afterInvalid = await store.currentIndex()
        XCTAssertEqual(afterInvalid?.records.count ?? 0, 0,
                       "invalid numeric input must not write a feedback record")

        // Normal timestamp/version parse through the same handler.
        let accepted = await tools.execute(
            name: "RecordFeedback",
            arguments: .object([
                "action": .string("adopt"),
                "target": .object([
                    "kind": .string("proactive"), "id": .string(decision.id),
                    "delivery_key": .string(decision.dedupeKey ?? ""),
                ]),
                "expires_at_ms": .number(1_800_000_000_000),
            ]),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "good-expires"))
        guard case .object(let acceptedBody)? = accepted.structuredContent else {
            return XCTFail("normal timestamp must be accepted")
        }
        XCTAssertEqual(acceptedBody["ok"], .bool(true), "body=\(acceptedBody)")

        let normalVersion = await tools.execute(
            name: "RecordFeedback",
            arguments: .object([
                "action": .string("suppress"),
                "scope": .string("class"),
                "target": .object([
                    "kind": .string("routine"), "id": .string("routine-does-not-exist"),
                    "version": .number(7),
                ]),
            ]),
            principal: principal(kind: .chat),
            context: BotMCPRequestContext(callId: "good-version"))
        guard case .object(let versionBody)? = normalVersion.structuredContent else {
            return XCTFail("normal version must reach the center")
        }
        XCTAssertEqual(versionBody["code"], .string("target-unresolved"),
                       "a normal integer must not be rejected as invalid_arguments")
    }

    func testDefinitionIsClosedAndHasNoClassInput() {
        let definition = BotFeedbackTools.definition
        XCTAssertEqual(definition.name, "RecordFeedback")
        guard case .object(let schema) = definition.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            return XCTFail("schema must be an object")
        }
        XCTAssertNil(properties["class_key"])
        XCTAssertNil(properties["class"])
        if case .object(let target)? = properties["target"],
           case .object(let targetProperties)? = target["properties"] {
            XCTAssertNil(targetProperties["class_key"])
        } else {
            XCTFail("target schema missing")
        }
    }
}

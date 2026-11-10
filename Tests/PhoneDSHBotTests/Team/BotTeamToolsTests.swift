// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotTeamToolsTests: XCTestCase {
    private let fixedNow: Int64 = 1_700_000_000_000

    private func makeTools(_ host: FakeBotTeamHost,
                           timeoutMilliseconds: Int = 300_000) -> BotTeamTools {
        BotTeamTools(host: host, timeoutMilliseconds: timeoutMilliseconds, now: { self.fixedNow })
    }

    private func execute(_ tools: BotTeamTools, _ arguments: [String: BotJSONValue],
                         botID: String = "bot-a", callID: String = "call-1") async -> BotMCPCallResult {
        await tools.execute(
            name: BotTeamTools.sendToAgentName, arguments: .object(arguments),
            principal: botTeamPrincipal(botID),
            context: BotMCPRequestContext(callId: callID))
    }

    private func executeCreate(_ tools: BotTeamTools, _ arguments: [String: BotJSONValue],
                               botID: String = "bot-a") async -> BotMCPCallResult {
        await tools.execute(
            name: BotTeamTools.createTeammateName, arguments: .object(arguments),
            principal: botTeamPrincipal(botID),
            context: BotMCPRequestContext(callId: "create-1"))
    }

    // MARK: - Arguments and aliases

    func testTargetAndMessageAliasesAreAccepted() async throws {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)

        let byTargetID = await execute(tools, [
            "target_id": .string("bot-b"), "text": .string("from target_id alias"),
            "priority": .bool(true),
        ], callID: "alias-target")
        XCTAssertNotEqual(byTargetID.isError, true, botTeamResultText(byTargetID))

        let byBotName = await execute(tools, [
            "bot_name": .string("Bee"), "message": .string("from bot_name alias"),
            "priority": .bool(true), "title": .string("Question"),
        ], callID: "alias-name")
        XCTAssertNotEqual(byBotName.isError, true, botTeamResultText(byBotName))

        let byAgentID = await execute(tools, [
            "agentId": .string("bot-b"), "message": .string("from agentId alias"),
            "priority": .bool(true),
        ], callID: "alias-camel")
        XCTAssertNotEqual(byAgentID.isError, true, botTeamResultText(byAgentID))

        let delivered = await host.delivered
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered[0].target.id, "bot-b")
        XCTAssertEqual(delivered[0].promptText,
                       "[agent] Alpha (id: bot-a): from target_id alias")
        XCTAssertEqual(delivered[1].promptText,
                       "[agent] Alpha (id: bot-a) — Question: from bot_name alias")
        XCTAssertEqual(delivered[2].message, "from agentId alias")
    }

    func testMissingWakePolicyUsesTheUpstreamSentence() async {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hello"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("invalid_arguments"))
        XCTAssertEqual(botTeamResultText(result),
                       "SendToAgent requires priority (true = wake now, false = hold for their next turn).")
        let delivered = await host.delivered
        XCTAssertTrue(delivered.isEmpty)
    }

    func testPriorityDeliveryConflictAndInvalidValues() async {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)

        let conflict = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hello"),
            "priority": .bool(true), "delivery": .string("queued"),
        ], callID: "conflict")
        XCTAssertEqual(botTeamResultText(conflict),
                       "priority true implies delivery \"now\" but delivery \"queued\" was also given")

        let badPriority = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hello"),
            "priority": .string("yes"),
        ], callID: "bad-priority")
        XCTAssertEqual(botTeamResultText(badPriority),
                       "priority must be a boolean (true = wake now, false = hold for their next turn)")

        let badDelivery = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hello"),
            "delivery": .string("later"),
        ], callID: "bad-delivery")
        XCTAssertEqual(botTeamResultText(badDelivery), "delivery must be \"now\" or \"queued\"")

        let matching = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hello"),
            "priority": .bool(true), "delivery": .string("now"),
        ], callID: "matching")
        XCTAssertNotEqual(matching.isError, true, botTeamResultText(matching))

        let queued = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hold this"),
            "priority": .bool(false),
        ], callID: "queued")
        XCTAssertNotEqual(queued.isError, true, botTeamResultText(queued))
        let held = await host.heldRequests
        XCTAssertEqual(held.last?.item.text, "hold this")
    }

    // MARK: - Loop safety

    func testSelfTargetIsRejected() async {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-a"), "message": .string("self"),
            "priority": .bool(true),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(botTeamResultText(result),
                       "SendToAgent cannot target the same bot that is running; answer the request yourself.")
        let delivered = await host.delivered
        XCTAssertTrue(delivered.isEmpty)
    }

    func testHopLimitIsInboundPlusOne() async {
        let host = FakeBotTeamHost()
        await host.setContext(BotAgentCommContext(depth: 2), for: "bot-a")
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("too deep"),
            "priority": .bool(true),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(botTeamResultText(result).contains("delegation depth limit reached (max 2 hops)"))
        let delivered = await host.delivered
        XCTAssertTrue(delivered.isEmpty)

        await host.setContext(BotAgentCommContext(depth: 1), for: "bot-a")
        let allowed = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("depth two"),
            "priority": .bool(true),
        ], callID: "depth-two")
        XCTAssertNotEqual(allowed.isError, true, botTeamResultText(allowed))
    }

    func testHandOffCycleIsRejected() async {
        let host = FakeBotTeamHost()
        await host.setContext(
            BotAgentCommContext(depth: 1, chain: ["bot-a", "bot-b"]), for: "bot-a")
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("loop"),
            "priority": .bool(true),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(botTeamResultText(result).contains("delegation cycle detected: Bee"))
        XCTAssertTrue(botTeamResultText(result).contains("bot-a → bot-b"))
        let delivered = await host.delivered
        XCTAssertTrue(delivered.isEmpty)
    }

    // MARK: - Idempotency and delivery

    func testRequestIDIsIdempotentAndDoesNotRedeliver() async throws {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)
        let arguments: [String: BotJSONValue] = [
            "agent_id": .string("bot-b"), "message": .string("once"),
            "priority": .bool(true),
        ]
        let first = await execute(tools, arguments, callID: "idempotent")
        XCTAssertNotEqual(first.isError, true, botTeamResultText(first))
        let second = await execute(tools, arguments, callID: "idempotent")
        XCTAssertNotEqual(second.isError, true, botTeamResultText(second))
        XCTAssertEqual(second.structuredContent?["duplicated"], .bool(true))
        XCTAssertEqual(first.structuredContent?["threadId"], second.structuredContent?["threadId"])

        let delivered = await host.delivered
        XCTAssertEqual(delivered.count, 1)
        let held = await host.heldRequests
        XCTAssertEqual(held.count, 1)
    }

    func testQueuedDeliveryEnqueuesAgentHeldWithoutWakingTheTarget() async throws {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("hold this"),
            "priority": .bool(false), "title": .string("FYI"),
        ], callID: "queued-call")
        XCTAssertNotEqual(result.isError, true, botTeamResultText(result))
        XCTAssertEqual(botTeamResultText(result),
                       "已扣住給 Bee：訊息會在對方下一個回合開頭交付，不會喚醒對方。")

        let delivered = await host.delivered
        XCTAssertTrue(delivered.isEmpty)
        let held = await host.heldRequests
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].botID, "bot-b")
        let item = held[0].item
        XCTAssertEqual(item.kind, "agent-held")
        XCTAssertEqual(item.fromAgentId, "bot-a")
        XCTAssertEqual(item.fromAgentName, "Alpha")
        XCTAssertEqual(item.title, "FYI")
        XCTAssertEqual(item.text, "hold this")
        XCTAssertEqual(item.requestId, "queued-call")
        XCTAssertNotNil(item.threadId)
        XCTAssertEqual(item.state, .pending)

        let records = await host.records
        XCTAssertEqual(records.map(\.direction), [.outbound])
        XCTAssertEqual(records[0].status, "held")
        XCTAssertEqual(records[0].toAgent?.id, "bot-b")
        XCTAssertEqual(records[0].hop, 1)
    }

    func testNowDeliveryProducesBothRowsAndTheSenderReplyHeldItem() async throws {
        let host = FakeBotTeamHost()
        await host.setReply(BotAgentDeliveryReply(text: "the answer", replyEntryId: "t7u"))
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("question"),
            "priority": .bool(true), "title": .string("Question"),
        ], callID: "now-call")
        XCTAssertNotEqual(result.isError, true, botTeamResultText(result))
        XCTAssertEqual(botTeamResultText(result),
                       "已送出給 Bee，回覆稍後以 agent-comm 訊息送達。")

        let delivered = await host.delivered
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].promptText,
                       "[agent] Alpha (id: bot-a) — Question: question")
        XCTAssertEqual(delivered[0].target.id, "bot-b")
        XCTAssertEqual(delivered[0].hop, 1)
        XCTAssertEqual(delivered[0].chain, ["bot-a", "bot-b"])
        XCTAssertEqual(delivered[0].delivery, "now")

        let records = await host.records
        XCTAssertEqual(records.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(records[0].toAgent?.id, "bot-b")
        XCTAssertEqual(records[0].title, "Question")
        XCTAssertEqual(records[1].fromAgent?.id, "bot-b")
        XCTAssertEqual(records[1].text, "the answer")
        XCTAssertEqual(records[1].replyEntryID, "t7u")
        XCTAssertEqual(records[0].threadID, records[1].threadID)
        XCTAssertEqual(records[1].rowID, "t0u")

        let held = await host.heldRequests
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].botID, "bot-a")
        XCTAssertEqual(held[0].item.kind, "agent-held")
        XCTAssertEqual(held[0].item.fromAgentId, "bot-b")
        XCTAssertEqual(held[0].item.fromAgentName, "Bee")
        XCTAssertEqual(held[0].item.text, "the answer")
        XCTAssertEqual(held[0].item.title, "回复：Question")
        XCTAssertEqual(held[0].item.requestId, "reply:now-call")
        XCTAssertEqual(held[0].item.threadId, records[0].threadID)
        XCTAssertEqual(held[0].item.state, .pending)
        XCTAssertEqual(result.structuredContent?["threadId"]?.stringValue, records[0].threadID)
    }

    func testBusyTargetWaitsForItsTurnInsteadOfBeingInterrupted() async throws {
        let host = FakeBotTeamHost()
        await host.setBusy(["bot-b"])
        await host.setDeliveryDelay(20)
        await host.setReply(BotAgentDeliveryReply(text: "after the running turn"))
        let tools = makeTools(host)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("queued behind"),
            "priority": .bool(true),
        ], callID: "busy-call")
        XCTAssertNotEqual(result.isError, true, botTeamResultText(result))
        let deliveredWhileBusy = await host.deliveredWhileBusy
        XCTAssertEqual(deliveredWhileBusy, ["bot-b"])
        let held = await host.heldRequests
        XCTAssertEqual(held.first?.item.text, "after the running turn")
    }

    func testTimeoutFailsAndStillRecordsTheInboundErrorRow() async throws {
        let host = FakeBotTeamHost()
        await host.setDeliveryDelay(200)
        let tools = makeTools(host, timeoutMilliseconds: 30)
        let result = await execute(tools, [
            "agent_id": .string("bot-b"), "message": .string("slow"),
            "priority": .bool(true),
        ], callID: "timeout-call")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("timeout"))
        XCTAssertEqual(botTeamResultText(result), "目標 bot 未在時限內完成回合。")
        let records = await host.records
        XCTAssertEqual(records.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(records[1].text, "")
        XCTAssertNotNil(records[1].error)
        let held = await host.heldRequests
        XCTAssertTrue(held.isEmpty)
    }

    // MARK: - CreateTeammate

    func testCreateTeammateRequiresTheMainBot() async {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)
        let denied = await executeCreate(tools, [
            "name": .string("Builder"),
        ], botID: "bot-b")
        XCTAssertEqual(denied.isError, true)
        XCTAssertEqual(denied.structuredContent?["error"]?["code"], .string("permission_denied"))
        XCTAssertTrue(botTeamResultText(denied).contains("只能由主 Bot 调用"))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)

        let allowed = await executeCreate(tools, [
            "name": .string("Builder"), "description": .string("builds things"),
            "color": .string("amber"), "hairstyle": .string("twin-tail"),
            "section_id": .string("ignored-section"),
        ])
        XCTAssertNotEqual(allowed.isError, true, botTeamResultText(allowed))
        XCTAssertTrue(botTeamResultText(allowed).contains("已建立隊友「Builder」"))
        XCTAssertTrue(botTeamResultText(allowed).contains("agent_id: agent-"))
        XCTAssertTrue(botTeamResultText(allowed).contains("顏色=amber"))
        XCTAssertTrue(botTeamResultText(allowed).contains("髮型=twin-tail"))
        XCTAssertFalse(botTeamResultText(allowed).contains("ignored-section"))
        let createdAfter = await host.created
        XCTAssertEqual(createdAfter.count, 1)
        XCTAssertEqual(createdAfter[0].name, "Builder")
        XCTAssertEqual(createdAfter[0].color, .amber)
        XCTAssertEqual(createdAfter[0].hairstyle, .twinTail)
    }

    func testCreateTeammateValidatesNameLengthDescriptionAndAppearance() async {
        let host = FakeBotTeamHost()
        let tools = makeTools(host)

        let missing = await executeCreate(tools, [:])
        XCTAssertEqual(botTeamResultText(missing), "CreateTeammate requires name.")
        let blank = await executeCreate(tools, ["name": .string("   ")])
        XCTAssertEqual(botTeamResultText(blank), "CreateTeammate requires name.")
        let tooLong = await executeCreate(tools, [
            "name": .string(String(repeating: "a", count: 61)),
        ])
        XCTAssertTrue(botTeamResultText(tooLong).contains("too long (61 > 60)"))

        let invalidColor = await executeCreate(tools, [
            "name": .string("Builder"), "color": .string("rainbow"),
        ])
        XCTAssertTrue(botTeamResultText(invalidColor).contains("color must be one of"))
        let invalidHairstyle = await executeCreate(tools, [
            "name": .string("Builder"), "hairstyle": .string("mohawk"),
        ])
        XCTAssertTrue(botTeamResultText(invalidHairstyle).contains("hairstyle must be one of"))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)

        let description = String(repeating: "d", count: 400)
        let success = await executeCreate(tools, [
            "name": .string("  Builder  "), "description": .string(description),
        ])
        XCTAssertNotEqual(success.isError, true, botTeamResultText(success))
        XCTAssertTrue(botTeamResultText(success).contains("外觀：依 Bot ID 自動組合"))
        let createdAfter = await host.created
        XCTAssertEqual(createdAfter.first?.name, "Builder")
        XCTAssertEqual(createdAfter.first?.description.count, 300)
        XCTAssertNil(createdAfter.first?.color)
        XCTAssertNil(createdAfter.first?.hairstyle)
    }

    // MARK: - Catalog and effects

    func testCatalogRosterLineExcludesCallerAndHiddenBots() throws {
        let roster = botTeamRoster()
        let mainCaller = BotToolCatalog.teamDefinitions(roster: roster, callerBotID: "bot-a")
        let send = try XCTUnwrap(mainCaller.first { $0.name == "SendToAgent" })
        let create = try XCTUnwrap(mainCaller.first { $0.name == "CreateTeammate" })
        XCTAssertTrue(send.description.contains("Available bots: Bee (id: bot-b); Xray (id: bot-x)."))
        XCTAssertFalse(send.description.contains("Alpha"))
        XCTAssertFalse(send.description.contains("Hidden"))
        XCTAssertTrue(create.description.contains("Available bots: Bee (id: bot-b); Xray (id: bot-x)."))

        let teammateCaller = BotToolCatalog.teamDefinitions(roster: roster, callerBotID: "bot-b")
        let teammateSend = try XCTUnwrap(teammateCaller.first { $0.name == "SendToAgent" })
        XCTAssertTrue(teammateSend.description.contains(
            "Available bots: Alpha (id: bot-a, main Bot); Xray (id: bot-x)."))
        XCTAssertFalse(teammateSend.description.contains("Bee"))
        XCTAssertFalse(teammateSend.description.contains("Hidden"))

        XCTAssertEqual(BotToolCatalog.allDefinitions.count, 20)
        XCTAssertEqual(BotToolCatalog.allDefinitions(roster: roster, callerBotID: "bot-a").count, 20)
        XCTAssertTrue(BotToolCatalog.isTeamTool("SendToAgent"))
        XCTAssertFalse(BotToolCatalog.isRegistered("SendToAgent"))
    }

    func testAgentCommRecordEventDataProjectsThroughTheRealRowProjector() throws {
        let record = BotTeamAgentCommRecord(
            rowID: "agent-outbound-row", botID: "bot-a", direction: .outbound,
            role: "assistant", text: "hello", toAgent: BotAgentRef(id: "bot-b", name: "Bee"),
            threadID: "agent-outbound-row@5:agent-comm", requestID: "call-1",
            delivery: "now", hop: 1)
        let event = BotEvent(
            type: "agent.comm", eventId: "comm-1", time: 10,
            origin: .local(source: "comm-service"), traceId: "trace-comm-1",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-bot-a", kind: "chat"),
            causationId: nil, correlationId: "call-1", data: record.eventData)
        let rows = BotSessionLogProjector().project(
            botID: "bot-a", sessionID: "gb-bot-a", sessionEvents: [], uiEvents: [event]).rows
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "agent-outbound-row")
        XCTAssertEqual(row.body.additionalProperties["toAgent"]?["id"], .string("bot-b"))
        XCTAssertEqual(row.body.additionalProperties["agentComm"]?["direction"], .string("outbound"))
        XCTAssertEqual(BotDisplayContract.project(row, profile: .phoneP0).surface, "agent-comm")
        let summary = try XCTUnwrap(BotAgentCommSummarizer.summarize(rows))
        XCTAssertEqual(summary.kind, .single)
        XCTAssertEqual(summary.peer?.name, "Bee")
    }

    func testPhoneToolCatalogGoldenMatchesTheRealDefinitions() throws {
        let fixture = try RowTestSupport.golden("tool-catalog.phone")
        let team = try RowTestSupport.object(fixture["team"], in: "tool-catalog.phone.team")
        let roster = botTeamRoster()
        let definitions = BotToolCatalog.teamDefinitions(roster: roster, callerBotID: "bot-a")
        XCTAssertEqual(definitions.map(\.name), team["tools"] as? [String])

        let sendExpected = try RowTestSupport.object(
            team["sendToAgent"], in: "tool-catalog.phone.team.sendToAgent")
        let send = try XCTUnwrap(definitions.first { $0.name == "SendToAgent" })
        guard case .object(let sendSchema) = send.inputSchema else {
            return XCTFail("SendToAgent inputSchema must be an object")
        }
        XCTAssertEqual(sendSchema["required"]?.arrayValue?.compactMap(\.stringValue),
                       sendExpected["required"] as? [String])
        XCTAssertEqual(sendSchema["properties"]?.objectValue.map { Array($0.keys).sorted() },
                       (sendExpected["properties"] as? [String])?.sorted())
        for needle in sendExpected["descriptionContains"] as? [String] ?? [] {
            XCTAssertTrue(send.description.contains(needle), "missing description: \(needle)")
        }

        let createExpected = try RowTestSupport.object(
            team["createTeammate"], in: "tool-catalog.phone.team.createTeammate")
        let create = try XCTUnwrap(definitions.first { $0.name == "CreateTeammate" })
        guard case .object(let createSchema) = create.inputSchema else {
            return XCTFail("CreateTeammate inputSchema must be an object")
        }
        XCTAssertEqual(createSchema["required"]?.arrayValue?.compactMap(\.stringValue),
                       createExpected["required"] as? [String])
        XCTAssertEqual(createSchema["properties"]?.objectValue.map { Array($0.keys).sorted() },
                       (createExpected["properties"] as? [String])?.sorted())
        for needle in createExpected["descriptionContains"] as? [String] ?? [] {
            XCTAssertTrue(create.description.contains(needle), "missing description: \(needle)")
        }

        let rosterLine = try RowTestSupport.object(
            team["rosterLine"], in: "tool-catalog.phone.team.rosterLine")
        XCTAssertTrue(send.description.contains(rosterLine["mainCaller"] as? String ?? ""))
        let teammateSend = try XCTUnwrap(
            BotToolCatalog.teamDefinitions(roster: roster, callerBotID: "bot-b")
                .first { $0.name == "SendToAgent" })
        XCTAssertTrue(teammateSend.description.contains(
            rosterLine["teammateCaller"] as? String ?? ""))
    }

    func testPhoneToolEffectsGoldenDrivesTheRealClassifier() throws {
        let fixture = try RowTestSupport.golden("tool-effects.phone")
        let valid = try RowTestSupport.array(fixture["valid"], in: "tool-effects.phone.valid")
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            let name = try XCTUnwrap(vector["name"] as? String)
            let args = try RowTestSupport.decode(BotJSONValue.self, vector["args"] as Any)
            let effect = BotToolEffectClassifier.effect(for: name, arguments: args)
            XCTAssertEqual(effect.policy.rawValue, vector["policy"] as? String, name)
            let expected = try RowTestSupport.decode(
                BotToolEffect.self, vector["effect"] as Any)
            XCTAssertEqual(effect, expected, name)
        }
    }

    func testTeamToolEffectsAreAuditedAutomatically() {
        let send = BotToolEffectClassifier.effect(for: "SendToAgent", arguments: .object([
            "agent_id": .string("bot-b"), "message": .string("hello"),
            "priority": .bool(true),
        ]))
        XCTAssertEqual(send.operation, "dshbot.SendToAgent")
        XCTAssertEqual(send.mutability, .externalSend)
        XCTAssertEqual(send.policy, .auto)
        XCTAssertTrue(send.resource.contains("agent=bot-b"))

        let create = BotToolEffectClassifier.effect(for: "CreateTeammate", arguments: .object([
            "name": .string("Builder"),
        ]))
        XCTAssertEqual(create.operation, "dshbot.CreateTeammate")
        XCTAssertEqual(create.mutability, .write)
        XCTAssertEqual(create.policy, .auto)
        XCTAssertTrue(create.resource.contains("name=Builder"))
    }
}

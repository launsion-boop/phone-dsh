// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Conformance for the frozen `team-cases.phone.json` vector.
///
/// Every case drives the real `BotTeamTools` argument parser, target resolver,
/// delivery loop and row writer with a fake `BotTeamHost`; the row identities
/// and event data go through the real `BotAgentCommIdentity` /
/// `BotTeamAgentCommRecord` code. Nothing in this file restates a vector: the
/// expected values are read from `spec/bot/v1/golden/team-cases.phone.json`.
final class BotTeamCasesTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("team-cases.phone")
    }

    private func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func cases(_ group: String) throws -> [[String: Any]] {
        guard let list = try fixture()[group] as? [[String: Any]] else {
            throw BotGoldenFixture.FixtureError(description: "team-cases.phone.\(group)")
        }
        return list
    }

    private func json(_ value: Any) throws -> BotJSONValue {
        try BotJSONValue.parse(JSONSerialization.data(withJSONObject: value))
    }

    private func json(data: Data) throws -> BotJSONValue {
        try BotJSONValue.parse(data)
    }

    private func roster(_ spec: [String: Any]) -> BotRoster {
        let bots = (spec["bots"] as? [[String: Any]] ?? []).map { entry in
            BotProfile(id: entry["id"] as? String ?? "",
                       name: entry["name"] as? String ?? "",
                       hiddenByUser: entry["hiddenByUser"] as? Bool ?? false)
        }
        return BotRoster(bots: bots, mainBotID: spec["mainBotId"] as? String)
    }

    private func makeTools(_ host: FakeBotTeamHost,
                           _ caseSpec: [String: Any]) -> BotTeamTools {
        let tools = object(caseSpec["tools"])
        let timeout = tools["timeoutMilliseconds"] as? Int ?? 300_000
        return BotTeamTools(host: host, timeoutMilliseconds: timeout, now: { self.now })
    }

    private func arguments(_ caseSpec: [String: Any]) throws -> BotJSONValue {
        if caseSpec["argumentsNotObject"] as? Bool == true {
            return .string(caseSpec["arguments"] as? String ?? "")
        }
        return try json(caseSpec["arguments"] ?? [:])
    }

    private func execute(_ tools: BotTeamTools, name: String,
                         _ caseSpec: [String: Any], callID: String) async throws -> BotMCPCallResult {
        await tools.execute(
            name: name, arguments: try arguments(caseSpec),
            principal: botTeamPrincipal(caseSpec["callerBotId"] as? String ?? "bot-a"),
            context: BotMCPRequestContext(callId: callID))
    }

    private func assertStructured(_ expectedSpec: [String: Any],
                                  patterns: [String: String],
                                  actual: BotJSONValue?,
                                  _ name: String) throws {
        guard case .object(let actualFields)? = actual,
              case .object(let expectedFields) = try json(expectedSpec) else {
            XCTFail("\(name): structuredContent is not an object")
            return
        }
        XCTAssertEqual(Set(actualFields.keys), Set(expectedFields.keys), "\(name): keys")
        for (key, expected) in expectedFields {
            if key == "heldId", let pattern = patterns["heldId"] {
                guard case .string(let value)? = actualFields[key] else {
                    XCTFail("\(name): heldId is not a string")
                    continue
                }
                XCTAssertNotNil(value.range(of: pattern, options: .regularExpression),
                                "\(name): heldId \(value) does not match \(pattern)")
            } else {
                XCTAssertEqual(actualFields[key], expected, "\(name): structured.\(key)")
            }
        }
    }

    private func assertRecord(_ actual: BotTeamAgentCommRecord,
                              _ expectedSpec: [String: Any], _ name: String) throws {
        let data = try JSONEncoder().encode(actual)
        let value = try BotJSONValue.parse(data)
        XCTAssertEqual(value, try json(expectedSpec), "\(name): agent-comm row")
    }

    private func assertHeld(_ actual: [BotTeamHeldRequest],
                            _ expectedSpec: [[String: Any]], _ name: String) throws {
        XCTAssertEqual(actual.count, expectedSpec.count, "\(name): held count")
        for (index, expected) in expectedSpec.enumerated() where index < actual.count {
            let request = actual[index]
            XCTAssertEqual(request.botID, expected["botID"] as? String,
                           "\(name): held[\(index)].botID")
            if let handOff = expected["handOff"] as? [String: Any] {
                XCTAssertEqual(request.handOff?.depth, handOff["depth"] as? Int,
                               "\(name): held[\(index)].handOff.depth")
                XCTAssertEqual(request.handOff?.chain, handOff["chain"] as? [String],
                               "\(name): held[\(index)].handOff.chain")
            } else {
                XCTAssertNil(request.handOff, "\(name): held[\(index)].handOff must be nil")
            }
            let item = try json(data: JSONEncoder().encode(request.item))
            guard case .object(var fields) = item,
                  case .object(let expectedItem) = try json(expected["item"] ?? [:]) else {
                XCTFail("\(name): held[\(index)].item is not an object")
                continue
            }
            let id = fields.removeValue(forKey: "id")
            XCTAssertEqual(fields, expectedItem.filter { $0.key != "id" },
                           "\(name): held[\(index)].item")
            if let pattern = expected["idPattern"] as? String,
               case .string(let value)? = id {
                XCTAssertNotNil(value.range(of: pattern, options: .regularExpression),
                                "\(name): held id \(value)")
            } else {
                XCTFail("\(name): held idPattern")
            }
        }
    }

    private func assertDeliveries(_ actual: [BotAgentDeliveryRequest],
                                  _ expectedSpec: [[String: Any]], _ name: String) {
        XCTAssertEqual(actual.count, expectedSpec.count, "\(name): delivery count")
        for (index, expected) in expectedSpec.enumerated() where index < actual.count {
            let request = actual[index]
            XCTAssertEqual(request.target.id, expected["targetId"] as? String,
                           "\(name): delivery[\(index)].target")
            XCTAssertEqual(request.target.name, expected["targetName"] as? String,
                           "\(name): delivery[\(index)].targetName")
            XCTAssertEqual(request.promptText, expected["promptText"] as? String,
                           "\(name): delivery[\(index)].promptText")
            XCTAssertEqual(request.message, expected["message"] as? String,
                           "\(name): delivery[\(index)].message")
            XCTAssertEqual(request.title, expected["title"] as? String,
                           "\(name): delivery[\(index)].title")
            XCTAssertEqual(request.delivery, expected["delivery"] as? String,
                           "\(name): delivery[\(index)].delivery")
            XCTAssertEqual(request.hop, expected["hop"] as? Int,
                           "\(name): delivery[\(index)].hop")
            XCTAssertEqual(request.chain, expected["chain"] as? [String],
                           "\(name): delivery[\(index)].chain")
            XCTAssertEqual(request.requestId, expected["requestId"] as? String,
                           "\(name): delivery[\(index)].requestId")
            XCTAssertEqual(request.threadId, expected["threadId"] as? String,
                           "\(name): delivery[\(index)].threadId")
        }
    }

    private func assertHostConfiguration(_ host: FakeBotTeamHost,
                                         _ caseSpec: [String: Any]) async throws {
        let hostSpec = object(caseSpec["host"])
        if let reply = hostSpec["reply"] as? [String: Any] {
            await host.setReply(BotAgentDeliveryReply(
                text: reply["text"] as? String ?? "",
                replyEntryId: reply["replyEntryId"] as? String))
        }
        if let delay = hostSpec["deliveryDelayMilliseconds"] as? Int {
            await host.setDeliveryDelay(delay)
        }
        if let error = hostSpec["deliveryError"] as? [String: Any] {
            await host.setDeliveryError(hostError(error))
        }
        if let error = hostSpec["enqueueError"] as? [String: Any] {
            await host.setEnqueueError(hostError(error))
        }
        if let profile = hostSpec["createdProfile"] as? [String: Any] {
            await host.setCreatedProfileID(profile["id"] as? String)
        }
    }

    private func hostError(_ spec: [String: Any]) -> BotTeamHostError? {
        switch spec["case"] as? String {
        case "deliveryTimeout": return .deliveryTimeout
        case "deliveryFailed":
            return .deliveryFailed(spec["message"] as? String ?? "")
        case "rejected": return .rejected(spec["message"] as? String ?? "")
        case "invalidTarget": return .invalidTarget(spec["message"] as? String ?? "")
        case "botNotFound": return .botNotFound(spec["message"] as? String ?? "")
        default: return nil
        }
    }

    private func run(_ caseSpec: [String: Any], isCreate: Bool) async throws {
        let name = caseSpec["name"] as? String ?? "?"
        let root = try fixture()
        let host = FakeBotTeamHost(roster: roster(object(root["roster"])))
        try await assertHostConfiguration(host, caseSpec)
        if let context = caseSpec["context"] as? [String: Any] {
            var inbound: BotAgentInboundHop?
            if let hop = context["inbound"] as? [String: Any] {
                inbound = BotAgentInboundHop(
                    senderID: hop["senderID"] as? String ?? "",
                    requestID: hop["requestID"] as? String ?? "",
                    threadID: hop["threadID"] as? String ?? "",
                    delivery: hop["delivery"] as? String ?? "now",
                    title: hop["title"] as? String)
            }
            await host.setContext(BotAgentCommContext(
                depth: context["depth"] as? Int ?? 0,
                chain: context["chain"] as? [String] ?? [],
                turn: context["turn"] as? Int ?? 0,
                existingRowIDs: Set(context["existingRowIDs"] as? [String] ?? []),
                inbound: inbound),
                for: caseSpec["callerBotId"] as? String ?? "bot-a")
        }
        for seed in caseSpec["seedThreads"] as? [[String: Any]] ?? [] {
            await host.seedThread(botID: seed["botID"] as? String ?? "",
                                  requestID: seed["requestID"] as? String ?? "",
                                  threadID: seed["threadID"] as? String ?? "")
        }
        let tools = makeTools(host, caseSpec)
        let toolName = isCreate ? BotTeamTools.createTeammateName : BotTeamTools.sendToAgentName
        let callID = caseSpec["callId"] as? String ?? "create-1"
        let first = try await execute(tools, name: toolName, caseSpec, callID: callID)
        var result = first
        if caseSpec["replay"] as? Bool == true {
            let second = try await execute(tools, name: toolName, caseSpec, callID: callID)
            XCTAssertEqual(first.structuredContent?["threadId"],
                           second.structuredContent?["threadId"],
                           "\(name): a replay must reuse the thread")
            result = second
        }

        let expect = object(caseSpec["expect"])
        if expect["isError"] as? Bool == true {
            XCTAssertEqual(result.isError, true, "\(name): expected failure")
            try assertStructured(object(expect["structured"]), patterns: [:],
                                 actual: result.structuredContent, name)
            XCTAssertEqual(botTeamResultText(result), expect["text"] as? String,
                           "\(name): failure text")
        } else {
            XCTAssertNotEqual(result.isError, true, "\(name): \(botTeamResultText(result))")
            try assertStructured(object(expect["structured"]),
                                 patterns: object(expect["structuredPatterns"]) as? [String: String] ?? [:],
                                 actual: result.structuredContent, name)
            var expectedText = expect["text"] as? String ?? ""
            if isCreate {
                let arguments = object(caseSpec["arguments"])
                let description = arguments["description"] as? String ?? ""
                let truncated = description.count > 300
                    ? String(description.prefix(300)) : description
                expectedText = expectedText.replacingOccurrences(of: "<description>",
                                                                 with: truncated)
            }
            XCTAssertEqual(botTeamResultText(result), expectedText, "\(name): success text")
        }

        if let identity = expect["rowIdentity"] as? [String: Any] {
            let rowID = BotAgentCommIdentity.outboundRowID(
                senderAgentID: identity["sender"] as? String ?? "",
                targetID: identity["target"] as? String ?? "",
                requestID: identity["requestId"] as? String,
                seq: Int64(identity["seq"] as? Int ?? 0))
            XCTAssertEqual(rowID, identity["rowID"] as? String, "\(name): outbound row id")
            XCTAssertEqual(BotAgentCommIdentity.threadID(
                rowID: rowID, seq: Int64(identity["seq"] as? Int ?? 0)),
                identity["threadId"] as? String, "\(name): thread id")
        }

        let expectedRecords = expect["records"] as? [[String: Any]] ?? []
        let records = await host.records
        XCTAssertEqual(records.count, expectedRecords.count, "\(name): row count")
        for (index, expected) in expectedRecords.enumerated() where index < records.count {
            try assertRecord(records[index], expected, "\(name)[\(index)]")
        }
        assertDeliveries(await host.delivered,
                         expect["deliveries"] as? [[String: Any]] ?? [], name)
        try assertHeld(await host.heldRequests,
                       expect["held"] as? [[String: Any]] ?? [], name)
        // `expect.wake` freezes the §2.3.1 wake policy: one target per reply at
        // most, and nothing for a reply that is queued on either side.
        let expectedWake = expect["wake"] as? [String] ?? []
        let actualWake = await host.wakeRequests
        XCTAssertEqual(actualWake, expectedWake, "\(name): wake requests")

        if let expected = expect["created"] as? [String: Any] {
            let created = await host.created
            XCTAssertEqual(created.count, 1, "\(name): created count")
            if let actual = created.first {
                XCTAssertEqual(actual.name, expected["name"] as? String, "\(name): created name")
                XCTAssertEqual(actual.description.count,
                               expected["descriptionLength"] as? Int,
                               "\(name): description length")
                XCTAssertTrue(actual.description.hasPrefix(
                    expected["descriptionPrefix"] as? String ?? ""), "\(name): description")
                XCTAssertEqual(actual.color?.rawValue, expected["color"] as? String,
                               "\(name): color")
                XCTAssertEqual(actual.hairstyle?.rawValue, expected["hairstyle"] as? String,
                               "\(name): hairstyle")
            }
            let authors = await host.createdAuthors
            XCTAssertEqual(authors.count, 1, "\(name): author audit count")
            XCTAssertNil(authors.first ?? nil, "\(name): direct tool call has no authority")
        } else if !isCreate {
            let created = await host.created
            XCTAssertEqual(created.count, 0, "\(name): no Bot may be created")
        }
    }

    func testValidTeamCases() async throws {
        for caseSpec in try cases("valid") {
            try await run(caseSpec, isCreate: (caseSpec["callId"] as? String) == nil)
        }
    }

    func testInvalidTeamCases() async throws {
        for caseSpec in try cases("invalid") {
            try await run(caseSpec, isCreate: (caseSpec["callId"] as? String) == nil)
        }
    }

    func testAgentCommRowDirectionsAndEventData() throws {
        for caseSpec in try cases("rowCases") {
            let name = caseSpec["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: caseSpec["record"] ?? [:])
            let record = try JSONDecoder().decode(BotTeamAgentCommRecord.self, from: data)
            XCTAssertEqual(record.eventData, try json(caseSpec["eventData"] ?? [:]),
                           "\(name): eventData")
            if record.direction == .outbound {
                XCTAssertEqual(
                    record.rowID,
                    BotAgentCommIdentity.outboundRowID(
                        senderAgentID: record.botID,
                        targetID: record.toAgent?.id ?? "",
                        requestID: record.requestID,
                        seq: Int64(try fixture()["nowMilliseconds"] as? Int ?? 0) * 1_000),
                    "\(name): outbound hash")
                XCTAssertEqual(record.threadID,
                               BotAgentCommIdentity.threadID(
                                rowID: record.rowID,
                                seq: Int64(try fixture()["nowMilliseconds"] as? Int ?? 0) * 1_000),
                               "\(name): thread")
            }
        }
    }

    func testSendToUserBoundary() async throws {
        let root = try fixture()
        let sendToUser = object(root["sendToUserCases"])
        for group in ["valid", "invalid"] {
            for caseSpec in object(sendToUser)[group] as? [[String: Any]] ?? [] {
                let name = caseSpec["name"] as? String ?? "?"
                let session = object(caseSpec["session"])
                let kind = BotSessionKind(rawValue: session["kind"] as? String ?? "chat") ?? .chat
                let fixture = try makeBotMCPFixture()
                defer { fixture.cleanup() }
                let sessionID = "gb-\(name)"
                _ = try await fixture.runtime.issueSession(
                    botId: "main", sessionId: sessionID, kind: kind)
                let origin = session["origin"] as? String
                await fixture.runtime.beginTurn(
                    sessionId: sessionID,
                    hidden: session["hidden"] as? Bool ?? false,
                    origin: origin.map { BotTurnOrigin(rpcId: $0) })
                if session["suppressed"] as? Bool == true {
                    await fixture.runtime.suppressText(sessionId: sessionID)
                }
                let arguments = try json(caseSpec["arguments"] ?? [:])
                let callID = "send-to-user-\(name)"
                _ = try await fixture.runtime.registerIdentity(
                    runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionID,
                    callId: callID, name: "SendToUser", arguments: arguments)
                let result = await fixture.runtime.execute(
                    name: "SendToUser", arguments: arguments,
                    context: BotMCPRequestContext(callId: callID))
                let expect = object(caseSpec["expect"])
                if expect["isError"] as? Bool == true {
                    XCTAssertEqual(result.isError, true, "\(name): expected failure")
                    XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue,
                                   "invalid_arguments", "\(name): code")
                    XCTAssertEqual(botTeamResultText(result),
                                   expect["text"] as? String, "\(name): message")
                } else {
                    XCTAssertNotEqual(result.isError, true, "\(name): \(botTeamResultText(result))")
                    XCTAssertEqual(result.structuredContent?["ok"], .bool(true), "\(name): ok")
                    guard case .string(let rowID)? = result.structuredContent?["rowId"] else {
                        XCTFail("\(name): rowId")
                        continue
                    }
                    XCTAssertNotNil(rowID.range(of: "^message-[0-9a-f-]+$",
                                                options: .regularExpression), "\(name): rowId")
                    let events = try await fixture.store.events(after: 0, limit: 100)
                    let event = events.last { $0.type == "ui.send_to_user" }
                    XCTAssertEqual(event?.data["text"]?.stringValue,
                                   expect["eventText"] as? String, "\(name): event text")
                    XCTAssertEqual(event?.data["role"]?.stringValue, "assistant",
                                   "\(name): event role")
                }
            }
        }
    }
}

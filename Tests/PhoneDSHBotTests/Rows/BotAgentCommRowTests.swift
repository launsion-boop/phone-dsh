// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotAgentCommRowTests: XCTestCase {
    func testSummarySingleFanoutAndThread() throws {
        let outboundB = commRow(id: "r1", role: "assistant", text: "to b",
                                to: ("bot-b", "Bee"), direction: .outbound)
        let single = try XCTUnwrap(BotAgentCommSummarizer.summarize([outboundB]))
        XCTAssertEqual(single.kind, .single)
        XCTAssertEqual(single.direction, .outbound)
        XCTAssertEqual(single.peer?.id, "bot-b")
        XCTAssertEqual(single.peers.map(\.id), ["bot-b"])
        XCTAssertEqual(single.messageCount, 1)

        let outboundC = commRow(id: "r2", role: "assistant", text: "to c",
                                to: ("bot-c", "Cee"), direction: .outbound)
        let fanout = try XCTUnwrap(BotAgentCommSummarizer.summarize([outboundB, outboundC]))
        XCTAssertEqual(fanout.kind, .fanout)
        XCTAssertEqual(fanout.peers.map(\.id), ["bot-b", "bot-c"])
        XCTAssertEqual(fanout.messageCount, 2)
        XCTAssertNil(fanout.direction)

        let inboundB = commRow(id: "r3", role: "user", text: "from b",
                               from: ("bot-b", "Bee"), direction: .inbound)
        let thread = try XCTUnwrap(BotAgentCommSummarizer.summarize([outboundB, inboundB]))
        XCTAssertEqual(thread.kind, .thread)
        XCTAssertEqual(thread.peers.map(\.id), ["bot-b"])
        XCTAssertEqual(thread.messageCount, 2)

        // Two outbound rows to the same peer are a thread, not a fan-out.
        let samePeerThread = try XCTUnwrap(
            BotAgentCommSummarizer.summarize([outboundB, outboundB]))
        XCTAssertEqual(samePeerThread.kind, .thread)

        XCTAssertNil(BotAgentCommSummarizer.summarize([] as [BotRow]))
    }

    func testSummaryUsesTheRealRowProjector() throws {
        let events = [
            RowTestSupport.uiEvent(type: "agent.comm", id: "comm-out", commitSeq: 1, time: 1,
                                   data: commData(id: "r1", direction: .outbound,
                                                  role: "assistant", text: "to b",
                                                  to: ("bot-b", "Bee"))),
            RowTestSupport.uiEvent(type: "agent.comm", id: "comm-in", commitSeq: 2, time: 2,
                                   data: commData(id: "r2", direction: .inbound,
                                                  role: "user", text: "from b",
                                                  from: ("bot-b", "Bee"))),
        ]
        let rows = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [], uiEvents: events).rows
        let summary = try XCTUnwrap(BotAgentCommSummarizer.summarize(rows))
        XCTAssertEqual(summary.kind, .thread)
        XCTAssertEqual(summary.peers.map(\.name), ["Bee"])
        XCTAssertEqual(summary.messageCount, 2)
    }

    func testFourDirectionsProjectAndDisplayAsUpstream() throws {
        let outbound = RowTestSupport.uiEvent(
            type: "agent.comm", id: "comm-out", commitSeq: 1, time: 1,
            data: commData(id: "r1", direction: .outbound, role: "assistant",
                           text: "question", to: ("bot-b", "Bee")))
        let inbound = RowTestSupport.uiEvent(
            type: "agent.comm", id: "comm-in", commitSeq: 2, time: 2,
            data: commData(id: "r2", direction: .inbound, role: "user",
                           text: "answer", from: ("bot-b", "Bee")))
        let incoming = RowTestSupport.uiEvent(
            type: "agent.comm", id: "comm-incoming", commitSeq: 3, time: 3,
            data: commData(id: "r3", direction: .incoming, role: "user",
                           text: "[agent] Alpha: question", from: ("bot-a", "Alpha")))
        let reply = RowTestSupport.uiEvent(
            type: "agent.comm", id: "comm-reply", commitSeq: 4, time: 4,
            data: commData(id: "r4", direction: .reply, role: "assistant",
                           text: "answer", to: ("bot-a", "Alpha")))

        let rows = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: [],
            uiEvents: [outbound, inbound, incoming, reply]).rows
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        let outboundRow = try XCTUnwrap(byID["r1"])
        XCTAssertEqual(outboundRow.kind, .sendMessage)
        XCTAssertEqual(outboundRow.role, "assistant")
        XCTAssertEqual(outboundRow.body.additionalProperties["toAgent"]?["id"], .string("bot-b"))
        XCTAssertEqual(outboundRow.body.additionalProperties["agentComm"]?["direction"],
                       .string("outbound"))
        XCTAssertEqual(BotDisplayContract.project(outboundRow, profile: .phoneP0).surface,
                       "agent-comm")

        let inboundRow = try XCTUnwrap(byID["r2"])
        XCTAssertEqual(inboundRow.kind, .message)
        XCTAssertEqual(inboundRow.role, "user")
        XCTAssertEqual(inboundRow.body.additionalProperties["fromAgent"]?["name"], .string("Bee"))
        XCTAssertEqual(BotDisplayContract.project(inboundRow, profile: .phoneP0).surface,
                       "agent-comm")

        let incomingRow = try XCTUnwrap(byID["r3"])
        XCTAssertEqual(incomingRow.kind, .message)
        XCTAssertEqual(BotDisplayContract.project(incomingRow, profile: .phoneP0).surface,
                       "bubble")
        XCTAssertTrue(BotDisplayContract.project(incomingRow, profile: .phoneP0).renderable)

        let replyRow = try XCTUnwrap(byID["r4"])
        XCTAssertEqual(replyRow.kind, .sendMessage)
        XCTAssertEqual(BotDisplayContract.project(replyRow, profile: .phoneP0).surface,
                       "bubble")
        XCTAssertTrue(BotDisplayContract.project(replyRow, profile: .phoneP0).renderable)
    }

    func testTeamBotRowIsNoLongerHiddenOnPhone() throws {
        let input = try RowTestSupport.decode(BotJSONValue.self, [
            "kind": "team-bot", "name": "Builder", "description": "builds",
        ])
        guard case .object(let object) = input else { return XCTFail("expected object") }
        let phone = BotDisplayContract.project(object, profile: .phoneP0)
        XCTAssertEqual(phone.surface, "team-bot-row")
        XCTAssertTrue(phone.renderable)
        let upstream = BotDisplayContract.project(object, profile: .upstreamReference)
        XCTAssertEqual(upstream.surface, "team-bot-row")
        XCTAssertTrue(upstream.renderable)
    }

    func testOutboundIdentityAndThreadRulesMatchUpstream() {
        let rowID = BotAgentCommIdentity.outboundRowID(
            senderAgentID: "bot-a", targetID: "bot-b", requestID: "req-1", seq: 5)
        XCTAssertEqual(
            rowID,
            "agent-outbound-fbc4708c613f1308aaad9cbc6450327340bbe8f86b175454af75a0d79bbc22d6")
        XCTAssertEqual(BotAgentCommIdentity.threadID(rowID: rowID, seq: 5),
                       "\(rowID)@5:agent-comm")
        XCTAssertEqual(BotAgentCommIdentity.turnRowID(turn: 3), "t3u")
        XCTAssertEqual(BotAgentCommIdentity.turnRowID(turn: 3, existingIDs: ["t3u"]), "t3u2")
        XCTAssertEqual(BotAgentCommIdentity.turnRowID(turn: 3, existingIDs: ["t3u", "t3u2"]),
                       "t3u3")
    }

    private func commRow(id: String, role: String, text: String,
                         from: (String, String)? = nil, to: (String, String)? = nil,
                         direction: BotAgentCommDirection) -> BotRow {
        var fields: [String: BotJSONValue] = ["text": .string(text)]
        if let from {
            fields["fromAgent"] = .object(["id": .string(from.0), "name": .string(from.1)])
        }
        if let to {
            fields["toAgent"] = .object([
                "id": .string(to.0), "name": .string(to.1), "kind": .string("agent"),
            ])
        }
        fields["agentComm"] = .object(["direction": .string(direction.rawValue)])
        return BotRow(
            id: id, botID: "bot-a", seq: 1, updatedSeq: 1,
            kind: role == "user" ? .message : .sendMessage, role: role,
            body: BotRowBody(type: .text, additionalProperties: fields),
            provenance: BotRowProvenance(eventIDs: [], trust: BotRowProvenance.model,
                                         tainted: false),
            createdAt: 1)
    }

    private func commData(id: String, direction: BotAgentCommDirection,
                          role: String, text: String,
                          from: (String, String)? = nil,
                          to: (String, String)? = nil) -> [String: BotJSONValue] {
        var data: [String: BotJSONValue] = [
            "id": .string(id), "role": .string(role), "text": .string(text),
            "threadId": .string("thread-1"),
        ]
        var comm: [String: BotJSONValue] = [
            "direction": .string(direction.rawValue),
            "threadId": .string("thread-1"),
        ]
        if let from {
            data["fromAgent"] = .object(["id": .string(from.0), "name": .string(from.1)])
            comm["fromAgentId"] = .string(from.0)
        }
        if let to {
            data["toAgent"] = .object([
                "id": .string(to.0), "name": .string(to.1), "kind": .string("agent"),
            ])
            comm["targetId"] = .string(to.0)
        }
        data["agentComm"] = .object(comm)
        return data
    }
}

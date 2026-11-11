// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Regression for the production `SendToAgent` path: the host writes the
/// outbound and inbound `agent.comm` events through the real SQLite journal,
/// so the envelope codec must accept both the event type and the local origin
/// the production composition uses. A fake host that only appends records to
/// an in-memory array cannot catch this class of bug.
final class BotTeamCommPersistenceTests: XCTestCase {
    private let fixedNow: Int64 = 1_700_000_000_000
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-team-comm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSendToAgentWritesOutboundAndInboundAgentCommThroughTheJournal() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { self.fixedNow })
        let host = JournalBotTeamHost(store: store, now: fixedNow)
        let tools = BotTeamTools(host: host, now: { self.fixedNow })

        let result = await tools.execute(
            name: BotTeamTools.sendToAgentName,
            arguments: .object([
                "agent_id": .string("bot-b"), "message": .string("check the journal"),
                "priority": .bool(true),
            ]),
            principal: botTeamPrincipal("bot-a", kind: .team),
            context: BotMCPRequestContext(callId: "journal-comm-1"))
        XCTAssertNotEqual(result.isError, true, botTeamResultText(result))

        let events = try await store.events(after: 0, limit: 10)
        let comms = events.filter { $0.type == "agent.comm" }
        XCTAssertEqual(comms.count, 2)
        guard comms.count == 2 else { return }
        XCTAssertEqual(comms.map { $0.data["direction"]?.stringValue }, ["outbound", "inbound"])
        XCTAssertTrue(comms.allSatisfy { $0.origin == .local(source: "comm-service") })
        XCTAssertEqual(comms[0].principal.botId, "bot-a")
        XCTAssertEqual(comms[0].data["toAgent"]?["id"]?.stringValue, "bot-b")
        XCTAssertEqual(comms[1].data["fromAgent"]?["id"]?.stringValue, "bot-b")
        XCTAssertEqual(comms[0].correlationId, "agent:journal-comm-1")
        XCTAssertEqual(comms[1].correlationId, "agent:journal-comm-1")
        XCTAssertEqual(comms[0].data["threadId"], comms[1].data["threadId"])
        let head = try await store.headCommitSeq()
        XCTAssertEqual(head, 2)
        try await store.close()

        // The bytes on disk must decode through the public envelope codec, not
        // just through the in-memory records the host kept.
        let reopened = try SQLiteDomainStore(fileURL: file, now: { self.fixedNow })
        let decoded = try await reopened.events(after: 0, limit: 10)
        XCTAssertEqual(decoded.map(\.type), ["agent.comm", "agent.comm"])
        XCTAssertEqual(decoded.map(\.commitSeq), [1, 2])
        let byID = try await reopened.event(withId: decoded[0].eventId)
        XCTAssertEqual(byID, decoded[0])
        try await reopened.close()
    }
}

private actor JournalBotTeamHost: BotTeamHost {
    let store: SQLiteDomainStore
    let now: Int64
    private var threads: [String: String] = [:]
    private var held: [BotTeamHeldRequest] = []

    init(store: SQLiteDomainStore, now: Int64) {
        self.store = store
        self.now = now
    }

    func roster() async throws -> BotRoster { botTeamRoster() }

    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        BotProfile(id: "bot-created", name: name, fishColor: color,
                   fishHairstyle: hairstyle, description: description)
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        BotAgentCommContext()
    }

    func existingAgentCommThread(botID: String, requestID: String) async -> String? {
        threads["\(botID)\u{0}\(requestID)"]
    }

    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        BotAgentDeliveryReply(text: "the journal reply", replyEntryId: "t1u")
    }

    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue {
        held.append(request)
        return WakeInboxEnqueue(ok: true, item: request.item, duplicate: false)
    }

    /// Mirrors `BotRuntimeComposition.recordAgentComm`, including the local
    /// origin the production code writes for `agent.comm`.
    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        let event = BotEvent(
            type: "agent.comm",
            eventId: "agent.comm:\(record.rowID)",
            time: now,
            origin: .local(source: "comm-service"),
            traceId: "agent-comm:\(record.threadID)",
            principal: BotPrincipal(botId: record.botID, sessionId: nil, kind: "team"),
            causationId: nil,
            correlationId: record.requestID,
            data: record.eventData)
        _ = try await store.append(event)
        if record.direction == .outbound {
            threads["\(record.botID)\u{0}\(record.requestID)"] = record.threadID
        }
    }
}

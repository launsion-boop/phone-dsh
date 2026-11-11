// SPDX-License-Identifier: MIT
// Regression for the production App composition: `SendToAgent` must persist
// both `agent.comm` directions through the real `SQLiteDomainStore` envelope
// codec. This drives `BotRuntimeComposition`'s own `recordAgentComm`, so a
// source string or durable type that the real assembly cannot write fails here
// instead of after a real-model smoke run.

import Foundation
import XCTest
@testable import BotEvalApp
@testable import PhoneDSHBot

@MainActor
final class BotTeamCommProductionTests: XCTestCase {
    func testProductionCompositionPersistsBothAgentCommDirections() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-team-comm-production-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let profileStore = BotProfileStore(directory: root.appendingPathComponent("profiles"))
        let launch = try await BotRuntimeComposition.prepare(
            store: store, profileStore: profileStore, selectedBotID: "main")
        let server = launch.composition.server
        addTeardownBlock {
            await launch.composition.stop()
            server.stop()
            try? await store.close()
            try? FileManager.default.removeItem(at: root)
        }

        let target = try await profileStore.createBot(
            name: "Bee", fishColor: nil, fishHairstyle: nil, description: "")
        let host = CompositionRecordHost(composition: launch.composition)
        let tools = BotTeamTools(host: host)
        let roster = try await profileStore.roster()
        let main = try XCTUnwrap(roster.mainBotID)
        let result = await tools.execute(
            name: BotTeamTools.sendToAgentName,
            arguments: .object([
                "agent_id": .string(target.id), "message": .string("production journal check"),
                "priority": .bool(true),
            ]),
            principal: BotGatewayPrincipal(
                botId: main, sessionId: "gb-\(main)", kind: .team, expiresAt: Int64.max),
            context: BotMCPRequestContext(callId: "production-comm-1"))
        XCTAssertNotEqual(result.isError, true,
                          result.content.first?["text"]?.stringValue ?? "unexpected send error")

        let events = try await store.events(after: 0, limit: 10)
        let comms = events.filter { $0.type == "agent.comm" }
        XCTAssertEqual(comms.count, 2)
        guard comms.count == 2 else { return }
        XCTAssertEqual(comms.map { $0.data["direction"]?.stringValue }, ["outbound", "inbound"])
        XCTAssertTrue(comms.allSatisfy { $0.origin == .local(source: "comm-service") })
        XCTAssertEqual(comms[0].data["toAgent"]?["id"]?.stringValue, target.id)
        XCTAssertEqual(comms[1].data["fromAgent"]?["id"]?.stringValue, target.id)
        XCTAssertEqual(comms[0].principal.botId, main)
        XCTAssertEqual(comms[1].data["threadId"], comms[0].data["threadId"])
    }
}

@MainActor
private final class CompositionRecordHost: BotTeamHost {
    let composition: BotRuntimeComposition

    init(composition: BotRuntimeComposition) {
        self.composition = composition
    }

    func roster() async throws -> BotRoster { try await composition.roster() }

    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        throw BotTeamHostError.rejected("CreateTeammate is not under test")
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        BotAgentCommContext()
    }

    func existingAgentCommThread(botID: String, requestID: String) async -> String? { nil }

    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        BotAgentDeliveryReply(text: "production reply", replyEntryId: "t1u")
    }

    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue {
        WakeInboxEnqueue(ok: true, item: request.item, duplicate: false)
    }

    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        try await composition.recordAgentComm(record)
    }
}

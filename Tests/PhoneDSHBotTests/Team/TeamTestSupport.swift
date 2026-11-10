// SPDX-License-Identifier: MIT

import Foundation
@testable import PhoneDSHBot

func botTeamRoster() -> BotRoster {
    BotRoster(bots: [
        BotProfile(id: "bot-a", name: "Alpha", fishColor: .blue, fishHairstyle: .long,
                   pinned: true),
        BotProfile(id: "bot-b", name: "Bee", fishColor: .red, fishHairstyle: .bob),
        BotProfile(id: "bot-c", name: "Hidden", hiddenByUser: true),
        BotProfile(id: "bot-x", name: "Xray"),
    ], mainBotID: "bot-a")
}

func botTeamPrincipal(_ botID: String, kind: BotSessionKind = .chat) -> BotGatewayPrincipal {
    BotGatewayPrincipal(botId: botID, sessionId: "gb-\(botID)", kind: kind,
                        expiresAt: Int64.max)
}

func botTeamResultText(_ result: BotMCPCallResult) -> String {
    result.content.first?["text"]?.stringValue ?? ""
}

actor FakeBotTeamHost: BotTeamHost {
    var rosterValue: BotRoster
    private(set) var created: [(name: String, description: String,
                                color: BotFishColor?, hairstyle: BotFishHairstyle?)] = []
    private(set) var delivered: [BotAgentDeliveryRequest] = []
    private(set) var heldRequests: [BotTeamHeldRequest] = []
    private(set) var records: [BotTeamAgentCommRecord] = []
    private(set) var contexts: [String: BotAgentCommContext] = [:]
    private var threads: [String: String] = [:]
    private var heldRequestIDs: Set<String> = []
    var reply = BotAgentDeliveryReply(text: "reply text", replyEntryId: "t0u")
    var deliveryDelayMilliseconds = 0
    var deliveryError: BotTeamHostError?
    var enqueueError: BotTeamHostError?
    var busyBotIDs: Set<String> = []
    private(set) var deliveredWhileBusy: [String] = []
    private var createdCount = 0

    init(roster: BotRoster = botTeamRoster()) {
        rosterValue = roster
    }

    func roster() async throws -> BotRoster { rosterValue }

    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        createdCount += 1
        created.append((name, description, color, hairstyle))
        let profile = BotProfile(
            id: "agent-00000000000000\(String(format: "%02d", createdCount))",
            name: name, fishColor: color ?? .blue,
            fishHairstyle: hairstyle ?? .long, nameExplicit: true,
            createdAt: 1, updatedAt: 1, description: description)
        rosterValue.bots.append(profile)
        return profile
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        contexts[botID] ?? BotAgentCommContext()
    }

    func existingAgentCommThread(botID: String, requestID: String) async -> String? {
        threads[threadKey(botID: botID, requestID: requestID)]
    }

    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        if busyBotIDs.contains(request.target.id) {
            deliveredWhileBusy.append(request.target.id)
        }
        delivered.append(request)
        if deliveryDelayMilliseconds > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(deliveryDelayMilliseconds) * 1_000_000)
        }
        if let deliveryError { throw deliveryError }
        return reply
    }

    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue {
        if let enqueueError { throw enqueueError }
        heldRequests.append(request)
        let duplicate = !heldRequestIDs.insert(request.item.requestId ?? request.item.id).inserted
        return WakeInboxEnqueue(ok: true, item: request.item, duplicate: duplicate)
    }

    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        records.append(record)
        if record.direction == .outbound {
            threads[threadKey(botID: record.botID, requestID: record.requestID)] = record.threadID
        }
    }

    func setContext(_ context: BotAgentCommContext, for botID: String) {
        contexts[botID] = context
    }

    func setReply(_ value: BotAgentDeliveryReply) { reply = value }
    func setDeliveryDelay(_ milliseconds: Int) { deliveryDelayMilliseconds = milliseconds }
    func setDeliveryError(_ error: BotTeamHostError?) { deliveryError = error }
    func setEnqueueError(_ error: BotTeamHostError?) { enqueueError = error }
    func setBusy(_ botIDs: Set<String>) { busyBotIDs = botIDs }

    private func threadKey(botID: String, requestID: String) -> String {
        "\(botID)\u{0}\(requestID)"
    }
}

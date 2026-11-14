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

/// In-memory `BotTeamHost` that models the production chain semantics instead
/// of returning static contexts:
///
/// - `deliverToAgent` installs an **active** context on the target for the
///   delivery turn and releases it when the delivery returns (or throws), like
///   `BotRuntimeComposition`'s `setActive`/`defer clearActive`;
/// - `enqueueHeld(handOff:)` installs a **one-shot pending** context that the
///   target's next `agentCommContext` consumes, like the real tracker;
/// - `setContext` is the explicit/sticky context the frozen team vectors use to
///   describe "this Bot is inside a hand-off";
/// - `enqueueHeld(wake: true)` records one wake request per non-duplicate item.
///
/// A test can run real work inside a delivery through `setDeliveryHandler`,
/// which is how the A→B→A round trip exercises the real install/release path.
actor FakeBotTeamHost: BotTeamHost {
    var rosterValue: BotRoster
    private(set) var created: [(name: String, description: String,
                                color: BotFishColor?, hairstyle: BotFishHairstyle?)] = []
    private(set) var createdAuthors: [BotTeammateAuthor?] = []
    private(set) var delivered: [BotAgentDeliveryRequest] = []
    private(set) var heldRequests: [BotTeamHeldRequest] = []
    private(set) var records: [BotTeamAgentCommRecord] = []
    private(set) var contexts: [String: BotAgentCommContext] = [:]
    private(set) var wakeRequests: [String] = []
    private var active: [String: BotAgentCommContext] = [:]
    private var pendingHeld: [String: BotAgentCommContext] = [:]
    private var turns: [String: Int] = [:]
    private var threads: [String: String] = [:]
    private var heldRequestIDs: Set<String> = []
    var reply = BotAgentDeliveryReply(text: "reply text", replyEntryId: "t0u")
    var deliveryDelayMilliseconds = 0
    var deliveryError: BotTeamHostError?
    var enqueueError: BotTeamHostError?
    var busyBotIDs: Set<String> = []
    private(set) var deliveredWhileBusy: [String] = []
    private var deliveryHandler:
        (@Sendable (BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply)?
    var createdProfileID: String?
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
            id: createdProfileID
                ?? "agent-00000000000000\(String(format: "%02d", createdCount))",
            name: name, fishColor: color ?? .blue,
            fishHairstyle: hairstyle ?? .long, nameExplicit: true,
            createdAt: 1, updatedAt: 1, description: description)
        rosterValue.bots.append(profile)
        return profile
    }

    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?,
                   author: BotTeammateAuthor?) async throws -> BotProfile {
        createdAuthors.append(author)
        return try await createBot(
            name: name, description: description, color: color, hairstyle: hairstyle)
    }

    func agentCommContext(for botID: String) async -> BotAgentCommContext {
        // The real tracker consumes a pending held context on the target's next
        // team-tool call, unless an active delivery context already owns it.
        if active[botID] == nil,
           let pending = pendingHeld.removeValue(forKey: botID) {
            return resolved(pending, for: botID)
        }
        return resolved(active[botID] ?? contexts[botID] ?? BotAgentCommContext(),
                        for: botID)
    }

    func existingAgentCommThread(botID: String, requestID: String) async -> String? {
        threads[threadKey(botID: botID, requestID: requestID)]
    }

    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        if busyBotIDs.contains(request.target.id) {
            deliveredWhileBusy.append(request.target.id)
        }
        delivered.append(request)
        active[request.target.id] = BotAgentCommContext(
            depth: request.hop, chain: request.chain,
            inbound: BotAgentInboundHop(
                senderID: request.sender.id, requestID: request.requestId,
                threadID: request.threadId, delivery: request.delivery,
                title: request.title))
        defer { active[request.target.id] = nil }
        if deliveryDelayMilliseconds > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(deliveryDelayMilliseconds) * 1_000_000)
        }
        if let deliveryError { throw deliveryError }
        if let deliveryHandler { return try await deliveryHandler(request) }
        return reply
    }

    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue {
        if let enqueueError { throw enqueueError }
        heldRequests.append(request)
        if let handOff = request.handOff {
            pendingHeld[request.botID] = handOff
        }
        let duplicate = !heldRequestIDs
            .insert(request.item.requestId ?? request.item.id).inserted
        if request.wake, !duplicate {
            wakeRequests.append(request.botID)
        }
        return WakeInboxEnqueue(ok: true, item: request.item, duplicate: duplicate)
    }

    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws {
        records.append(record)
        switch record.direction {
        case .outbound:
            threads[threadKey(botID: record.botID, requestID: record.requestID)] =
                record.threadID
        case .reply:
            // A reply carries the exchange requestID; its own callID is the
            // durable idempotency key, exactly like the production index.
            if let callID = record.callID, !callID.isEmpty {
                threads[threadKey(botID: record.botID, requestID: callID)] =
                    record.threadID
            }
        case .inbound, .incoming:
            break
        }
    }

    // MARK: - Test controls

    func setContext(_ context: BotAgentCommContext, for botID: String) {
        contexts[botID] = context
    }

    func setTurn(_ turn: Int, for botID: String) { turns[botID] = turn }

    func setDeliveryHandler(
        _ handler: (@Sendable (BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply)?
    ) {
        deliveryHandler = handler
    }

    func seedThread(botID: String, requestID: String, threadID: String) {
        threads[threadKey(botID: botID, requestID: requestID)] = threadID
    }

    func setCreatedProfileID(_ id: String?) { createdProfileID = id }

    func setReply(_ value: BotAgentDeliveryReply) { reply = value }
    func setDeliveryDelay(_ milliseconds: Int) { deliveryDelayMilliseconds = milliseconds }
    func setDeliveryError(_ error: BotTeamHostError?) { deliveryError = error }
    func setEnqueueError(_ error: BotTeamHostError?) { enqueueError = error }
    func setBusy(_ botIDs: Set<String>) { busyBotIDs = botIDs }

    private func resolved(_ context: BotAgentCommContext,
                          for botID: String) -> BotAgentCommContext {
        var context = context
        if context.turn == 0 { context.turn = turns[botID] ?? 0 }
        context.existingRowIDs.formUnion(
            records.lazy.filter { $0.botID == botID }.map(\.rowID))
        return context
    }

    private func threadKey(botID: String, requestID: String) -> String {
        "\(botID)\u{0}\(requestID)"
    }
}

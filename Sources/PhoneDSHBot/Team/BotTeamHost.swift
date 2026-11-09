// SPDX-License-Identifier: MIT

import Foundation

/// Where one Bot stands inside the current hand-off chain.
///
/// `depth` is the inbound hop depth (0 for a user turn). `chain` contains the
/// Bot ids already visited by the current hand-off, including the caller, so a
/// target already present in the chain is a cycle. `turn` and `existingRowIDs`
/// let the caller allocate the upstream `t<turn>u` inbound row id without
/// asking the transcript owner.
public struct BotAgentCommContext: Sendable, Equatable {
    public var depth: Int
    public var chain: [String]
    public var turn: Int
    public var existingRowIDs: Set<String>

    public init(depth: Int = 0, chain: [String] = [], turn: Int = 0,
                existingRowIDs: Set<String> = []) {
        self.depth = depth
        self.chain = chain
        self.turn = turn
        self.existingRowIDs = existingRowIDs
    }
}

/// One `now` delivery. The host opens (or queues behind) a visible target turn
/// and resolves with the final assistant text. A busy target is queued, never
/// interrupted. Cancelling the waiting task must stop waiting; the target turn
/// itself may still finish.
public struct BotAgentDeliveryRequest: Sendable, Equatable {
    public var sender: BotAgentRef
    public var target: BotAgentRef
    /// Full prompt exactly as upstream builds it:
    /// `[agent] <name> (id: <id>)[ — <title>]: <message>`.
    public var promptText: String
    public var message: String
    public var title: String?
    public var threadId: String
    public var requestId: String
    public var delivery: String
    public var hop: Int
    /// Chain the target must use for its own SendToAgent calls. It includes the
    /// sender and the target.
    public var chain: [String]

    public init(sender: BotAgentRef, target: BotAgentRef, promptText: String,
                message: String, title: String?, threadId: String, requestId: String,
                delivery: String = "now", hop: Int, chain: [String]) {
        self.sender = sender
        self.target = target
        self.promptText = promptText
        self.message = message
        self.title = title
        self.threadId = threadId
        self.requestId = requestId
        self.delivery = delivery
        self.hop = hop
        self.chain = chain
    }
}

public struct BotAgentDeliveryReply: Sendable, Equatable {
    public var text: String
    public var replyEntryId: String?
    public var status: String?

    public init(text: String, replyEntryId: String? = nil, status: String? = nil) {
        self.text = text
        self.replyEntryId = replyEntryId
        self.status = status
    }
}

public struct BotTeamHeldRequest: Sendable, Equatable {
    public var botID: String
    public var item: WakeInboxItem

    public init(botID: String, item: WakeInboxItem) {
        self.botID = botID
        self.item = item
    }
}

/// One durable agent-comm row as the host should project it. The tools write
/// the sender's `outbound` row before delivery and its `inbound` row after the
/// reply; a host may reuse the same record type for the target's `incoming` and
/// `reply` rows.
public struct BotTeamAgentCommRecord: Codable, Sendable, Equatable {
    public var rowID: String
    public var botID: String
    public var direction: BotAgentCommDirection
    public var role: String
    public var text: String
    public var fromAgent: BotAgentRef?
    public var toAgent: BotAgentRef?
    public var threadID: String
    public var requestID: String
    public var delivery: String?
    public var status: String?
    public var title: String?
    public var hop: Int?
    public var turn: Int?
    public var callID: String?
    public var replyEntryID: String?
    public var error: String?

    public init(rowID: String, botID: String, direction: BotAgentCommDirection,
                role: String, text: String, fromAgent: BotAgentRef? = nil,
                toAgent: BotAgentRef? = nil, threadID: String, requestID: String,
                delivery: String? = nil, status: String? = nil, title: String? = nil,
                hop: Int? = nil, turn: Int? = nil, callID: String? = nil,
                replyEntryID: String? = nil, error: String? = nil) {
        self.rowID = rowID
        self.botID = botID
        self.direction = direction
        self.role = role
        self.text = text
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.threadID = threadID
        self.requestID = requestID
        self.delivery = delivery
        self.status = status
        self.title = title
        self.hop = hop
        self.turn = turn
        self.callID = callID
        self.replyEntryID = replyEntryID
        self.error = error
    }

    public var agentComm: BotAgentComm {
        switch direction {
        case .outbound:
            return BotAgentComm(
                direction: .outbound, targetId: toAgent?.id, targetName: toAgent?.name,
                message: text, requestId: requestID, threadId: threadID,
                delivery: delivery, status: status, title: title, hop: hop,
                callId: callID)
        case .inbound:
            return BotAgentComm(
                direction: .inbound, fromAgentId: fromAgent?.id,
                fromAgentName: fromAgent?.name, replyText: text, requestId: requestID,
                threadId: threadID, replyEntryId: replyEntryID, error: error)
        case .incoming:
            return BotAgentComm(
                direction: .incoming, fromAgentId: fromAgent?.id,
                fromAgentName: fromAgent?.name, message: text, requestId: requestID,
                threadId: threadID, hop: hop)
        case .reply:
            return BotAgentComm(
                direction: .reply, targetId: toAgent?.id, targetName: toAgent?.name,
                message: text, requestId: requestID, threadId: threadID)
        }
    }

    /// Data for the existing `agent.comm` Bot event. The UI projector turns
    /// this into one row without a new event envelope.
    public var eventData: BotJSONValue {
        var object: [String: BotJSONValue] = [
            "id": .string(rowID), "rowID": .string(rowID),
            "role": .string(role), "text": .string(text),
            "direction": .string(direction.rawValue),
            "threadId": .string(threadID), "requestId": .string(requestID),
            "agentComm": agentComm.jsonValue,
        ]
        if let fromAgent { object["fromAgent"] = fromAgent.jsonValue }
        if let toAgent { object["toAgent"] = toAgent.jsonValue }
        if let delivery { object["delivery"] = .string(delivery) }
        if let status { object["status"] = .string(status) }
        if let title { object["title"] = .string(title) }
        if let hop { object["hop"] = .number(Double(hop)) }
        if let turn { object["turn"] = .number(Double(turn)) }
        if let callID { object["callId"] = .string(callID) }
        if let replyEntryID { object["replyEntryId"] = .string(replyEntryID) }
        if let error { object["error"] = .string(error) }
        return .object(object)
    }
}

public enum BotTeamHostError: Error, Sendable, Equatable, CustomStringConvertible {
    case botNotFound(String)
    case invalidTarget(String)
    case deliveryTimeout
    case deliveryFailed(String)
    case rejected(String)

    public var description: String {
        switch self {
        case .botNotFound(let id): return "Unknown Bot: \(id)"
        case .invalidTarget(let reason): return "Invalid agent target: \(reason)"
        case .deliveryTimeout: return "目標 bot 未在時限內完成回合。"
        case .deliveryFailed(let reason): return "Agent delivery failed: \(reason)"
        case .rejected(let reason): return reason
        }
    }
}

/// The host seam the App layer implements in `bm-app`.
///
/// The tools only see this protocol, so a test can inject a fake roster,
/// delivery queue and held inbox. JSON-backed profile storage is
/// `BotProfileStore`; the live per-Bot turn belongs to `BotDSHRemoteRuntime`.
public protocol BotTeamHost: Sendable {
    /// Full roster, including hidden Bots and the repaired main-Bot pointer.
    func roster() async throws -> BotRoster

    /// Create one Bot. `color`/`hairstyle` `nil` means "let the profile store
    /// choose the explicit blue/long default".
    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?) async throws -> BotProfile

    /// Current hand-off context for the Bot that is calling a team tool.
    func agentCommContext(for botID: String) async -> BotAgentCommContext

    /// Idempotency lookup: the thread already opened by this caller for this
    /// request id, or `nil` when the call is new.
    func existingAgentCommThread(botID: String, requestID: String) async -> String?

    /// Open (or queue behind) a visible target turn and await its final
    /// assistant text. The implementation must not interrupt a running turn.
    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply

    /// Enqueue one held item for `request.botID`; the idempotency key is
    /// `item.requestId`.
    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue

    /// Persist one agent-comm row for `record.botID` and bump the unread
    /// counter of the sender or target when that Bot is not currently
    /// selected. The host owns selection state.
    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws
}

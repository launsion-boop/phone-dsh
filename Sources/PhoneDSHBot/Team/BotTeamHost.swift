// SPDX-License-Identifier: MIT

import Foundation

/// The hand-off hop that opened the caller's current turn.
///
/// It is what makes an answer to the **immediate previous hop** a reply rather
/// than a cycle (`team.md` §2.3.1): the `SendToAgent` tool can only write the
/// exchange's `reply` row and the exchange-shaped held item if it knows which
/// request/thread handed the turn over. The value is in-memory only, exactly
/// like the chain; a host that cannot supply it keeps the historical cycle
/// rejection.
public struct BotAgentInboundHop: Sendable, Equatable {
    /// The Bot that handed the current turn to the caller (`chain[count-2]`).
    public var senderID: String
    /// The exchange's `requestId` (`agent:<sender callId>`).
    public var requestID: String
    /// The exchange's `threadID`; the reply row and held item join it.
    public var threadID: String
    /// How the hop was delivered: `"now"` or `"queued"`. The reply wake policy
    /// requires `"now"` here **and** on the reply call (`team.md` §2.3.1).
    public var delivery: String
    /// The inbound message's title, used for the held reply title
    /// (`回复：<title>`); absent when the message had none.
    public var title: String?

    public init(senderID: String, requestID: String, threadID: String,
                delivery: String, title: String? = nil) {
        self.senderID = senderID
        self.requestID = requestID
        self.threadID = threadID
        self.delivery = delivery
        self.title = title
    }

    /// `now` on both sides is the only wake combination; `queued` stays silent.
    public func wakesReply(delivery replyDelivery: String) -> Bool {
        delivery == "now" && replyDelivery == "now"
    }
}

/// Where one Bot stands inside the current hand-off chain.
///
/// `depth` is the inbound hop depth (0 for a user turn). `chain` contains the
/// Bot ids already visited by the current hand-off, including the caller, so a
/// target already present in the chain is a cycle — unless it is the immediate
/// previous hop and `inbound` identifies that hop. `turn` and `existingRowIDs`
/// let the caller allocate the upstream `t<turn>u` inbound row id without
/// asking the transcript owner.
public struct BotAgentCommContext: Sendable, Equatable {
    public var depth: Int
    public var chain: [String]
    public var turn: Int
    public var existingRowIDs: Set<String>
    /// The hop that opened the current turn, or `nil` for a user turn and for
    /// hosts that do not record it.
    public var inbound: BotAgentInboundHop?

    public init(depth: Int = 0, chain: [String] = [], turn: Int = 0,
                existingRowIDs: Set<String> = [],
                inbound: BotAgentInboundHop? = nil) {
        self.depth = depth
        self.chain = chain
        self.turn = turn
        self.existingRowIDs = existingRowIDs
        self.inbound = inbound
    }

    /// The hop that handed the current turn to `callerID`, when that hop is the
    /// target. This is the guard that separates a legitimate reply from a real
    /// cycle: the chain must still end with the caller, the target must be the
    /// element immediately before it, and the host must have recorded the
    /// inbound identity. Anything else returns `nil` and follows the v1
    /// depth/cycle rejection.
    public func immediatePreviousHop(for callerID: String) -> BotAgentInboundHop? {
        guard depth >= 1,
              let inbound,
              !callerID.isEmpty,
              chain.count >= 2,
              chain.last == callerID,
              chain[chain.count - 2] == inbound.senderID,
              inbound.senderID != callerID else { return nil }
        return inbound
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
    /// The in-progress hand-off this held message opens, or `nil` when the
    /// item is a reply/notification rather than a new hop. A reply must not
    /// extend the chain: otherwise the sender of the original message would
    /// look like it is already inside the chain and its next send would be
    /// rejected as a cycle.
    public var handOff: BotAgentCommContext?
    /// Best-effort single wake of `botID` after the item is durably enqueued.
    /// Only an explicit reply to a `now` hand-off sets this (`team.md`
    /// §2.3.1); queued deliveries and automatic held replies leave it `false`
    /// and stay silent. A duplicate enqueue never wakes.
    public var wake: Bool

    public init(botID: String, item: WakeInboxItem,
                handOff: BotAgentCommContext? = nil, wake: Bool = false) {
        self.botID = botID
        self.item = item
        self.handOff = handOff
        self.wake = wake
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
        case .deliveryTimeout: return "目标 Bot 未在时限内完成回合。"
        case .deliveryFailed(let reason): return "Agent delivery failed: \(reason)"
        case .rejected(let reason): return reason
        }
    }
}

/// Who asked for a teammate Bot. The description enters the new Bot's
/// persona, so the authoring turn is recorded durably when the Bot is created.
public struct BotTeammateAuthor: Codable, Sendable, Equatable {
    public enum Authorization: String, Codable, Sendable {
        case userTurn = "user-turn"
        case userConfirmed = "user-confirmed"
    }

    public var rpcId: String?
    public var turnId: String?
    public var sessionId: String?
    public var origin: BotTurnOriginKind
    public var authorization: Authorization
    public var approvalID: String?

    public init(rpcId: String? = nil, turnId: String? = nil, sessionId: String? = nil,
                origin: BotTurnOriginKind, authorization: Authorization,
                approvalID: String? = nil) {
        self.rpcId = rpcId
        self.turnId = turnId
        self.sessionId = sessionId
        self.origin = origin
        self.authorization = authorization
        self.approvalID = approvalID
    }

    /// A non-user author must already carry the approval card that allowed the
    /// creation; the tool refuses to fabricate `user-confirmed` without it.
    public init?(authority: BotTurnAuthority) {
        if authority.isUserTurn {
            self.init(rpcId: authority.rpcId, turnId: authority.turnId,
                      sessionId: authority.sessionId, origin: authority.origin,
                      authorization: .userTurn)
        } else {
            guard let approvalID = authority.approvalID, !approvalID.isEmpty else { return nil }
            self.init(rpcId: authority.rpcId, turnId: authority.turnId,
                      sessionId: authority.sessionId, origin: authority.origin,
                      authorization: .userConfirmed, approvalID: approvalID)
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

    /// Author-audited creation. The App records `author` in a durable
    /// `ui.system_event{event:"teammate.created"}`; a test host may keep the
    /// default implementation and inspect the tool result instead.
    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?,
                   author: BotTeammateAuthor?) async throws -> BotProfile

    /// Current hand-off context for the Bot that is calling a team tool.
    func agentCommContext(for botID: String) async -> BotAgentCommContext

    /// Idempotency lookup: the thread already opened by this caller for this
    /// request id, or `nil` when the call is new.
    func existingAgentCommThread(botID: String, requestID: String) async -> String?

    /// Open (or queue behind) a visible target turn and await its final
    /// assistant text. The implementation must not interrupt a running turn.
    /// For the duration of the target turn it installs an active context on
    /// the target (`depth = request.hop`, `chain = request.chain`) **including**
    /// the `inbound` hop built from this request, then releases it; that is
    /// what lets the target answer the sender with `SendToAgent` (`team.md`
    /// §2.3.1).
    func deliverToAgent(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply

    /// Enqueue one held item for `request.botID`; the idempotency key is
    /// `item.requestId`. A non-nil `handOff` installs a one-shot pending
    /// context (chain and `inbound`) consumed by the target's next team-tool
    /// call. `wake` asks for one best-effort wake after a non-duplicate
    /// enqueue; a duplicate never wakes.
    func enqueueHeld(_ request: BotTeamHeldRequest) async throws -> WakeInboxEnqueue

    /// Persist one agent-comm row for `record.botID` and bump the unread
    /// counter of the sender or target when that Bot is not currently
    /// selected. The host owns selection state.
    func recordAgentComm(_ record: BotTeamAgentCommRecord) async throws
}

public extension BotTeamHost {
    /// Compatibility default: the legacy create path has no author audit.
    /// Production overrides this to persist `author`.
    func createBot(name: String, description: String,
                   color: BotFishColor?, hairstyle: BotFishHairstyle?,
                   author: BotTeammateAuthor?) async throws -> BotProfile {
        try await createBot(
            name: name, description: description, color: color, hairstyle: hairstyle)
    }
}

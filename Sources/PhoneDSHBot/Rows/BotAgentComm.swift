// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The four row directions the upstream agent-comm transcript uses.
///
/// - `outbound`: the sender's row for a message it just sent.
/// - `inbound`: the sender's row carrying the target's reply.
/// - `incoming`: the target's user row opened by an `[agent]` prompt.
/// - `reply`: the target's assistant row patched to name the sender.
public enum BotAgentCommDirection: String, Codable, Sendable, Equatable, CaseIterable {
    case outbound
    case inbound
    case incoming
    case reply
}

/// `toAgent` / `fromAgent` peer reference. `kind` is `"agent"` upstream and is
/// omitted on `fromAgent` rows.
public struct BotAgentRef: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String?

    public init(id: String, name: String, kind: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init?(json: BotJSONValue?) {
        guard case .object(let object)? = json else { return nil }
        let id = object["id"]?.stringValue ?? ""
        let name = object["name"]?.stringValue ?? ""
        guard !id.isEmpty || !name.isEmpty else { return nil }
        self.init(id: id, name: name, kind: object["kind"]?.stringValue)
    }

    public var jsonValue: BotJSONValue {
        var object: [String: BotJSONValue] = ["id": .string(id), "name": .string(name)]
        if let kind { object["kind"] = .string(kind) }
        return .object(object)
    }
}

/// The upstream `agentComm` object. Every field except `direction` is
/// optional so old rows (which only carried `toAgent`/`fromAgent`) still
/// decode.
public struct BotAgentComm: Codable, Sendable, Equatable {
    public var direction: BotAgentCommDirection
    public var targetId: String?
    public var targetName: String?
    public var fromAgentId: String?
    public var fromAgentName: String?
    public var message: String?
    public var replyText: String?
    public var requestId: String?
    public var threadId: String?
    public var firstEntryId: String?
    public var replyEntryId: String?
    public var delivery: String?
    public var status: String?
    public var title: String?
    public var hop: Int?
    public var callId: String?
    public var error: String?

    public init(direction: BotAgentCommDirection, targetId: String? = nil,
                targetName: String? = nil, fromAgentId: String? = nil,
                fromAgentName: String? = nil, message: String? = nil,
                replyText: String? = nil, requestId: String? = nil,
                threadId: String? = nil, firstEntryId: String? = nil,
                replyEntryId: String? = nil, delivery: String? = nil,
                status: String? = nil, title: String? = nil, hop: Int? = nil,
                callId: String? = nil, error: String? = nil) {
        self.direction = direction
        self.targetId = targetId
        self.targetName = targetName
        self.fromAgentId = fromAgentId
        self.fromAgentName = fromAgentName
        self.message = message
        self.replyText = replyText
        self.requestId = requestId
        self.threadId = threadId
        self.firstEntryId = firstEntryId
        self.replyEntryId = replyEntryId
        self.delivery = delivery
        self.status = status
        self.title = title
        self.hop = hop
        self.callId = callId
        self.error = error
    }

    public init?(json: BotJSONValue?) {
        guard case .object(let object)? = json,
              let raw = object["direction"]?.stringValue,
              let direction = BotAgentCommDirection(rawValue: raw) else { return nil }
        func value(_ key: String) -> String? { object[key]?.stringValue }
        self.init(
            direction: direction,
            targetId: value("targetId"), targetName: value("targetName"),
            fromAgentId: value("fromAgentId"), fromAgentName: value("fromAgentName"),
            message: value("message"), replyText: value("replyText"),
            requestId: value("requestId"), threadId: value("threadId"),
            firstEntryId: value("firstEntryId"), replyEntryId: value("replyEntryId"),
            delivery: value("delivery"), status: value("status"), title: value("title"),
            hop: object["hop"]?.intValue, callId: value("callId"), error: value("error"))
    }

    public var jsonValue: BotJSONValue {
        var object: [String: BotJSONValue] = ["direction": .string(direction.rawValue)]
        func put(_ key: String, _ value: String?) {
            if let value { object[key] = .string(value) }
        }
        put("targetId", targetId)
        put("targetName", targetName)
        put("fromAgentId", fromAgentId)
        put("fromAgentName", fromAgentName)
        put("message", message)
        put("replyText", replyText)
        put("requestId", requestId)
        put("threadId", threadId)
        put("firstEntryId", firstEntryId)
        put("replyEntryId", replyEntryId)
        put("delivery", delivery)
        put("status", status)
        put("title", title)
        if let hop { object["hop"] = .number(Double(hop)) }
        put("callId", callId)
        put("error", error)
        return .object(object)
    }
}

/// Row identity and thread identity from upstream `agentComm.cjs`.
///
/// The outbound row id is `agent-outbound-<sha256>` over the sender id, the
/// target id, the request id (or nonce) and the row sequence, joined with one
/// NUL. Every row of an exchange shares `threadId = <rowId>@<seq>:agent-comm`.
public enum BotAgentCommIdentity {
    public static func outboundRowID(senderAgentID: String, targetID: String,
                                     requestID: String?, seq: Int64) -> String {
        let input = [senderAgentID, targetID, requestID ?? "", String(seq)].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "agent-outbound-" + digest
    }

    public static func threadID(rowID: String, seq: Int64?) -> String {
        if let seq { return "\(rowID)@\(seq):agent-comm" }
        return "\(rowID):agent-comm"
    }

    /// `t<turn>u`, with a numeric suffix on the rare collision inside one turn.
    public static func turnRowID(turn: Int, existingIDs: Set<String> = []) -> String {
        let normalized = max(0, turn)
        var id = "t\(normalized)u"
        var suffix = 2
        while existingIDs.contains(id) {
            id = "t\(normalized)u\(suffix)"
            suffix += 1
        }
        return id
    }
}

/// Aggregated rendering data for a run of agent-comm rows, mirroring the
/// upstream `summarizeCommRows` helper (`single` / `fanout` / `thread`).
public enum BotAgentCommSummaryKind: String, Codable, Sendable, Equatable {
    case single
    case fanout
    case thread
}

public struct BotAgentCommSummary: Codable, Sendable, Equatable {
    public var kind: BotAgentCommSummaryKind
    /// Present only for `single`; it names the one row's direction.
    public var direction: BotAgentCommDirection?
    /// Present only for `single`; the peer the row was sent to or received from.
    public var peer: BotAgentRef?
    public var peers: [BotAgentRef]
    public var messageCount: Int

    public init(kind: BotAgentCommSummaryKind,
                direction: BotAgentCommDirection? = nil,
                peer: BotAgentRef? = nil,
                peers: [BotAgentRef],
                messageCount: Int) {
        self.kind = kind
        self.direction = direction
        self.peer = peer
        self.peers = peers
        self.messageCount = messageCount
    }
}

public enum BotAgentCommSummarizer {
    /// Upstream `isCommRow`: a message row carrying `fromAgent` or `toAgent`.
    public static func isCommRow(_ row: BotRow) -> Bool {
        guard row.kind == .message || row.kind == .sendMessage else { return false }
        let fields = row.body.additionalProperties
        return fields["fromAgent"] != nil || fields["toAgent"] != nil
    }

    public static func summarize(_ rows: [BotRow]) -> BotAgentCommSummary? {
        summarize(rows.compactMap { row -> (from: BotAgentRef?, to: BotAgentRef?)? in
            guard isCommRow(row) else { return nil }
            let fields = row.body.additionalProperties
            return (BotAgentRef(json: fields["fromAgent"]),
                    BotAgentRef(json: fields["toAgent"]))
        })
    }

    /// Raw-row variant for hosts that build summary data before projecting.
    public static func summarize(_ rows: [[String: BotJSONValue]]) -> BotAgentCommSummary? {
        summarize(rows.compactMap { object -> (from: BotAgentRef?, to: BotAgentRef?)? in
            let kind = object["kind"]?.stringValue
            guard kind == nil || kind == "message" || kind == "sendMessage" else { return nil }
            let from = BotAgentRef(json: object["fromAgent"])
            let to = BotAgentRef(json: object["toAgent"])
            guard from != nil || to != nil else { return nil }
            return (from, to)
        })
    }

    private static func summarize(
        _ rows: [(from: BotAgentRef?, to: BotAgentRef?)]
    ) -> BotAgentCommSummary? {
        guard !rows.isEmpty else { return nil }
        let messages = rows.map { row -> (direction: BotAgentCommDirection, peer: BotAgentRef?) in
            if let from = row.from { return (.inbound, from) }
            return (.outbound, row.to)
        }
        var peers: [BotAgentRef] = []
        var seen: Set<String> = []
        for message in messages {
            guard let peer = message.peer else { continue }
            let key = !peer.id.isEmpty ? peer.id : peer.name
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            peers.append(peer)
        }
        if messages.count == 1 {
            return BotAgentCommSummary(
                kind: .single, direction: messages[0].direction,
                peer: messages[0].peer, peers: peers, messageCount: 1)
        }
        let allOutbound = messages.allSatisfy { $0.direction == .outbound }
        if allOutbound, peers.count >= 2, messages.count == peers.count {
            return BotAgentCommSummary(kind: .fanout, peers: peers, messageCount: messages.count)
        }
        return BotAgentCommSummary(kind: .thread, peers: peers, messageCount: messages.count)
    }
}

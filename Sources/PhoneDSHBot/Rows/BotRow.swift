// SPDX-License-Identifier: MIT

import Foundation

public enum BotRowKind: String, Codable, Sendable {
    case message
    case sendMessage
    case event
}

public enum BotRowBodyType: String, Codable, Sendable {
    case text
    case widget
    case attachment
    case approval
    case automation
    case notice
    case deleted
}

public enum BotWidgetCardType: String, Codable, Sendable, CaseIterable {
    case question
    case steps
    case task
    case document
    case progress
    case checklist
    case link
    case table
    case callout
    case info
    case payload
    case library

    public var isPhoneP0: Bool {
        switch self {
        case .question, .steps, .task, .document, .progress, .checklist, .link:
            return true
        case .table, .callout, .info, .payload, .library:
            return false
        }
    }
}

public struct BotRowBody: Codable, Sendable, Equatable {
    public var type: BotRowBodyType
    public var cardType: BotWidgetCardType?
    public var cardKey: String?
    public var additionalProperties: [String: BotJSONValue]

    public init(type: BotRowBodyType, cardType: BotWidgetCardType? = nil, cardKey: String? = nil,
                additionalProperties: [String: BotJSONValue] = [:]) {
        self.type = type
        self.cardType = cardType
        self.cardKey = cardKey
        self.additionalProperties = additionalProperties
    }

    public subscript(key: String) -> BotJSONValue? {
        get { additionalProperties[key] }
        set { additionalProperties[key] = newValue }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        type = try container.decode(BotRowBodyType.self, forKey: Key(stringValue: "type")!)
        cardType = try container.decodeIfPresent(BotWidgetCardType.self, forKey: Key(stringValue: "cardType")!)
        cardKey = try container.decodeIfPresent(String.self, forKey: Key(stringValue: "cardKey")!)
        var fields: [String: BotJSONValue] = [:]
        for key in container.allKeys where !["type", "cardType", "cardKey"].contains(key.stringValue) {
            fields[key.stringValue] = try container.decode(BotJSONValue.self, forKey: key)
        }
        additionalProperties = fields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(type, forKey: Key(stringValue: "type")!)
        try container.encodeIfPresent(cardType, forKey: Key(stringValue: "cardType")!)
        try container.encodeIfPresent(cardKey, forKey: Key(stringValue: "cardKey")!)
        for (key, value) in additionalProperties where !["type", "cardType", "cardKey"].contains(key) {
            try container.encode(value, forKey: Key(stringValue: key)!)
        }
    }
}

public struct BotRowProvenance: Codable, Sendable, Equatable {
    public var eventIDs: [String]
    public var trust: String
    public var tainted: Bool

    public init(eventIDs: [String], trust: String, tainted: Bool) {
        self.eventIDs = eventIDs
        self.trust = trust
        self.tainted = tainted
    }

    public static let ownerDirect = "owner_direct"
    public static let model = "model"
    public static let projector = "projector"
}

public struct BotRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var botID: String
    public var seq: Int
    public var updatedSeq: Int
    public var kind: BotRowKind
    public var role: String?
    public var body: BotRowBody
    public var provenance: BotRowProvenance
    public var streaming: Bool
    public var createdAt: Int64
    public internal(set) var chatActionNonce: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, botID, seq, updatedSeq, kind, role, body, provenance, streaming, createdAt
    }

    public init(id: String, botID: String, seq: Int, updatedSeq: Int, kind: BotRowKind,
                role: String? = nil, body: BotRowBody, provenance: BotRowProvenance,
                streaming: Bool = false, createdAt: Int64) {
        self.id = id
        self.botID = botID
        self.seq = seq
        self.updatedSeq = updatedSeq
        self.kind = kind
        self.role = role
        self.body = body
        self.provenance = provenance
        self.streaming = streaming
        self.createdAt = createdAt
    }

    public func replacing(body: BotRowBody? = nil, updatedSeq: Int? = nil,
                          provenance: BotRowProvenance? = nil, streaming: Bool? = nil) -> BotRow {
        var row = self
        row.updatedSeq = updatedSeq ?? self.updatedSeq
        row.body = body ?? self.body
        row.provenance = provenance ?? self.provenance
        row.streaming = streaming ?? self.streaming
        return row
    }
}

public struct BotRowBatch: Codable, Sendable, Equatable {
    public var rows: [BotRow]
    public var deletes: [String]
    public var cursor: Int
    public var reset: Bool

    public init(rows: [BotRow], deletes: [String], cursor: Int, reset: Bool) {
        self.rows = rows
        self.deletes = deletes
        self.cursor = cursor
        self.reset = reset
    }
}

public typealias Row = BotRow
public typealias RowBatch = BotRowBatch

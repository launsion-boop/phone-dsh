// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public typealias BotJSONValue = JSONValue

public enum BotEventOrigin: Codable, Sendable, Equatable {
    case dsh(sessionId: String, seq: Int)
    case local(source: String)

    private enum CodingKeys: String, CodingKey { case kind, sessionId, seq, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "dsh":
            guard container.allKeys.allSatisfy({ [.kind, .sessionId, .seq].contains($0) }) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                       debugDescription: "unknown DSH origin member")
            }
            self = .dsh(sessionId: try container.decode(String.self, forKey: .sessionId),
                        seq: try container.decode(Int.self, forKey: .seq))
        case "local":
            guard container.allKeys.allSatisfy({ [.kind, .source].contains($0) }) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                       debugDescription: "unknown local origin member")
            }
            self = .local(source: try container.decode(String.self, forKey: .source))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "unknown origin kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .dsh(sessionId, seq):
            try container.encode("dsh", forKey: .kind)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(seq, forKey: .seq)
        case let .local(source):
            try container.encode("local", forKey: .kind)
            try container.encode(source, forKey: .source)
        }
    }
}

public struct BotPrincipal: Codable, Sendable, Equatable {
    public let botId: String?
    public let sessionId: String?
    public let kind: String
    public let capabilities: [String]

    public init(botId: String?, sessionId: String?, kind: String, capabilities: [String] = []) {
        self.botId = botId
        self.sessionId = sessionId
        self.kind = kind
        self.capabilities = capabilities
    }
}

public struct BotEventBatchRef: Codable, Sendable, Equatable {
    public let id: String
    public let index: Int
    public let total: Int

    public init(id: String, index: Int, total: Int) {
        self.id = id
        self.index = index
        self.total = total
    }
}

public struct BotEvent: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let type: String
    public let eventId: String
    public let commitSeq: Int?
    public let time: Int64
    public let origin: BotEventOrigin
    public let traceId: String
    public let principal: BotPrincipal
    public let causationId: String?
    public let correlationId: String?
    public let turnId: String?
    public let runId: String?
    public let attempt: Int?
    public let batch: BotEventBatchRef?
    public let ignorable: Bool?
    public let data: BotJSONValue

    public var id: String { eventId }

    public init(schemaVersion: Int = Self.currentSchemaVersion, type: String, eventId: String,
                commitSeq: Int? = nil, time: Int64, origin: BotEventOrigin, traceId: String,
                principal: BotPrincipal, causationId: String?, correlationId: String?,
                turnId: String? = nil, runId: String? = nil, attempt: Int? = nil,
                batch: BotEventBatchRef? = nil, ignorable: Bool? = nil, data: BotJSONValue) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.eventId = eventId
        self.commitSeq = commitSeq
        self.time = time
        self.origin = origin
        self.traceId = traceId
        self.principal = principal
        self.causationId = causationId
        self.correlationId = correlationId
        self.turnId = turnId
        self.runId = runId
        self.attempt = attempt
        self.batch = batch
        self.ignorable = ignorable
        self.data = data
    }
}

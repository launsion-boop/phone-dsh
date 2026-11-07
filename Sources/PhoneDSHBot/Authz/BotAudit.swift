// SPDX-License-Identifier: MIT

import Foundation

public struct BotAuditPrincipal: Codable, Sendable, Equatable {
    public let botId: String?
    public let sessionId: String?
    public let kind: String
    public let sessionKind: BotSessionKind?
    public let certain: Bool

    public init(botId: String?, sessionId: String? = nil, kind: String,
                sessionKind: BotSessionKind? = nil, certain: Bool) {
        self.botId = botId
        self.sessionId = sessionId
        self.kind = kind
        self.sessionKind = sessionKind
        self.certain = certain
    }
}

public struct BotAuditEffect: Codable, Sendable, Equatable {
    public let tool: String
    public let operation: String
    public let resourceDigest: String
    public let argsDigest: String?
    public let mutability: BotToolMutability
    public let policy: BotToolPolicy

    public init(tool: String, operation: String, resourceDigest: String, argsDigest: String?,
                mutability: BotToolMutability, policy: BotToolPolicy) {
        self.tool = tool
        self.operation = operation
        self.resourceDigest = resourceDigest
        self.argsDigest = argsDigest
        self.mutability = mutability
        self.policy = policy
    }
}

public struct BotAuditGrant: Codable, Sendable, Equatable {
    public let id: String
    public let scope: BotGrantScope
    public let decision: BotGrantDecision
    public let resourceDigest: String

    public init(id: String, scope: BotGrantScope, decision: BotGrantDecision, resourceDigest: String) {
        self.id = id
        self.scope = scope
        self.decision = decision
        self.resourceDigest = resourceDigest
    }
}

public struct BotAuditRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let at: Int64
    public let event: String
    public let source: String
    public let decision: BotGrantDecision
    public let principal: BotAuditPrincipal
    public let effects: [BotAuditEffect]
    public let grants: [BotAuditGrant]
    public let reason: String

    public init(at: Int64, event: String = "tool-execution", source: String,
                decision: BotGrantDecision, principal: BotAuditPrincipal,
                effects: [BotAuditEffect] = [], grants: [BotAuditGrant] = [], reason: String) {
        schemaVersion = 1
        self.at = at
        self.event = event
        self.source = source
        self.decision = decision
        self.principal = principal
        self.effects = effects
        self.grants = grants
        self.reason = reason
    }
}

public protocol BotAuditRecording: Actor {
    @discardableResult
    func append(_ record: BotAuditRecord) async -> Bool
}

public actor BotAuditLog: BotAuditRecording {
    private let eventLog: any BotEventLog
    private let encoder: JSONEncoder

    public init(eventLog: any BotEventLog) {
        self.eventLog = eventLog
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    nonisolated var domainStore: SQLiteDomainStore? { eventLog as? SQLiteDomainStore }

    @discardableResult
    public func append(_ record: BotAuditRecord) async -> Bool {
        do {
            let data = try BotJSONValue.parse(encoder.encode(record))
            guard case .object = data else { return false }
            let type: String
            let origin: BotEventOrigin
            switch record.event {
            case "tool-execution":
                type = "effect.attempted"
                origin = .local(source: "effect-runner")
            case "grant.added", "grant.consumed", "grant.revoked":
                type = record.event
                origin = .local(source: "ipc")
            default:
                return false
            }
            let eventId = "authz-\(UUID().uuidString.lowercased())"
            let event = BotEvent(type: type, eventId: eventId, time: record.at, origin: origin,
                                 traceId: "trace-\(UUID().uuidString.lowercased())",
                                 principal: BotPrincipal(botId: record.principal.botId,
                                                         sessionId: record.principal.sessionId,
                                                         kind: Self.principalKind(record.principal)),
                                 causationId: nil, correlationId: nil, data: data)
            _ = try await eventLog.append(event)
            return true
        } catch {
            return false
        }
    }

    private static func principalKind(_ principal: BotAuditPrincipal) -> String {
        if let sessionKind = principal.sessionKind { return sessionKind.rawValue }
        switch principal.kind {
        case "chat", "task", "routine", "team", "proactive", "watchdog", "ipc":
            return principal.kind
        case "model":
            return "chat"
        default:
            return "ipc"
        }
    }
}

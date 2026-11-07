// SPDX-License-Identifier: MIT

import Foundation

public enum BotGrantRecoveryError: Error, Sendable, Equatable {
    case missingSnapshot
    case invalidSnapshot(String)
    case unsupportedSnapshot(Int)
    case replayFailed(String)
}

struct BotGrantSnapshot: Codable {
    static let eventType = "authz.grant_snapshot"

    let grants: [Entry]

    struct Entry: Codable {
        let grantId: String
        let botId: String
        let tool: String
        let operation: String
        let canonicalResource: String
        let scope: BotGrantScope
        let sessionId: String?
        let expiresAt: Int64?
        let createdAt: Int64
        let source: String
        let decision: BotGrantDecision

        private static let allowedKeys: Set<String> = [
            "grantId", "botId", "tool", "operation", "canonicalResource", "scope",
            "sessionId", "expiresAt", "createdAt", "source", "decision",
        ]

        private enum CodingKeys: String, CodingKey {
            case grantId, botId, tool, operation, canonicalResource, scope
            case sessionId, expiresAt, createdAt, source, decision
        }

        init(grant: BotGrant) {
            grantId = grant.id
            botId = grant.botId
            tool = grant.tool
            operation = grant.operation
            canonicalResource = grant.resource
            scope = grant.scope
            sessionId = grant.sessionId
            expiresAt = grant.expiresAt
            createdAt = grant.createdAt
            source = grant.source
            decision = grant.decision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.allKeys.count == Self.allowedKeys.count,
                  container.allKeys.allSatisfy({ Self.allowedKeys.contains($0.stringValue) }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .grantId, in: container,
                    debugDescription: "grant snapshot entries require exactly the frozen grant fields")
            }
            grantId = try container.decode(String.self, forKey: .grantId)
            botId = try container.decode(String.self, forKey: .botId)
            tool = try container.decode(String.self, forKey: .tool)
            operation = try container.decode(String.self, forKey: .operation)
            canonicalResource = try container.decode(String.self, forKey: .canonicalResource)
            scope = try container.decode(BotGrantScope.self, forKey: .scope)
            sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
            expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
            createdAt = try container.decode(Int64.self, forKey: .createdAt)
            source = try container.decode(String.self, forKey: .source)
            decision = try container.decode(BotGrantDecision.self, forKey: .decision)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(grantId, forKey: .grantId)
            try container.encode(botId, forKey: .botId)
            try container.encode(tool, forKey: .tool)
            try container.encode(operation, forKey: .operation)
            try container.encode(canonicalResource, forKey: .canonicalResource)
            try container.encode(scope, forKey: .scope)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(expiresAt, forKey: .expiresAt)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(source, forKey: .source)
            try container.encode(decision, forKey: .decision)
        }

        func validatedGrant() throws -> BotGrant {
            let trimmedID = grantId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBot = botId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, trimmedBot == botId, !trimmedBot.isEmpty,
                  trimmedTool == tool, !trimmedTool.isEmpty,
                  trimmedOperation == operation, !trimmedOperation.isEmpty,
                  trimmedSource == source, !trimmedSource.isEmpty,
                  BotResourceNormalizer.normalize(canonicalResource) == canonicalResource,
                  !canonicalResource.isEmpty, createdAt >= 0,
                  normalizedSession == sessionId,
                  normalizedSession == nil || normalizedSession?.isEmpty == false else {
                throw BotGrantRecoveryError.invalidSnapshot("grant \(grantId) is not canonical")
            }
            return BotGrant(id: grantId, botId: botId, tool: tool, operation: operation,
                            resource: canonicalResource, scope: scope, sessionId: sessionId,
                            expiresAt: expiresAt, createdAt: createdAt, source: source,
                            decision: decision)
        }
    }

    private enum CodingKeys: String, CodingKey { case grants }

    init(grants: [BotGrant]) {
        self.grants = grants.map(Entry.init(grant:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys == [.grants] else {
            throw DecodingError.dataCorruptedError(
                forKey: .grants, in: container,
                debugDescription: "grant snapshot requires exactly one grants member")
        }
        grants = try container.decode([Entry].self, forKey: .grants)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(grants, forKey: .grants)
    }

    func validatedGrants(now: Int64) throws -> [BotGrant] {
        guard grants.count <= BotGrantStore.maximumGrants else {
            throw BotGrantRecoveryError.invalidSnapshot("grant snapshot exceeds the grant limit")
        }
        var identifiers: Set<String> = []
        let restored = try grants.map { entry -> BotGrant in
            let grant = try entry.validatedGrant()
            guard identifiers.insert(grant.id).inserted else {
                throw BotGrantRecoveryError.invalidSnapshot("duplicate grant id \(grant.id)")
            }
            return grant
        }
        return restored.filter { $0.expiresAt == nil || $0.expiresAt! > now }
    }

    static func event(grants: [BotGrant], at timestamp: Int64) throws -> BotEvent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try BotJSONValue.parse(encoder.encode(BotGrantSnapshot(grants: grants)))
        return BotEvent(type: eventType,
                        eventId: "authz-snapshot-\(UUID().uuidString.lowercased())",
                        time: timestamp, origin: .local(source: "ipc"),
                        traceId: "trace-\(UUID().uuidString.lowercased())",
                        principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
                        causationId: nil, correlationId: nil, ignorable: true, data: data)
    }

    static func decode(_ event: BotEvent, now: Int64) throws -> [BotGrant] {
        guard event.schemaVersion == BotEvent.currentSchemaVersion else {
            throw BotGrantRecoveryError.unsupportedSnapshot(event.schemaVersion)
        }
        do {
            let snapshot = try JSONDecoder().decode(BotGrantSnapshot.self, from: event.data.encoded())
            return try snapshot.validatedGrants(now: now)
        } catch let error as BotGrantRecoveryError {
            throw error
        } catch {
            throw BotGrantRecoveryError.invalidSnapshot(String(describing: error))
        }
    }
}

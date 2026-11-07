// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotResolvedToolCall: Sendable, Equatable {
    public let sessionId: String
    public let callId: String
    public let agentId: String
    public let principal: BotGatewayPrincipal
    public let attribution: BotAttribution

    public init?(sessionId: String, callId: String, agentId: String,
                 principal: BotGatewayPrincipal, attribution: BotAttribution) {
        guard sessionId == principal.sessionId, attribution.sessionId == principal.sessionId,
              callId == attribution.callId, agentId == principal.botId,
              attribution.incarnation == principal.incarnation else { return nil }
        self.sessionId = sessionId
        self.callId = callId
        self.agentId = agentId
        self.principal = principal
        self.attribution = attribution
    }
}

public enum BotGatewayError: Error, Sendable, Equatable {
    case unknownSession
}

public actor BotGateway {
    public static let chatTTLMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    public static let ephemeralTTLMilliseconds: Int64 = 12 * 60 * 60 * 1_000

    public let tokens: BotTokenRegistry
    public let attribution: BotAttributionRegistry

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                tokenTTLMilliseconds: Int64 = BotGateway.ephemeralTTLMilliseconds,
                attributionTTLMilliseconds: Int64 = BotAttributionRegistry.defaultTTLMilliseconds,
                maximumTokens: Int = BotTokenRegistry.defaultMaximumTokens,
                maximumAttributions: Int = BotAttributionRegistry.defaultMaximumEntries) {
        tokens = BotTokenRegistry(now: now, defaultTTLMilliseconds: tokenTTLMilliseconds,
                                  maximumTokens: maximumTokens)
        attribution = BotAttributionRegistry(now: now, ttlMilliseconds: attributionTTLMilliseconds,
                                             maximumEntries: maximumAttributions)
    }

    @discardableResult
    public func issueSession(botId: String, sessionId: String, kind: BotSessionKind,
                             capabilities: [String] = [], ttlMilliseconds: Int64? = nil) async throws -> BotGatewayPrincipal {
        let ttl = ttlMilliseconds ?? (kind == .chat ? Self.chatTTLMilliseconds : Self.ephemeralTTLMilliseconds)
        let issued = try await tokens.issueSession(botId: botId, sessionId: sessionId, kind: kind,
                                                   capabilities: capabilities, ttlMilliseconds: ttl)
        await discardStaleAttributions(sessionId: issued.principal.sessionId)
        return issued.principal
    }

    @discardableResult
    public func issueToken(botId: String, sessionId: String, kind: BotSessionKind,
                           capabilities: [String] = [], expiresAt: Int64? = nil,
                           ttlMilliseconds: Int64? = nil) async throws -> BotIssuedToken {
        let issued = try await tokens.issue(botId: botId, sessionId: sessionId, kind: kind,
                                            capabilities: capabilities, expiresAt: expiresAt,
                                            ttlMilliseconds: ttlMilliseconds)
        await discardStaleAttributions(sessionId: issued.principal.sessionId)
        return issued
    }

    @discardableResult
    public func registerToolCall(sessionId: String, callId: String, name: String,
                                 arguments: BotJSONValue = .object([:]), argsDigest: String? = nil,
                                 runtimeId: String, expiresAt: Int64? = nil,
                                 ttlMilliseconds: Int64? = nil) async throws -> BotAttribution {
        guard let principal = await tokens.lookupSession(sessionId) else {
            throw BotGatewayError.unknownSession
        }
        return try await attribution.register(sessionId: sessionId, incarnation: principal.incarnation,
                                              callId: callId, name: Self.bareToolName(name),
                                              arguments: arguments, argsDigest: argsDigest,
                                              runtimeId: runtimeId, expiresAt: expiresAt,
                                              ttlMilliseconds: ttlMilliseconds)
    }

    /// Claims the one registration for `runtimeId` + tool name + argument
    /// digest. The tool name is part of the identity: a `bash` registration
    /// with the same argument digest must never be consumed by `write`.
    public func resolveToolCall(runtimeId: String, name: String,
                                argsDigest: String) async -> BotResolvedToolCall? {
        let bareName = Self.bareToolName(name)
        guard !runtimeId.isEmpty, !bareName.isEmpty, !argsDigest.isEmpty,
              let entry = try? await attribution.claimByDigest(name: bareName,
                                                               argsDigest: argsDigest,
                                                               runtimeId: runtimeId),
              let principal = await tokens.lookupSession(entry.sessionId),
              entry.incarnation == principal.incarnation else { return nil }
        return BotResolvedToolCall(sessionId: entry.sessionId, callId: entry.callId,
                                   agentId: principal.botId, principal: principal,
                                   attribution: entry)
    }

    public func resolveToolCall(runtimeId: String, name: String,
                                arguments: BotJSONValue) async -> BotResolvedToolCall? {
        guard let digest = try? BotArgumentsDigest.string(for: arguments) else { return nil }
        return await resolveToolCall(runtimeId: runtimeId, name: name, argsDigest: digest)
    }

    /// Revokes every pending attribution for one runtime generation. A Worker
    /// restart calls this before switching generation so no old call can be
    /// claimed by the new Worker.
    @discardableResult
    public func cancelToolCalls(runtimeId: String) async -> Int {
        await attribution.cancelRuntime(runtimeId: runtimeId)
    }

    @discardableResult
    public func cancelToolCall(id: String) async -> Bool {
        await attribution.cancel(id: id)
    }

    /// The MCP client exposes tools as `mcp__<server>__<name>`; attribution is
    /// keyed by the bare name so a registration and its claim agree.
    static func bareToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }

    private func discardStaleAttributions(sessionId: String) async {
        while let current = await tokens.lookupSession(sessionId) {
            _ = await attribution.revokeStale(sessionId: sessionId,
                                              currentIncarnation: current.incarnation)
            let settled = await tokens.lookupSession(sessionId)
            if settled?.incarnation == current.incarnation { return }
        }
        _ = await attribution.revokeSession(sessionId)
    }
}

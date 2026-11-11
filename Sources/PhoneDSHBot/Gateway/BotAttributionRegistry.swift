// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotAttribution: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let incarnation: String
    public let callId: String
    public let name: String
    public let argsDigest: String
    public let runtimeId: String?
    public let createdAt: Int64
    public let expiresAt: Int64

    public init(id: String, sessionId: String, incarnation: String, callId: String, name: String,
                argsDigest: String, runtimeId: String?, createdAt: Int64, expiresAt: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.incarnation = incarnation
        self.callId = callId
        self.name = name
        self.argsDigest = argsDigest
        self.runtimeId = runtimeId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum BotAttributionError: Error, Sendable, Equatable {
    case invalidInput(String)
    case duplicate
    case full
}

public actor BotAttributionRegistry {
    /// One registration must outlive the 300 s approval wait plus transport
    /// slack; otherwise an approval card approved near the deadline could
    /// never be claimed. The runtime still prunes expired entries and a Worker
    /// restart invalidates every registration through a new generation.
    public static let defaultTTLMilliseconds: Int64 = BotApprovalCoordinator.defaultTimeoutMilliseconds + 30_000
    public static let defaultMaximumEntries = 4_096

    private let now: @Sendable () -> Int64
    private let ttlMilliseconds: Int64
    private let maximumEntries: Int
    private var entries: [String: BotAttribution] = [:]

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                ttlMilliseconds: Int64 = BotAttributionRegistry.defaultTTLMilliseconds,
                maximumEntries: Int = BotAttributionRegistry.defaultMaximumEntries) {
        precondition(ttlMilliseconds > 0, "ttlMilliseconds must be positive")
        precondition(maximumEntries > 0, "maximumEntries must be positive")
        self.now = now
        self.ttlMilliseconds = ttlMilliseconds
        self.maximumEntries = maximumEntries
    }

    public var count: Int {
        prune()
        return entries.count
    }

    @discardableResult
    public func register(sessionId: String, incarnation: String, callId: String, name: String,
                         arguments: BotJSONValue = .object([:]), argsDigest: String? = nil,
                         runtimeId: String? = nil, expiresAt: Int64? = nil,
                         ttlMilliseconds: Int64? = nil) throws -> BotAttribution {
        let session = try Self.identifier(sessionId, name: "sessionId")
        let generation = try Self.identifier(incarnation, name: "incarnation")
        let call = try Self.identifier(callId, name: "callId")
        let toolName = try Self.identifier(name, name: "name")
        let runtime = try Self.optionalIdentifier(runtimeId, name: "runtimeId")
        let digest = try argsDigest.map(BotArgumentsDigest.validated)
            ?? BotArgumentsDigest.string(for: arguments)
        let timestamp = now()
        let expiry: Int64
        if let expiresAt {
            expiry = expiresAt
        } else {
            let ttl = ttlMilliseconds ?? self.ttlMilliseconds
            guard ttl > 0 else { throw BotAttributionError.invalidInput("ttlMilliseconds") }
            let result = timestamp.addingReportingOverflow(ttl)
            guard !result.overflow else { throw BotAttributionError.invalidInput("expiresAt") }
            expiry = result.partialValue
        }
        guard expiry > timestamp else { throw BotAttributionError.invalidInput("expiresAt") }
        prune()
        if entries.values.contains(where: {
            $0.sessionId == session && $0.incarnation == generation && $0.argsDigest == digest
                && $0.name == toolName && $0.runtimeId == runtime
        }) {
            throw BotAttributionError.duplicate
        }
        guard entries.count < maximumEntries else { throw BotAttributionError.full }
        let entry = BotAttribution(id: Self.randomHexString(byteCount: 16), sessionId: session,
                                   incarnation: generation, callId: call, name: toolName,
                                   argsDigest: digest, runtimeId: runtime,
                                   createdAt: timestamp, expiresAt: expiry)
        entries[entry.id] = entry
        return entry
    }

    public func claim(sessionId: String, name: String, arguments: BotJSONValue = .object([:]),
                      argsDigest: String? = nil, runtimeId: String?? = nil) throws -> BotAttribution? {
        let session = try Self.identifier(sessionId, name: "sessionId")
        let toolName = try Self.identifier(name, name: "name")
        let digest = try argsDigest.map(BotArgumentsDigest.validated)
            ?? BotArgumentsDigest.string(for: arguments)
        let runtime = try runtimeId.map { try Self.optionalIdentifier($0, name: "runtimeId") }
        prune()
        let matches = entries.values.filter {
            $0.sessionId == session && $0.name == toolName && $0.argsDigest == digest
                && (runtime == nil || $0.runtimeId == runtime!)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        entries.removeValue(forKey: match.id)
        return match
    }

    public func claimByDigest(name: String? = nil, arguments: BotJSONValue = .object([:]),
                              argsDigest: String? = nil, runtimeId: String?? = nil) throws -> BotAttribution? {
        let toolName = try name.map { try Self.identifier($0, name: "name") }
        let digest = try argsDigest.map(BotArgumentsDigest.validated)
            ?? BotArgumentsDigest.string(for: arguments)
        let runtime = try runtimeId.map { try Self.optionalIdentifier($0, name: "runtimeId") }
        prune()
        let matches = entries.values.filter {
            (toolName == nil || $0.name == toolName) && $0.argsDigest == digest
                && (runtime == nil || $0.runtimeId == runtime!)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        entries.removeValue(forKey: match.id)
        return match
    }

    public func get(id: String) -> BotAttribution? {
        prune()
        return entries[id]
    }

    /// Extends one live registration without re-publishing it.
    ///
    /// A background job outlives the `bash` tool call that started it, but the
    /// original registration still has to authorize the job's `/v1/http`
    /// writes. Refreshing the same id keeps the attribution stable: no second
    /// entry appears, and an old cancelled generation can never be revived.
    /// `maximumExpiry` caps the extension at the session credential's expiry.
    /// A request that would shorten the current lifetime is ignored.
    @discardableResult
    public func refresh(id: String, ttlMilliseconds: Int64? = nil,
                        maximumExpiry: Int64? = nil) -> BotAttribution? {
        prune()
        guard let entry = entries[id] else { return nil }
        let timestamp = now()
        let ttl = ttlMilliseconds ?? self.ttlMilliseconds
        guard ttl > 0 else { return entry }
        let sum = timestamp.addingReportingOverflow(ttl)
        guard !sum.overflow else { return entry }
        var expiry = sum.partialValue
        if let maximumExpiry { expiry = min(expiry, maximumExpiry) }
        guard expiry > entry.expiresAt else { return entry }
        let refreshed = BotAttribution(
            id: entry.id, sessionId: entry.sessionId, incarnation: entry.incarnation,
            callId: entry.callId, name: entry.name, argsDigest: entry.argsDigest,
            runtimeId: entry.runtimeId, createdAt: entry.createdAt, expiresAt: expiry)
        entries[id] = refreshed
        return refreshed
    }

    @discardableResult
    public func cancel(id: String) -> Bool {
        entries.removeValue(forKey: id) != nil
    }

    func revokeStale(sessionId: String, currentIncarnation: String) -> Int {
        let ids = entries.values.filter {
            $0.sessionId == sessionId && $0.incarnation != currentIncarnation
        }.map(\.id)
        for id in ids { entries.removeValue(forKey: id) }
        return ids.count
    }

    func revokeSession(_ sessionId: String) -> Int {
        let ids = entries.values.filter { $0.sessionId == sessionId }.map(\.id)
        for id in ids { entries.removeValue(forKey: id) }
        return ids.count
    }

    func cancelRuntime(runtimeId: String) -> Int {
        let ids = entries.values.filter { $0.runtimeId == runtimeId }.map(\.id)
        for id in ids { entries.removeValue(forKey: id) }
        return ids.count
    }

    public func pendingCount(runtimeId: String? = nil) -> Int {
        prune()
        guard let runtimeId else { return entries.count }
        return entries.values.filter { $0.runtimeId == runtimeId }.count
    }

    @discardableResult
    public func prune() -> Int {
        let timestamp = now()
        let ids = entries.values.filter { $0.expiresAt <= timestamp }.map(\.id)
        for id in ids { entries.removeValue(forKey: id) }
        return ids.count
    }

    private static func identifier(_ value: String, name: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 256 else { throw BotAttributionError.invalidInput(name) }
        return text
    }

    private static func optionalIdentifier(_ value: String?, name: String) throws -> String? {
        guard let value else { return nil }
        return try identifier(value, name: name)
    }

    private static func randomHexString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }
}

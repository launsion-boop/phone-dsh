// SPDX-License-Identifier: MIT

import Foundation

public protocol BotEventLog: Actor {
    @discardableResult
    func append(_ event: BotEvent) async throws -> Int
    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent]
}

public struct BotEffect: Codable, Sendable, Equatable, Identifiable {
    public let effectKey: String
    public let kind: String
    public let operation: String
    public let target: String
    public let canonicalResource: String
    public let argsDigest: String
    public let payloadDigest: String
    public let logicalKey: String
    public let idempotent: Bool
    public let retryPolicy: String
    public let maxAttempts: Int
    public let generation: Int
    public let notBefore: Int64?

    public var id: String { effectKey }

    public init(effectKey: String, kind: String = "generic", operation: String,
                target: String? = nil, canonicalResource: String, argsDigest: String,
                payloadDigest: String? = nil, logicalKey: String, idempotent: Bool,
                retryPolicy: String? = nil, maxAttempts: Int? = nil,
                generation: Int = 1, notBefore: Int64? = nil) {
        self.effectKey = effectKey
        self.kind = kind
        self.operation = operation
        self.target = target ?? canonicalResource
        self.canonicalResource = canonicalResource
        self.argsDigest = argsDigest
        self.payloadDigest = payloadDigest ?? argsDigest
        self.logicalKey = logicalKey
        self.idempotent = idempotent
        let policy = retryPolicy ?? (idempotent ? "local-idempotent" : "local-nonidempotent")
        self.retryPolicy = policy
        self.maxAttempts = maxAttempts ?? Self.defaultMaxAttempts(policy: policy, idempotent: idempotent)
        self.generation = generation
        self.notBefore = notBefore
    }

    private static func defaultMaxAttempts(policy: String, idempotent: Bool) -> Int {
        switch policy {
        case "network-idempotent": return 5
        case "local-idempotent": return 2
        case "local-nonidempotent", "network-nonidempotent": return 1
        default: return idempotent ? 2 : 1
        }
    }
}

public struct BotEffectLease: Codable, Sendable, Equatable {
    public let effectKey: String
    public let attempt: Int
    public let leaseOwner: String
    public let leaseExpiresAt: Int64
    public let generation: Int

    public init(effectKey: String, attempt: Int, leaseOwner: String, leaseExpiresAt: Int64, generation: Int) {
        self.effectKey = effectKey
        self.attempt = attempt
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.generation = generation
    }
}

public protocol BotEffectOutbox: Actor {
    @discardableResult
    func enqueue(_ effect: BotEffect) async throws -> String
    func lease(owner: String, now: Int64) async throws -> BotEffectLease?
    func ack(_ lease: BotEffectLease, resultRef: String?) async throws
    func fail(_ lease: BotEffectLease, errorClass: String, reason: String) async throws
    func markNeedsReconciliation(_ effectKey: String, reason: String) async throws
}

public enum BotEventStoreError: Error, Sendable, Equatable {
    case unimplemented
}

public actor UnimplementedBotEventLog: BotEventLog {
    public init() {}
    public func append(_ event: BotEvent) async throws -> Int { throw BotEventStoreError.unimplemented }
    public func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] { [] }
}

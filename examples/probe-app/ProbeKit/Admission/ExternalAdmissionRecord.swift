// SPDX-License-Identifier: MIT
// External admission record (P06; spec/host/v1/external-admission.md,
// schema/admission-record.schema.json, revision external-admission-v1).
//
// The types here are the Swift consumer of the closed schema: the decoder
// rejects unknown members, a stage that carries a member its branch does not
// allow, and an `admissionId` that is not the derivation of the record's own
// identity fields. A file that fails this decoder is never interpreted.

import Foundation
import CryptoKit

public enum ExternalAdmissionStage: String, Codable, CaseIterable, Sendable {
    case admitted
    case dispatching
    case linked
    case completed
    case failed
    case expired
    case cancelled
    case unknown

    /// `admitted` or `dispatching`: the record still carries `text`.
    public var isPending: Bool { self == .admitted || self == .dispatching }
    /// No edge leaves these stages; the record is a dedupe tombstone.
    public var isTerminal: Bool { !isPending && self != .linked }
}

/// The limits of external-admission.md. `fixtures/external-admission-v1.json`
/// `limits` is compared with these in the journal test.
public enum ExternalAdmissionLimits {
    public static let maxTextBytes = 16_384
    public static let minTtlMs: Int64 = 1_000
    public static let maxTtlMs: Int64 = 604_800_000
    public static let maxPending = 256
    public static let maxEntries = 2_048
    public static let maxAttempts = 12
    public static let tombstoneMs: Int64 = 86_400_000
    public static let linkedTimeoutMs: Int64 = 1_209_600_000
    public static let passLimit = 16
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991
}

public struct ExternalAdmissionSource: Codable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case tonolinkVoice = "tonolink-voice"
        case cloudTask = "cloud-task"
    }

    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AdmissionCodingKey.self)
        try container.requireOnly(["kind", "id"])
        let rawKind = try container.decode(String.self, forKey: AdmissionCodingKey("kind"))
        guard let kind = Kind(rawValue: rawKind) else {
            throw container.corrupted("kind", "unknown source kind")
        }
        self.kind = kind
        self.id = try container.decode(String.self, forKey: AdmissionCodingKey("id"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AdmissionCodingKey.self)
        try container.encode(kind.rawValue, forKey: AdmissionCodingKey("kind"))
        try container.encode(id, forKey: AdmissionCodingKey("id"))
    }
}

/// Fixed at admission. Delivery never re-reads "the currently selected chat".
public enum ExternalAdmissionTarget: Codable, Equatable, Sendable {
    case dshSession(sessionId: String)
    case bot(botId: String)

    public var kind: String {
        switch self {
        case .dshSession: return "dsh-session"
        case .bot: return "bot"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AdmissionCodingKey.self)
        let kind = try container.decode(String.self, forKey: AdmissionCodingKey("kind"))
        switch kind {
        case "dsh-session":
            try container.requireOnly(["kind", "sessionId"])
            self = .dshSession(sessionId: try container.decode(
                String.self, forKey: AdmissionCodingKey("sessionId")))
        case "bot":
            try container.requireOnly(["kind", "botId"])
            self = .bot(botId: try container.decode(
                String.self, forKey: AdmissionCodingKey("botId")))
        default:
            throw container.corrupted("kind", "unknown target kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AdmissionCodingKey.self)
        try container.encode(kind, forKey: AdmissionCodingKey("kind"))
        switch self {
        case .dshSession(let sessionId):
            try container.encode(sessionId, forKey: AdmissionCodingKey("sessionId"))
        case .bot(let botId):
            try container.encode(botId, forKey: AdmissionCodingKey("botId"))
        }
    }

    var identifier: String {
        switch self {
        case .dshSession(let sessionId): return sessionId
        case .bot(let botId): return botId
        }
    }
}

public struct ExternalAdmissionRecord: Codable, Equatable, Sendable {
    public var v: Int
    public var admissionId: String
    public var principal: String
    public var source: ExternalAdmissionSource
    public var sourceRequestId: String
    public var target: ExternalAdmissionTarget
    public var contentSha256: String
    /// Present only while the record is pending.
    public var text: String?
    public var downstreamId: String
    public var admittedAtMs: Int64
    public var expiresAtMs: Int64
    public var stage: ExternalAdmissionStage
    public var attempts: Int
    public var lastError: String?
    public var nextAttemptAtMs: Int64?
    public var linkedAtMs: Int64?
    public var settledAtMs: Int64?
    public var reason: String?

    public init(v: Int = 1, admissionId: String, principal: String,
                source: ExternalAdmissionSource, sourceRequestId: String,
                target: ExternalAdmissionTarget, contentSha256: String, text: String?,
                downstreamId: String, admittedAtMs: Int64, expiresAtMs: Int64,
                stage: ExternalAdmissionStage, attempts: Int, lastError: String? = nil,
                nextAttemptAtMs: Int64? = nil, linkedAtMs: Int64? = nil,
                settledAtMs: Int64? = nil, reason: String? = nil) {
        self.v = v
        self.admissionId = admissionId
        self.principal = principal
        self.source = source
        self.sourceRequestId = sourceRequestId
        self.target = target
        self.contentSha256 = contentSha256
        self.text = text
        self.downstreamId = downstreamId
        self.admittedAtMs = admittedAtMs
        self.expiresAtMs = expiresAtMs
        self.stage = stage
        self.attempts = attempts
        self.lastError = lastError
        self.nextAttemptAtMs = nextAttemptAtMs
        self.linkedAtMs = linkedAtMs
        self.settledAtMs = settledAtMs
        self.reason = reason
    }

    private static let members: Set<String> = [
        "v", "admissionId", "principal", "source", "sourceRequestId", "target",
        "contentSha256", "text", "downstreamId", "admittedAtMs", "expiresAtMs", "stage",
        "attempts", "lastError", "nextAttemptAtMs", "linkedAtMs", "settledAtMs", "reason",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AdmissionCodingKey.self)
        try container.requireOnly(Self.members)
        func key(_ name: String) -> AdmissionCodingKey { AdmissionCodingKey(name) }
        // An explicit null is not "absent": the schema types every member.
        func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            container.contains(key(name)) ? try container.decode(type, forKey: key(name)) : nil
        }
        self.v = try container.decode(Int.self, forKey: key("v"))
        self.admissionId = try container.decode(String.self, forKey: key("admissionId"))
        self.principal = try container.decode(String.self, forKey: key("principal"))
        self.source = try container.decode(ExternalAdmissionSource.self, forKey: key("source"))
        self.sourceRequestId = try container.decode(String.self, forKey: key("sourceRequestId"))
        self.target = try container.decode(ExternalAdmissionTarget.self, forKey: key("target"))
        self.contentSha256 = try container.decode(String.self, forKey: key("contentSha256"))
        self.text = try optional(String.self, "text")
        self.downstreamId = try container.decode(String.self, forKey: key("downstreamId"))
        self.admittedAtMs = try container.decode(Int64.self, forKey: key("admittedAtMs"))
        self.expiresAtMs = try container.decode(Int64.self, forKey: key("expiresAtMs"))
        let rawStage = try container.decode(String.self, forKey: key("stage"))
        guard let stage = ExternalAdmissionStage(rawValue: rawStage) else {
            throw container.corrupted("stage", "unknown stage")
        }
        self.stage = stage
        self.attempts = try container.decode(Int.self, forKey: key("attempts"))
        self.lastError = try optional(String.self, "lastError")
        self.nextAttemptAtMs = try optional(Int64.self, "nextAttemptAtMs")
        self.linkedAtMs = try optional(Int64.self, "linkedAtMs")
        self.settledAtMs = try optional(Int64.self, "settledAtMs")
        self.reason = try optional(String.self, "reason")
        if let problem = validationProblem() {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: problem))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AdmissionCodingKey.self)
        func key(_ name: String) -> AdmissionCodingKey { AdmissionCodingKey(name) }
        try container.encode(v, forKey: key("v"))
        try container.encode(admissionId, forKey: key("admissionId"))
        try container.encode(principal, forKey: key("principal"))
        try container.encode(source, forKey: key("source"))
        try container.encode(sourceRequestId, forKey: key("sourceRequestId"))
        try container.encode(target, forKey: key("target"))
        try container.encode(contentSha256, forKey: key("contentSha256"))
        try container.encodeIfPresent(text, forKey: key("text"))
        try container.encode(downstreamId, forKey: key("downstreamId"))
        try container.encode(admittedAtMs, forKey: key("admittedAtMs"))
        try container.encode(expiresAtMs, forKey: key("expiresAtMs"))
        try container.encode(stage.rawValue, forKey: key("stage"))
        try container.encode(attempts, forKey: key("attempts"))
        try container.encodeIfPresent(lastError, forKey: key("lastError"))
        try container.encodeIfPresent(nextAttemptAtMs, forKey: key("nextAttemptAtMs"))
        try container.encodeIfPresent(linkedAtMs, forKey: key("linkedAtMs"))
        try container.encodeIfPresent(settledAtMs, forKey: key("settledAtMs"))
        try container.encodeIfPresent(reason, forKey: key("reason"))
    }

    /// The closed schema's field laws plus the identity law. `nil` means the
    /// record is a valid v1 record. The decoder and admission share this.
    public func validationProblem() -> String? {
        guard v == 1 else { return "unsupported record version" }
        guard AdmissionText.isLowerHex64(admissionId) else { return "invalid admissionId" }
        guard AdmissionText.isPrincipal(principal) else { return "invalid principal" }
        guard AdmissionText.isVisibleASCII(source.id, max: 128) else { return "invalid source.id" }
        guard AdmissionText.isVisibleASCII(sourceRequestId, max: 128) else {
            return "invalid sourceRequestId"
        }
        guard AdmissionText.isVisibleASCII(target.identifier, max: 256) else {
            return "invalid target"
        }
        guard AdmissionText.isLowerHex64(contentSha256) else { return "invalid contentSha256" }
        guard AdmissionText.isLowerUUIDv4(downstreamId) else { return "invalid downstreamId" }
        for value in [admittedAtMs, expiresAtMs, nextAttemptAtMs, linkedAtMs, settledAtMs] {
            if let value, value < 0 || value > ExternalAdmissionLimits.maxSafeInteger {
                return "timestamp out of range"
            }
        }
        guard attempts >= 0, attempts <= ExternalAdmissionLimits.maxAttempts else {
            return "attempts out of range"
        }
        if let lastError, !AdmissionText.isReasonCode(lastError) { return "invalid lastError" }
        if let reason, !AdmissionText.isReasonCode(reason) { return "invalid reason" }
        if stage.isPending {
            guard let text else { return "a pending record needs text" }
            let scalars = text.unicodeScalars.count
            guard scalars >= 1, scalars <= ExternalAdmissionLimits.maxTextBytes else {
                return "text length out of range"
            }
            guard linkedAtMs == nil, settledAtMs == nil, reason == nil else {
                return "member not allowed on a pending record"
            }
        } else if stage == .linked {
            guard text == nil, lastError == nil, nextAttemptAtMs == nil,
                  settledAtMs == nil, reason == nil else {
                return "member not allowed on a linked record"
            }
        } else {
            guard text == nil, lastError == nil, nextAttemptAtMs == nil else {
                return "member not allowed on a terminal record"
            }
            guard settledAtMs != nil else { return "a terminal record needs settledAtMs" }
        }
        guard admissionId == ExternalAdmissionPolicy.admissionId(
            principal: principal, source: source, sourceRequestId: sourceRequestId) else {
            return "admissionId is not the derivation of this record's identity"
        }
        return nil
    }
}

/// What a source hands to admission. `downstreamId` is chosen by the caller at
/// admission (a lowercase UUIDv4) and is never replaced afterwards.
public struct ExternalAdmissionRequest: Equatable, Sendable {
    public var principal: String
    public var source: ExternalAdmissionSource
    public var sourceRequestId: String
    public var target: ExternalAdmissionTarget
    public var text: String
    public var downstreamId: String
    public var expiresAtMs: Int64

    public init(principal: String, source: ExternalAdmissionSource, sourceRequestId: String,
                target: ExternalAdmissionTarget, text: String, downstreamId: String,
                expiresAtMs: Int64) {
        self.principal = principal
        self.source = source
        self.sourceRequestId = sourceRequestId
        self.target = target
        self.text = text
        self.downstreamId = downstreamId
        self.expiresAtMs = expiresAtMs
    }

    /// TTL of a TonoLink voice request (PC-20261116-external-admission §2.1).
    public static let tonoLinkVoiceTtlMs: Int64 = 86_400_000

    /// PC-20261116-external-admission §2.1: principal `local`, source
    /// `tonolink-voice` + SHA-256 of the board name, one wake-time UUIDv4 as
    /// both `sourceRequestId` and `downstreamId`, TTL 24 hours.
    public static func tonoLinkVoice(boardName: String, requestID: String,
                                     target: ExternalAdmissionTarget, text: String,
                                     nowMs: Int64) -> ExternalAdmissionRequest {
        ExternalAdmissionRequest(
            principal: "local",
            source: ExternalAdmissionSource(
                kind: .tonolinkVoice,
                id: ExternalAdmissionPolicy.sha256Hex(Data(boardName.utf8))),
            sourceRequestId: requestID, target: target, text: text,
            downstreamId: requestID, expiresAtMs: nowMs + tonoLinkVoiceTtlMs)
    }
}

public enum ExternalAdmissionResult: String, CaseIterable, Sendable {
    case invalid
    case duplicate
    case conflict
    case capacity
    case storage
    case admitted
}

/// The durable receipt. It exists only for `admitted` and `duplicate`.
public struct ExternalAdmissionReceipt: Equatable, Sendable {
    public let admissionId: String
    public let downstreamId: String
    public let stage: ExternalAdmissionStage
    public let target: ExternalAdmissionTarget
}

public struct ExternalAdmissionOutcome: Equatable, Sendable {
    public let result: ExternalAdmissionResult
    public let receipt: ExternalAdmissionReceipt?

    public init(result: ExternalAdmissionResult, receipt: ExternalAdmissionReceipt? = nil) {
        self.result = result
        self.receipt = receipt
    }
}

public enum ExternalAdmissionError: Error, Equatable, CustomStringConvertible {
    case unknownRecord
    case illegalTransition(from: ExternalAdmissionStage, to: ExternalAdmissionStage)
    case invalidRecord(String)
    case storage(String)

    public var description: String {
        switch self {
        case .unknownRecord: return "admission record does not exist"
        case let .illegalTransition(from, to):
            return "illegal admission transition \(from.rawValue) → \(to.rawValue)"
        case let .invalidRecord(problem): return "admission record is invalid: \(problem)"
        case let .storage(message): return "admission storage failed: \(message)"
        }
    }
}

struct AdmissionCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == AdmissionCodingKey {
    /// `additionalProperties: false`.
    func requireOnly(_ allowed: Set<String>) throws {
        for key in allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "unknown member \(key.stringValue)")
        }
    }

    func corrupted(_ name: String, _ message: String) -> DecodingError {
        DecodingError.dataCorruptedError(forKey: AdmissionCodingKey(name), in: self,
                                         debugDescription: message)
    }
}

/// The schema's string patterns, matched byte by byte: a regular expression's
/// `$` also matches before a trailing line terminator, which the schema does not allow.
enum AdmissionText {
    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    /// `^[0-9a-f]{64}$`
    static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowerHex)
    }

    /// `^[\x21-\x7e]{1,max}$`
    static func isVisibleASCII(_ value: String, max: Int) -> Bool {
        let bytes = value.utf8
        return bytes.count >= 1 && bytes.count <= max
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    /// `^(local|account:[A-Za-z0-9._-]{1,128})$`
    static func isPrincipal(_ value: String) -> Bool {
        if value == "local" { return true }
        let prefix = "account:"
        guard value.hasPrefix(prefix) else { return false }
        let id = value.utf8.dropFirst(prefix.utf8.count)
        return id.count >= 1 && id.count <= 128 && id.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a) || byte == 0x2e || byte == 0x5f || byte == 0x2d
        }
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
    static func isLowerUUIDv4(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == 0x2d else { return false }
            case 14:
                guard byte == 0x34 else { return false }
            case 19:
                guard byte == 0x38 || byte == 0x39 || byte == 0x61 || byte == 0x62 else {
                    return false
                }
            default:
                guard isLowerHex(byte) else { return false }
            }
        }
        return true
    }

    /// `^[a-z_]{1,64}$`
    static func isReasonCode(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count >= 1 && bytes.count <= 64
            && bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x5f }
    }
}

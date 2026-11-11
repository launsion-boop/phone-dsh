// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public enum BotMemoryScope: String, Codable, Sendable, CaseIterable {
    case agent
    case user
}

/// Legacy fact shape. Only the one-time migration reads this; the live model
/// is `BotMemoryDocument`.
public enum BotMemoryTier: String, Codable, Sendable, CaseIterable {
    case profile
    case log
    case note
}

public enum BotMemorySensitivity: String, Codable, Sendable {
    case low
    case personal
    case sensitive
}

public enum BotMemorySourceKind: String, Codable, Sendable, CaseIterable {
    case userTurn = "user-turn"
    case hiddenWake = "hidden-wake"
    case agentMessage = "agent-message"
    case routine
    case task
    /// S3: a maintainer session has no user turn; trust still comes from evidence.
    case maintenance = "maintenance"
}

public struct BotMemorySource: Codable, Sendable, Equatable {
    public var kind: BotMemorySourceKind
    public var sessionID: String?
    public var turnID: String?
    public var role: String?

    public init(kind: BotMemorySourceKind, sessionID: String? = nil, turnID: String? = nil, role: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.turnID = turnID
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionID = "sessionId"
        case turnID = "turnId"
        case role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(BotMemorySourceKind.self, forKey: .kind)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        if let text = try? container.decodeIfPresent(String.self, forKey: .turnID) {
            turnID = text
        } else if let number = try? container.decode(Int64.self, forKey: .turnID) {
            turnID = String(number)
        } else {
            turnID = nil
        }
        role = try container.decodeIfPresent(String.self, forKey: .role)
    }
}

public struct BotMemorySourceState: Sendable, Equatable {
    public private(set) var kind: BotMemorySourceKind

    public init(kind: BotMemorySourceKind) {
        self.kind = kind
    }

    public mutating func join(_ incoming: BotMemorySourceKind) {
        if kind == .userTurn {
            kind = incoming
        }
    }
}

public struct BotMemoryFact: Codable, Sendable, Equatable, Identifiable {
    public var factID: String
    public var text: String
    public var learnedAtMS: Int64
    public var tier: BotMemoryTier
    public var scope: BotMemoryScope
    public var key: String?
    public var trust: BotJSONValue?
    public var sensitivity: BotMemorySensitivity
    public var importance: Double
    public var lastUsedMS: Int64
    public var extractor: String?
    public var source: BotMemorySource?
    public var evidence: [String]?
    public var supersededBy: String?
    public var expiresAt: Int64?
    public var applicableWhen: String?
    public var notApplicableWhen: String?
    public var extractRunID: String?
    public var archived: Bool?
    public var archivedAtMS: Int64?
    public var archiveReason: String?
    public var l2: Bool?

    public var id: String { factID }

    public init(
        factID: String,
        text: String,
        learnedAtMS: Int64,
        tier: BotMemoryTier,
        scope: BotMemoryScope,
        key: String? = nil,
        trust: BotJSONValue? = nil,
        sensitivity: BotMemorySensitivity = .personal,
        importance: Double = 0.5,
        lastUsedMS: Int64 = 0,
        extractor: String? = nil,
        source: BotMemorySource? = nil,
        evidence: [String]? = nil,
        supersededBy: String? = nil,
        expiresAt: Int64? = nil,
        applicableWhen: String? = nil,
        notApplicableWhen: String? = nil,
        extractRunID: String? = nil,
        archived: Bool? = nil,
        archivedAtMS: Int64? = nil,
        archiveReason: String? = nil,
        l2: Bool? = nil
    ) {
        self.factID = factID
        self.text = text
        self.learnedAtMS = learnedAtMS
        self.tier = tier
        self.scope = scope
        self.key = key
        self.trust = trust
        self.sensitivity = sensitivity
        self.importance = importance
        self.lastUsedMS = lastUsedMS
        self.extractor = extractor
        self.source = source
        self.evidence = evidence
        self.supersededBy = supersededBy
        self.expiresAt = expiresAt
        self.applicableWhen = applicableWhen
        self.notApplicableWhen = notApplicableWhen
        self.extractRunID = extractRunID
        self.archived = archived
        self.archivedAtMS = archivedAtMS
        self.archiveReason = archiveReason
        self.l2 = l2
    }

    enum CodingKeys: String, CodingKey {
        case factID = "fact_id"
        case text
        case learnedAtMS = "learned_at_ms"
        case tier
        case scope
        case key
        case trust
        case sensitivity
        case importance
        case lastUsedMS = "last_used_ms"
        case extractor
        case source
        case evidence
        case supersededBy = "superseded_by"
        case expiresAt = "expires_at"
        case applicableWhen
        case notApplicableWhen
        case extractRunID = "extractRunId"
        case archived
        case archivedAtMS = "archived_at_ms"
        case archiveReason = "archive_reason"
        case l2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        factID = try container.decode(String.self, forKey: .factID)
        text = try container.decode(String.self, forKey: .text)
        learnedAtMS = try container.decode(Int64.self, forKey: .learnedAtMS)
        tier = try container.decode(BotMemoryTier.self, forKey: .tier)
        scope = try container.decode(BotMemoryScope.self, forKey: .scope)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        trust = try container.decodeIfPresent(BotJSONValue.self, forKey: .trust)
        sensitivity = try container.decodeIfPresent(BotMemorySensitivity.self, forKey: .sensitivity) ?? .personal
        importance = try container.decodeIfPresent(Double.self, forKey: .importance) ?? 0.5
        lastUsedMS = try container.decodeIfPresent(Int64.self, forKey: .lastUsedMS) ?? 0
        extractor = try container.decodeIfPresent(String.self, forKey: .extractor)
        source = try container.decodeIfPresent(BotMemorySource.self, forKey: .source)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence)
        supersededBy = try container.decodeIfPresent(String.self, forKey: .supersededBy)
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
        applicableWhen = try container.decodeIfPresent(String.self, forKey: .applicableWhen)
        notApplicableWhen = try container.decodeIfPresent(String.self, forKey: .notApplicableWhen)
        extractRunID = try container.decodeIfPresent(String.self, forKey: .extractRunID)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        archivedAtMS = try container.decodeIfPresent(Int64.self, forKey: .archivedAtMS)
        archiveReason = try container.decodeIfPresent(String.self, forKey: .archiveReason)
        l2 = try container.decodeIfPresent(Bool.self, forKey: .l2)
    }
}

public enum BotMemoryPromptLanguage: String, Codable, Sendable {
    case zh
    case en
}

enum BotMemoryText {
    static let lineBreaks = CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}\u{0085}\u{000B}\u{000C}")
    static let whitespace = CharacterSet.whitespacesAndNewlines

    static func codePointCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    static func utf16Count(_ text: String) -> Int {
        text.utf16.count
    }

    static func prefixCodePoints(_ text: String, _ count: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars.prefix(max(0, count)) {
            result.append(contentsOf: String(scalar))
        }
        return result
    }

    static func trimEnd(_ text: String) -> String {
        var result = text
        while let scalar = result.unicodeScalars.last, whitespace.contains(scalar) {
            result.removeLast()
        }
        return result
    }
}

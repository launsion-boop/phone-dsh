// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public enum BotMemoryScope: String, Codable, Sendable, CaseIterable {
    case agent
    case user
}

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

public struct BotMemoryWriteContext: Sendable {
    public let source: BotMemorySource
    /// Trust the host derived from `evidence`. Absent means the caller is an
    /// internal/migration write that predates the record-evidence rule; the
    /// MCP tool path always supplies it.
    public let trust: BotRecordTrust?

    init(source: BotMemorySource, trust: BotRecordTrust? = nil) {
        self.source = source
        self.trust = trust
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
    /// Canonical `record://` references this fact was learned from.
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

public struct BotMemoryFactNormalization: Codable, Sendable, Equatable {
    public let ok: Bool
    public let code: String?
    public let text: String
    public let chars: Int?
    public let error: String?

    public init(ok: Bool, code: String?, text: String, chars: Int?, error: String?) {
        self.ok = ok
        self.code = code
        self.text = text
        self.chars = chars
        self.error = error
    }
}

public enum BotMemoryNormalizer {
    public static let maximumFactCodePoints = 2_000
    public static let maximumConditionCodePoints = 80

    public static func normalizeFactText(
        _ value: String,
        language: BotMemoryPromptLanguage = .zh
    ) -> BotMemoryFactNormalization {
        let text = BotMemoryText.foldFactLines(value)
        if text.isEmpty {
            return BotMemoryFactNormalization(
                ok: false,
                code: "empty",
                text: "",
                chars: nil,
                error: bilingual(
                    language,
                    zh: "事實不能為空，未寫入。",
                    en: "A memory fact cannot be empty; nothing was written."
                )
            )
        }
        let chars = BotMemoryText.codePointCount(text)
        if chars > maximumFactCodePoints {
            return BotMemoryFactNormalization(
                ok: false,
                code: "too-long",
                text: text,
                chars: chars,
                error: bilingual(
                    language,
                    zh: "事實有 \(chars) 字，超過 \(maximumFactCodePoints) 字上限，未寫入。",
                    en: "The fact has \(chars) characters, exceeding the \(maximumFactCodePoints)-character limit; nothing was written."
                )
            )
        }
        return BotMemoryFactNormalization(ok: true, code: nil, text: text, chars: chars, error: nil)
    }

    public static func normalizeForgetText(_ value: String) -> String {
        BotMemoryText.normalizedForgetText(value)
    }

    public static func normalizeConditionText(_ value: String?) -> String {
        BotMemoryText.normalizedCondition(value)
    }

    static func bilingual(
        _ language: BotMemoryPromptLanguage,
        zh: String,
        en: String
    ) -> String {
        language == .en ? "\(en) / \(zh)" : "\(zh) / \(en)"
    }
}

enum BotMemoryText {
    static let lineBreaks = CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}\u{0085}\u{000B}\u{000C}")
    static let whitespace = CharacterSet.whitespacesAndNewlines

    static func foldFactLines(_ value: String) -> String {
        var parts: [String] = []
        var current = ""
        func flush() {
            let part = current.trimmingCharacters(in: whitespace)
            if !part.isEmpty {
                parts.append(part)
            }
            current = ""
        }
        for scalar in value.unicodeScalars {
            if lineBreaks.contains(scalar) {
                flush()
            } else {
                current.append(contentsOf: String(scalar))
            }
        }
        flush()
        return parts.joined(separator: "；").trimmingCharacters(in: whitespace)
    }

    static func normalizedForgetText(_ value: String) -> String {
        var result = foldFactLines(value)
        for pattern in [#"^[-*•]\s+"#, #"^\d+[.)]\s+"#, #"^\*\*[^*]+\*\*:\s*"#] {
            result = replacing(pattern, in: result, with: "")
        }
        return result.trimmingCharacters(in: whitespace)
    }

    static func normalizedCondition(_ value: String?) -> String {
        guard let value else { return "" }
        let normalized = value.precomposedStringWithCompatibilityMapping
            .components(separatedBy: whitespace)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return prefixCodePoints(normalized, BotMemoryNormalizer.maximumConditionCodePoints)
    }

    static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func codePointCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    static func prefixCodePoints(_ text: String, _ count: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars.prefix(max(0, count)) {
            result.append(contentsOf: String(scalar))
        }
        return result
    }

    static func utf16Count(_ text: String) -> Int {
        text.utf16.count
    }

    static func utf16Prefix(_ text: String, _ maximumUnits: Int) -> String {
        guard maximumUnits > 0 else { return "" }
        var used = 0
        var result = ""
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf16.count
            if used + width > maximumUnits {
                break
            }
            result.append(contentsOf: String(scalar))
            used += width
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

    static func clip(_ text: String, _ maximumUnits: Int) -> String {
        if maximumUnits == 0 || utf16Count(text) <= maximumUnits {
            return text
        }
        let prefix = utf16Prefix(text, max(0, maximumUnits - 1))
        return trimEnd(prefix) + "…"
    }
}

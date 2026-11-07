// SPDX-License-Identifier: MIT

import Foundation

public enum BotContextProfileName: String, Codable, Sendable, CaseIterable {
    case `default`
    case conservative

    public static func resolve(_ requested: String?) -> Self {
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return Self(rawValue: normalized) ?? .default
    }
}

public struct BotContextCompaction: Codable, Sendable, Equatable {
    public let auto: Bool
    public let thresholdRatio: Double
    public let headroomTokens: Int
    public let retainRatio: Double
    public let maxTokens: Int
    public let summarizationProvider: String
    public let summarizationModel: String
    public let compactionRetries: Int
    public let maxOverflowRetries: Int
}

public struct BotContextPruner: Codable, Sendable, Equatable {
    public let thresholdChars: Int
    public let headChars: Int
    public let tailChars: Int
}

public struct BotContextSpillPolicy: Codable, Sendable, Equatable {
    public let maxInlineTokens: Int
}

public struct BotContextSpillLocal: Codable, Sendable, Equatable {
    public let cleanupPeriodDays: Int
}

public struct BotContextProfile: Codable, Sendable, Equatable {
    public let compaction: BotContextCompaction
    public let pruner: BotContextPruner
    public let spillPolicy: BotContextSpillPolicy
    public let spillLocal: BotContextSpillLocal

    public init(
        compaction: BotContextCompaction,
        pruner: BotContextPruner,
        spillPolicy: BotContextSpillPolicy,
        spillLocal: BotContextSpillLocal
    ) {
        self.compaction = compaction
        self.pruner = pruner
        self.spillPolicy = spillPolicy
        self.spillLocal = spillLocal
    }

    public static let `default` = Self(
        compaction: BotContextCompaction(
            auto: true, thresholdRatio: 0.8, headroomTokens: 65_536, retainRatio: 0.16,
            maxTokens: 65_536, summarizationProvider: "", summarizationModel: "",
            compactionRetries: 1, maxOverflowRetries: 1),
        pruner: BotContextPruner(thresholdChars: 8_192, headChars: 4_096, tailChars: 1_024),
        spillPolicy: BotContextSpillPolicy(maxInlineTokens: 12_500),
        spillLocal: BotContextSpillLocal(cleanupPeriodDays: 30))

    public static let conservative = Self(
        compaction: BotContextCompaction(
            auto: true, thresholdRatio: 0.4, headroomTokens: 32_768, retainRatio: 0.12,
            maxTokens: 32_768, summarizationProvider: "", summarizationModel: "",
            compactionRetries: 1, maxOverflowRetries: 1),
        pruner: BotContextPruner(thresholdChars: 4_096, headChars: 2_048, tailChars: 512),
        spillPolicy: BotContextSpillPolicy(maxInlineTokens: 4_096),
        spillLocal: BotContextSpillLocal(cleanupPeriodDays: 30))

    public static func named(_ name: BotContextProfileName) -> Self {
        switch name {
        case .default: return .default
        case .conservative: return .conservative
        }
    }
}

public struct BotContextProfilePair: Codable, Sendable, Equatable {
    public let `default`: BotContextProfile
    public let conservative: BotContextProfile

    public static let frozen = Self(default: .default, conservative: .conservative)
}

public struct BotContextProfileYAMLPair: Codable, Sendable, Equatable {
    public let `default`: String
    public let conservative: String

    public static let frozen = Self(
        default: BotContextProfileYAML.render(name: .default, profile: .default),
        conservative: BotContextProfileYAML.render(name: .conservative, profile: .conservative))
}

public struct BotContextProfileDocument: Codable, Sendable, Equatable {
    public let profiles: BotContextProfilePair
    public let yaml: BotContextProfileYAMLPair

    public static let frozen = Self(profiles: .frozen, yaml: .frozen)
}

public enum BotContextProfileYAML {
    public static func render(name: BotContextProfileName, profile: BotContextProfile) -> String {
        let c = profile.compaction
        return [
            "# M5 上下文工程：顯式寫出 compaction / pruner / spill 設定（contextProfile=\(name.rawValue)）。",
            "# 數值與理由見 docs/upgrade/context-tuning.md；patch 會整段取代 bundle 預設 config。",
            "- id: compaction-basic",
            "  config:",
            "    auto: \(c.auto)",
            "    thresholdRatio: \(yamlNumber(c.thresholdRatio))",
            "    headroomTokens: \(c.headroomTokens)",
            "    retainRatio: \(yamlNumber(c.retainRatio))",
            "    maxTokens: \(c.maxTokens)",
            "    summarizationProvider: \(jsonString(c.summarizationProvider))",
            "    summarizationModel: \(jsonString(c.summarizationModel))",
            "    compactionRetries: \(c.compactionRetries)",
            "    maxOverflowRetries: \(c.maxOverflowRetries)",
            "    modelPolicies: []",
            "- id: tool-result-pruner",
            "  config:",
            "    thresholdChars: \(profile.pruner.thresholdChars)",
            "    headChars: \(profile.pruner.headChars)",
            "    tailChars: \(profile.pruner.tailChars)",
            "- id: spill-policy",
            "  config:",
            "    maxInlineTokens: \(profile.spillPolicy.maxInlineTokens)",
            "- id: spill-local",
            "  config:",
            "    cleanupPeriodDays: \(profile.spillLocal.cleanupPeriodDays)",
            "",
        ].joined(separator: "\n")
    }

    private static func yamlNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

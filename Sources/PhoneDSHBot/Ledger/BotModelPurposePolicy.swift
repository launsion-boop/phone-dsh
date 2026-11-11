// SPDX-License-Identifier: MIT

import Foundation

public enum BotModelPurpose: String, Codable, CaseIterable, Sendable {
    case frontTurn = "front-turn"
    case workerTurn = "worker-turn"
    case triage
    case memoryExtract = "memory-extract"
    case reflect
    case compact
    case watchdog
    case completionCheck = "completion-check"
    /// S3 maintainer run; its spend is budgeted per run and per UTC day.
    case memoryMaintenance = "memory-maintenance"

    public var largeModelAllowed: Bool {
        self == .frontTurn || self == .workerTurn
    }
}

public struct BotModelPurposeDefaults: Codable, Sendable, Equatable {
    public let model: String
    public let maxTokens: Int
    public let temperature: Double

    public init(model: String, maxTokens: Int, temperature: Double) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct BotModelPurposeRow: Codable, Sendable, Equatable {
    public let purpose: BotModelPurpose
    public let largeModelAllowed: Bool
    public let defaults: BotModelPurposeDefaults

    public init(purpose: BotModelPurpose, largeModelAllowed: Bool, defaults: BotModelPurposeDefaults) {
        self.purpose = purpose
        self.largeModelAllowed = largeModelAllowed
        self.defaults = defaults
    }
}

public struct BotModelPurposePolicy: Codable, Sendable, Equatable {
    public static let smallModel = "deepseek-flash"
    public static let largeModel = "deepseek-v4-pro"

    public let purposes: [BotModelPurposeRow]
    public let largeModelPurposes: [BotModelPurpose]

    public init(purposes: [BotModelPurposeRow], largeModelPurposes: [BotModelPurpose]) {
        self.purposes = purposes
        self.largeModelPurposes = largeModelPurposes
    }

    public static let frozen = Self(
        purposes: BotModelPurpose.allCases.map { purpose in
            BotModelPurposeRow(
                purpose: purpose,
                largeModelAllowed: purpose.largeModelAllowed,
                defaults: defaults(for: purpose))
        },
        largeModelPurposes: [.frontTurn, .workerTurn])

    public static func allowsLargeModel(_ purpose: BotModelPurpose) -> Bool {
        purpose.largeModelAllowed
    }

    public static func defaults(for purpose: BotModelPurpose) -> BotModelPurposeDefaults {
        switch purpose {
        case .frontTurn, .workerTurn:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 8_192, temperature: 1)
        case .triage, .watchdog, .completionCheck:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 256, temperature: 0)
        case .memoryMaintenance:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 4_096, temperature: 0)
        case .memoryExtract:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 1_024, temperature: 0)
        case .reflect:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 1_024, temperature: 0.7)
        case .compact:
            return BotModelPurposeDefaults(model: smallModel, maxTokens: 2_048, temperature: 0)
        }
    }

    public static func assertModelAllowed(purpose: BotModelPurpose, model: String) throws -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw BotModelPurposeError(
                code: "EPURPOSE_MODEL_REQUIRED", purpose: purpose, model: model,
                message: "model must be a non-empty string")
        }
        if !purpose.largeModelAllowed, modelTier(normalized) != .small {
            throw BotModelPurposeError(
                code: "EPURPOSE_MODEL_DENIED", purpose: purpose, model: normalized,
                message: "purpose \"\(purpose.rawValue)\" requires a known small model")
        }
        return normalized
    }

    public static func modelTier(_ model: String) -> BotModelTier {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown }
        if normalized == smallModel || normalized.hasPrefix("\(smallModel)-") { return .small }
        let largeModels: Set<String> = [largeModel, "deepseek-pro", "deepseek-reasoner", "deepseek-chat"]
        if largeModels.contains(normalized) { return .large }
        let suffix = #"(?:^|[-_/])(pro|reasoner|max|opus)(?:$|[-_.:/])"#
        if normalized.range(of: suffix, options: .regularExpression) != nil { return .large }
        return .unknown
    }
}

public enum BotModelTier: Sendable, Equatable {
    case small
    case large
    case unknown
}

public struct BotModelPurposeError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let purpose: BotModelPurpose
    public let model: String
    public let message: String

    public init(code: String, purpose: BotModelPurpose, model: String, message: String) {
        self.code = code
        self.purpose = purpose
        self.model = model
        self.message = message
    }

    public var description: String { message }
}

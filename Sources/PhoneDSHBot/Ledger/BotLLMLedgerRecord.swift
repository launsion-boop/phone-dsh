// SPDX-License-Identifier: MIT

import Foundation

public struct BotLLMLedgerRecord: Codable, Sendable, Equatable {
    public let ts: String
    public let botId: String?
    public let sessionId: String?
    public let purpose: BotModelPurpose
    public let model: String?
    public let provider: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cacheHitRatio: Double
    public let ttftMs: Int?
    public let durationMs: Int?
    public let status: String
    public let errorKind: String?

    public init(
        ts: String,
        botId: String?,
        sessionId: String?,
        purpose: BotModelPurpose,
        model: String?,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        ttftMs: Int? = nil,
        durationMs: Int?,
        status: String = "ok",
        errorKind: String? = nil
    ) {
        self.ts = ts
        self.botId = botId
        self.sessionId = sessionId
        self.purpose = purpose
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheHitRatio = Self.cacheHitRatio(
            inputTokens: inputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
        self.ttftMs = ttftMs
        self.durationMs = durationMs
        self.status = status
        self.errorKind = errorKind
    }

    public static func cacheHitRatio(inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) -> Double {
        let input = Double(max(0, inputTokens))
        let read = Double(max(0, cacheReadTokens))
        let write = Double(max(0, cacheWriteTokens))
        let prompt = input + read + write
        return prompt > 0 ? read / prompt : 0
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public func validate() throws {
        guard ts.count >= 20 else { throw BotLLMLedgerError(field: "ts", message: "timestamp is too short") }
        for (field, value) in [
            ("inputTokens", inputTokens), ("outputTokens", outputTokens),
            ("cacheReadTokens", cacheReadTokens), ("cacheWriteTokens", cacheWriteTokens),
        ] where value < 0 {
            throw BotLLMLedgerError(field: field, message: "token counts must be non-negative")
        }
        if let ttftMs, ttftMs < 0 {
            throw BotLLMLedgerError(field: "ttftMs", message: "TTFT must be non-negative")
        }
        if let durationMs, durationMs < 0 {
            throw BotLLMLedgerError(field: "durationMs", message: "duration must be non-negative")
        }
        guard !status.isEmpty else {
            throw BotLLMLedgerError(field: "status", message: "status must not be empty")
        }
        let expected = Self.cacheHitRatio(
            inputTokens: inputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
        guard cacheHitRatio.isFinite, cacheHitRatio >= 0, cacheHitRatio <= 1,
              abs(cacheHitRatio - expected) <= 1e-12 else {
            throw BotLLMLedgerError(
                field: "cacheHitRatio",
                message: "cacheHitRatio must equal cacheRead/(input+cacheRead+cacheWrite)")
        }
    }

    public static func date(from timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractional.date(from: timestamp) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        return plain.date(from: timestamp)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ts, botId, sessionId, purpose, model, provider
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, cacheHitRatio
        case ttftMs, durationMs, status, errorKind
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        guard rawContainer.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: container, debugDescription: "unknown LLM ledger member")
        }
        ts = try container.decode(String.self, forKey: .ts)
        botId = try container.decode(String?.self, forKey: .botId)
        sessionId = try container.decode(String?.self, forKey: .sessionId)
        purpose = try container.decode(BotModelPurpose.self, forKey: .purpose)
        model = try container.decode(String?.self, forKey: .model)
        provider = try container.decode(String?.self, forKey: .provider)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try container.decode(Int.self, forKey: .cacheWriteTokens)
        cacheHitRatio = try container.decode(Double.self, forKey: .cacheHitRatio)
        ttftMs = container.contains(.ttftMs) ? try container.decode(Int.self, forKey: .ttftMs) : nil
        durationMs = try container.decode(Int?.self, forKey: .durationMs)
        status = try container.decode(String.self, forKey: .status)
        errorKind = try container.decode(String?.self, forKey: .errorKind)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(botId, forKey: .botId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(purpose, forKey: .purpose)
        try container.encode(model, forKey: .model)
        try container.encode(provider, forKey: .provider)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encode(cacheHitRatio, forKey: .cacheHitRatio)
        try container.encodeIfPresent(ttftMs, forKey: .ttftMs)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(status, forKey: .status)
        try container.encode(errorKind, forKey: .errorKind)
    }
}

public struct BotLLMLedgerError: Error, Sendable, Equatable, CustomStringConvertible {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

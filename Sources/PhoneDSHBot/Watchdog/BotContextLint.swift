// SPDX-License-Identifier: MIT

import Foundation

public enum BotContextLintRule: String, Codable, Sendable, CaseIterable {
    case systemPromptBloat = "system-prompt-bloat"
    case toolResultBloat = "tool-result-bloat"
    case duplicateContext = "duplicate-context"
    case orphanToolCall = "orphan-tool-call"
    case orphanToolResult = "orphan-tool-result"
    case toolDefBloat = "tool-def-bloat"
}

public enum BotContextLintSeverity: String, Codable, Sendable {
    case warn
    case error
}

public struct BotContextLintFinding: Codable, Sendable, Equatable {
    public let rule: BotContextLintRule
    public let severity: BotContextLintSeverity
    public let evidence: String
    public let location: BotJSONValue

    public init(
        rule: BotContextLintRule,
        severity: BotContextLintSeverity,
        evidence: String,
        location: [String: BotJSONValue]
    ) {
        self.rule = rule
        self.severity = severity
        self.evidence = evidence
        self.location = .object(location)
    }
}

public struct BotContextLintThresholds: Codable, Sendable, Equatable {
    public var personaCharsWarn: Int
    public var personaCharsError: Int
    public var toolResultTokensWarn: Int
    public var toolResultTokensError: Int
    public var toolDefTokensWarn: Int
    public var toolDefTokensError: Int
    public var toolCountWarn: Int
    public var maxRuntimeContextsPerTurn: Int
    public var repeatedTextChars: Int
    public var repeatedTextMaxFindings: Int

    public init(
        personaCharsWarn: Int = 20_000,
        personaCharsError: Int = 32_000,
        toolResultTokensWarn: Int = 4_096,
        toolResultTokensError: Int = 12_000,
        toolDefTokensWarn: Int = 8_000,
        toolDefTokensError: Int = 16_000,
        toolCountWarn: Int = 40,
        maxRuntimeContextsPerTurn: Int = 2,
        repeatedTextChars: Int = 500,
        repeatedTextMaxFindings: Int = 20
    ) {
        self.personaCharsWarn = personaCharsWarn
        self.personaCharsError = personaCharsError
        self.toolResultTokensWarn = toolResultTokensWarn
        self.toolResultTokensError = toolResultTokensError
        self.toolDefTokensWarn = toolDefTokensWarn
        self.toolDefTokensError = toolDefTokensError
        self.toolCountWarn = toolCountWarn
        self.maxRuntimeContextsPerTurn = maxRuntimeContextsPerTurn
        self.repeatedTextChars = repeatedTextChars
        self.repeatedTextMaxFindings = repeatedTextMaxFindings
    }

    private enum CodingKeys: String, CodingKey {
        case personaCharsWarn
        case personaCharsError
        case toolResultTokensWarn
        case toolResultTokensError
        case toolDefTokensWarn
        case toolDefTokensError
        case toolCountWarn
        case maxRuntimeContextsPerTurn
        case repeatedTextChars
        case repeatedTextMaxFindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        personaCharsWarn = try container.decodeIfPresent(Int.self, forKey: .personaCharsWarn)
            ?? defaults.personaCharsWarn
        personaCharsError = try container.decodeIfPresent(Int.self, forKey: .personaCharsError)
            ?? defaults.personaCharsError
        toolResultTokensWarn = try container.decodeIfPresent(Int.self, forKey: .toolResultTokensWarn)
            ?? defaults.toolResultTokensWarn
        toolResultTokensError = try container.decodeIfPresent(Int.self, forKey: .toolResultTokensError)
            ?? defaults.toolResultTokensError
        toolDefTokensWarn = try container.decodeIfPresent(Int.self, forKey: .toolDefTokensWarn)
            ?? defaults.toolDefTokensWarn
        toolDefTokensError = try container.decodeIfPresent(Int.self, forKey: .toolDefTokensError)
            ?? defaults.toolDefTokensError
        toolCountWarn = try container.decodeIfPresent(Int.self, forKey: .toolCountWarn)
            ?? defaults.toolCountWarn
        maxRuntimeContextsPerTurn = try container.decodeIfPresent(
            Int.self, forKey: .maxRuntimeContextsPerTurn) ?? defaults.maxRuntimeContextsPerTurn
        repeatedTextChars = try container.decodeIfPresent(Int.self, forKey: .repeatedTextChars)
            ?? defaults.repeatedTextChars
        repeatedTextMaxFindings = try container.decodeIfPresent(
            Int.self, forKey: .repeatedTextMaxFindings) ?? defaults.repeatedTextMaxFindings
    }

    public static let `default` = Self()
}

public struct BotContextLintEvent: Codable, Sendable, Equatable {
    public let type: String
    public let seq: Int?
    public let time: Double?
    public let data: [String: BotJSONValue]

    public init(
        type: String,
        seq: Int? = nil,
        time: Double? = nil,
        data: [String: BotJSONValue] = [:]
    ) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case type, seq, time, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        data = try container.decodeIfPresent([String: BotJSONValue].self, forKey: .data) ?? [:]
    }
}

struct BotContextLintMessage {
    var role: String
    var text: String
    var sourceKind: String
    var turn: Int?
    var step: Int?
    var seq: Int?
    var time: Double?
    var eventType: String
    var callId: String?
}

struct BotContextLintCall {
    var callId: String
    var name: String
    var turn: Int?
    var step: Int?
    var seq: Int?
}

struct BotContextLintResult {
    var callId: String?
    var turn: Int?
    var step: Int?
    var seq: Int?
}

public enum BotContextLint {
    public static func estimateTokens(_ text: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for unit in text.utf16 {
            if unit < 0x80 { ascii += 1 } else { nonASCII += 1 }
        }
        return Int(ceil(Double(ascii) / 3.5)) + nonASCII
    }

    public static func lint(
        events: [BotContextLintEvent] = [],
        promptMount: BotJSONValue? = nil,
        tools: BotJSONValue? = nil,
        thresholds: BotContextLintThresholds = .default,
        sessionId: String? = nil
    ) -> [BotContextLintFinding] {
        var findings: [BotContextLintFinding] = []
        let messages = BotContextLintSupport.collectMessages(events)
        let calls = BotContextLintSupport.collectCalls(events)
        let results = BotContextLintSupport.collectResults(events)
        var seenSignatures: Set<String> = []
        lintSystemPrompt(
            events: events, promptMount: promptMount, thresholds: thresholds,
            sessionId: sessionId, findings: &findings)
        lintToolResults(
            events: events, thresholds: thresholds, sessionId: sessionId,
            callsById: calls, findings: &findings)
        lintDuplicateContext(
            messages: messages, thresholds: thresholds, sessionId: sessionId,
            seenSignatures: &seenSignatures, findings: &findings)
        lintOrphans(
            callsById: calls, resultsById: results, sessionId: sessionId, findings: &findings)
        lintToolDefinitions(
            events: events, tools: tools, thresholds: thresholds,
            sessionId: sessionId, findings: &findings)
        return findings.enumerated().sorted { left, right in
            let severityLeft = left.element.severity == .error ? 0 : 1
            let severityRight = right.element.severity == .error ? 0 : 1
            if severityLeft != severityRight { return severityLeft < severityRight }
            let ruleLeft = BotContextLintRule.allCases.firstIndex(of: left.element.rule) ?? 99
            let ruleRight = BotContextLintRule.allCases.firstIndex(of: right.element.rule) ?? 99
            if ruleLeft != ruleRight { return ruleLeft < ruleRight }
            let seqLeft = BotContextLintSupport.object(left.element.location)["seq"].flatMap(BotContextLintSupport.int) ?? -1
            let seqRight = BotContextLintSupport.object(right.element.location)["seq"].flatMap(BotContextLintSupport.int) ?? -1
            if seqLeft != seqRight { return seqLeft < seqRight }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func positive(_ value: Int, fallback: Int) -> Int {
        value > 0 ? value : fallback
    }
}

enum BotContextLintSupport {
    static func object(_ value: BotJSONValue?) -> [String: BotJSONValue] {
        guard case let .object(object)? = value else { return [:] }
        return object
    }

    static func array(_ value: BotJSONValue?) -> [BotJSONValue]? {
        guard case let .array(array)? = value else { return nil }
        return array
    }

    static func string(_ value: BotJSONValue?) -> String {
        switch value {
        case let .string(text)?: return text
        case let .number(number)?:
            guard number.isFinite else { return "" }
            if number.rounded() == number {
                if number >= Double(Int.min), number < -Double(Int.min) { return String(Int(number)) }
                return String(format: "%.0f", number)
            }
            return String(number)
        case let .bool(bool)?: return String(bool)
        default: return ""
        }
    }

    static func int(_ value: BotJSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.isFinite, number.rounded() == number,
              number >= Double(Int.min), number < -Double(Int.min) else { return nil }
        return Int(number)
    }

    static func double(_ value: BotJSONValue?) -> Double? {
        guard case let .number(number)? = value, number.isFinite else { return nil }
        return number
    }

    static func jsonString(_ value: BotJSONValue) -> String {
        guard let data = try? value.encoded() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func number(_ value: Int) -> BotJSONValue { .number(Double(value)) }
    static func nullableString(_ value: String?) -> BotJSONValue { value.map(BotJSONValue.string) ?? .null }
    static func nullableInt(_ value: Int?) -> BotJSONValue { value.map(number) ?? .null }
    static func jsLength(_ text: String) -> Int { text.utf16.count }

    static func message(of event: BotContextLintEvent) -> [String: BotJSONValue] {
        object(event.data["message"])
    }

    static func turn(of event: BotContextLintEvent) -> Int? { int(event.data["turn"]) }
    static func step(of event: BotContextLintEvent) -> Int? { int(event.data["step"]) }

    static func blockText(_ value: BotJSONValue?) -> String {
        if case let .string(text)? = value { return text }
        let block = object(value)
        if case let .string(text)? = block["text"] { return text }
        if case let .string(text)? = block["content"] { return text }
        if let content = array(block["content"]) {
            return content.map { blockText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    static func contentText(_ value: BotJSONValue?) -> String {
        if case let .string(text)? = value { return text }
        guard let content = array(value) else { return "" }
        return content.map { blockText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func userText(_ event: BotContextLintEvent) -> String {
        let message = message(of: event)
        return contentText(event.data["content"] ?? message["content"])
    }

    static func systemText(_ event: BotContextLintEvent) -> String {
        contentText(message(of: event)["content"])
    }

    static func assistantText(_ event: BotContextLintEvent) -> String {
        contentText(message(of: event)["content"])
    }

    static func toolResultText(_ event: BotContextLintEvent) -> String {
        let fromMessage = contentText(message(of: event)["content"])
        if !fromMessage.isEmpty { return fromMessage }
        for key in ["result", "output"] {
            if case let .string(text)? = event.data[key] { return text }
        }
        return ""
    }

    static func toolResultCallId(_ event: BotContextLintEvent) -> String {
        let message = message(of: event)
        for value in [message["toolCallId"], event.data["callId"], object(message["source"])["callId"]] {
            let text = string(value)
            if !text.isEmpty { return text }
        }
        return ""
    }

    static func toolResultIsError(_ event: BotContextLintEvent) -> Bool {
        if case .bool(true)? = message(of: event)["isError"] { return true }
        if case .bool(true)? = event.data["isError"] { return true }
        return false
    }

    static func collectMessages(_ events: [BotContextLintEvent]) -> [BotContextLintMessage] {
        var messages: [BotContextLintMessage] = []
        var currentTurn: Int?
        for event in events {
            if event.type == "turn/start" {
                if let turn = turn(of: event) { currentTurn = turn }
                continue
            }
            let turn = turn(of: event) ?? currentTurn
            switch event.type {
            case "user/message":
                let source = object(event.data["source"])["kind"] ?? message(of: event)["source"].flatMap { object($0)["kind"] }
                messages.append(BotContextLintMessage(
                    role: "user", text: userText(event), sourceKind: string(source),
                    turn: turn, step: step(of: event), seq: event.seq, time: event.time,
                    eventType: event.type, callId: nil))
            case "assistant/message":
                messages.append(BotContextLintMessage(
                    role: "assistant", text: assistantText(event), sourceKind: "assistant",
                    turn: turn, step: step(of: event), seq: event.seq, time: event.time,
                    eventType: event.type, callId: nil))
            case "system/message":
                messages.append(BotContextLintMessage(
                    role: "system", text: systemText(event), sourceKind: "system",
                    turn: turn, step: step(of: event), seq: event.seq, time: event.time,
                    eventType: event.type, callId: nil))
            case "tool/result":
                messages.append(BotContextLintMessage(
                    role: "tool", text: toolResultText(event), sourceKind: "tool",
                    turn: turn, step: step(of: event), seq: event.seq, time: event.time,
                    eventType: event.type, callId: toolResultCallId(event)))
            default:
                break
            }
        }
        return messages
    }

    static func collectCalls(_ events: [BotContextLintEvent]) -> [String: BotContextLintCall] {
        var calls: [String: BotContextLintCall] = [:]
        var currentTurn: Int?
        for event in events {
            if event.type == "turn/start" {
                if let turn = turn(of: event) { currentTurn = turn }
                continue
            }
            if event.type == "tool/call" {
                let id = string(event.data["callId"])
                if !id.isEmpty, calls[id] == nil {
                    calls[id] = BotContextLintCall(
                        callId: id, name: string(event.data["name"]),
                        turn: turn(of: event) ?? currentTurn, step: step(of: event), seq: event.seq)
                }
            }
            if event.type == "assistant/message" {
                for block in array(message(of: event)["content"]) ?? [] {
                    let object = object(block)
                    guard string(object["type"]) == "tool-call" else { continue }
                    let id = !string(object["id"]).isEmpty ? string(object["id"]) : string(object["toolCallId"])
                    if !id.isEmpty, calls[id] == nil {
                        calls[id] = BotContextLintCall(
                            callId: id, name: string(object["name"]),
                            turn: turn(of: event) ?? currentTurn, step: step(of: event), seq: event.seq)
                    }
                }
            }
        }
        return calls
    }

    static func collectResults(_ events: [BotContextLintEvent]) -> [String: BotContextLintResult] {
        var results: [String: BotContextLintResult] = [:]
        var currentTurn: Int?
        for event in events where event.type == "turn/start" || event.type == "tool/result" {
            if event.type == "turn/start" {
                if let turn = turn(of: event) { currentTurn = turn }
                continue
            }
            let callId = toolResultCallId(event)
            let result = BotContextLintResult(
                callId: callId.isEmpty ? nil : callId,
                turn: turn(of: event) ?? currentTurn, step: step(of: event), seq: event.seq)
            let key = !callId.isEmpty ? callId : "missing:\(event.seq.map(String.init) ?? "null")"
            if results[key] == nil { results[key] = result }
        }
        return results
    }

    static func normalizeText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func hasSpillNotice(_ text: String) -> Bool {
        let patterns = [
            "Full formatted result stored at:",
            "Omitted [0-9][0-9,]* bytes\\.",
            "More bytes were omitted\\.",
            "\\[spilled?\\]",
            "\\bspill(?:ed)?\\s+(?:to|file|at)\\b",
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func promptMountChars(_ promptMount: BotJSONValue?) -> Int? {
        let mount = object(promptMount)
        if let chars = double(mount["chars"]), chars > 0 { return Int(chars) }
        guard let mounted = array(mount["mounted"]) else { return nil }
        var total = 0
        for entry in mounted {
            let object = object(entry)
            total += int(object["chars"]) ?? jsLength(string(object["text"]))
        }
        return total > 0 ? total : nil
    }

    static func tools(_ input: BotJSONValue?, events: [BotContextLintEvent]) -> [BotJSONValue]? {
        if let tools = array(input) { return tools }
        if let tools = array(object(input)["tools"]) { return tools }
        var latest: [BotJSONValue]?
        for event in events where event.type == "request/header" {
            let header = object(event.data["header"])
            if let tools = array(header["tools"]) { latest = tools }
        }
        return latest
    }
}

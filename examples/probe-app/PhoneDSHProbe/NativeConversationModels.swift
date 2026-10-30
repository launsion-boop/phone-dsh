// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

// Native projections of DSH's conversation, usage, and deliverable records.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, context, assistant, reasoning, image, toolCall
        case toolResult(isError: Bool)
        case systemEvent, turnError, maxTokens, unknown, status
    }

    let id: String
    let kind: Kind
    var title: String
    var text: String
    var streaming = false
    var timestamp: Date?
    var messageID: String?
    var turn: Int?
    var step: Int?
    var callID: String?
    var toolName: String?
    var argumentsRaw: String?
    var arguments: JSONValue?
    var toolOutput: String?
    var toolMetadata: JSONValue?
    var toolState: NativeToolState?
    var turnUsage: NativeTurnUsage?
    var attachments: [NativeMessageAttachment] = []
    var rawBlock: JSONValue?

    init(id: String = UUID().uuidString, kind: Kind, title: String, text: String, streaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.streaming = streaming
    }
}

enum NativeToolState: String, Equatable {
    case preparing, running, ok, error, stopped
}

struct NativeTokenUsage: Equatable {
    var uncachedInputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int

    var billedInputTokens: Int { uncachedInputTokens + cacheReadTokens + cacheWriteTokens }
    var totalTokens: Int { billedInputTokens + outputTokens }

    init?(value: JSONValue?) {
        guard let value,
              let input = value["uncachedInputTokens"]?.intValue,
              let output = value["outputTokens"]?.intValue,
              let cacheRead = value["cacheReadTokens"]?.intValue,
              let cacheWrite = value["cacheWriteTokens"]?.intValue,
              [input, output, cacheRead, cacheWrite].allSatisfy({ $0 >= 0 }) else { return nil }
        uncachedInputTokens = input
        outputTokens = output
        cacheReadTokens = cacheRead
        cacheWriteTokens = cacheWrite
    }

    init(uncachedInputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    var cacheHitPercent: Double? {
        guard billedInputTokens > 0 else { return nil }
        return Double(cacheReadTokens) * 100 / Double(billedInputTokens)
    }
}

struct NativeTurnUsage: Equatable {
    var uncachedInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var reasoningTokens: Int?

    init() {}

    init?(value: JSONValue?) {
        guard let value,
              let input = value["inputTokens"]?.intValue,
              let output = value["outputTokens"]?.intValue,
              input >= 0, output >= 0 else { return nil }
        self.init()
        uncachedInputTokens = input
        outputTokens = output
        let cacheRead = value["cacheReadTokens"]?.intValue
        let cacheWrite = value["cacheWriteTokens"]?.intValue
        cacheReadTokens = cacheRead
        cacheWriteTokens = cacheWrite
        reasoningTokens = value["reasoningTokens"]?.intValue
        totalTokens = value["totalTokens"]?.intValue
            ?? input + (cacheRead ?? 0) + (cacheWrite ?? 0) + output
    }

    mutating func add(_ other: NativeTurnUsage) {
        uncachedInputTokens += other.uncachedInputTokens
        outputTokens += other.outputTokens
        totalTokens += other.totalTokens
        cacheReadTokens = other.cacheReadTokens == nil ? nil : cacheReadTokens.map { $0 + (other.cacheReadTokens ?? 0) }
        cacheWriteTokens = other.cacheWriteTokens == nil ? nil : cacheWriteTokens.map { $0 + (other.cacheWriteTokens ?? 0) }
        reasoningTokens = other.reasoningTokens == nil ? nil : reasoningTokens.map { $0 + (other.reasoningTokens ?? 0) }
    }

    var cacheHitPercent: Double? {
        guard let cacheReadTokens, totalTokens > outputTokens else { return nil }
        return Double(cacheReadTokens) * 100 / Double(totalTokens - outputTokens)
    }
}

struct NativeSessionStats: Equatable {
    var turns: Int
    var steps: Int
    var llmMs: Double
    var toolMs: Double
    var ttftMs: Double
    var ttftSteps: Int
    var decodeMs: Double
    var decodeTokens: Int

    init?(value: JSONValue?) {
        guard let value,
              let turns = value["turns"]?.intValue,
              let steps = value["steps"]?.intValue,
              let llmMs = value["llmMs"]?.numberValue,
              let toolMs = value["toolMs"]?.numberValue,
              let ttftMs = value["ttftMs"]?.numberValue,
              let ttftSteps = value["ttftSteps"]?.intValue,
              let decodeMs = value["decodeMs"]?.numberValue,
              let decodeTokens = value["decodeTokens"]?.intValue else { return nil }
        self.turns = turns
        self.steps = steps
        self.llmMs = llmMs
        self.toolMs = toolMs
        self.ttftMs = ttftMs
        self.ttftSteps = ttftSteps
        self.decodeMs = decodeMs
        self.decodeTokens = decodeTokens
    }

    var tokensPerSecond: Double? {
        guard decodeMs > 0 else { return nil }
        return Double(decodeTokens) / (decodeMs / 1_000)
    }
}

struct NativeContextPressure: Equatable {
    var pressureTokens: Int?
    var projectedTokens: Int?
    var contextWindow: Int

    init?(value: JSONValue?) {
        guard let value, let contextWindow = value["contextWindow"]?.intValue, contextWindow > 0 else { return nil }
        pressureTokens = value["pressureTokens"]?.intValue
        projectedTokens = value["projectedTokens"]?.intValue
        self.contextWindow = contextWindow
    }

    var usedTokens: Int? { projectedTokens ?? pressureTokens }
    var percent: Int? {
        guard let usedTokens else { return nil }
        return min(100, max(0, Int((Double(usedTokens) * 100 / Double(contextWindow)).rounded())))
    }
}

struct NativeContextBreakdown: Equatable {
    var systemTokens: Int
    var toolsTokens: Int
    var messageTokens: Int

    init?(value: JSONValue?) {
        guard let value,
              let system = value["systemTokens"]?.intValue,
              let tools = value["toolsTokens"]?.intValue,
              let messages = value["messageTokens"]?.intValue else { return nil }
        systemTokens = system
        toolsTokens = tools
        messageTokens = messages
    }
}

struct NativeMessageAttachment: Equatable {
    enum Kind: Equatable {
        case image
        case file
        case other
    }
    var kind: Kind
    var name: String
    var path: String?
    var mimeType: String?
    var payload: JSONValue
}

struct NativeChangedFile: Equatable, Identifiable {
    var path: String
    var display: String
    var added: Int
    var deleted: Int
    var binary = false
    var oversized = false
    var oldText: String?
    var newText: String
    var id: String { path }
}

struct NativeChangedFiles: Equatable {
    var files: [NativeChangedFile]
    var added: Int { files.reduce(0) { $0 + $1.added } }
    var deleted: Int { files.reduce(0) { $0 + $1.deleted } }
}

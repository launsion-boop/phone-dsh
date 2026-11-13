// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

/// Process-wide monotonic source for `ChatItem.renderRevision`.
///
/// Render caches key on item identity **and** revision. Rebuilding a row from a
/// snapshot, an authoritative page or a projector restore creates a new value
/// with the same id, so a per-item counter starting at 0 would let that new
/// instance hit the old instance's parse/summary/changes entry. Taking a fresh
/// revision on every construction makes rebuilds miss instead. Value copies
/// keep their revision, which is correct: they are the same content.
private enum NativeRenderRevision {
    private static let lock = NSLock()
    private static var next = 0

    static func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        next &+= 1
        return next
    }
}

// Native projections of DSH's conversation, usage, and deliverable records.
public struct ChatItem: Identifiable, Equatable {
    public enum Kind: Equatable {
        case user, context, assistant, reasoning, image, toolCall
        case toolResult(isError: Bool)
        case systemEvent, turnError, maxTokens, unknown, status
    }

    public let id: String
    public let kind: Kind
    public var title: String
    public var text: String
    public var streaming = false
    public var timestamp: Date?
    public var messageID: String?
    /// DSH `source.rpcId` of a human prompt or steering submission.
    public var promptRequestID: String?
    /// Set only once that input appears in a durable `user/message` record.
    public var promptJournalSeq: Int?
    public var turn: Int?
    public var step: Int?
    public var callID: String?
    public var toolName: String?
    public var argumentsRaw: String?
    public var arguments: JSONValue?
    public var toolOutput: String?
    public var toolMetadata: JSONValue?
    /// DSH `tool/result.error.code` (e.g. `interrupted`, `AUTO_REVIEW_DENIED`).
    /// Kept beside `toolState` so realtime and replayed rows agree.
    public var toolErrorCode: String?
    public var toolState: NativeToolState?
    /// DSH `user/message.source.kind` for injected/steering messages. nil for
    /// human prompts and ordinary transcript rows.
    public var sourceKind: String?
    /// Optional one-line summary carried by a producer notice.
    public var sourceSummary: String?
    public var turnUsage: NativeTurnUsage?
    public var attachments: [NativeMessageAttachment] = []
    public var rawBlock: JSONValue?
    /// True only for the display-only row painted from
    /// `NativeStreamDraftStore` after an interrupted stream. It is never sent
    /// to the model and never written into the transcript snapshot.
    public var isInterruptedDraft = false
    /// The draft file byte cap forced this row to keep only the text tail.
    public var isInterruptedDraftTruncated = false
    /// Fresh for every constructed value and bumped whenever a field that feeds
    /// the Markdown/summary/changes caches changes. Value copies share it.
    public var renderRevision: Int

    public init(id: String = UUID().uuidString, kind: Kind, title: String, text: String, streaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.streaming = streaming
        self.renderRevision = NativeRenderRevision.take()
    }

    /// Marks this value's rendered content as changed.
    ///
    /// The new revision must come from the same process-wide source as
    /// construction: a per-item `&+= 1` could land on a value the global source
    /// later hands to a re-created instance with the same id, making that new
    /// instance hit this instance's parse/summary/changes entry.
    public mutating func bumpRenderRevision() {
        renderRevision = NativeRenderRevision.take()
    }
}

public enum NativeToolState: String, Equatable {
    case preparing, running, ok, error, stopped
}

public struct NativeTokenUsage: Equatable {
    public var uncachedInputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public var billedInputTokens: Int { uncachedInputTokens + cacheReadTokens + cacheWriteTokens }
    public var totalTokens: Int { billedInputTokens + outputTokens }

    public init?(value: JSONValue?) {
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

    public init(uncachedInputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public var cacheHitPercent: Double? {
        guard billedInputTokens > 0 else { return nil }
        return Double(cacheReadTokens) * 100 / Double(billedInputTokens)
    }
}

public struct NativeTurnUsage: Equatable {
    public var uncachedInputTokens = 0
    public var outputTokens = 0
    public var totalTokens = 0
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?

    public init() {}

    public init?(value: JSONValue?) {
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

    public mutating func add(_ other: NativeTurnUsage) {
        uncachedInputTokens += other.uncachedInputTokens
        outputTokens += other.outputTokens
        totalTokens += other.totalTokens
        cacheReadTokens = other.cacheReadTokens == nil ? nil : cacheReadTokens.map { $0 + (other.cacheReadTokens ?? 0) }
        cacheWriteTokens = other.cacheWriteTokens == nil ? nil : cacheWriteTokens.map { $0 + (other.cacheWriteTokens ?? 0) }
        reasoningTokens = other.reasoningTokens == nil ? nil : reasoningTokens.map { $0 + (other.reasoningTokens ?? 0) }
    }

    public var cacheHitPercent: Double? {
        guard let cacheReadTokens, totalTokens > outputTokens else { return nil }
        return Double(cacheReadTokens) * 100 / Double(totalTokens - outputTokens)
    }
}

/// Official session projection `imageLimits`; the composer's pre-check uses the
/// host values rather than assuming the deployment defaults.
public struct NativeImageLimits: Equatable, Sendable {
    public var maxImagesPerMessage: Int = 20
    public var maxImageBytes: Int = 20 * 1024 * 1024
    public var maxMessageImageBytes: Int = 200 * 1024 * 1024

    public static let fallback = NativeImageLimits()

    public init(maxImagesPerMessage: Int = 20,
                maxImageBytes: Int = 20 * 1024 * 1024,
                maxMessageImageBytes: Int = 200 * 1024 * 1024) {
        self.maxImagesPerMessage = maxImagesPerMessage
        self.maxImageBytes = maxImageBytes
        self.maxMessageImageBytes = maxMessageImageBytes
    }
}

public struct NativeSessionStats: Equatable {
    public var turns: Int
    public var steps: Int
    public var llmMs: Double
    public var toolMs: Double
    public var ttftMs: Double
    public var ttftSteps: Int
    public var decodeMs: Double
    public var decodeTokens: Int

    public init?(value: JSONValue?) {
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

    public var tokensPerSecond: Double? {
        guard decodeMs > 0 else { return nil }
        return Double(decodeTokens) / (decodeMs / 1_000)
    }
}

public struct NativeContextPressure: Equatable {
    public var pressureTokens: Int?
    public var projectedTokens: Int?
    public var contextWindow: Int

    public init?(value: JSONValue?) {
        guard let value, let contextWindow = value["contextWindow"]?.intValue, contextWindow > 0 else { return nil }
        pressureTokens = value["pressureTokens"]?.intValue
        projectedTokens = value["projectedTokens"]?.intValue
        self.contextWindow = contextWindow
    }

    public var usedTokens: Int? { projectedTokens ?? pressureTokens }
    public var percent: Int? {
        guard let usedTokens else { return nil }
        return min(100, max(0, Int((Double(usedTokens) * 100 / Double(contextWindow)).rounded())))
    }
}

public struct NativeContextBreakdown: Equatable {
    public var systemTokens: Int
    public var toolsTokens: Int
    public var messageTokens: Int

    public init?(value: JSONValue?) {
        guard let value,
              let system = value["systemTokens"]?.intValue,
              let tools = value["toolsTokens"]?.intValue,
              let messages = value["messageTokens"]?.intValue else { return nil }
        systemTokens = system
        toolsTokens = tools
        messageTokens = messages
    }
}

public struct NativeMessageAttachment: Equatable {
    public enum Kind: Equatable {
        case image
        case file
        case other
    }
    public var kind: Kind
    public var name: String
    public var path: String?
    public var mimeType: String?
    public var payload: JSONValue

    public init(kind: Kind, name: String, path: String? = nil,
                mimeType: String? = nil, payload: JSONValue) {
        self.kind = kind
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.payload = payload
    }
}

public struct NativeChangedFile: Equatable, Identifiable {
    public var path: String
    public var display: String
    public var added: Int
    public var deleted: Int
    public var binary = false
    public var oversized = false
    public var oldText: String?
    public var newText: String
    public var id: String { path }

    public init(path: String, display: String, added: Int, deleted: Int,
                binary: Bool = false, oversized: Bool = false,
                oldText: String? = nil, newText: String) {
        self.path = path
        self.display = display
        self.added = added
        self.deleted = deleted
        self.binary = binary
        self.oversized = oversized
        self.oldText = oldText
        self.newText = newText
    }
}

public struct NativeChangedFiles: Equatable {
    public var files: [NativeChangedFile]
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var deleted: Int { files.reduce(0) { $0 + $1.deleted } }

    public init(files: [NativeChangedFile]) {
        self.files = files
    }
}

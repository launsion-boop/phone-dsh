// SPDX-License-Identifier: MIT

import Foundation

/// The glyph vocabulary shared with the Agent-facing `FishAction` tool and the
/// renderer. The names are the upstream `FISH_REACTIONS` values, in the same
/// order, so the model-facing enum and the one-shot playback cannot drift.
public enum BotFishReactionVocabulary {
    public static let actions = [
        "waving", "bowing", "clapping", "kiss", "cheering", "shy", "smug", "crying",
        "sighing", "shaking-head", "stretching", "yawning", "high-five", "nod",
        "celebrate", "dancing",
    ]

    public static let expressions = [
        "happy", "sad", "surprised", "confused", "laughing", "love", "angry", "wink",
    ]

    public static let reactions = actions + expressions

    /// Upstream `playFishReaction` keeps an expression on screen for 4 s and
    /// then restores the lifecycle face.
    public static let expressionDurationMs: Int64 = 4_000

    /// One full clip period per action, copied from upstream
    /// `CLIPS`/`EXTRA_PERIODS`. `playAction` clears the action after this
    /// period; a second call is intentionally not required to stop it.
    private static let actionDurations: [String: Int64] = [
        "waving": 1_600,
        "bowing": 2_800,
        "clapping": 1_200,
        "kiss": 2_600,
        "cheering": 1_600,
        "shy": 3_200,
        "smug": 2_600,
        "crying": 2_400,
        "sighing": 3_600,
        "shaking-head": 2_400,
        "stretching": 4_200,
        "yawning": 4_800,
        "high-five": 2_200,
        "nod": 2_000,
        "celebrate": 1_500,
        "dancing": 1_800,
    ]

    public static func kind(for name: String) -> BotFishReactionKind? {
        if actionDurations[name] != nil { return .action }
        if expressions.contains(name) { return .expression }
        return nil
    }

    public static func durationMs(for name: String) -> Int64? {
        switch kind(for: name) {
        case .action: return actionDurations[name]
        case .expression: return expressionDurationMs
        case nil: return nil
        }
    }

    public static func isValid(_ name: String) -> Bool {
        kind(for: name) != nil
    }
}

public enum BotFishReactionKind: String, Codable, Sendable, Equatable {
    case action
    case expression
}

/// A single Agent-driven, cosmetic reaction. The lifecycle state stays
/// authoritative underneath; the renderer overlays this value until `endsAt`
/// and then falls back to the Bot's real lifecycle state.
public struct BotFishReaction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let botID: String?
    public let kind: BotFishReactionKind
    public let name: String
    public let startedAt: Int64
    public let durationMs: Int64

    public var endsAt: Int64 { startedAt + max(0, durationMs) }

    public var lifecycle: BotFishLifecycle? { BotFishLifecycle(rawValue: name) }

    public init(id: String, botID: String? = nil, kind: BotFishReactionKind, name: String,
                startedAt: Int64, durationMs: Int64) {
        self.id = id
        self.botID = botID
        self.kind = kind
        self.name = name
        self.startedAt = max(0, startedAt)
        self.durationMs = max(1, durationMs)
    }

    public func isActive(at time: Int64) -> Bool {
        time >= startedAt && time < endsAt
    }

    /// Turns one `FishAction` tool call into the renderer's one-shot signal.
    ///
    /// Only the tool call is needed: phoneDSH deliberately does not add a
    /// second wire event. The UI sees the Agent's normal `tool/call` session
    /// frame (or `conversation.tool_call` BotEvent) and derives the reaction
    /// locally, so the durable journal and the wire envelope stay unchanged.
    public static func reaction(from toolCall: BotFishToolCall,
                                now: Int64? = nil) -> BotFishReaction? {
        guard bareToolName(toolCall.name) == BotFishActionTool.toolName,
              let arguments = argumentsObject(toolCall.arguments),
              let action = arguments["action"]?.stringValue,
              let kind = BotFishReactionVocabulary.kind(for: action),
              let duration = BotFishReactionVocabulary.durationMs(for: action) else {
            return nil
        }
        let startedAt = max(0, now ?? toolCall.time)
        let fallbackID = "\(toolCall.botID ?? "bot"):\(toolCall.time):\(action)"
        let id = toolCall.id.isEmpty ? fallbackID : toolCall.id
        return BotFishReaction(id: id, botID: toolCall.botID, kind: kind, name: action,
                               startedAt: startedAt, durationMs: duration)
    }

    private static func bareToolName(_ name: String) -> String {
        name.components(separatedBy: "__").last ?? name
    }

    private static func argumentsObject(_ value: BotJSONValue) -> [String: BotJSONValue]? {
        if case .object(let object) = value { return object }
        guard case .string(let text) = value, let data = text.data(using: .utf8),
              let decoded = try? BotJSONValue.parse(data) else { return nil }
        return decoded.objectValue
    }
}

/// One tool invocation in the shape both of phoneDSH's event sources can
/// supply: the live DSH `tool/call` frame or the durable
/// `conversation.tool_call` BotEvent.
public struct BotFishToolCall: Sendable, Equatable {
    public var id: String
    public var botID: String?
    public var name: String
    public var arguments: BotJSONValue
    public var time: Int64

    public init(id: String = "", botID: String? = nil, name: String,
                arguments: BotJSONValue = .object([:]), time: Int64 = 0) {
        self.id = id
        self.botID = botID
        self.name = name
        self.arguments = arguments
        self.time = max(0, time)
    }

    public init?(sessionEvent: BotDSHSessionEvent) {
        guard sessionEvent.type == "tool/call",
              let name = sessionEvent.data["name"]?.stringValue, !name.isEmpty else { return nil }
        self.init(id: sessionEvent.eventID ?? "dsh:\(sessionEvent.seq):tool/call",
                  name: name,
                  arguments: sessionEvent.data["arguments"] ?? .object([:]),
                  time: sessionEvent.time)
    }

    public init?(botEvent: BotEvent) {
        guard botEvent.type == "conversation.tool_call" || botEvent.type == "tool.call",
              let data = botEvent.data.objectValue,
              let name = data["name"]?.stringValue, !name.isEmpty else { return nil }
        self.init(id: botEvent.eventId, botID: botEvent.principal.botId, name: name,
                  arguments: data["arguments"] ?? .object([:]), time: botEvent.time)
    }
}

/// The `FishAction` execution face. It is registered through the existing
/// host-tool seam (`BotMCPRuntime.registerTeamTools`) so executing it does not
/// modify the catalog while the UI still discovers it from the catalog.
public struct BotFishActionTool: BotTeamToolHandling {
    public static let toolName = "FishAction"

    public init() {}

    public nonisolated func handles(_ toolName: String) -> Bool {
        (toolName.components(separatedBy: "__").last ?? toolName) == Self.toolName
    }

    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext) async -> BotMCPCallResult {
        guard handles(name), case .object(let args) = arguments else {
            return .failure("invalid_arguments", "FishAction arguments must be an object")
        }
        guard let action = args["action"]?.stringValue, !action.isEmpty else {
            return .failure("invalid_arguments",
                            "FishAction requires action. Allowed: \(BotFishReactionVocabulary.reactions.joined(separator: ", ")).")
        }
        guard let kind = BotFishReactionVocabulary.kind(for: action),
              let duration = BotFishReactionVocabulary.durationMs(for: action) else {
            return .failure("invalid_arguments",
                            "FishAction: 不支持的动作「\(action)」。可用：\(BotFishReactionVocabulary.reactions.joined(separator: ", ")).")
        }
        // Upstream local-tool wording. This is cosmetic: neither durable task
        // state nor the model's understanding of what happened changes.
        let text = "FishAction: 已在界面播放「\(action)」；这只是外观动作，没有改变任何工作状态。"
        return .success(.object([
            "ok": .bool(true),
            "action": .string(action),
            "kind": .string(kind.rawValue),
            "durationMs": .number(Double(duration)),
        ]), text: text)
    }
}

public extension BotMCPRuntime {
    /// Registers the cosmetic FishAction host tool. The runtime keeps the
    /// catalog unchanged; call this once after building the App's runtime.
    func registerFishActionTool() async {
        await registerTeamTools(BotFishActionTool())
    }
}

// SPDX-License-Identifier: MIT

import Foundation

public enum BotToolCatalog {
    public static let p0Names = [
        "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
        "show_checklist", "show_link", "UpdateMemory", "RecallMemory", "Task", "AwaitTask",
        "StopSubagent", "UpdateRoutine", "ListRoutines", "RequestApproval", "SendToUser",
    ]
    public static let p1TargetNames = ["show_table", "show_callout", "show_info", "show_payload", "show_library"]
    public static let volatileContextName = "BotVolatileContext"
    public static let cardToolNames = Set(p0Names.prefix(7))
    /// Team tools are routed through `BotTeamToolHandling` rather than the
    /// catalog dispatch switch. They are advertised separately so the
    /// upstream P0 golden stays untouched.
    public static let teamToolNames = ["SendToAgent", "CreateTeammate"]
    public static let sendToAgentName = "SendToAgent"
    public static let createTeammateName = "CreateTeammate"

    /// FishAction is advertised by the catalog but executed through the same
    /// host-tool seam as the team tools. The model-facing enum is the upstream
    /// `FISH_REACTIONS` vocabulary; `isRegistered` stays false so the runtime
    /// never lets the generic catalog dispatch claim the cosmetic call.
    public static let fishActionName = "FishAction"
    public static let fishActionNames = [fishActionName]
    public static let fishActions = BotFishReactionVocabulary.actions
    public static let fishExpressions = BotFishReactionVocabulary.expressions
    public static let fishReactions = BotFishReactionVocabulary.reactions

    public static let definitions: [BotMCPToolDefinition] = [
        tool("ask_user", "Show a question card with 2-4 concrete suggested replies. The host assigns each option a stable optionID. Put a clearly best option first, mark at most one option recommended:true (or style:primary), and never recommend a danger option. A successful card ends the turn.", schema([
            "question": string(), "options": array(object([
                "label": string(), "value": string(), "style": enumString(["primary", "default", "danger"]),
                "recommended": bool(), "description": string(),
            ], required: ["label"]), minItems: 2, maxItems: 4),
            "helpText": string(),
        ], required: ["question", "options"])),
        tool("show_next_steps", "Offer 2-4 tappable next actions. Put a clearly best step first, mark at most one step recommended:true (or style:primary), and never recommend a danger step. A successful card ends the turn.", schema([
            "steps": array(.object(["anyOf": .array([string(), object([
                "label": string(), "value": string(), "description": string(),
                "style": enumString(["primary", "default", "danger"]), "recommended": bool(),
            ], required: ["label"])])]), minItems: 2, maxItems: 4),
        ], required: ["steps"])),
        tool("show_attachment", "Attach a file to the chat as an attachment card.", schema([
            "path": string(), "caption": string(),
        ], required: ["path"])),
        tool("show_document", "Show a document card for an existing workspace document or inline Markdown.", schema([
            "title": string(), "summary": string(), "path": string(), "content": string(),
            "toc": array(string()), "parseHeadings": bool(),
            "kind": enumString(["document", "markdown", "table", "pdf", "code", "library"]),
            "kindLabel": string(), "fileName": string(), "size": string(),
        ], additionalProperties: false)),
        tool("show_progress", "Show or update a progress card. Reuse cardKey to update the same row.", schema([
            "title": string(), "state": enumString(["running", "done", "paused", "failed", "cancelled"]),
            "percent": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(100)]),
            "summary": string(),
            "steps": array(object([
                "label": string(), "state": enumString(["pending", "active", "done", "failed", "skipped"]),
                "detail": string(),
            ], required: ["label"]), maxItems: 8),
            "eta": string(), "cardKey": string(),
        ], required: ["title"], additionalProperties: false)),
        tool("show_checklist", "Show a checklist card with 1-12 items.", schema([
            "title": string(),
            "items": array(object(["text": string(), "done": bool(), "note": string()], required: ["text"]), minItems: 1, maxItems: 12),
            "summary": string(), "interactive": bool(),
        ], required: ["title", "items"], additionalProperties: false)),
        tool("show_link", "Show 1-4 HTTP/HTTPS links as a link-preview card.", schema([
            "title": string(),
            "links": array(object([
                "url": string(), "title": string(), "site": string(), "description": string(),
                "kind": enumString(["doc", "repo", "article", "video", "tool", "other"]),
            ], required: ["url"]), minItems: 1, maxItems: 4),
        ], required: ["links"], additionalProperties: false)),
        tool("UpdateMemory", "Write or forget one durable memory fact.", schema([
            "action": .object(["type": .string("string"), "enum": .array([.string("write"), .string("forget")])]),
            "fact": string(), "fact_id": string(),
            "tier": .object(["type": .string("string"), "enum": .array([.string("profile"), .string("log"), .string("note")]), "default": .string("log")]),
            "scope": enumString(["agent", "user"]), "key": string(),
        ], additionalProperties: false)),
        tool("RecallMemory", "Search durable memory in agent and user scopes.", schema([
            "query": string(), "limit": .object(["type": .string("number"), "minimum": .number(1), "maximum": .number(50)]),
            "scope": enumString(["agent", "user", "all"]),
        ], additionalProperties: false)),
        tool("Task", "Delegate work to another DSH session in the same runtime; async tasks wake the parent with a hidden turn.", schema([
            "description": string(), "prompt": string(), "task_description": string(), "task_title": string(),
            "subagent_type": enumString(["executor"]), "async": bool(),
            "model": string(), "model_override": string(), "allowed_write_directories": array(string()),
            "max_mode_override": bool(), "default_expanded_while_running": bool(), "agent_id": string(),
            "attachments": array(string()), "mode": string(), "responding_to_message_ids": array(string()),
            "environment": string(), "machine": .object(["type": .string("object")]), "timeout_ms": .object(["type": .string("number")]),
        ])),
        tool("AwaitTask", "Wait for an async Task; a timeout leaves it running.", schema([
            "task_id": string(), "timeout_ms": .object(["type": .string("number")]),
        ], required: ["task_id"], additionalProperties: false)),
        tool("StopSubagent", "Cancel one running Task and keep its partial result.", schema([
            "task_id": string(), "id": string(),
        ], additionalProperties: false)),
        tool("UpdateRoutine", "Create, update, delete, inspect, pause or resume routines.", schema([
            "action": enumString(["create", "update", "delete", "list", "get", "pause", "resume"]),
            "routine_id": string(), "title": string(), "prompt": string(),
            "schedule": .object(["oneOf": .array([string(), object([
                "kind": enumString(["interval", "daily", "weekly", "cron"]),
                "everyMinutes": .object(["type": .string("integer")]), "time": string(),
                "weekdays": array(.object(["type": .string("integer")])), "expr": string(), "timezone": string(),
            ], required: ["kind"])])]),
            "enabled": bool(), "delivery": enumString(["held", "interrupt"]),
            "interrupt_reason": string(), "urgent": bool(), "urgent_reason": string(),
        ], required: ["action"], additionalProperties: false)),
        tool("ListRoutines", "List this bot's routines (read-only).", schema([:], additionalProperties: false)),
        tool("RequestApproval", "Ask the user for permission and block until they answer; timeout denies.", schema([
            "action": string(), "detail": string(), "command": string(),
        ], required: ["action"])),
        tool("SendToUser", "Send one message to the user in this chat.", schema([
            "message": string(),
        ], required: ["message"])),
    ]

    /// Team tools without a roster line. `allDefinitions(roster:callerBotID:)`
    /// rebuilds both descriptions with the live sendable roster.
    public static let baseTeamDefinitions: [BotMCPToolDefinition] = [
        teamTool(sendToAgentName,
                 sendToAgentDescription,
                 schema([
                     "agent_id": string(), "message": string(),
                     "priority": bool(), "delivery": enumString(["now", "queued"]),
                     "title": string(),
                     "target_id": string(), "bot_name": string(),
                     "agentId": string(), "text": string(),
                 ], required: ["agent_id", "message"])),
        teamTool(createTeammateName,
                 createTeammateDescription,
                 schema([
                     "name": string(), "description": string(),
                     "color": enumString(BotFishColor.allCases.map(\.rawValue)),
                     "hairstyle": enumString(BotFishHairstyle.allCases.map(\.rawValue)),
                     "section_id": string(),
                 ], required: ["name"], additionalProperties: false)),
    ]

    /// Both descriptions contain the sendable roster, excluding the caller and
    /// every Bot the user hid. A hidden Bot is still reachable by id/name; it
    /// is only absent from the model-facing list, like the upstream roster
    /// injection with the phone privacy fix applied.
    ///
    /// `CreateTeammate` is only advertised to the roster's main Bot. A caller
    /// that cannot be identified (`nil`) keeps the historical two-tool list so
    /// a standard MCP client that never sends caller identity sees no change;
    /// the execution path still enforces the main-Bot rule.
    public static func teamDefinitions(roster: BotRoster,
                                        callerBotID: String?) -> [BotMCPToolDefinition] {
        let line = availableBotsLine(roster: roster, callerBotID: callerBotID)
        var definitions = [
            teamTool(sendToAgentName, sendToAgentDescription + "\n" + line,
                     baseTeamDefinitions[0].inputSchema),
            teamTool(createTeammateName, createTeammateDescription + "\n" + line,
                     baseTeamDefinitions[1].inputSchema),
        ]
        if let callerBotID, roster.mainBotID != callerBotID {
            definitions.removeAll { $0.name == createTeammateName }
        }
        return definitions
    }

    public static func allDefinitions(roster: BotRoster,
                                      callerBotID: String?) -> [BotMCPToolDefinition] {
        definitions + [fishActionDefinition, volatileContextDefinition]
            + teamDefinitions(roster: roster, callerBotID: callerBotID)
    }

    /// `name (id: <id>[, main Bot])` entries for the sendable roster.
    public static func availableBotEntries(roster: BotRoster,
                                           callerBotID: String?) -> [String] {
        roster.visibleBots.compactMap { bot in
            guard bot.id != callerBotID else { return nil }
            if bot.id == roster.mainBotID {
                return "\(bot.name) (id: \(bot.id), main Bot)"
            }
            return "\(bot.name) (id: \(bot.id))"
        }
    }

    public static func availableBotsLine(roster: BotRoster,
                                         callerBotID: String?) -> String {
        let entries = availableBotEntries(roster: roster, callerBotID: callerBotID)
        return "Available bots: \(entries.isEmpty ? "(none)" : entries.joined(separator: "; "))."
    }

    /// Upstream `tools/fish.cjs` description, verbatim: cosmetic, at most once
    /// per reply, never completion evidence, and never forced on a plain or
    /// serious answer.
    public static let fishActionDescription =
        "Play one cosmetic gesture or temporary facial expression on the DS big-fish character. "
        + "Use it at most once per reply, only when the emotional beat genuinely fits (celebration, apology, shyness, cheering the user up). "
        + "It never changes task state, progress, files, approvals or what actually happened; never use it as evidence that work is done. "
        + "Do not use it when the user asks for a plain, serious answer. "
        + "Actions: \(fishActions.joined(separator: ", ")). "
        + "Expressions: \(fishExpressions.joined(separator: ", "))."

    public static let fishActionDefinition = BotMCPToolDefinition(
        name: fishActionName,
        description: fishActionDescription,
        inputSchema: schema([
            "action": enumString(fishReactions),
        ], required: ["action"], additionalProperties: false))

    public static let volatileContextDefinition = BotMCPToolDefinition(
        name: volatileContextName,
        description: "Return only the caller session's current Bot variant, persona, memory and automation snapshot.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("sessionId")]),
            "properties": .object(["sessionId": .object([
                "type": .string("string"), "minLength": .number(1), "maxLength": .number(200),
            ])]),
            "additionalProperties": .bool(false),
        ]))

    public static var allDefinitions: [BotMCPToolDefinition] {
        definitions + [fishActionDefinition, volatileContextDefinition] + baseTeamDefinitions
    }

    public static func isRegistered(_ name: String) -> Bool {
        name == volatileContextName || p0Names.contains(name)
    }

    public static func isTeamTool(_ name: String) -> Bool {
        teamToolNames.contains(name)
    }

    public static func isFishTool(_ name: String) -> Bool {
        (name.components(separatedBy: "__").last ?? name) == fishActionName
    }

    private static let sendToAgentDescription =
        "Send an asynchronous message to another bot in the roster. The target "
        + "receives it as a normal new turn and answers in its own transcript; "
        + "its reply later arrives here as an inbound agent-comm row on the same "
        + "thread. You must pass priority or delivery: priority true / delivery "
        + "\"now\" wakes the target now; priority false / delivery \"queued\" holds "
        + "the message for their next turn and does not wake them. Never send to "
        + "yourself and do not poll for the reply."

    private static let createTeammateDescription =
        "Create a teammate Bot in this DSH Bot roster. Only the main Bot may call "
        + "this tool; any other Bot receives a permission error. The new Bot gets "
        + "its own transcript and memory. `section_id` is accepted and ignored "
        + "(sidebar sections are not rendered)."

    private static func teamTool(_ name: String, _ description: String,
                                 _ inputSchema: BotJSONValue) -> BotMCPToolDefinition {
        BotMCPToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }

    private static func tool(_ name: String, _ description: String, _ inputSchema: BotJSONValue) -> BotMCPToolDefinition {
        BotMCPToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }

    private static func schema(_ properties: [String: BotJSONValue], required: [String] = [], additionalProperties: Bool? = nil) -> BotJSONValue {
        var result: [String: BotJSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { result["required"] = .array(required.map(BotJSONValue.string)) }
        if let additionalProperties { result["additionalProperties"] = .bool(additionalProperties) }
        return .object(result)
    }

    private static func object(_ properties: [String: BotJSONValue], required: [String] = []) -> BotJSONValue {
        var result: [String: BotJSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { result["required"] = .array(required.map(BotJSONValue.string)) }
        return .object(result)
    }

    private static func array(_ items: BotJSONValue, minItems: Int? = nil, maxItems: Int? = nil) -> BotJSONValue {
        var result: [String: BotJSONValue] = ["type": .string("array"), "items": items]
        if let minItems { result["minItems"] = .number(Double(minItems)) }
        if let maxItems { result["maxItems"] = .number(Double(maxItems)) }
        return .object(result)
    }

    private static func string() -> BotJSONValue { .object(["type": .string("string")]) }
    private static func bool() -> BotJSONValue { .object(["type": .string("boolean")]) }
    private static func enumString(_ values: [String]) -> BotJSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(BotJSONValue.string))])
    }
}

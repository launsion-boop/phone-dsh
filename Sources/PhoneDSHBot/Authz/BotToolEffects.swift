// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public enum BotToolMutability: String, Codable, Sendable {
    case read
    case write
    case externalSend = "external-send"
    case destructive
}

public enum BotToolPolicy: String, Codable, Sendable {
    case auto
    case ask
}

public enum BotToolLanguage: String, Codable, Sendable {
    case zh
    case en
}

public struct BotToolEffect: Codable, Sendable, Equatable {
    public let tool: String
    public let operation: String
    public let resource: String
    public let target: String
    public let mutability: BotToolMutability
    public let policy: BotToolPolicy
    public let label: String
    public let detail: String
    public let ui: Bool
    public let execution: String?
    public let known: Bool
    public let isMcp: Bool

    public init(tool: String, operation: String, resource: String, target: String? = nil,
                mutability: BotToolMutability, policy: BotToolPolicy, label: String = "",
                detail: String = "", ui: Bool = false, execution: String? = nil,
                known: Bool = true, isMcp: Bool = false) {
        self.tool = tool
        self.operation = operation
        self.resource = resource
        self.target = target ?? resource
        self.mutability = mutability
        self.policy = policy
        self.label = label
        self.detail = detail
        self.ui = ui
        self.execution = execution
        self.known = known
        self.isMcp = isMcp
    }
}

public enum BotToolEffectClassifier {
    private static let prefix = "mcp__dshbot__"
    private static let uiLabels: [String: (String, String)] = [
        "ask_user": ("詢問使用者", "Ask the user"),
        "show_attachment": ("顯示附件卡片", "Show an attachment card"),
        "show_next_steps": ("顯示下一步建議", "Show next-step suggestions"),
        "show_document": ("顯示文件卡片", "Show a document card"),
        "show_library": ("顯示文件庫卡片", "Show a library card"),
        "show_info": ("顯示資訊卡片", "Show an info card"),
        "show_payload": ("顯示資料卡片", "Show a payload card"),
        "show_progress": ("顯示進度卡片", "Show a progress card"),
        "show_checklist": ("顯示清單卡片", "Show a checklist card"),
        "show_link": ("顯示連結卡片", "Show a link card"),
        "show_table": ("顯示表格卡片", "Show a table card"),
        "show_callout": ("顯示提示卡片", "Show a callout card"),
        "ReportVerification": ("記錄驗證結論", "Record a verification verdict"),
        "FishAction": ("播放角色動作", "Play a character action"),
        "RequestApproval": ("請求使用者授權", "Request user approval"),
    ]

    public static func policy(for name: String, arguments: BotJSONValue = .object([:])) -> BotToolPolicy {
        effect(for: name, arguments: arguments).policy
    }

    public static func effect(for name: String, arguments: BotJSONValue = .object([:]),
                              language: BotToolLanguage = .zh) -> BotToolEffect {
        let args = object(arguments)
        let isMcp = name.hasPrefix("mcp__")
        let bareName = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count))
            : name.hasPrefix("mcp__phone__") ? String(name.dropFirst("mcp__phone__".count)) : name
        if let labels = uiLabels[bareName] {
            return BotToolEffect(tool: bareName, operation: "ui.\(bareName)", resource: "*",
                                 mutability: .read, policy: .auto,
                                 label: language == .zh ? labels.0 : labels.1,
                                 detail: defaultDetail(name: name, args: args, language: language),
                                 ui: true, isMcp: isMcp)
        }
        switch bareName {
        case "bluetooth.scan", "network.browse":
            return BotDeviceToolProvider.discoveryEffect(for: bareName)
        case "UpdateMemory":
            return memoryEffect(args, forceForget: false, language: language, isMcp: isMcp)
        case "ForgetMemory":
            return memoryEffect(args, forceForget: true, language: language, isMcp: isMcp)
        case "RecallMemory", "SortMemories":
            let operation = bareName == "RecallMemory" ? "memory.recall" : "memory.sort"
            let label = bareName == "RecallMemory" ? "回想記憶" : "檢視記憶順序"
            return BotToolEffect(tool: bareName, operation: operation, resource: "*",
                                 mutability: .read, policy: .auto,
                                 label: language == .zh ? label : bareName,
                                 detail: defaultDetail(name: name, args: args, language: language),
                                 isMcp: isMcp)
        case "Task":
            let title = clip(firstNonEmpty(args["description"], args["task_title"]), max: 80)
            let prompt = clip(firstNonEmpty(args["prompt"], args["task_description"]), max: 120)
            let resource = mergedResource(["task=\(title)", "prompt=\(prompt)"])
            return BotToolEffect(tool: bareName, operation: "dshbot.Task",
                                 resource: resource.isEmpty ? "dshbot:task:*" : resource,
                                 mutability: .write, policy: .auto,
                                 label: language == .zh
                                    ? (title.isEmpty ? "啟動子代理任務" : "啟動子代理任務「\(title)」")
                                    : (title.isEmpty ? "Start a subagent task" : "Start subagent task \"\(title)\""),
                                 detail: language == .zh
                                    ? "會啟動一個子代理並使用模型額度。"
                                    : "Starts a subagent and consumes model budget.",
                                 isMcp: isMcp)
        case "AwaitTask":
            return readEffect(name: name, bareName: bareName, operation: "dshbot.AwaitTask",
                              zhLabel: "等待子代理結果", args: args, language: language, isMcp: isMcp)
        case "StopSubagent":
            let id = clip(firstNonEmpty(args["task_id"], args["id"]), max: 120)
            return BotToolEffect(tool: bareName, operation: "dshbot.StopSubagent",
                                 resource: id.isEmpty ? "dshbot:stop-subagent:*" : "task=\(id)",
                                 mutability: .write, policy: .auto,
                                 label: language == .zh
                                    ? (id.isEmpty ? "停止子代理任務" : "停止子代理任務 \(id)")
                                    : (id.isEmpty ? "Stop a subagent task" : "Stop subagent task \(id)"),
                                 detail: language == .zh
                                    ? "中止正在執行的子代理，保留可讀的部分結果。"
                                    : "Aborts a running subagent and keeps its partial result readable.",
                                 isMcp: isMcp)
        case "SendToUser":
            let preview = clip(args["message"], max: 180)
            return BotToolEffect(tool: bareName, operation: "dshbot.SendToUser",
                                 resource: "dshbot:send-to-user", mutability: .externalSend,
                                 policy: .auto,
                                 label: language == .zh ? "傳送訊息給使用者" : "Send a message to the user",
                                 detail: language == .zh
                                    ? "在對話中送出一則訊息\(preview.isEmpty ? "" : "：\(preview)")"
                                    : "Posts one message into the conversation\(preview.isEmpty ? "" : ": \(preview)")",
                                 isMcp: isMcp)
        case BotDeviceReplyTool.toolName:
            // Host extension (tool-effects.json hostExtensions): the pure
            // argument classifier can only name the staged source. The runtime
            // resolves the concrete device id and session and replaces
            // resource/target before authorization; the model cannot name a
            // destination. Keeping it registered means it is a known effect
            // instead of an unclassified, fail-closed write.
            return BotToolEffect(
                tool: BotDeviceReplyTool.toolName, operation: "device.reply",
                resource: "device:*", target: "*", mutability: .externalSend, policy: .ask,
                label: "回覆來源設備",
                detail: "host resolves the staged source (deviceID, transport, mapped transport session) and replaces resource/target with the concrete values before execution; the model cannot name a destination",
                execution: "device-reply")
        case "UpdateRoutine":
            let title = clip(args["title"], max: 80)
            let action = args["action"].map { clip($0, max: 40) } ?? "update"
            let prompt = clip(args["prompt"], max: 120)
            let schedule = clip(args["schedule"], max: 120)
            let resource = mergedResource([
                "action=\(action)", "routine=\(clip(args["routine_id"], max: 120))",
                "title=\(title)", schedule.isEmpty ? "" : "schedule=\(schedule)",
                prompt.isEmpty ? "" : "prompt=\(prompt)",
            ])
            return BotToolEffect(tool: bareName, operation: "dshbot.UpdateRoutine",
                                 resource: resource.isEmpty ? "dshbot:routine:*" : resource,
                                 mutability: .write, policy: .auto,
                                 label: language == .zh
                                    ? (title.isEmpty ? "更新例行工作" : "更新例行工作「\(title)」")
                                    : (title.isEmpty ? "Update a routine" : "Update routine \"\(title)\""),
                                 detail: language == .zh
                                    ? "建立、修改或刪除本機例行工作\(schedule.isEmpty ? "" : "；排程：\(schedule)")\(prompt.isEmpty ? "" : "；指示：\(prompt)")。"
                                    : "Create, change or delete a local routine\(schedule.isEmpty ? "" : "; schedule: \(schedule)")\(prompt.isEmpty ? "" : "; prompt: \(prompt)").",
                                 isMcp: isMcp)
        case "ListRoutines":
            return BotToolEffect(tool: bareName, operation: "dshbot.ListRoutines", resource: "*",
                                 mutability: .read, policy: .auto,
                                 label: language == .zh ? "列出例行工作" : "List routines",
                                 detail: defaultDetail(name: name, args: args, language: language),
                                 isMcp: isMcp)
        default:
            let target = isMcp ? name : bareName
            let suffix = (try? BotArgumentsDigest.resourceSuffix(for: arguments)) ?? "args=invalid"
            let resource = mergedResource(["unclassified=\(target)", suffix])
            return BotToolEffect(tool: target.isEmpty ? "unclassified" : target,
                                 operation: "tool.unclassified", resource: resource,
                                 mutability: .write, policy: .ask,
                                 label: language == .zh ? "執行未分類工具 \(target)" : "Run unclassified tool \(target)",
                                 detail: language == .zh
                                    ? "這個工具沒有在效果分類表中登記；依預設需要使用者審批。"
                                    : "This tool is not registered in the effect table; it is write-class by default and needs approval.",
                                 execution: nil, known: false, isMcp: isMcp)
        }
    }

    private static func memoryEffect(_ args: [String: BotJSONValue], forceForget: Bool,
                                     language: BotToolLanguage, isMcp: Bool) -> BotToolEffect {
        let action = forceForget || string(args["action"]).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "forget" ? "forget" : "write"
        let scope = string(args["scope"]) == "user" ? "user" : "agent"
        if action == "forget" {
            let fact = clip(firstNonEmpty(args["fact"], args["key"]), max: 300)
            let factId = clip(firstNonEmpty(args["fact_id"], args["factId"]), max: 200)
            let resource = mergedResource(["memory:\(scope)",
                factId.isEmpty ? "fact=\(fact)" : "fact_id=\(factId)"])
            return BotToolEffect(tool: "memory", operation: "memory.forget",
                                 resource: resource.isEmpty ? "memory:\(scope):fact:*" : resource,
                                 mutability: .destructive, policy: scope == "user" ? .ask : .auto,
                                 label: language == .zh
                                    ? (factId.isEmpty ? "忘記記憶「\(clip(fact, max: 60))」" : "忘記記憶（fact_id）")
                                    : (factId.isEmpty ? "Forget memory \"\(clip(fact, max: 60))\"" : "Forget a memory (fact_id)"),
                                 detail: language == .zh
                                    ? "從 \(scope == "user" ? "使用者共用" : "這個 Bot 的")記憶移除一則事實。"
                                    : "Remove one fact from the \(scope == "user" ? "shared user" : "Bot") memory.",
                                 execution: "memory", isMcp: isMcp)
        }
        let fact = clip(args["fact"], max: 400)
        let requestedTier = string(args["tier"])
        let tier = ["profile", "log", "note"].contains(requestedTier) ? requestedTier : "log"
        let key = clip(args["key"], max: 200)
        let resource = mergedResource(["memory:\(scope)", "tier=\(tier)",
                                       key.isEmpty ? "" : "key=\(key)", "fact=\(fact)"])
        return BotToolEffect(tool: "memory", operation: "memory.write", resource: resource,
                             mutability: .write, policy: .auto,
                             label: language == .zh
                                ? "寫入記憶：\(clip(fact, max: 60).isEmpty ? "一則事實" : clip(fact, max: 60))"
                                : "Save a memory: \(clip(fact, max: 60).isEmpty ? "one fact" : clip(fact, max: 60))",
                             detail: language == .zh
                                ? "寫入 \(scope == "user" ? "使用者共用" : "這個 Bot 的")\(tier) 記憶。"
                                : "Write one \(tier) fact into the \(scope == "user" ? "shared user" : "Bot") memory.",
                             execution: "memory", isMcp: isMcp)
    }

    private static func readEffect(name: String, bareName: String, operation: String,
                                   zhLabel: String, args: [String: BotJSONValue],
                                   language: BotToolLanguage, isMcp: Bool) -> BotToolEffect {
        BotToolEffect(tool: bareName, operation: operation, resource: "*",
                      mutability: .read, policy: .auto,
                      label: language == .zh ? zhLabel : bareName,
                      detail: defaultDetail(name: name, args: args, language: language), isMcp: isMcp)
    }

    private static func defaultDetail(name: String, args: [String: BotJSONValue],
                                      language: BotToolLanguage) -> String {
        let preferred = ["question", "options", "path", "caption", "title", "content",
                         "query", "limit", "action", "detail"]
        let suppressed: Set<String> = ["body", "prompt", "message", "expectedStateToken", "acting_user_id"]
        let keys = args.keys.filter { !suppressed.contains($0) && !isNull(args[$0]) }.sorted {
            let left = preferred.firstIndex(of: $0) ?? Int.max
            let right = preferred.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
        let pairs = keys.prefix(6).map { key -> String in
            let value = args[key]!
            let text: String
            switch value {
            case .object, .array:
                text = (try? String(data: value.encoded(), encoding: .utf8)) ?? ""
            default:
                text = string(value)
            }
            return "\(key)=\(clip(text, max: 160))"
        }
        let prefix = language == .zh ? "工具 \(name)" : "Tool \(name)"
        return pairs.isEmpty ? prefix : "\(prefix)（\(pairs.joined(separator: ", "))）"
    }

    private static func object(_ value: BotJSONValue) -> [String: BotJSONValue] {
        if case .object(let object) = value { return object }
        return [:]
    }

    private static func isNull(_ value: BotJSONValue?) -> Bool {
        guard let value else { return true }
        if case .null = value { return true }
        return false
    }

    private static func firstNonEmpty(_ values: BotJSONValue?...) -> BotJSONValue? {
        for value in values where !string(value).isEmpty { return value }
        return nil
    }

    private static func string(_ value: BotJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, number >= Double(Int64.min),
               number < 9_223_372_036_854_775_808.0 {
                return String(Int64(number))
            }
            return String(number)
        case .array(let values): return values.map { string($0) }.joined(separator: ",")
        case .object: return (try? String(data: value.encoded(), encoding: .utf8)) ?? ""
        }
    }

    private static func clip(_ value: BotJSONValue?, max: Int = 120) -> String {
        clip(string(value), max: max)
    }

    private static func clip(_ value: String, max: Int) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let units = Array(text.utf16)
        guard units.count > max else { return text }
        return String(decoding: units.prefix(Swift.max(0, max - 1)), as: UTF16.self) + "…"
    }

    private static func mergedResource(_ parts: [String]) -> String {
        BotResourceNormalizer.normalize(parts.filter { !$0.isEmpty }.joined(separator: "&"))
    }
}

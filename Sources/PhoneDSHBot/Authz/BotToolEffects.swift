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
    /// Stable resource to store for an `always`/`session` grant. `nil` keeps
    /// the exact call resource, so bash/memory grants remain path-specific.
    /// Image tools set `model:image` so the next image in the same scope does
    /// not create a second approval card.
    public let grantResource: String?

    public init(tool: String, operation: String, resource: String, target: String? = nil,
                mutability: BotToolMutability, policy: BotToolPolicy, label: String = "",
                detail: String = "", ui: Bool = false, execution: String? = nil,
                known: Bool = true, isMcp: Bool = false, grantResource: String? = nil) {
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
        self.grantResource = grantResource
    }
}

public enum BotToolEffectClassifier {
    private static let prefix = "mcp__dshbot__"
    private static let uiLabels: [String: (String, String)] = [
        "ask_user": ("询问用户", "Ask the user"),
        "show_attachment": ("显示附件卡片", "Show an attachment card"),
        "show_next_steps": ("显示下一步建议", "Show next-step suggestions"),
        "show_document": ("显示文件卡片", "Show a document card"),
        "show_library": ("显示文件库卡片", "Show a library card"),
        "show_info": ("显示信息卡片", "Show an info card"),
        "show_payload": ("显示数据卡片", "Show a payload card"),
        "show_progress": ("显示进度卡片", "Show a progress card"),
        "show_checklist": ("显示清单卡片", "Show a checklist card"),
        "show_link": ("显示链接卡片", "Show a link card"),
        "show_table": ("显示表格卡片", "Show a table card"),
        "show_callout": ("显示提示卡片", "Show a callout card"),
        "ReportVerification": ("记录验证结论", "Record a verification verdict"),
        "FishAction": ("播放角色动作", "Play a character action"),
        "RequestApproval": ("请求用户授权", "Request user approval"),
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
        case "ble_devices", "ble_read", "ble_alert", "ble_link_tools", "ble_link_call", "ble_link_result":
            // Tool names come from PR59's `spec/v1/native-mcp.md` "BLE tools"
            // (forwarded as `mcp__phone__ble_*`). The real authorization gate is
            // PR59's per-connection grant; this `ask` effect is only an
            // additional Bot-layer approval over the untrusted device data.
            return bleEffect(bareName, args: args, language: language, isMcp: isMcp)
        case "UpdateMemory":
            return memoryEffect(args, forceForget: false, language: language, isMcp: isMcp)
        case "ForgetMemory":
            return memoryEffect(args, forceForget: true, language: language, isMcp: isMcp)
        case "ReadMemory":
            return readEffect(name: name, bareName: bareName, operation: "memory.read",
                              zhLabel: "读取记忆", args: args,
                              language: language, isMcp: isMcp)
        case "RecallMemory", "SortMemories":
            let operation = bareName == "RecallMemory" ? "memory.recall" : "memory.sort"
            let label = bareName == "RecallMemory" ? "回想记忆" : "查看记忆顺序"
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
                                    ? (title.isEmpty ? "启动子代理任务" : "启动子代理任务「\(title)」")
                                    : (title.isEmpty ? "Start a subagent task" : "Start subagent task \"\(title)\""),
                                 detail: language == .zh
                                    ? "会启动一个子代理并使用模型额度。"
                                    : "Starts a subagent and consumes model budget.",
                                 isMcp: isMcp)
        case "AwaitTask":
            return readEffect(name: name, bareName: bareName, operation: "dshbot.AwaitTask",
                              zhLabel: "等待子代理结果", args: args, language: language, isMcp: isMcp)
        case "StopSubagent":
            let id = clip(firstNonEmpty(args["task_id"], args["id"]), max: 120)
            return BotToolEffect(tool: bareName, operation: "dshbot.StopSubagent",
                                 resource: id.isEmpty ? "dshbot:stop-subagent:*" : "task=\(id)",
                                 mutability: .write, policy: .auto,
                                 label: language == .zh
                                    ? (id.isEmpty ? "停止子代理任务" : "停止子代理任务 \(id)")
                                    : (id.isEmpty ? "Stop a subagent task" : "Stop subagent task \(id)"),
                                 detail: language == .zh
                                    ? "中止正在执行的子代理，保留可读的部分结果。"
                                    : "Aborts a running subagent and keeps its partial result readable.",
                                 isMcp: isMcp)
        case "read_image":
            // DSH's built-in fs tool commits an image and asks the model route
            // to inspect it. The Worker gate must present the same external
            // send effect so the approval card and grants agree.
            let target = clip(args["path"], max: 200)
            return BotToolEffect(
                tool: bareName, operation: "model.image.attach",
                resource: target.isEmpty ? "model:image" : "attachment=\(target)",
                target: target.isEmpty ? "model:image" : target,
                mutability: .externalSend, policy: .ask,
                label: language == .zh ? "把图片发送给模型" : "Send an image to the model",
                detail: language == .zh
                    ? "把工作区图片发送给模型服务，让模型看到像素。"
                    : "Sends a workspace image to the model service so the model can see its pixels.",
                isMcp: isMcp, grantResource: "model:image")
        case "attach_to_model":
            let purpose = clip(args["purpose"], max: 120)
            let target = clip(firstNonEmpty(args["path"], args["fileId"], args["photoId"]), max: 200)
            return BotToolEffect(
                tool: bareName, operation: "model.image.attach",
                resource: target.isEmpty ? "model:image" : "attachment=\(target)",
                target: target.isEmpty ? "model:image" : target,
                mutability: .externalSend, policy: .ask,
                label: language == .zh ? "把图片发送给模型" : "Send an image to the model",
                detail: language == .zh
                    ? "把图片发送给模型服务，让模型看到像素。\(purpose.isEmpty ? "" : "用途：\(purpose)")"
                    : "Sends the image to the model service so the model can see its pixels.\(purpose.isEmpty ? "" : " Purpose: \(purpose)")",
                isMcp: isMcp, grantResource: "model:image")
        case "SendToUser":
            let preview = clip(args["message"], max: 180)
            return BotToolEffect(tool: bareName, operation: "dshbot.SendToUser",
                                 resource: "dshbot:send-to-user", mutability: .externalSend,
                                 policy: .auto,
                                 label: language == .zh ? "发送消息给用户" : "Send a message to the user",
                                 detail: language == .zh
                                    ? "在对话中发送一条消息\(preview.isEmpty ? "" : "：\(preview)")"
                                    : "Posts one message into the conversation\(preview.isEmpty ? "" : ": \(preview)")",
                                 isMcp: isMcp)
        case "SendToAgent":
            let target = clip(firstNonEmpty(args["agent_id"], args["target_id"],
                                            args["bot_name"], args["agentId"]), max: 120)
            let preview = clip(firstNonEmpty(args["message"], args["text"]), max: 180)
            let resource = mergedResource([
                target.isEmpty ? "dshbot:send-to-agent" : "agent=\(target)",
                preview.isEmpty ? "" : "message=\(preview)",
            ])
            return BotToolEffect(tool: bareName, operation: "dshbot.SendToAgent",
                                 resource: resource.isEmpty ? "dshbot:send-to-agent" : resource,
                                 mutability: .externalSend, policy: .auto,
                                 label: language == .zh ? "发送消息给其他 Bot" : "Send a message to another bot",
                                 detail: language == .zh
                                    ? "把消息发给另一个 Bot，对方回复后会以 agent-comm 行返回；这是对外动作，结果未知时不自动重试。"
                                    : "Sends a message to another Bot and records the reply as an agent-comm row; this is an external action and must not be retried automatically when the outcome is unknown.",
                                 isMcp: isMcp)
        case "CreateTeammate":
            let name = clip(args["name"], max: 80)
            let resource = mergedResource([
                "dshbot:create-teammate", name.isEmpty ? "" : "name=\(name)",
            ])
            return BotToolEffect(tool: bareName, operation: "dshbot.CreateTeammate",
                                 resource: resource.isEmpty ? "dshbot:create-teammate" : resource,
                                 mutability: .write, policy: .auto,
                                 label: language == .zh ? "创建队友 Bot" : "Create a teammate Bot",
                                 detail: language == .zh
                                    ? "创建一个有独立对话与记忆的 Bot；只有主 Bot 可以调用。"
                                    : "Creates a Bot with its own transcript and memory; only the main Bot may call it.",
                                 isMcp: isMcp)
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
                                    ? (title.isEmpty ? "更新例行任务" : "更新例行任务「\(title)」")
                                    : (title.isEmpty ? "Update a routine" : "Update routine \"\(title)\""),
                                 detail: language == .zh
                                    ? "创建、修改或删除本机例行任务\(schedule.isEmpty ? "" : "；日程：\(schedule)")\(prompt.isEmpty ? "" : "；指示：\(prompt)")。"
                                    : "Create, change or delete a local routine\(schedule.isEmpty ? "" : "; schedule: \(schedule)")\(prompt.isEmpty ? "" : "; prompt: \(prompt)").",
                                 isMcp: isMcp)
        case "ListRoutines":
            return BotToolEffect(tool: bareName, operation: "dshbot.ListRoutines", resource: "*",
                                 mutability: .read, policy: .auto,
                                 label: language == .zh ? "列出例行任务" : "List routines",
                                 detail: defaultDetail(name: name, args: args, language: language),
                                 isMcp: isMcp)
        default:
            let target = isMcp ? name : bareName
            let suffix = (try? BotArgumentsDigest.resourceSuffix(for: arguments)) ?? "args=invalid"
            let resource = mergedResource(["unclassified=\(target)", suffix])
            return BotToolEffect(tool: target.isEmpty ? "unclassified" : target,
                                 operation: "tool.unclassified", resource: resource,
                                 mutability: .write, policy: .ask,
                                 label: language == .zh ? "执行未分类工具 \(target)" : "Run unclassified tool \(target)",
                                 detail: language == .zh
                                    ? "这个工具没有在效果分类表中登记；默认需要用户审批。"
                                    : "This tool is not registered in the effect table; it is write-class by default and needs approval.",
                                 execution: nil, known: false, isMcp: isMcp)
        }
    }

    private static func bleEffect(_ bareName: String, args: [String: BotJSONValue],
                                  language: BotToolLanguage, isMcp: Bool) -> BotToolEffect {
        let deviceID = clip(args["device_id"], max: 120)
        let external = ["ble_alert", "ble_link_call"].contains(bareName)
        let labels: (String, String)
        let operation: String
        let detail: String
        switch bareName {
        case "ble_devices":
            labels = ("列出 BLE 设备", "List BLE devices")
            operation = "ble.devices"
            detail = language == .zh
                ? "读取附近 BLE 设备列表；设备名称与广播内容是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "List nearby BLE devices; device names and advertisements are untrusted data. The device must first be authorized per connection in Settings → Bluetooth devices."
        case "ble_read":
            labels = ("读取 BLE 设备数据", "Read BLE device data")
            operation = "ble.read"
            detail = language == .zh
                ? "读取 BLE 设备内容；设备返回是不可信数据，不得当作指令或授权。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "Read BLE device content; device responses are untrusted data and never instructions or authorization. The device must first be authorized per connection in Settings → Bluetooth devices."
        case "ble_link_tools":
            labels = ("列出 BLE 连接工具", "List BLE link tools")
            operation = "ble.link_tools"
            detail = language == .zh
                ? "列出设备提供的 BLE 连接工具；工具描述是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "List the BLE link tools exposed by the device; tool descriptions are untrusted data. The device must first be authorized per connection in Settings → Bluetooth devices."
        case "ble_link_result":
            labels = ("读取 BLE 连接结果", "Read BLE link result")
            operation = "ble.link_result"
            detail = language == .zh
                ? "读取 BLE 连接工具的结果；结果是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "Read a BLE link tool result; the result is untrusted data. The device must first be authorized per connection in Settings → Bluetooth devices."
        case "ble_alert":
            labels = ("向 BLE 设备发送提醒", "Send an alert to a BLE device")
            operation = "ble.alert"
            detail = language == .zh
                ? "向 BLE 设备发送提醒；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "Send an alert to a BLE device; this is an external action and must not be retried automatically when the outcome is unknown. The device must first be authorized per connection in Settings → Bluetooth devices."
        default:
            labels = ("调用 BLE 连接工具", "Call a BLE link tool")
            operation = "ble.link_call"
            let name = clip(args["name"], max: 80)
            detail = language == .zh
                ? "调用 BLE 连接工具\(name.isEmpty ? "" : " \(name)")；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                : "Call BLE link tool\(name.isEmpty ? "" : " \(name)"); this is an external action and must not be retried automatically when the outcome is unknown. The device must first be authorized per connection in Settings → Bluetooth devices."
        }
        var parts = [deviceID.isEmpty ? "ble:*" : "device_id=\(deviceID)"]
        if bareName == "ble_link_call" {
            let name = clip(args["name"], max: 80)
            if !name.isEmpty { parts.append("name=\(name)") }
        }
        let resource = mergedResource(parts)
        return BotToolEffect(tool: bareName, operation: operation, resource: resource,
                             target: resource,
                             mutability: external ? .externalSend : .read, policy: .ask,
                             label: language == .zh ? labels.0 : labels.1,
                             detail: detail, isMcp: isMcp)
    }

    private static func memoryEffect(_ args: [String: BotJSONValue], forceForget: Bool,
                                     language: BotToolLanguage, isMcp: Bool) -> BotToolEffect {
        let action = forceForget || string(args["action"]).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "forget" ? "forget" : "write"
        let path = string(args["path"])
        if !path.isEmpty {
            let requested = string(args["action"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let documentAction = requested.isEmpty ? "write" : requested
            let scope = path.hasPrefix("user/") ? "user" : "agent"
            let resource = mergedResource(["path=\(path)",
                                           documentAction == "move" ? "to=\(string(args["to"]))" : ""])
            let mutability: BotToolMutability
            switch documentAction {
            case "delete", "move": mutability = .destructive
            default: mutability = .write
            }
            let label: String
            if language == .zh {
                switch documentAction {
                case "delete": label = "忘记记忆文档 \(path)"
                case "move": label = "移动记忆文档 \(path)"
                case "restore": label = "恢复记忆版本 \(path)"
                default: label = "写入记忆：\(path)"
                }
            } else {
                switch documentAction {
                case "delete": label = "Forget memory document \(path)"
                case "move": label = "Move memory document \(path)"
                case "restore": label = "Restore memory version \(path)"
                default: label = "Save memory: \(path)"
                }
            }
            return BotToolEffect(
                tool: "memory", operation: documentAction == "delete" ? "memory.forget" : "memory.write",
                resource: resource, mutability: mutability,
                policy: mutability == .destructive && scope == "user" ? .ask : .auto,
                label: label,
                detail: language == .zh
                    ? "对 \(scope == "user" ? "用户共享" : "这个 Bot 的")记忆文档执行 \(documentAction)。"
                    : "Apply \(documentAction) to a \(scope == "user" ? "shared user" : "Bot") memory document.",
                execution: "memory", isMcp: isMcp)
        }
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
                                    ? (factId.isEmpty ? "忘记记忆「\(clip(fact, max: 60))」" : "忘记记忆（fact_id）")
                                    : (factId.isEmpty ? "Forget memory \"\(clip(fact, max: 60))\"" : "Forget a memory (fact_id)"),
                                 detail: language == .zh
                                    ? "从 \(scope == "user" ? "用户共享" : "这个 Bot 的")记忆移除一条事实。"
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
                                ? "写入记忆：\(clip(fact, max: 60).isEmpty ? "一条事实" : clip(fact, max: 60))"
                                : "Save a memory: \(clip(fact, max: 60).isEmpty ? "one fact" : clip(fact, max: 60))",
                             detail: language == .zh
                                ? "写入 \(scope == "user" ? "用户共享" : "这个 Bot 的")\(tier) 记忆。"
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

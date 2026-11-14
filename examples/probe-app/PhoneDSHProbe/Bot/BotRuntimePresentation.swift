// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

/// One live frame of the main chat turn (`BotLiveTurnFrame` in the runtime).
/// It lives with the presentation projection because both the open page and
/// the per-Bot runtime unit feed it through `BotLiveFishProjection`; the
/// Bot E2E test target includes this file but not the page's view layer.
enum BotLiveFrame {
    case streamStart
    case textDelta(String)
    case event(JSONValue)
}

extension PhoneDSHBot.BotJSONValue {
    var runtimeString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var runtimeObject: [String: PhoneDSHBot.BotJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var runtimeInt: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    var runtimeBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

struct BotActivity: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case thinking
        case toolRunning = "tool-running"
        case streaming
    }

    var status: Status
    var detail = ""
    /// What the activity is about. The text may come from the model's own
    /// `description`, but the category always follows the tool name; the fish
    /// avatar maps these raw names onto its work style.
    var category: BotActivityCategory = .generic
    /// Start of this phase in the event clock (milliseconds). Drives the
    /// activity line's `· N 分钟` suffix.
    var startedAt: Int64 = 0
}

struct BotRuntimePresentation: Equatable, Sendable {
    var fishState: BotFishLifecycle = .idle
    var runningTurnID: String?
    var activity: BotActivity?
    /// The latest active one-shot FishAction; every avatar of the Bot gets it.
    var reaction: BotFishReaction?
    /// The director's current one-shot (celebration, failure, …). Kept so the
    /// chat and sidebar can show it after a turn has already ended.
    var oneShot: BotFishOneShot?
}

enum BotRuntimePresentationFactory {
    private struct TimedEvent {
        var time: Int64
        var source: Int
        var sequence: Int
        var index: Int
        var event: BotFishEvent
    }

    static func make(botID: String, sessionID: String,
                     sessionEvents: [BotDSHSessionEvent], uiEvents: [BotEvent],
                     now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> BotRuntimePresentation {
        var timed: [TimedEvent] = []
        for (index, event) in sessionEvents.enumerated() {
            guard let mapped = BotFishDirectorEventMapper.event(from: .dshSession(event)) else { continue }
            timed.append(TimedEvent(time: event.time, source: 0, sequence: event.seq, index: index,
                                    event: mapped))
        }
        for (index, event) in uiEvents.enumerated() {
            guard event.principal.botId == nil || event.principal.botId == botID,
                  let mapped = BotFishDirectorEventMapper.event(from: .botEvent(event)) else { continue }
            timed.append(TimedEvent(time: event.time, source: 1, sequence: event.commitSeq ?? .max, index: index,
                                    event: mapped))
        }
        timed.sort {
            ($0.time, $0.source, $0.sequence, $0.index) < ($1.time, $1.source, $1.sequence, $1.index)
        }
        var director = BotFishDirectorState()
        for item in timed {
            director = BotFishDirector.reduce(director, event: item.event).directorState
        }
        director = BotFishDirector.expireOneShot(director, now: max(0, now)).directorState
        let running = currentTurn(sessionID: sessionID, events: sessionEvents)
        return BotRuntimePresentation(
            fishState: director.current,
            runningTurnID: running?.id,
            activity: activity(turn: running, events: sessionEvents, now: now),
            reaction: latestReaction(botID: botID, sessionEvents: sessionEvents,
                                     uiEvents: uiEvents, now: now),
            oneShot: director.oneShot)
    }

    /// The same projection from the live turn frames the page already holds.
    /// Live events carry the DSH session event shape (`type`/`seq`/`time`/
    /// `data`), so they go through the one factory instead of a second table.
    static func live(botID: String, events: [JSONValue],
                     now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> BotRuntimePresentation {
        let sessionEvents: [BotDSHSessionEvent] = events.enumerated().compactMap { index, event in
            guard let type = event["type"]?.stringValue else { return nil }
            var data: [String: PhoneDSHBot.BotJSONValue] = [:]
            if case .object(let object)? = event["data"] { data = object }
            let time = Int64((event["time"]?.numberValue ?? 0).rounded())
            return BotDSHSessionEvent(type: type,
                                      seq: event["seq"]?.intValue ?? index,
                                      time: max(0, time),
                                      data: data,
                                      eventID: event["eventId"]?.stringValue
                                        ?? event["eventID"]?.stringValue)
        }
        return make(botID: botID, sessionID: "live", sessionEvents: sessionEvents,
                    uiEvents: [], now: now)
    }

    /// Latest `FishAction` call, in either authoritative event source. The
    /// reaction's own TTL decides whether it is still alive.
    private static func latestReaction(botID: String, sessionEvents: [BotDSHSessionEvent],
                                       uiEvents: [BotEvent], now: Int64) -> BotFishReaction? {
        var latest: BotFishReaction?
        for event in sessionEvents {
            guard var call = BotFishToolCall(sessionEvent: event) else { continue }
            call.botID = botID
            guard let reaction = BotFishReaction.reaction(from: call) else { continue }
            if latest == nil || reaction.startedAt >= latest!.startedAt { latest = reaction }
        }
        for event in uiEvents {
            guard event.principal.botId == nil || event.principal.botId == botID,
                  var call = BotFishToolCall(botEvent: event) else { continue }
            call.botID = botID
            guard let reaction = BotFishReaction.reaction(from: call) else { continue }
            if latest == nil || reaction.startedAt >= latest!.startedAt { latest = reaction }
        }
        guard let latest, latest.isActive(at: now) else { return nil }
        return latest
    }

    private static func currentTurn(sessionID: String, events: [BotDSHSessionEvent]) -> (id: String, seq: Int)? {
        var current: (id: String, seq: Int)?
        for event in events.enumerated().sorted(by: { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }).map(\.element) {
            switch event.type {
            case "turn/start":
                let id = event.data["turn"]?.runtimeString ?? event.data["turn"]?.runtimeInt.map(String.init)
                    ?? "\(sessionID):\(event.seq)"
                current = (id, event.seq)
            case "turn/end":
                let ended = event.data["turn"]?.runtimeString ?? event.data["turn"]?.runtimeInt.map(String.init)
                if ended == nil || ended == current?.id { current = nil }
            default: break
            }
        }
        return current
    }

    /// Derive activity from the whole open turn. Every call participates in
    /// correlation (including hidden calls); only visible in-flight work can
    /// become the displayed action. Steering and step boundaries do not end it.
    private static func activity(turn: (id: String, seq: Int)?,
                                 events: [BotDSHSessionEvent], now: Int64) -> BotActivity? {
        guard let turn else { return nil }
        let tail = events.enumerated().filter { $0.element.seq >= turn.seq }
            .sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
            .map(\.element).filter { event in
                let id = event.data["turn"]?.runtimeString ?? event.data["turn"]?.runtimeInt.map(String.init)
                return id == nil || id == turn.id
            }
        struct Call {
            var id: String
            var name: String
            var arguments: [String: PhoneDSHBot.BotJSONValue]
            var time: Int64
        }
        var pending: [Call] = []
        var seenIDs = Set<String>()
        var lastReturn: (call: Call, index: Int, failed: Bool, time: Int64)?
        var phase: (index: Int, streaming: Bool, time: Int64)?
        let startTime = max(0, tail.first?.time ?? 0)
        for (index, event) in tail.enumerated() {
            let time = max(0, event.time)
            switch event.type {
            case "tool/call":
                let id = event.data["callId"]?.runtimeString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !id.isEmpty && !seenIDs.insert(id).inserted { continue }
                pending.append(Call(id: id, name: event.data["name"]?.runtimeString ?? "",
                                    arguments: toolArguments(event.data["arguments"]), time: time))
            case "tool/result":
                guard let id = toolResultCallID(event.data) else { continue }
                let match = id.isEmpty ? (pending.count == 1 ? pending.startIndex : nil)
                    : pending.firstIndex(where: { !$0.id.isEmpty && $0.id == id })
                if let match {
                    let call = pending.remove(at: match)
                    if BotDisplayContract.isToolCallVisible(named: call.name) {
                        let message = event.data["message"]?.runtimeObject ?? [:]
                        lastReturn = (call, index, message["isError"]?.runtimeBool == true || event.data["error"]?.runtimeObject != nil, time)
                    }
                }
            case "step/start": phase = (index, false, time)
            case "assistant/stream", "assistant/message":
                if visibleAssistantText(event.data) { phase = (index, true, time) }
            default: break
            }
        }
        if let call = pending.last(where: { BotDisplayContract.isToolCallVisible(named: $0.name) }) {
            let phrase = BotActivityEvidence.action(forToolNamed: call.name, arguments: call.arguments)
            return BotActivity(status: .toolRunning,
                               detail: phrase.text.isEmpty ? "等待操作结果" : phrase.text,
                               category: phrase.category, startedAt: call.time)
        }
        if let phase, phase.streaming, phase.index > (lastReturn?.index ?? -1) {
            return BotActivity(status: .streaming, detail: "正在回复", category: .replying, startedAt: phase.time)
        }
        if let result = lastReturn {
            return BotActivity(status: .thinking,
                               detail: BotActivityEvidence.resultText(forToolNamed: result.call.name, failed: result.failed),
                               category: .reviewing, startedAt: (phase?.index ?? -1) > result.index ? phase!.time : result.time)
        }
        return BotActivity(status: .thinking, detail: "等待响应", category: .thinking,
                           startedAt: phase?.time ?? startTime)
    }

    private static func visibleAssistantText(_ data: [String: PhoneDSHBot.BotJSONValue]) -> Bool {
        if let channel = data["channel"]?.runtimeString, channel != "text" { return false }
        if let text = data["text"]?.runtimeString, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let content = data["message"]?.runtimeObject?["content"]
        if let text = content?.runtimeString { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard case .array(let parts)? = content else { return false }
        return parts.contains { part in
            guard let value = part.runtimeObject, value["type"]?.runtimeString == "text",
                  let text = value["text"]?.runtimeString else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// nil means invalid/conflicting correlation, "" means truly absent.
    private static func toolResultCallID(_ data: [String: PhoneDSHBot.BotJSONValue]) -> String? {
        let message = data["message"]?.runtimeObject ?? [:]
        let values = [message["toolCallId"], data["callId"], message["source"]?.runtimeObject?["callId"]]
        var ids = Set<String>()
        for value in values {
            guard let value, value != .null else { continue }
            guard let raw = value.runtimeString else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { ids.insert(id) }
        }
        guard ids.count <= 1 else { return nil }
        return ids.first ?? ""
    }

    private static func toolArguments(_ value: PhoneDSHBot.BotJSONValue?) -> [String: PhoneDSHBot.BotJSONValue] {
        if let object = value?.runtimeObject { return object }
        guard let text = value?.runtimeString, let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PhoneDSHBot.BotJSONValue.self, from: data) else { return [:] }
        return decoded.runtimeObject ?? [:]
    }
}

/// Compatibility shim for callers that only need the visible tool text. The
/// category/phrase table now lives in `BotActivityPhrases`.
enum BotToolActivity {
    static func describe(name: String,
                         arguments: [String: PhoneDSHBot.BotJSONValue]) -> String {
        BotActivityEvidence.action(forToolNamed: name, arguments: arguments).text
    }
}


/// Live-frame accumulator shared by the open page and the per-Bot runtime
/// unit. It turns `streamStart`/`textDelta` into the missing `model.delta`
/// source, turns a failed `turn/end` into the missing `error` source, and keeps
/// the last `FishAction` reaction. The director mapping itself stays in
/// `BotFishDirectorEventMapper`.
struct BotLiveFishProjection {
    /// Same millisecond rounding as the live event conversion, so a synthetic
    /// error cannot sort before the real turn/end it follows.
    static var now: Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }

    private let botID: String
    private(set) var records: [JSONValue] = []
    private var nextSequence = 1
    private var streaming = false
    private var lastActivityAt: Int64?

    init(botID: String) {
        self.botID = botID
    }

    mutating func receive(_ frame: BotLiveFrame, now: Int64 = BotLiveFishProjection.now) {
        switch frame {
        case .streamStart:
            lastActivityAt = max(0, now)
            if !streaming {
                streaming = true
                appendSynthetic(type: "assistant/stream", time: now,
                                data: ["channel": .string("text")])
            }
        case .textDelta(let text):
            lastActivityAt = max(0, now)
            if !streaming {
                streaming = true
                appendSynthetic(type: "assistant/stream", time: now,
                                data: ["channel": .string("text"), "text": .string(text)])
            }
        case .event(let event):
            guard let type = event["type"]?.stringValue else { return }
            let eventTime = Int64((event["time"]?.numberValue ?? Double(now)).rounded())
            if let seq = event["seq"]?.intValue {
                nextSequence = max(nextSequence, seq + 1)
            }
            switch type {
            case "turn/start":
                // Keep the replay bounded to the open turn, like BotLiveTurn.
                records.removeAll(keepingCapacity: true)
                streaming = false
                lastActivityAt = max(0, now)
            case "step/start":
                streaming = false
            case "tool/call", "user/message", "assistant/message":
                lastActivityAt = max(0, now)
            case "turn/end":
                streaming = false
                lastActivityAt = max(0, now)
            default:
                break
            }
            records.append(event)
            if type == "turn/end", failedTurnEnd(event["data"] ?? .null) {
                appendSynthetic(type: "error", time: max(now, eventTime + 1),
                                data: ["reason": .string("turn failed")])
            }
        }
    }

    mutating func noteInteraction(now: Int64 = BotLiveFishProjection.now) {
        lastActivityAt = max(0, now)
    }

    /// Runtime failures that have no DSH session event (for example a watch
    /// poll error) still reach the director through the same `error` source.
    mutating func noteError(_ message: String, now: Int64 = BotLiveFishProjection.now) {
        appendSynthetic(type: "error", time: now,
                        data: ["reason": .string(message)])
        lastActivityAt = max(0, now)
    }

    func presentation(now: Int64 = BotLiveFishProjection.now) -> BotRuntimePresentation {
        BotRuntimePresentationFactory.live(botID: botID, events: records, now: now)
    }

    /// Sixty seconds without a turn, a frame or a user touch.
    func isIdleSleeping(now: Int64 = BotLiveFishProjection.now) -> Bool {
        guard let lastActivityAt else { return false }
        return now - lastActivityAt >= 60_000
    }

    private mutating func appendSynthetic(type: String, time: Int64,
                                          data: [String: PhoneDSHBot.BotJSONValue]) {
        records.append(.object([
            "type": .string(type),
            "seq": .number(Double(nextSequence)),
            "time": .number(Double(max(0, time))),
            "data": .object(data),
        ]))
        nextSequence += 1
    }

    private func failedTurnEnd(_ data: JSONValue) -> Bool {
        guard let reason = data["reason"] else { return data["error"] != nil }
        if reason["error"] != nil { return true }
        let kind = (reason["kind"]?.stringValue ?? reason["status"]?.stringValue ?? "")
            .lowercased()
        return ["error", "failed", "failure", "timeout", "timed_out"].contains(kind)
    }
}

/// iOS evidence policy. The shared phrase table remains the legacy vocabulary
/// for other clients; only semantic action fields can override it here.
/// No raw reasoning, command, task prompt or business-summary text is displayed.
enum BotActivityEvidence {
    /// Only a purpose, never a file identifier or command, enters this label.
    /// Metadata is deliberately not passed to the legacy target-suffix builder.
    static func action(forToolNamed name: String,
                       arguments: [String: PhoneDSHBot.BotJSONValue]) -> BotToolActivityPhrase {
        let bare = BotActivityPhrases.bareToolName(name).lowercased()
        var result = BotActivityPhrases.toolActivity(forToolNamed: name, arguments: [:])
        let fallbacks: [String: String] = [
            "bash": "执行当前操作", "read": "读取相关资料", "write": "保存处理结果",
            "edit": "更新相关内容", "glob": "查找相关资料", "grep": "查找相关内容",
            "web_search": "查找相关信息", "web_fetch": "查看网页内容",
            "job_list": "查看任务进展", "job_output": "等待任务结果", "job_kill": "停止当前任务",
            "todo_write": "整理待办事项", "create_goal": "确定处理目标",
            "get_goal": "查看处理目标", "update_goal": "更新处理目标",
            "updatememory": "更新记忆内容", "readmemory": "查阅相关记忆", "recallmemory": "查找相关记忆",
            "task": "安排协作任务", "awaittask": "等待协作结果", "stopsubagent": "停止协作任务",
            "sendtoagent": "联系协作助手", "createteammate": "创建协作助手",
            "sendtouser": "发送回复", "send_to_user": "发送回复", "botvolatilecontext": "读取当前信息",
            "show_attachment": "展示处理结果", "show_document": "展示整理结果",
            "show_progress": "更新任务进度", "show_checklist": "整理检查清单", "show_link": "整理参考来源",
        ]
        result.text = fallbacks[bare] ?? (result.text.isEmpty ? "等待操作结果" : result.text)
        if bare == "updateroutine" {
            let actions = ["create": "创建例行安排", "update": "更新例行安排", "delete": "删除例行安排",
                           "list": "查看例行安排", "get": "查看例行安排", "pause": "暂停例行安排", "resume": "恢复例行安排"]
            result.text = actions[arguments["action"]?.runtimeString ?? ""] ?? "处理例行安排"
        }
        if bare == "web_search" {
            var topic = arguments["query"]?.runtimeString
            if topic == nil, case .array(let queries)? = arguments["queries"] {
                topic = queries.compactMap { $0.runtimeString }.first
            }
            if let topic, let spoken = spokenIntent(topic), spoken.count <= 10 {
                result.text = "查询" + spoken
            }
        }
        let keys: [String]
        switch bare {
        case "bash": keys = ["description"]
        case "task": keys = ["task_title", "description"]
        default: keys = []
        }
        for key in keys {
            guard let raw = arguments[key]?.runtimeString,
                  let text = spokenIntent(raw) else { continue }
            result.text = text
            break
        }
        return result
    }

    /// Reject unsuitable prose instead of cutting a sentence into an ellipsis.
    /// This is a display policy; original tool arguments are never rewritten.
    static func spokenIntent(_ raw: String) -> String? {
        let first = raw.components(separatedBy: .newlines).first ?? ""
        let punctuation = CharacterSet(charactersIn: "。！？!?；;，,、.…")
        let text = first.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punctuation).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCJK = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        let limit = hasCJK ? 16 : 48
        guard !text.isEmpty, text.count <= limit,
              text.split(whereSeparator: \.isWhitespace).count <= 7,
              !text.unicodeScalars.contains(where: CharacterSet.symbols.contains) else { return nil }
        let forbidden = #"(?i)(https?:|www\.|[/\\`<>|{}\[\]=:：*?&#%“”‘’《》]|[\p{L}\p{N}_-]+\.[a-z0-9]{1,8}(?=$|[^a-z0-9])|mcp__|[a-z0-9]+_[a-z0-9_]+|bearer\s+\S+|(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=])"#
        guard text.range(of: forbidden, options: .regularExpression) == nil else { return nil }
        let generic = ["思考中", "整理思绪", "准备下一步", "马上就好", "正在处理", "处理中"]
        let completion = #"(?i)^(?:已(?:完成|成功|验证|发送|删除)|completed\b|verified\b|all tests passed\b|done\b)"#
        guard !generic.contains(text), text.range(of: completion, options: .regularExpression) == nil else { return nil }
        return text
    }

    static func resultText(forToolNamed name: String, failed: Bool) -> String {
        if failed { return "这步遇到问题" }
        switch BotActivityPhrases.bareToolName(name).lowercased() {
        case "read", "readmemory", "get_goal": return "已收到读取结果"
        case "glob", "grep", "web_search", "web_fetch", "recallmemory": return "已收到查询结果"
        case "write", "edit", "updatememory", "updateroutine": return "已收到更新结果"
        case "task", "awaittask", "sendtoagent": return "已收到协作反馈"
        default: return "已收到操作结果"
        }
    }

    static func lineActivity(factory: BotActivity?, streaming: Bool,
                             pendingApprovals: Int, visible: Bool) -> BotActivity? {
        guard visible else { return nil }
        if pendingApprovals > 0 { return BotActivity(status: .thinking, detail: "等你确认", category: .waiting) }
        let phase = factory.map(normalized)
        if phase?.status == .toolRunning { return phase }
        if streaming { return BotActivity(status: .streaming, detail: "正在回复", category: .replying) }
        return phase ?? BotActivity(status: .thinking, detail: "等待响应", category: .thinking)
    }

    /// Every activity entering the iOS line has one stable, evidence-based
    /// label. The legacy synonym pool is never used by this display path.
    static func normalized(_ activity: BotActivity) -> BotActivity {
        guard activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return activity }
        var result = activity
        switch activity.category {
        case .waiting: result.detail = "等你确认"
        case .replying: result.detail = "正在回复"
        case .reviewing: result.detail = "已收到操作结果"
        default:
            switch activity.status {
            case .toolRunning: result.detail = "等待操作结果"
            case .streaming: result.detail = "正在回复"
            case .thinking: result.detail = "等待响应"
            }
        }
        return result
    }
}

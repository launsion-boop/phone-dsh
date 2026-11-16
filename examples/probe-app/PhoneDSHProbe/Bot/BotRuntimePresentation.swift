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
        return BotActivityReducer.activity(events: tail)
    }

    /// nil means invalid/conflicting correlation, "" means truly absent.
    static func toolResultCallID(_ data: [String: PhoneDSHBot.BotJSONValue]) -> String? {
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

    static func toolArguments(_ value: PhoneDSHBot.BotJSONValue?) -> [String: PhoneDSHBot.BotJSONValue] {
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
    /// Accumulated text of the current streaming segment. It is patched into
    /// the one synthetic `assistant/stream` record only when a presentation is
    /// built, so a turn's token count never adds events, never advances
    /// `nextSequence` past the real session events, and never reorders them.
    private var streamText = ""
    private var streamEventIndex: Int?
    /// A real text-bearing `assistant/stream` in this step makes the session's
    /// own deltas authoritative, so later `textDelta` frames are ignored
    /// instead of duplicating the sentence.
    private var realTextAuthoritative = false

    init(botID: String) {
        self.botID = botID
    }

    mutating func receive(_ frame: BotLiveFrame, now: Int64 = BotLiveFishProjection.now) {
        switch frame {
        case .streamStart:
            lastActivityAt = max(0, now)
            streaming = true
            guard !realTextAuthoritative, streamEventIndex == nil else { return }
            streamText = ""
            appendSynthetic(type: "assistant/stream", time: now,
                            data: ["channel": .string("text")])
            streamEventIndex = records.count - 1
        case .textDelta(let text):
            lastActivityAt = max(0, now)
            streaming = true
            // `activity-evidence-v2.1` accumulates the step's text-channel
            // deltas. Keep the snapshot in the accumulator and patch the one
            // synthetic record at presentation time: appending per token made
            // every frame sort/reduce the whole replay and pushed synthetic
            // sequence numbers past the real `assistant/message`/`tool/call`
            // events they must follow.
            guard !realTextAuthoritative else { return }
            streamText += text
            if streamEventIndex == nil {
                appendSynthetic(type: "assistant/stream", time: now,
                                data: ["channel": .string("text")])
                streamEventIndex = records.count - 1
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
                endStreamSnapshot(discardText: true)
                records.removeAll(keepingCapacity: true)
                streaming = false
                lastActivityAt = max(0, now)
            case "step/start":
                streaming = false
                endStreamSnapshot()
            case "assistant/stream":
                // The session's own text deltas are authoritative for this
                // step; drop the live snapshot so the reducer cannot see the
                // sentence twice. Textless stream markers clear nothing.
                let text = event["data"]?["text"]?.stringValue ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endStreamSnapshot(discardText: true)
                    realTextAuthoritative = true
                }
                lastActivityAt = max(0, now)
            case "assistant/message", "tool/call", "tool/result":
                endStreamSnapshot()
                lastActivityAt = max(0, now)
            case "user/message":
                lastActivityAt = max(0, now)
            case "turn/end":
                streaming = false
                endStreamSnapshot()
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

    /// Finish the current streaming segment: persist the accumulated text into
    /// its single synthetic record once, so the call that follows can still
    /// read it, then let a later segment create its own record.
    private mutating func endStreamSnapshot(discardText: Bool = false) {
        if let index = streamEventIndex {
            storeStreamText(discardText ? "" : streamText, at: index)
        }
        streamText = ""
        streamEventIndex = nil
        realTextAuthoritative = false
    }

    private mutating func storeStreamText(_ text: String, at index: Int) {
        guard records.indices.contains(index), case .object(var record) = records[index] else {
            return
        }
        var data: [String: JSONValue] = [:]
        if case .object(let current)? = record["data"] { data = current }
        data["text"] = .string(text)
        record["data"] = .object(data)
        records[index] = .object(record)
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
        BotRuntimePresentationFactory.live(botID: botID, events: presentationRecords(), now: now)
    }

    /// The accumulated text snapshot is patched into the one synthetic
    /// `assistant/stream` record here instead of on every delta, so the
    /// record list stays as small as the real event list and the factory's
    /// `seq` sort cannot move real events behind live text.
    private func presentationRecords() -> [JSONValue] {
        guard let index = streamEventIndex, records.indices.contains(index),
              !streamText.isEmpty, case .object(var record) = records[index] else {
            return records
        }
        var data: [String: JSONValue] = [:]
        if case .object(let current)? = record["data"] { data = current }
        data["text"] = .string(streamText)
        record["data"] = .object(data)
        var patched = records
        patched[index] = .object(record)
        return patched
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

/// iOS evidence policy for `activity-evidence-v3`. The bubble carries one
/// short, real progress sentence for the current call: the model's per-call
/// intent or same-step public progress, or a short object when the model gave
/// no sentence. A model sentence is never extended with a full path or URL.
/// Only credential shapes, generic fillers and completion claims are rejected.
enum BotActivityEvidence {
    /// `activity-evidence-v3` short-progress bound.
    static let cjkBound = 28
    static let nonCJKBound = 56

    /// Compatibility entry point for callers that only need the tool label.
    /// The production bubble resolves the sentence alongside the same-step
    /// public text in `BotActivityReducer.sentence`.
    static func action(forToolNamed name: String,
                       arguments: [String: PhoneDSHBot.BotJSONValue]) -> BotToolActivityPhrase {
        let resolved = BotActivityReducer.sentence(toolName: name, arguments: arguments,
                                                   publicText: nil)
        return BotToolActivityPhrase(category: resolved.category, text: resolved.text)
    }

    /// One display sentence: first line, collapsed whitespace, sentence-final
    /// punctuation stripped, then shortened to the short-progress bound. The
    /// sentence keeps its real task object; only the shapes below are rejected.
    static func displayText(_ raw: String) -> String? {
        let firstLine = raw.components(separatedBy: .newlines).first ?? ""
        var text = firstLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: "。！？!?；;，,、.…")
        while let last = text.unicodeScalars.last, punctuation.contains(last) {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        guard !fillerPhrases.contains(text), !fillerPhrases.contains(lower) else { return nil }
        guard text.range(of: receiptPattern, options: .regularExpression) == nil else { return nil }
        guard !completionPrefixes.contains(where: { text.hasPrefix($0) }) else { return nil }
        for word in englishCompletionWords {
            guard lower.hasPrefix(word) else { continue }
            let rest = lower.dropFirst(word.count)
            if rest.isEmpty || rest.first.map({ !$0.isLetter && !$0.isNumber }) == true {
                return nil
            }
        }
        guard !credentialPatterns.contains(where: {
            text.range(of: $0, options: .regularExpression) != nil
        }) else { return nil }
        return shortened(text)
    }

    /// Whether an assembled fallback sentence still fits the short bound.
    static func fitsShortBound(_ raw: String) -> Bool {
        let hasCJK = raw.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        return raw.count <= (hasCJK ? cjkBound : nonCJKBound)
    }

    /// Short progress bound: 28 characters with CJK, else 56. Longer text is
    /// shortened at the last sentence/clause punctuation within the bound,
    /// else `bound - 1` characters plus `…` — a long public answer never
    /// reaches the bubble whole.
    static func shortened(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        let hasCJK = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        let bound = hasCJK ? cjkBound : nonCJKBound
        guard text.count > bound else { return text }
        let prefix = String(text.prefix(bound))
        let clause = CharacterSet(charactersIn: "。！？!?；;，,、")
        if let index = prefix.unicodeScalars.lastIndex(where: { clause.contains($0) }) {
            let cut = String(prefix.unicodeScalars[..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cut.isEmpty { return cut }
        }
        return String(text.prefix(bound - 1)) + "…"
    }

    /// A URL object is a quiet host: no scheme, `www.`, userinfo, path or query.
    static func displayHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let absolute = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let host = URLComponents(string: absolute)?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        var text = trimmed
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? text
    }

    /// The short object fallback uses the file name, never the whole path.
    static func basename(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .filter { !$0.isEmpty }.last ?? text
        return base.isEmpty ? text : base
    }

    private static let fillerPhrases: Set<String> = [
        "思考中", "整理思绪", "准备下一步", "马上就好", "正在处理", "处理中",
        "等待响应", "等待模型响应", "正在回复", "好的", "我来看看", "我看一下",
        "稍等", "开始",
    ]
    private static let receiptPattern = #"^已收到.*结果$"#
    private static let completionPrefixes = [
        "已完成", "已成功", "已验证", "已确认", "已修复", "已合并", "已发送",
        "已删除", "已通过", "已解决",
    ]
    private static let englishCompletionWords = ["completed", "verified", "done", "all tests passed"]
    private static let credentialPatterns = [
        #"(?i)\bbearer\s+\S+"#,
        #"(?i)(?:api[_-]?key|access[_-]?token|session[_-]?token|password|passwd|secret|token)\s*[:=]"#,
        #"(?i)\bsk-[a-z0-9][a-z0-9_-]{5,}"#,
        #"(?i)\bghp_[a-z0-9]{8,}"#,
        #"(?i)\bxox[abprs]-[a-z0-9-]{6,}"#,
        #"(?i)\bakia[a-z0-9]{12,}"#,
    ]

    static func lineActivity(factory: BotActivity?, streaming: Bool,
                             pendingApprovals: Int, visible: Bool) -> BotActivity? {
        guard visible else { return nil }
        if pendingApprovals > 0 { return BotActivity(status: .thinking, detail: "等你确认", category: .waiting) }
        let phase = factory.map(normalized)
        if phase?.status == .toolRunning { return phase }
        if streaming { return BotActivity(status: .streaming, detail: "正在回复", category: .replying) }
        return phase ?? BotActivity(status: .thinking, detail: "等待响应", category: .thinking)
    }

    /// Every activity entering the iOS line has one stable, event-based label.
    /// The legacy synonym pool is never used by this display path.
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

/// `activity-evidence-v3` reducer: one deterministic fold over the open
/// turn's events. The durable factory and the live frames both call it, so a
/// replay of the same events yields the same activity. Model text only fills
/// `detail`; status and category come from the call lifecycle.
enum BotActivityReducer {
    struct Resolution: Equatable {
        var text: String
        var category: BotActivityCategory
    }

    private struct Rule {
        var category: BotActivityCategory
        var label: String
        var intentKeys: [String] = []
        var objectKeys: [String] = []
        var objectKind: ObjectKind = .plain
        /// Keys whose value is a path and therefore displays as its basename.
        var pathKeys: Set<String> = []
        var secondaryKeys: [String] = []
        /// Public task progress is the default source for every visible
        /// work tool; only card/messaging tools opt out (`v2.3`).
        var allowsPublicText = true
    }

    private enum ObjectKind { case plain, url, query, links }

    /// The v2.1 table. `BotActivityPhrases` stays the legacy vocabulary for
    /// Android and for non-production callers.
    private static let rules: [String: Rule] = [
        "bash": Rule(category: .running, label: "正在运行命令",
                     intentKeys: ["description"]),
        "read": Rule(category: .reading, label: "在翻文件",
                     objectKeys: ["file_path", "path", "filePath"],
                     pathKeys: ["file_path", "path", "filePath"]),
        "write": Rule(category: .writing, label: "在写文件",
                      objectKeys: ["file_path", "path", "filePath"],
                      pathKeys: ["file_path", "path", "filePath"]),
        "edit": Rule(category: .writing, label: "在改文件",
                     objectKeys: ["file_path", "path", "filePath"],
                     pathKeys: ["file_path", "path", "filePath"]),
        "str_replace_editor": Rule(category: .writing, label: "在改文件",
                                   objectKeys: ["file_path", "path", "filePath"],
                                   pathKeys: ["file_path", "path", "filePath"]),
        "glob": Rule(category: .searching, label: "在找文件", objectKeys: ["pattern"]),
        "grep": Rule(category: .searching, label: "在搜内容", objectKeys: ["pattern"],
                     secondaryKeys: ["path"]),
        "web_search": Rule(category: .searching, label: "在网上搜",
                           objectKeys: ["query", "queries"], objectKind: .query),
        "web_fetch": Rule(category: .browsing, label: "在开网页", objectKeys: ["url"],
                          objectKind: .url),
        "job_list": Rule(category: .running, label: "看看进展"),
        "job_output": Rule(category: .running, label: "等待结果"),
        "job_kill": Rule(category: .running, label: "停止任务"),
        "todo_write": Rule(category: .writing, label: "整理待办"),
        "create_goal": Rule(category: .writing, label: "定个目标", objectKeys: ["objective"]),
        "get_goal": Rule(category: .reading, label: "看看目标"),
        "update_goal": Rule(category: .writing, label: "更新目标", objectKeys: ["objective"]),
        "task": Rule(category: .messaging, label: "启动子任务",
                     intentKeys: ["task_title", "description"]),
        "awaittask": Rule(category: .running, label: "等子任务结果"),
        "stopsubagent": Rule(category: .running, label: "停止子任务"),
        "updatememory": Rule(category: .memory, label: "在记笔记", objectKeys: ["path"],
                             pathKeys: ["path"]),
        "readmemory": Rule(category: .memory, label: "在翻记忆", objectKeys: ["path"],
                            pathKeys: ["path"]),
        "recallmemory": Rule(category: .memory, label: "回想一下", objectKeys: ["query"]),
        "updateroutine": Rule(category: .writing, label: "修改例行任务", objectKeys: ["title"]),
        "listroutines": Rule(category: .reading, label: "看看例行任务"),
        // Card and messaging tools already carry their own public content, so
        // they never borrow the model's streamed prose (`v2.3`).
        "sendtouser": Rule(category: .messaging, label: "整理回复",
                           allowsPublicText: false),
        "send_to_user": Rule(category: .messaging, label: "整理回复",
                             allowsPublicText: false),
        "ask_user": Rule(category: .messaging, label: "想问问你",
                         allowsPublicText: false),
        "show_next_steps": Rule(category: .messaging, label: "给你选项",
                                allowsPublicText: false),
        "show_attachment": Rule(category: .messaging, label: "送上附件",
                                objectKeys: ["path"], pathKeys: ["path"],
                                allowsPublicText: false),
        "show_document": Rule(category: .reading, label: "打开文档",
                              objectKeys: ["title", "path"], pathKeys: ["path"],
                              allowsPublicText: false),
        "show_progress": Rule(category: .writing, label: "更新进度",
                              objectKeys: ["title"], allowsPublicText: false),
        "show_checklist": Rule(category: .writing, label: "列个清单",
                               objectKeys: ["title"], allowsPublicText: false),
        "show_link": Rule(category: .messaging, label: "放上链接",
                          objectKeys: ["links", "url"], objectKind: .links,
                          allowsPublicText: false),
        "requestapproval": Rule(category: .messaging, label: "请你确认",
                                objectKeys: ["detail"], allowsPublicText: false),
        "sendtoagent": Rule(category: .messaging, label: "给其他 Bot 发消息",
                            objectKeys: ["bot_name"], allowsPublicText: false),
        "createteammate": Rule(category: .messaging, label: "创建协作 Bot",
                               objectKeys: ["name"], allowsPublicText: false),
    ]
    private static let unknownRule = Rule(category: .generic, label: "等待操作结果")

    private static func rule(for rawName: String) -> Rule {
        rules[BotActivityPhrases.bareToolName(rawName).lowercased()] ?? unknownRule
    }

    /// Fold the open turn's events (already ordered and turn-filtered by the
    /// factory) into the one visible activity.
    static func activity(events: [BotDSHSessionEvent]) -> BotActivity? {
        struct Call {
            var id: String
            var name: String
            var time: Int64
            var resolution: Resolution
        }
        guard let firstEvent = events.first else { return nil }
        let startTime = max(0, firstEvent.time)
        var pending: [Call] = []
        var seenIDs = Set<String>()
        var lastReturn: (call: Call, index: Int, failed: Bool, time: Int64)?
        var phase: (index: Int, streaming: Bool, time: Int64)?
        var currentStep: Int?
        var streamText = ""
        var messageText: String?
        var candidateStep: Int?

        func clearCandidate() {
            streamText = ""
            messageText = nil
            candidateStep = nil
        }
        func candidate() -> String? { messageText ?? (streamText.isEmpty ? nil : streamText) }

        for (index, event) in events.enumerated() {
            let time = max(0, event.time)
            let eventStep = event.data["step"]?.runtimeInt
            switch event.type {
            case "turn/start":
                currentStep = nil
                clearCandidate()
            case "step/start":
                currentStep = eventStep
                phase = (index, false, time)
                clearCandidate()
            case "assistant/stream":
                guard event.data["channel"]?.runtimeString == "text",
                      let chunk = event.data["text"]?.runtimeString,
                      !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                // Text-channel deltas accumulate within the step; a durable
                // `assistant/message` replaces the accumulated text.
                messageText = nil
                streamText += chunk
                candidateStep = eventStep ?? currentStep
                phase = (index, true, time)
            case "assistant/message":
                guard let text = publicMessageText(event.data) else { break }
                streamText = ""
                messageText = text
                candidateStep = eventStep ?? currentStep
                phase = (index, true, time)
            case "tool/call":
                let id = event.data["callId"]?.runtimeString?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let callStep = eventStep ?? currentStep
                var usable: String?
                if let text = candidate() {
                    if let candidateStep, let callStep {
                        usable = candidateStep == callStep ? text : nil
                    } else {
                        usable = text
                    }
                }
                clearCandidate()
                if !id.isEmpty, !seenIDs.insert(id).inserted { break }
                let name = event.data["name"]?.runtimeString ?? ""
                let arguments = BotRuntimePresentationFactory.toolArguments(event.data["arguments"])
                pending.append(Call(id: id, name: name, time: time,
                                    resolution: sentence(toolName: name, arguments: arguments,
                                                         publicText: usable)))
            case "tool/result":
                clearCandidate()
                guard let id = BotRuntimePresentationFactory.toolResultCallID(event.data) else {
                    break
                }
                let match = id.isEmpty ? (pending.count == 1 ? pending.startIndex : nil)
                    : pending.firstIndex(where: { !$0.id.isEmpty && $0.id == id })
                guard let match else { break }
                let call = pending.remove(at: match)
                guard BotDisplayContract.isToolCallVisible(named: call.name) else { break }
                let message = event.data["message"]?.runtimeObject ?? [:]
                let failed = message["isError"]?.runtimeBool == true
                    || event.data["error"]?.runtimeObject != nil
                lastReturn = (call, index, failed, time)
            case "turn/end":
                clearCandidate()
            default:
                break
            }
        }

        if let call = pending.last(where: { BotDisplayContract.isToolCallVisible(named: $0.name) }) {
            return BotActivity(status: .toolRunning, detail: call.resolution.text,
                               category: call.resolution.category, startedAt: call.time)
        }
        if let phase, phase.streaming, phase.index > (lastReturn?.index ?? -1) {
            return BotActivity(status: .streaming, detail: "正在回复", category: .replying,
                               startedAt: phase.time)
        }
        if let result = lastReturn {
            return BotActivity(status: .thinking,
                               detail: result.failed ? "这步遇到问题" : result.call.resolution.text,
                               category: .reviewing,
                               startedAt: (phase?.index ?? -1) > result.index ? phase!.time : result.time)
        }
        return BotActivity(status: .thinking, detail: "等待响应", category: .thinking,
                           startedAt: phase?.time ?? startTime)
    }

    /// Priority (`activity-evidence-v3`): the call's own short model intent,
    /// then the same-step public progress sentence, then the short object
    /// fallback, then the concrete label. A model sentence is never extended
    /// with a full path or URL.
    static func sentence(toolName: String, arguments: [String: PhoneDSHBot.BotJSONValue],
                         publicText: String?) -> Resolution {
        let rule = Self.rule(for: toolName)
        for key in rule.intentKeys {
            guard let raw = arguments[key]?.runtimeString,
                  let text = BotActivityEvidence.displayText(raw) else { continue }
            return Resolution(text: text, category: rule.category)
        }
        if rule.allowsPublicText, let publicText,
           let text = BotActivityEvidence.displayText(publicText) {
            return Resolution(text: text, category: rule.category)
        }
        var label = rule.label
        if let object = objectText(rule, arguments: arguments) {
            label += " · " + object
        }
        if let secondary = secondaryText(rule, arguments: arguments) {
            let candidate = label + " · " + secondary
            if BotActivityEvidence.fitsShortBound(candidate) { label = candidate }
        }
        // The action label and object were shortened individually; the joined
        // fallback must be shortened again so a long basename/query cannot
        // exceed the short bound through the prefix. There is no separate
        // legacy target allowance.
        return Resolution(text: BotActivityEvidence.shortened(label),
                          category: rule.category)
    }

    /// The durable `assistant/message` text: only real text blocks count, so a
    /// reasoning-only message yields no candidate.
    private static func publicMessageText(_ data: [String: PhoneDSHBot.BotJSONValue]) -> String? {
        let content = data["message"]?.runtimeObject?["content"] ?? data["content"]
        if let text = content?.runtimeString {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        guard case .array(let parts)? = content else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let value = part.runtimeObject,
                  value["type"]?.runtimeString == "text",
                  let text = value["text"]?.runtimeString,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    /// Short object fallback: basename for files, host for URLs, pattern for
    /// glob/grep, name/title/query as written. A long value is shortened like
    /// a sentence instead of becoming a second path table.
    private static func objectText(_ rule: Rule,
                                   arguments: [String: PhoneDSHBot.BotJSONValue]) -> String? {
        for key in rule.objectKeys {
            guard let value = arguments[key] else { continue }
            switch rule.objectKind {
            case .links:
                if case .array(let items) = value {
                    if let url = items.compactMap({ $0.runtimeObject }).first?["url"]?.runtimeString {
                        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !raw.isEmpty {
                            return BotActivityEvidence.shortened(
                                BotActivityEvidence.displayHost(raw))
                        }
                    }
                    continue
                }
                if let raw = value.runtimeString?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    return BotActivityEvidence.shortened(BotActivityEvidence.displayHost(raw))
                }
                continue
            case .query:
                if case .array(let items) = value {
                    if let first = items.compactMap({ $0.runtimeString })
                        .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        return BotActivityEvidence.shortened(
                            first.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    continue
                }
            case .url:
                if let raw = value.runtimeString?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    return BotActivityEvidence.shortened(BotActivityEvidence.displayHost(raw))
                }
                continue
            case .plain:
                break
            }
            guard let raw = value.runtimeString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let display = rule.pathKeys.contains(key) ? BotActivityEvidence.basename(raw) : raw
            return BotActivityEvidence.shortened(display)
        }
        return nil
    }

    private static func secondaryText(_ rule: Rule,
                                      arguments: [String: PhoneDSHBot.BotJSONValue]) -> String? {
        for key in rule.secondaryKeys {
            guard let text = arguments[key]?.runtimeString?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            return BotActivityEvidence.basename(text)
        }
        return nil
    }
}

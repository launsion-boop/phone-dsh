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
            activity: activity(turn: running, events: sessionEvents),
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
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            switch event.type {
            case "turn/start":
                let id = event.data["turn"]?.runtimeString ?? event.data["turn"]?.runtimeInt.map(String.init)
                    ?? "\(sessionID):\(event.seq)"
                current = (id, event.seq)
            case "turn/end": current = nil
            default: break
            }
        }
        return current
    }

    private static func activity(turn: (id: String, seq: Int)?,
                                 events: [BotDSHSessionEvent]) -> BotActivity? {
        guard let turn else { return nil }
        let active = events.filter { $0.seq >= turn.seq }
        if active.contains(where: { $0.type == "assistant/stream" }) { return nil }
        let lastUser = active.lastIndex(where: {
            $0.type == "user/message" && $0.data["role"]?.runtimeString == "user"
        }) ?? active.startIndex
        guard let tool = active[lastUser...].last(where: { $0.type == "tool/call" }) else {
            return BotActivity(status: .thinking)
        }
        let name = tool.data["name"]?.runtimeString ?? ""
        // FishAction is cosmetic and hidden from process rows; it must not
        // become the visible activity line or leak its tool name into the
        // sidebar's status text. The director still plays its reaction.
        guard BotDisplayContract.isToolCallVisible(named: name) else { return nil }
        let arguments = toolArguments(tool.data["arguments"])
        return BotActivity(status: .toolRunning, detail: BotToolActivity.describe(name: name, arguments: arguments))
    }

    private static func toolArguments(_ value: PhoneDSHBot.BotJSONValue?) -> [String: PhoneDSHBot.BotJSONValue] {
        if let object = value?.runtimeObject { return object }
        guard let text = value?.runtimeString, let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PhoneDSHBot.BotJSONValue.self, from: data) else { return [:] }
        return decoded.runtimeObject ?? [:]
    }
}

enum BotToolActivity {
    private static let labels = [
        "bash": "执行指令", "shell": "执行指令", "exec": "执行指令", "terminal": "执行指令",
        "read": "读取文件", "read_file": "读取文件",
        "write": "写入文件", "write_file": "写入文件",
        "edit": "编辑文件", "edit_file": "编辑文件", "apply_patch": "编辑文件",
        "glob": "搜索文件", "grep": "搜索内容",
        "web_search": "搜索网络", "websearch": "搜索网络",
        "web_fetch": "读取网页", "webfetch": "读取网页", "fetch": "读取网页",
        "task": "启动子代理", "subagent": "启动子代理",
        "createteammate": "建立 Bot", "sendtouser": "整理回复", "send_to_user": "整理回复",
        "ask_user": "整理问题",
    ]

    static func describe(name rawName: String, arguments: [String: PhoneDSHBot.BotJSONValue]) -> String {
        if let custom = arguments.runtimeString("description", "summary", "label") {
            return String(custom.prefix(80))
        }
        let parts = rawName.components(separatedBy: "__")
        let name = (rawName.hasPrefix("mcp__") && parts.count > 2
                    ? parts.dropFirst(2).joined(separator: "__") : rawName).lowercased()
        let label = labels[name] ?? "使用 \(name.isEmpty ? "工具" : name)"
        let target = arguments.runtimeString("path", "file_path", "filePath", "query", "url", "command", "prompt", "name")
            .map(shortTarget) ?? ""
        return target.isEmpty ? label : "\(label) · \(target)"
    }

    private static func shortTarget(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .filter { !$0.isEmpty }.last ?? text
        return base.count > 42 ? "\(base.prefix(39))…" : base
    }
}

private extension Dictionary where Key == String, Value == PhoneDSHBot.BotJSONValue {
    func runtimeString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.runtimeString, !value.isEmpty { return value }
        }
        return nil
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

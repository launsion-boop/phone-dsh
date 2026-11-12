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

    /// The current phase of the running turn. Only the tail after the last
    /// user message counts: a finished tool call becomes `reviewing` until a
    /// new tool call or the next `step/start`, a stream hides the line, and a
    /// hidden cosmetic tool (FishAction) never produces one at all.
    private static func activity(turn: (id: String, seq: Int)?,
                                 events: [BotDSHSessionEvent],
                                 now: Int64) -> BotActivity? {
        guard let turn else { return nil }
        let active = events.filter { $0.seq >= turn.seq }
        let lastUser = active.lastIndex(where: {
            $0.type == "user/message" && $0.data["role"]?.runtimeString == "user"
        }) ?? active.startIndex
        let tail = Array(active[lastUser...])
        let lastStep = tail.lastIndex(where: { $0.type == "step/start" })
        let lastCall = tail.lastIndex(where: { $0.type == "tool/call" })
        let lastStream = tail.lastIndex(where: { $0.type == "assistant/stream" })

        // The latest phase is a tool call (no newer step yet).
        if let lastCall, lastStep == nil || lastCall > lastStep! {
            // A stream that starts after the latest call means the body is
            // visible; keep the existing rule and hide the line.
            if let lastStream, lastStream > lastCall { return nil }
            let call = tail[lastCall]
            let name = call.data["name"]?.runtimeString ?? ""
            // FishAction is cosmetic and hidden from process rows; it must not
            // become the visible activity line or leak its tool name into the
            // sidebar's status text. The director still plays its reaction.
            guard BotDisplayContract.isToolCallVisible(named: name) else { return nil }
            let arguments = toolArguments(call.data["arguments"])
            let startedAt = max(0, call.time) > 0 ? call.time : now
            if let result = matchingResult(after: lastCall, in: tail) {
                return BotActivity(
                    status: .toolRunning,
                    detail: BotActivityPhrases.reviewingText(forToolNamed: name,
                                                             arguments: arguments),
                    category: .reviewing,
                    startedAt: max(0, tail[result].time) > 0 ? tail[result].time : startedAt)
            }
            let phrase = BotActivityPhrases.toolActivity(forToolNamed: name, arguments: arguments)
            return BotActivity(status: .toolRunning, detail: phrase.text,
                               category: phrase.category, startedAt: startedAt)
        }

        // Streaming in the current step hides the line.
        if let lastStream, lastStep == nil || lastStream > lastStep! { return nil }
        // A new step without a tool call is back to thinking; the previous
        // tool's "running" detail must not linger.
        if let lastStep {
            let startedAt = max(0, tail[lastStep].time) > 0 ? tail[lastStep].time : now
            return BotActivity(status: .thinking, category: .thinking, startedAt: startedAt)
        }
        if lastStream != nil { return nil }
        let start = active.first(where: { $0.seq == turn.seq })
        let startedAt: Int64
        if let start, start.time > 0 { startedAt = start.time } else { startedAt = now }
        return BotActivity(status: .thinking, category: .thinking, startedAt: startedAt)
    }

    /// The matching `tool/result` after `callIndex`, using the real event
    /// shape (`message.toolCallId` / `source.callId`) with the older
    /// `data.callId` as a fallback. Events from before call IDs were carried
    /// still count as a result for the last call.
    private static func matchingResult(after callIndex: Int,
                                       in events: [BotDSHSessionEvent]) -> Int? {
        let callID = events[callIndex].data["callId"]?.runtimeString ?? ""
        for index in events.indices where index > callIndex {
            guard events[index].type == "tool/result" else { continue }
            let resultID = toolResultCallID(events[index].data)
            if callID.isEmpty || resultID.isEmpty || resultID == callID { return index }
        }
        return nil
    }

    private static func toolResultCallID(_ data: [String: PhoneDSHBot.BotJSONValue]) -> String {
        data["message"]?.runtimeObject?["toolCallId"]?.runtimeString
            ?? data["callId"]?.runtimeString
            ?? data["message"]?.runtimeObject?["source"]?.runtimeObject?["callId"]?.runtimeString
            ?? ""
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
        BotActivityPhrases.toolActivity(forToolNamed: name, arguments: arguments).text
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

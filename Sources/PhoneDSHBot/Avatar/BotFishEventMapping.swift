// SPDX-License-Identifier: MIT

import Foundation

/// One presentation event before it is reduced by `BotFishDirector`.
///
/// phoneDSH has two real event sources for a Bot: the DSH session log / live
/// frame (`BotDSHSessionEvent`) and the durable BotEvent journal. Both are
/// normalised here so the App never hand-copies the upstream director type
/// table. The upstream `BotFishDirector` mapping and its golden stay
/// authoritative and untouched.
public enum BotFishEventSource: Sendable, Equatable {
    case dshSession(BotDSHSessionEvent)
    case botEvent(BotEvent)
}

public enum BotFishDirectorEventMapper {
    /// Session-log/live-frame types that upstream's director names differently.
    /// Only real DSH events appear here; `step/start`, `step/end` and
    /// `assistant/message` are intentionally absent because they carry no
    /// additional fish state.
    public static func event(from event: BotDSHSessionEvent) -> BotFishEvent? {
        switch event.type {
        case "turn/start":
            return BotFishEvent(type: "turn.start", time: event.time, data: event.data)
        case "turn/end":
            return BotFishEvent(type: "turn.end", time: event.time, data: event.data)
        case "user/message":
            let role = event.data["role"]?.stringValue
                ?? event.data["message"]?["role"]?.stringValue
            guard role == "user" else { return nil }
            return BotFishEvent(type: "user.message", time: event.time, data: event.data)
        case "assistant/stream":
            var data = event.data
            if data["channel"] == nil { data["channel"] = .string("text") }
            return BotFishEvent(type: "model.delta", time: event.time, data: data)
        case "tool/call":
            return BotFishEvent(type: "tool.start", time: event.time, data: event.data)
        case "approval/requested":
            return BotFishEvent(type: "approval.requested", time: event.time, data: event.data)
        case "approval/resolved", "approval/decided":
            return BotFishEvent(type: "approval.resolved", time: event.time, data: event.data)
        case "error", "runtime/error":
            return BotFishEvent(type: "error", time: event.time, data: event.data)
        default:
            return nil
        }
    }

    /// Durable BotEvent types already use the upstream director vocabulary
    /// (`approval.requested`, `task.settled`, `memory.written`, …). A few
    /// legacy aliases accepted by `BotFishDirector` are normalised to one
    /// canonical name so the mapping is testable as a total table.
    public static func event(from event: BotEvent) -> BotFishEvent? {
        let type: String
        switch event.type {
        case "turn.start", "turn.started", "turn_start", "conversation.turn_started":
            type = "turn.start"
        case "turn.end", "turn.ended", "turn_end", "conversation.turn_ended":
            type = "turn.end"
        case "user.message", "user-message", "conversation.user_message":
            type = "user.message"
        case "model.delta", "model.stream", "stream.delta":
            type = "model.delta"
        case "tool.start", "tool.started", "tool_start", "conversation.tool_call":
            type = "tool.start"
        case "approval.requested", "approval_requested":
            type = "approval.requested"
        case "approval.resolved", "approval.decided", "approval_resolved":
            type = "approval.resolved"
        case "task.done", "task.settled", "task_done":
            type = "task.done"
        case "error", "conversation.error", "runtime.error":
            type = "error"
        case "memory.written", "memory_written":
            type = "memory.written"
        case "watchdog.flagged":
            type = "watchdog.flagged"
        default:
            return nil
        }
        let data = event.data.objectValue ?? [:]
        return BotFishEvent(type: type, time: event.time, data: data)
    }

    public static func event(from source: BotFishEventSource) -> BotFishEvent? {
        switch source {
        case .dshSession(let event): return self.event(from: event)
        case .botEvent(let event): return self.event(from: event)
        }
    }

    /// The real lifecycle inputs are not director events. Upstream derives
    /// them from the selected Bot's current turn/streaming/approval snapshot;
    /// phoneDSH exposes the same three real facts and the 60 s idle clock in
    /// `BotChatModel.fishState`. This helper only covers the per-event
    /// transitions so a caller cannot silently invent a state.
    public static func lifecycle(from event: BotDSHSessionEvent) -> BotFishLifecycle? {
        switch event.type {
        case "turn/start": return .thinking
        case "tool/call": return .working
        case "assistant/stream": return .streaming
        default: return nil
        }
    }

    public static func lifecycle(from event: BotEvent) -> BotFishLifecycle? {
        switch event.type {
        case "approval.requested": return .alerting
        case "conversation.tool_call": return .working
        case "conversation.user_message": return .listening
        case "conversation.turn_started": return .thinking
        case "conversation.turn_ended": return .idle
        default: return nil
        }
    }
}

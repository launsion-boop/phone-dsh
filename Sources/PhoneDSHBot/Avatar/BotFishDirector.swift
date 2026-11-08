// SPDX-License-Identifier: MIT

import Foundation

public enum BotFishLifecycle: String, Codable, Sendable {
    case idle, thinking, streaming, working, sleeping, alerting, listening, speaking, happy, sad
    case surprised, confused, laughing, love, angry, wink, nod, shrug, celebrate, poke
    case waking, waiting, loading, done, standby
    case spawning, bouncing, dancing, waving
    case shy, smug, crying, sighing, cheering, bowing, clapping, stretching, yawning, kiss
    case shakingHead = "shaking-head"
    case highFive = "high-five"
    case poweringDown = "powering-down"
}

public struct BotFishOneShot: Codable, Sendable, Equatable {
    public var state: BotFishLifecycle
    public var priority: Int
    public var startedAt: Int64
    public var endsAt: Int64

    public init(state: BotFishLifecycle, priority: Int, startedAt: Int64, endsAt: Int64) {
        self.state = state
        self.priority = priority
        self.startedAt = startedAt
        self.endsAt = endsAt
    }
}

public struct BotFishDirectorState: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var lifecycle: BotFishLifecycle
    public var current: BotFishLifecycle
    public var priority: Int
    public var oneShot: BotFishOneShot?
    public var lastOneShotAt: [String: Int64]
    public var now: Int64
    public var debounceMs: Int64
    public var lastEvent: String?
    public var version: Int

    public init(lifecycle: BotFishLifecycle = .idle, now: Int64 = 0, debounceMs: Int64 = 3_000) {
        self.lifecycle = lifecycle
        self.current = lifecycle
        self.priority = BotFishDirector.priority(for: lifecycle)
        self.oneShot = nil
        self.lastOneShotAt = [:]
        self.now = max(0, now)
        self.debounceMs = max(0, debounceMs)
        self.lastEvent = nil
        self.version = 0
    }
}

public struct BotFishCommand: Codable, Sendable, Equatable {
    public var state: BotFishLifecycle
    public var oneShot: Bool
    public var priority: Int
    public var ttlMs: Int64

    public init(state: BotFishLifecycle, oneShot: Bool, priority: Int, ttlMs: Int64) {
        self.state = state
        self.oneShot = oneShot
        self.priority = priority
        self.ttlMs = ttlMs
    }
}

public struct BotFishEvent: Sendable {
    public let type: String
    public let time: Int64
    public let data: [String: BotJSONValue]

    public init(type: String, time: Int64, data: [String: BotJSONValue] = [:]) {
        self.type = type
        self.time = max(0, time)
        self.data = data
    }
}

public enum BotFishDirector {
    private struct Mapping {
        let state: BotFishLifecycle
        let priority: Int
        let base: BotFishLifecycle?
        let oneShotTTL: Int64
        let force: Bool

        init(state: BotFishLifecycle, priority: Int, base: BotFishLifecycle? = nil,
             oneShotTTL: Int64 = 0, force: Bool = false) {
            self.state = state
            self.priority = priority
            self.base = base
            self.oneShotTTL = oneShotTTL
            self.force = force
        }
    }

    private static let turnStart: Set<String> = ["turn.start", "turn.started", "turn_start", "conversation.turn_started"]
    private static let turnEnd: Set<String> = ["turn.end", "turn.ended", "turn_end", "conversation.turn_ended"]
    private static let delta: Set<String> = ["model.delta", "model.stream", "stream.delta"]
    private static let toolStart: Set<String> = ["tool.start", "tool.started", "tool_start", "conversation.tool_call"]
    private static let approvalRequest: Set<String> = ["approval.requested", "approval_requested"]
    private static let approvalResolve: Set<String> = ["approval.resolved", "approval.decided", "approval_resolved"]
    private static let taskDone: Set<String> = ["task.done", "task.settled", "task_done"]
    private static let errors: Set<String> = ["error", "conversation.error", "runtime.error"]
    private static let memoryWritten: Set<String> = ["memory.written", "memory_written"]
    private static let userMessage: Set<String> = ["user.message", "user-message", "conversation.user_message"]

    public static func priority(for state: BotFishLifecycle) -> Int {
        switch state {
        case .idle: return 0
        case .sleeping, .standby: return 5
        case .waking, .waiting: return 10
        case .loading: return 15
        case .listening, .nod, .love: return 20
        case .thinking: return 30
        case .streaming: return 35
        case .speaking: return 40
        case .working: return 45
        case .confused, .surprised: return 50
        case .happy, .celebrate: return 70
        case .sad, .crying: return 75
        case .alerting: return 100
        default: return 10
        }
    }

    public static func reduce(_ state: BotFishDirectorState, event: BotFishEvent)
        -> (directorState: BotFishDirectorState, command: BotFishCommand?) {
        let now = event.time
        let freshened = expire(state, now: now)
        guard let mapping = mapping(for: event) else { return freshened }
        let active = freshened.directorState.oneShot.flatMap { now < $0.endsAt ? $0 : nil }
        let oneShot = mapping.oneShotTTL > 0
        if oneShot {
            if let active, active.state == mapping.state { return freshened }
            if let last = freshened.directorState.lastOneShotAt[mapping.state.rawValue],
               now - last < freshened.directorState.debounceMs { return freshened }
        }
        if !mapping.force {
            if let active, mapping.priority < active.priority { return freshened }
            if oneShot && mapping.priority < freshened.directorState.priority { return freshened }
            if !oneShot && freshened.directorState.current == .alerting
                && mapping.priority < freshened.directorState.priority { return freshened }
        }

        var next = freshened.directorState
        if let base = mapping.base { next.lifecycle = base }
        next.now = now
        next.current = mapping.state
        next.priority = mapping.priority
        next.oneShot = oneShot
            ? BotFishOneShot(state: mapping.state, priority: mapping.priority,
                             startedAt: now, endsAt: now + mapping.oneShotTTL)
            : nil
        if oneShot { next.lastOneShotAt[mapping.state.rawValue] = now }
        next.lastEvent = event.type
        next.version += 1
        let shouldCommand = oneShot || mapping.force
            || mapping.state != freshened.directorState.current
            || mapping.priority != freshened.directorState.priority
        let command = shouldCommand
            ? BotFishCommand(state: mapping.state, oneShot: oneShot,
                             priority: mapping.priority, ttlMs: mapping.oneShotTTL)
            : freshened.command
        return (next, command)
    }

    public static func setLifecycle(_ state: BotFishDirectorState, lifecycle: BotFishLifecycle,
                                    now: Int64? = nil)
        -> (directorState: BotFishDirectorState, command: BotFishCommand?) {
        let at = max(0, now ?? state.now)
        let freshened = expire(state, now: at)
        if freshened.directorState.oneShot != nil {
            var next = freshened.directorState
            next.lifecycle = lifecycle
            next.now = at
            return (next, freshened.command)
        }
        var next = freshened.directorState
        next.now = at
        next.lifecycle = lifecycle
        next.current = lifecycle
        next.priority = priority(for: lifecycle)
        let command = freshened.directorState.current == lifecycle
            ? freshened.command
            : BotFishCommand(state: lifecycle, oneShot: false, priority: next.priority, ttlMs: 0)
        return (next, command)
    }

    public static func expireOneShot(_ state: BotFishDirectorState, now: Int64)
        -> (directorState: BotFishDirectorState, command: BotFishCommand?) {
        expire(state, now: max(0, now))
    }

    private static func expire(_ state: BotFishDirectorState, now: Int64)
        -> (directorState: BotFishDirectorState, command: BotFishCommand?) {
        guard let reaction = state.oneShot, now >= reaction.endsAt else { return (state, nil) }
        var next = state
        next.now = now
        next.current = next.lifecycle
        next.priority = priority(for: next.lifecycle)
        next.oneShot = nil
        let command = state.current == next.current
            ? nil
            : BotFishCommand(state: next.current, oneShot: false, priority: next.priority, ttlMs: 0)
        return (next, command)
    }

    private static func mapping(for event: BotFishEvent) -> Mapping? {
        let type = event.type
        if turnStart.contains(type) {
            return Mapping(state: .thinking, priority: 40, base: .thinking, force: true)
        }
        if userMessage.contains(type) {
            return Mapping(state: .listening, priority: 30, base: .listening)
        }
        if delta.contains(type) {
            let state: BotFishLifecycle = string(event.data["channel"]) == "reasoning" ? .thinking : .speaking
            return Mapping(state: state, priority: 45, base: state)
        }
        if toolStart.contains(type) {
            return Mapping(state: .working, priority: 50, base: .working)
        }
        if approvalRequest.contains(type) {
            return Mapping(state: .alerting, priority: 100, base: .alerting)
        }
        if approvalResolve.contains(type) {
            if isApprovalDenied(event.data) {
                return Mapping(state: .sad, priority: 80, base: .idle, oneShotTTL: 3_200, force: true)
            }
            return Mapping(state: .working, priority: 50, base: .working, force: true)
        }
        if taskDone.contains(type) {
            if isTaskOk(event.data) {
                return Mapping(state: .celebrate, priority: 70, base: .idle, oneShotTTL: 2_200)
            }
            if isTaskError(event.data) {
                return Mapping(state: .sad, priority: 75, base: .idle, oneShotTTL: 3_600)
            }
            return nil
        }
        if errors.contains(type) {
            return Mapping(state: .sad, priority: 75, base: .idle, oneShotTTL: 3_600)
        }
        if memoryWritten.contains(type) {
            let state: BotFishLifecycle = string(event.data["scope"]) == "user" ? .love : .nod
            return Mapping(state: state, priority: 20, oneShotTTL: 2_000)
        }
        if turnEnd.contains(type) {
            return Mapping(state: .idle, priority: 0, base: .idle, force: true)
        }
        if type == "watchdog.flagged" {
            return Mapping(state: .alerting, priority: 100, base: .alerting)
        }
        return nil
    }

    private static func isTaskOk(_ data: [String: BotJSONValue]) -> Bool {
        if bool(data["ok"]) == true { return true }
        return ["ok", "done", "completed", "complete", "success", "succeeded"].contains(status(data))
    }

    private static func isTaskError(_ data: [String: BotJSONValue]) -> Bool {
        if bool(data["ok"]) == false { return true }
        if data["error"] != nil { return true }
        return ["error", "failed", "failure", "stopped", "cancelled", "canceled", "timed_out",
                "timeout", "aborted", "interrupted"].contains(status(data))
    }

    private static func isApprovalDenied(_ data: [String: BotJSONValue]) -> Bool {
        if bool(data["denied"]) == true || bool(data["deny"]) == true { return true }
        let resolution = (string(data["resolution"]) ?? string(data["decision"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["deny", "denied", "never", "timeout", "timed-out", "reject", "rejected"].contains(resolution)
    }

    private static func status(_ data: [String: BotJSONValue]) -> String {
        (string(data["status"]) ?? string(data["state"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }
}

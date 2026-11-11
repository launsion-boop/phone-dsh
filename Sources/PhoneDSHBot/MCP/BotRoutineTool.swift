// SPDX-License-Identifier: MIT

import Foundation

public enum BotRoutineTool {
    public static func handle(machine: RoutineMachine, principal: BotGatewayPrincipal,
                              arguments: BotJSONValue, now: Int64,
                              authority: BotTurnAuthority? = nil) async throws -> BotJSONValue {
        guard case .object(let args) = arguments,
              case .string(let action)? = args["action"] else {
            throw BotMCPError.invalidRequest("UpdateRoutine requires action")
        }
        let botId = principal.botId
        switch action {
        case "create":
            let title = try routineTitle(from: args)
            let prompt = try requiredString(args, "prompt")
            guard let rawSchedule = args["schedule"] else { throw BotMCPError.invalidRequest("schedule is required") }
            let creator = authority.map { RoutineCreator(authority: $0, approvalID: $0.approvalID) }
            if let creator, creator.authorization == .userConfirmed, creator.approvalID == nil {
                throw BotMCPError.invalidRequest("routine creation requires user confirmation")
            }
            let routine = try await machine.create(
                botId: botId, title: title, prompt: prompt,
                schedule: try schedule(rawSchedule),
                enabled: bool(args["enabled"]) ?? true,
                urgent: bool(args["urgent"]) ?? false,
                urgentReason: string(args["urgent_reason"]) ?? "",
                delivery: try delivery(args),
                interruptReason: string(args["interrupt_reason"]) ?? "",
                creator: creator,
                completionCriteria: optionalString(args["completion_criteria"]) ?? "",
                constraints: optionalString(args["constraints"]) ?? "",
                now: now)
            return try encode(routine)
        case "update":
            let id = try requiredString(args, "routine_id")
            let patch = try makePatch(from: args)
            return try await encode(machine.update(botId: botId, routineId: id, patch: patch, now: now))
        case "delete":
            let id = try requiredString(args, "routine_id")
            guard let removed = try await machine.delete(botId: botId, routineId: id) else {
                throw RoutineError.routineNotFound(id)
            }
            return try encode(removed)
        case "get":
            let id = try requiredString(args, "routine_id")
            guard let routine = try await machine.get(botId: botId, routineId: id) else {
                throw RoutineError.routineNotFound(id)
            }
            return try encode(routine)
        case "pause", "resume":
            let id = try requiredString(args, "routine_id")
            return try await encode(machine.update(
                botId: botId, routineId: id, patch: RoutinePatch(enabled: action == "resume"), now: now))
        case "list":
            let routines = try await machine.list(botId: botId)
            return .object(["routines": .array(try routines.map(encode)), "count": .number(Double(routines.count))])
        default:
            throw BotMCPError.invalidRequest("unsupported UpdateRoutine action: \(action)")
        }
    }

    public static func list(machine: RoutineMachine, principal: BotGatewayPrincipal) async throws -> BotJSONValue {
        let routines = try await machine.list(botId: principal.botId)
        return .object(["routines": .array(try routines.map(encode)), "count": .number(Double(routines.count))])
    }

    /// Parse the update half of an `UpdateRoutine` payload. `create` parsing
    /// stays in `handle`; `RoutineAuthority.assess` uses the same builder so
    /// the approval decision and the store see identical fields.
    static func makePatch(from args: [String: BotJSONValue]) throws -> RoutinePatch {
        var patch = RoutinePatch()
        if args["title"] != nil { patch.title = try requiredString(args, "title") }
        if args["prompt"] != nil { patch.prompt = try requiredString(args, "prompt") }
        if let rawSchedule = args["schedule"] { patch.schedule = try schedule(rawSchedule) }
        patch.enabled = bool(args["enabled"])
        patch.urgent = bool(args["urgent"])
        if args["urgent_reason"] != nil { patch.urgentReason = string(args["urgent_reason"]) }
        if args["delivery"] != nil { patch.delivery = try delivery(args) }
        if args["interrupt_reason"] != nil { patch.interruptReason = string(args["interrupt_reason"]) }
        if args["completion_criteria"] != nil { patch.completionCriteria = optionalString(args["completion_criteria"]) }
        if args["constraints"] != nil { patch.constraints = optionalString(args["constraints"]) }
        return patch
    }

    static func routineTitle(from args: [String: BotJSONValue]) throws -> String {
        try requiredString(args, "title")
    }

    static func schedule(_ value: BotJSONValue) throws -> RoutineSchedule {
        if case .string(let text) = value { return try schedule(text) }
        guard case .object(let object) = value,
              case .string(let kindName)? = object["kind"],
              let kind = RoutineSchedule.Kind(rawValue: kindName) else {
            throw BotMCPError.invalidRequest("invalid routine schedule")
        }
        let timezone = string(object["timezone"]) ?? TimeZone.current.identifier
        switch kind {
        case .interval:
            guard let minutes = try optionalInt(object["everyMinutes"]), minutes >= 1 else {
                throw BotMCPError.invalidRequest("everyMinutes must be at least 1")
            }
            return try RoutineSchedule.interval(everyMinutes: minutes, timezone: timezone).validated()
        case .daily:
            return try RoutineSchedule.daily(time: try requiredString(object, "time"), timezone: timezone).validated()
        case .weekly:
            guard case .array(let rawDays)? = object["weekdays"] else {
                throw BotMCPError.invalidRequest("weekly schedule requires weekdays")
            }
            let days = try rawDays.map { try integer($0) }
            return try RoutineSchedule.weekly(
                time: try requiredString(object, "time"), weekdays: days, timezone: timezone).validated()
        case .cron:
            return try RoutineSchedule.cron(try requiredString(object, "expr"), timezone: timezone).validated()
        }
    }

    static func schedule(_ raw: String) throws -> RoutineSchedule {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var timezone = TimeZone.current.identifier
        if text.hasPrefix("CRON_TZ=") {
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first, parts.count >= 2 else { throw BotMCPError.invalidRequest("invalid CRON_TZ schedule") }
            timezone = String(first.dropFirst("CRON_TZ=".count))
            text = parts.dropFirst().joined(separator: " ")
        }
        if text.hasPrefix("@every ") {
            let value = String(text.dropFirst("@every ".count))
            let pieces = value.split(separator: "/")
            let clock = pieces[0]
            let phase = pieces.count == 2 ? Int(pieces[1].dropLast()) : nil
            let minutes = try minutes(clock)
            return try RoutineSchedule.interval(everyMinutes: minutes, phaseMinutes: phase, timezone: timezone).validated()
        }
        switch text {
        case "@hourly": return try RoutineSchedule.interval(everyMinutes: 60, timezone: timezone).validated()
        case "@daily": return try RoutineSchedule.daily(time: "00:00", timezone: timezone).validated()
        case "@weekly": return try RoutineSchedule.weekly(time: "00:00", weekdays: [1], timezone: timezone).validated()
        case "@monthly": return try RoutineSchedule.cron("0 0 1 * *", timezone: timezone).validated()
        default: return try RoutineSchedule.cron(text, timezone: timezone).validated()
        }
    }

    static func minutes(_ value: Substring) throws -> Int {
        guard let unit = value.last, let number = Int(value.dropLast()) else {
            throw BotMCPError.invalidRequest("invalid @every schedule")
        }
        switch unit {
        case "m": return number
        case "h": return number * 60
        case "d": return number * 1_440
        default: throw BotMCPError.invalidRequest("@every supports m, h and d")
        }
    }

    static func delivery(_ args: [String: BotJSONValue]) throws -> RoutineDeliveryMode {
        guard let raw = string(args["delivery"]) else { return .held }
        guard let value = RoutineDeliveryMode(rawValue: raw) else { throw BotMCPError.invalidRequest("invalid delivery") }
        return value
    }

    private static func encode(_ routine: Routine) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(routine))
    }

    static func requiredString(_ object: [String: BotJSONValue], _ key: String) throws -> String {
        guard let value = string(object[key]), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BotMCPError.invalidRequest("\(key) is required")
        }
        return value
    }

    static func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    static func optionalString(_ value: BotJSONValue?) -> String? {
        guard let value else { return nil }
        guard case .null = value else { return string(value) }
        return ""
    }

    static func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    static func integer(_ value: BotJSONValue) throws -> Int {
        guard case .number(let number) = value, number.isFinite, number.rounded() == number else {
            throw BotMCPError.invalidRequest("weekdays must contain integers")
        }
        return Int(number)
    }

    static func optionalInt(_ value: BotJSONValue?) throws -> Int? {
        guard let value else { return nil }
        return try integer(value)
    }
}

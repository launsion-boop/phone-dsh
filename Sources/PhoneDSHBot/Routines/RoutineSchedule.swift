// SPDX-License-Identifier: MIT

import Foundation

struct CronExpression {
    struct Field {
        var values: Set<Int>
        var restricted: Bool
    }

    var minute: Field
    var hour: Field
    var dayOfMonth: Field
    var month: Field
    var dayOfWeek: Field

    static func parse(_ expression: String) throws -> CronExpression {
        let fields = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else {
            throw RoutineError.invalidSchedule("cron expr must have five fields: minute hour day-of-month month day-of-week")
        }
        let dow = try parseField(fields[4], min: 0, max: 7, label: "day-of-week")
        return CronExpression(
            minute: try parseField(fields[0], min: 0, max: 59, label: "minute"),
            hour: try parseField(fields[1], min: 0, max: 23, label: "hour"),
            dayOfMonth: try parseField(fields[2], min: 1, max: 31, label: "day-of-month"),
            month: try parseField(fields[3], min: 1, max: 12, label: "month"),
            dayOfWeek: Field(values: Set(dow.values.map { $0 == 7 ? 0 : $0 }), restricted: dow.restricted)
        )
    }

    private static func parseField(_ text: String, min: Int, max: Int, label: String) throws -> Field {
        guard !text.isEmpty else { throw RoutineError.invalidSchedule("cron \(label) field is empty") }
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !part.isEmpty else { throw RoutineError.invalidSchedule("cron \(label) field has an empty list item") }
            let slash = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard slash.count <= 2 else { throw RoutineError.invalidSchedule("cron \(label) item \"\(part)\" has too many \"/\"") }
            let step = slash.count == 2 ? Int(slash[1]) : 1
            guard let step, step >= 1 else { throw RoutineError.invalidSchedule("cron \(label) step is invalid") }
            let range = slash[0]
            let start: Int
            let end: Int
            if range == "*" {
                start = min
                end = max
            } else if range.contains("-") {
                let bounds = range.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]) else {
                    throw RoutineError.invalidSchedule("cron \(label) range \"\(part)\" must be \(min)–\(max)")
                }
                start = lower
                end = upper
            } else {
                guard let value = Int(range) else {
                    throw RoutineError.invalidSchedule("cron \(label) range \"\(part)\" must be \(min)–\(max)")
                }
                start = value
                end = slash.count == 2 ? max : value
            }
            guard start >= min, end <= max, start <= end else {
                throw RoutineError.invalidSchedule("cron \(label) range \"\(part)\" must be \(min)–\(max)")
            }
            for value in stride(from: start, through: end, by: step) { values.insert(value) }
        }
        return Field(values: values, restricted: text != "*" && text != "*/1")
    }

    func matches(date: RoutineClock.Parts) -> Bool {
        guard month.values.contains(date.month) else { return false }
        let domMatch = dayOfMonth.values.contains(date.day)
        let dowMatch = dayOfWeek.values.contains(date.weekday % 7)
        if dayOfMonth.restricted && dayOfWeek.restricted { return domMatch || dowMatch }
        return domMatch && dowMatch
    }

    var minutesOfDay: [Int] {
        hour.values.sorted().flatMap { hour in
            minute.values.sorted().map { minute in hour * 60 + minute }
        }.sorted()
    }
}

enum RoutineClock {
    struct Parts {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        var weekday: Int
    }

    static func parseTime(_ value: String?) throws -> (hour: Int, minute: Int, text: String) {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              hour >= 0, hour <= 23, minute >= 0, minute <= 59,
              pieces[0].count <= 2, pieces[1].count == 2 else {
            throw RoutineError.invalidSchedule("schedule.time must be HH:MM (00:00–23:59), got \"\(value ?? "")\"")
        }
        return (hour, minute, String(format: "%02d:%02d", hour, minute))
    }

    static func calendar(_ timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func parts(_ milliseconds: Int64, _ timezone: String) -> Parts {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let values = calendar(timezone).dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let sundayFirst = values.weekday ?? 1
        return Parts(year: values.year!, month: values.month!, day: values.day!,
                     hour: values.hour! % 24, minute: values.minute!, second: values.second!,
                     weekday: sundayFirst == 1 ? 7 : sundayFirst - 1)
    }

    static func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day,
                                                hour: hour, minute: minute, second: second))!
    }

    static func addDays(_ parts: Parts, _ days: Int) -> Parts {
        let date = utcCalendar().date(byAdding: .day, value: days,
                                      to: self.date(year: parts.year, month: parts.month, day: parts.day))!
        let values = utcCalendar().dateComponents([.year, .month, .day, .weekday], from: date)
        let sundayFirst = values.weekday ?? 1
        return Parts(year: values.year!, month: values.month!, day: values.day!, hour: 0,
                     minute: 0, second: 0, weekday: sundayFirst == 1 ? 7 : sundayFirst - 1)
    }

    static func wallToUTC(year: Int, month: Int, day: Int, hour: Int, minute: Int, timezone: String) -> Int64 {
        let base = date(year: year, month: month, day: day, hour: hour, minute: minute)
        let zone = TimeZone(identifier: timezone) ?? .current
        var candidate = base
        for _ in 0..<3 {
            let next = base.addingTimeInterval(-TimeInterval(zone.secondsFromGMT(for: candidate)))
            if next == candidate { break }
            candidate = next
        }
        return Int64(candidate.timeIntervalSince1970 * 1000)
    }

    static func formatter(_ format: String, timezone: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.calendar = calendar(timezone)
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = format
        return formatter
    }
}

public enum RoutineScheduleMath {
    public static func nextRunAt(_ input: RoutineSchedule, now: Int64,
                                 createdAt: Int64? = nil, lastRunAt: Int64? = nil) throws -> Int64 {
        let schedule = try input.validated()
        switch schedule.kind {
        case .interval:
            return try nextInterval(schedule, now: now, createdAt: createdAt, lastRunAt: lastRunAt)
        case .daily:
            let time = try RoutineClock.parseTime(schedule.time)
            let today = RoutineClock.parts(now, schedule.timezone)
            for offset in 0...2 {
                let date = RoutineClock.addDays(today, offset)
                let candidate = RoutineClock.wallToUTC(year: date.year, month: date.month, day: date.day,
                                                       hour: time.hour, minute: time.minute, timezone: schedule.timezone)
                if candidate > now { return candidate }
            }
            throw RoutineError.invalidSchedule("daily schedule has no occurrence in the next three days")
        case .weekly:
            let time = try RoutineClock.parseTime(schedule.time)
            let days = Set(schedule.weekdays ?? [])
            let today = RoutineClock.parts(now, schedule.timezone)
            for offset in 0...8 {
                let date = RoutineClock.addDays(today, offset)
                guard days.contains(date.weekday) else { continue }
                let candidate = RoutineClock.wallToUTC(year: date.year, month: date.month, day: date.day,
                                                       hour: time.hour, minute: time.minute, timezone: schedule.timezone)
                if candidate > now { return candidate }
            }
            throw RoutineError.invalidSchedule("weekly schedule has no occurrence in the next eight days")
        case .cron:
            let cron = try CronExpression.parse(schedule.expr ?? "")
            let minutes = cron.minutesOfDay
            guard !minutes.isEmpty else { throw RoutineError.invalidSchedule("cron expression matches no minute of the day") }
            let today = RoutineClock.parts(now, schedule.timezone)
            for offset in 0...366 {
                let date = RoutineClock.addDays(today, offset)
                guard cron.matches(date: date) else { continue }
                for minuteOfDay in minutes {
                    let candidate = RoutineClock.wallToUTC(year: date.year, month: date.month, day: date.day,
                                                           hour: minuteOfDay / 60, minute: minuteOfDay % 60,
                                                           timezone: schedule.timezone)
                    if candidate > now { return candidate }
                }
            }
            throw RoutineError.invalidSchedule("cron expression has no occurrence in the next year")
        }
    }

    public static func nextAfterAttempt(_ routine: Routine, startedAt: Int64,
                                        finishedAt: Int64, scheduledFor: Int64?) throws -> Int64? {
        guard routine.enabled else { return nil }
        if routine.schedule.kind == .interval {
            return try nextRunAt(routine.schedule, now: finishedAt, createdAt: routine.createdAt, lastRunAt: finishedAt)
        }
        var next = try nextRunAt(routine.schedule, now: scheduledFor ?? startedAt,
                                 createdAt: routine.createdAt, lastRunAt: startedAt)
        if next <= finishedAt {
            next = try nextRunAt(routine.schedule, now: finishedAt,
                                 createdAt: routine.createdAt, lastRunAt: startedAt)
        }
        return next
    }

    private static func nextInterval(_ schedule: RoutineSchedule, now: Int64,
                                     createdAt: Int64?, lastRunAt: Int64?) throws -> Int64 {
        let every = Int64(schedule.everyMinutes!) * 60_000
        if let phase = schedule.phaseMinutes {
            let phaseMs = Int64(phase) * 60_000
            let parts = RoutineClock.parts(now, schedule.timezone)
            let wallNow = Int64(RoutineClock.date(year: parts.year, month: parts.month, day: parts.day,
                                                  hour: parts.hour, minute: parts.minute, second: parts.second)
                .timeIntervalSince1970 * 1000)
            var candidateWall = ((wallNow - phaseMs) / every) * every + phaseMs
            while candidateWall <= wallNow { candidateWall += every }
            for _ in 0..<10 {
                let date = Date(timeIntervalSince1970: TimeInterval(candidateWall) / 1000)
                let parts = RoutineClock.utcCalendar().dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let candidate = RoutineClock.wallToUTC(year: parts.year!, month: parts.month!, day: parts.day!,
                                                       hour: parts.hour!, minute: parts.minute!, timezone: schedule.timezone)
                if candidate > now { return candidate }
                candidateWall += every
            }
            throw RoutineError.invalidSchedule("phased interval has no occurrence after now")
        }
        let anchor = lastRunAt ?? createdAt ?? now
        if anchor + every > now { return anchor + every }
        let steps = (now - anchor) / every + 1
        return anchor + steps * every
    }

    public static func expression(_ schedule: RoutineSchedule) -> String? {
        switch schedule.kind {
        case .cron:
            return schedule.expr?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .interval:
            guard let every = schedule.everyMinutes, every >= 1 else { return nil }
            if let phase = schedule.phaseMinutes {
                guard phase >= 0, phase < every else { return nil }
                return "@every \(every)m/\(phase)m"
            }
            return "@every \(every)m"
        case .daily:
            guard let parsed = try? RoutineClock.parseTime(schedule.time) else { return nil }
            return "\(parsed.minute) \(parsed.hour) * * *"
        case .weekly:
            guard let parsed = try? RoutineClock.parseTime(schedule.time), let weekdays = schedule.weekdays,
                  !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { return nil }
            return "\(parsed.minute) \(parsed.hour) * * \(Array(Set(weekdays)).sorted().map(String.init).joined(separator: ","))"
        }
    }

    public static func describe(_ schedule: RoutineSchedule, lang: String = "zh") -> String {
        let zh = lang != "en"
        var base: String
        switch schedule.kind {
        case .interval:
            let every = schedule.everyMinutes ?? 0
            base = zh ? "每 \(every) 分鐘" : "every \(every) minutes"
            if let phase = schedule.phaseMinutes {
                base += zh ? "（相位 :\(String(format: "%02d", phase))）" : " (phase :\(String(format: "%02d", phase)))"
            }
        case .daily:
            base = zh ? "每天 \(schedule.time ?? "")" : "daily \(schedule.time ?? "")"
        case .weekly:
            let zhLabels = ["", "一", "二", "三", "四", "五", "六", "日"]
            let enLabels = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let days = (schedule.weekdays ?? []).map { zh ? zhLabels[$0] : enLabels[$0] }.joined(separator: zh ? "、" : ", ")
            base = zh ? "每週\(days) \(schedule.time ?? "")" : "weekly \(days) \(schedule.time ?? "")"
        case .cron:
            base = "cron \(schedule.expr ?? "")"
        }
        return zh ? "\(base)（\(schedule.timezone)）" : "\(base) (\(schedule.timezone))"
    }

    public static func formatMinute(_ milliseconds: Int64?, timezone: String) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return RoutineClock.formatter("yyyy-MM-dd HH:mm", timezone: timezone)
            .string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }

    public static func summarize(_ value: String, max: Int = 100) -> String {
        let text = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var sentenceEnd: String.Index?
        for index in text.indices {
            let character = text[index]
            if "。！？".contains(character) {
                sentenceEnd = text.index(after: index)
                break
            }
            if ".!?".contains(character) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace {
                    sentenceEnd = next
                    break
                }
            }
        }
        let sentence = sentenceEnd.map { String(text[..<$0]) } ?? text
        return String(sentence.prefix(Swift.max(1, max))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension RoutineSchedule {
    static func parse(_ input: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                      timezone: TimeZone = .current) throws -> RoutineSchedule {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RoutineError.invalidSchedule("schedule string is empty") }
        var zone = timezone.identifier
        if text.uppercased().hasPrefix("CRON_TZ=") {
            let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard pieces.count >= 2, let prefix = pieces.first, prefix.count > 8 else {
                throw RoutineError.invalidSchedule("CRON_TZ= prefix must be followed by an IANA zone and a schedule")
            }
            zone = String(prefix.dropFirst(8))
            guard TimeZone(identifier: zone) != nil else { throw RoutineError.invalidSchedule("unsupported time zone: \(zone)") }
            text = pieces.dropFirst().joined(separator: " ")
        }
        if text.lowercased().hasPrefix("@every") { return try parseEvery(text, timezone: zone) }
        let shorthand = text.lowercased()
        if ["@hourly", "@daily", "@weekly", "@monthly"].contains(shorthand) {
            let parts = RoutineClock.parts(now, zone)
            let expression: String
            switch shorthand {
            case "@hourly": expression = "\(parts.minute) * * * *"
            case "@daily": expression = "\(parts.minute) \(parts.hour) * * *"
            case "@weekly": expression = "\(parts.minute) \(parts.hour) * * \(parts.weekday % 7)"
            default: expression = "\(parts.minute) \(parts.hour) \(parts.day) * *"
            }
            return try RoutineSchedule.cron(expression, timezone: zone).validated()
        }
        if text.hasPrefix("@") { throw RoutineError.invalidSchedule("unsupported schedule shorthand: \(text)") }
        return try RoutineSchedule.cron(text, timezone: zone).validated()
    }

    private static func parseEvery(_ input: String, timezone: String) throws -> RoutineSchedule {
        let pattern = #"^@every\s+(\d+)\s*([mhd])(?:\s*/\s*(\d+)\s*([mhd])?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw RoutineError.invalidSchedule("invalid @every parser")
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              let amountRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let amount = Int(input[amountRange]) else {
            throw RoutineError.invalidSchedule("@every must look like \"@every 5m\", \"@every 2h\", \"@every 1d\" or \"@every 30m/17m\"")
        }
        let unit = input[unitRange].lowercased()
        let multiplier = unit == "m" ? 1 : unit == "h" ? 60 : 1440
        let every = amount * multiplier
        guard every >= 5, every <= 525_600 else {
            throw RoutineError.invalidSchedule("@every interval must be 5–525600 minutes (official minimum is 5m)")
        }
        var phase: Int?
        if match.range(at: 3).location != NSNotFound,
           let phaseRange = Range(match.range(at: 3), in: input), let phaseAmount = Int(input[phaseRange]) {
            var phaseUnit = unit
            if match.range(at: 4).location != NSNotFound, let unitRange = Range(match.range(at: 4), in: input) {
                phaseUnit = input[unitRange].lowercased()
            }
            let phaseMultiplier = phaseUnit == "m" ? 1 : phaseUnit == "h" ? 60 : 1440
            phase = phaseAmount * phaseMultiplier
        }
        return try RoutineSchedule.interval(everyMinutes: every, phaseMinutes: phase, timezone: timezone).validated()
    }
}

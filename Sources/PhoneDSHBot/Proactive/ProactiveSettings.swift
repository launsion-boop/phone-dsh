// SPDX-License-Identifier: MIT

import Foundation

public enum ProactiveMode: String, Codable, Sendable {
    case off
    case would
    case on
}

public struct ProactiveSettings: Codable, Sendable, Equatable {
    public var mode: ProactiveMode
    public var dnd: Bool
    public var quietStart: String
    public var quietEnd: String
    public var routineQuietWeekends: Bool
    public var timeZone: String

    public init(mode: ProactiveMode = .would, dnd: Bool = false,
                quietStart: String = "23:00", quietEnd: String = "08:00",
                routineQuietWeekends: Bool = false,
                timeZone: String = TimeZone.current.identifier) {
        self.mode = mode
        self.dnd = dnd
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.routineQuietWeekends = routineQuietWeekends
        self.timeZone = timeZone
    }

    public func normalized() -> ProactiveSettings {
        var copy = self
        if QuietClock.minutes(quietStart) == nil { copy.quietStart = "23:00" }
        if QuietClock.minutes(quietEnd) == nil { copy.quietEnd = "08:00" }
        if TimeZone(identifier: timeZone) == nil { copy.timeZone = TimeZone.current.identifier }
        return copy
    }
}

enum QuietClock {
    static func minutes(_ value: String) -> Int? {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count <= 2, pieces[1].count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func parts(_ now: Int64, timeZone: String) -> (minute: Int, weekday: Int, day: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let components = calendar.dateComponents([.hour, .minute, .weekday, .year, .month, .day],
                                                 from: Date(timeIntervalSince1970: TimeInterval(now) / 1000))
        let day = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        return ((components.hour ?? 0) * 60 + (components.minute ?? 0), components.weekday ?? 1, day)
    }
}

public enum RoutineQuietHours {
    public static func contains(_ now: Int64, settings: ProactiveSettings) -> Bool {
        let settings = settings.normalized()
        let parts = QuietClock.parts(now, timeZone: settings.timeZone)
        if settings.routineQuietWeekends && (parts.weekday == 1 || parts.weekday == 7) { return true }
        return isWithinQuietHours(now, start: settings.quietStart, end: settings.quietEnd,
                                  timeZone: settings.timeZone)
    }

    public static func isWithinQuietHours(_ now: Int64, start: String, end: String,
                                          timeZone: String = TimeZone.current.identifier) -> Bool {
        guard let from = QuietClock.minutes(start), let to = QuietClock.minutes(end), from != to else { return false }
        let current = QuietClock.parts(now, timeZone: timeZone).minute
        if from < to { return current >= from && current < to }
        return current >= from || current < to
    }

    public static func nextEnd(_ now: Int64, settings: ProactiveSettings) -> Int64? {
        let settings = settings.normalized()
        guard contains(now, settings: settings) else { return now / 60_000 * 60_000 }
        var cursor = now / 60_000 * 60_000 + 60_000
        for _ in 0..<(9 * 24 * 60) {
            if !contains(cursor, settings: settings) { return cursor }
            cursor += 60_000
        }
        return nil
    }

    static func dayKey(_ now: Int64, timeZone: String) -> String {
        QuietClock.parts(now, timeZone: timeZone).day
    }
}

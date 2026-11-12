// SPDX-License-Identifier: MIT

import Foundation

/// The presence ladder from the plan §3.8. The App reports the inputs; the
/// library owns the decision so the Bot information page and the keep-alive
/// branch cannot drift apart.
public enum RoutinePresenceLevel: String, Sendable, Equatable, CaseIterable {
    case foreground
    case backgroundKeepAlive
    case scheduledNotification
}

public struct RoutinePresenceDelay: Sendable, Equatable, Identifiable {
    public var routineId: String
    public var title: String
    public var scheduledFor: Int64
    public var deferredUntil: Int64

    public var id: String { routineId }

    public init(routineId: String, title: String, scheduledFor: Int64, deferredUntil: Int64) {
        self.routineId = routineId
        self.title = title
        self.scheduledFor = scheduledFor
        self.deferredUntil = deferredUntil
    }
}

public struct RoutinePresence: Sendable, Equatable {
    public var level: RoutinePresenceLevel
    public var deferred: [RoutinePresenceDelay]
    public var scheduledNotificationCount: Int
    /// Earliest fire time among the routine-due notifications the host actually
    /// registered with the system, when one exists. The UI shows it next to the
    /// count; it is nil when nothing is registered (permission denied, DND, or
    /// no future routine) and must never be inferred from routine text.
    public var nextNotificationAt: Int64?

    public init(level: RoutinePresenceLevel,
                deferred: [RoutinePresenceDelay] = [],
                scheduledNotificationCount: Int = 0,
                nextNotificationAt: Int64? = nil) {
        self.level = level
        self.deferred = deferred
        self.scheduledNotificationCount = max(0, scheduledNotificationCount)
        self.nextNotificationAt = nextNotificationAt
    }
}

public enum RoutinePresencePolicy {
    /// A Bot whose routine is due inside this window keeps the silent-audio
    /// session alive after the App goes to the background.
    public static let keepAliveWindowMs: Int64 = 15 * 60 * 1_000

    public static func hasRoutineDueSoon(_ routines: [Routine], now: Int64,
                                        windowMs: Int64 = keepAliveWindowMs) -> Bool {
        let horizon = now + max(0, windowMs)
        return routines.contains {
            $0.enabled && $0.runState?.status != .needsReconciliation
                && ($0.nextRunAt ?? Int64.max) <= horizon
        }
    }

    public static func level(appActive: Bool, keepingAlive: Bool,
                             scheduledNotificationCount: Int) -> RoutinePresenceLevel {
        if appActive { return .foreground }
        if keepingAlive { return .backgroundKeepAlive }
        return .scheduledNotification
    }

    public static func deferred(_ routines: [Routine]) -> [RoutinePresenceDelay] {
        routines.compactMap { routine in
            guard routine.enabled, let deferral = routine.quietDefer else { return nil }
            return RoutinePresenceDelay(
                routineId: routine.id, title: routine.title,
                scheduledFor: deferral.scheduledFor, deferredUntil: deferral.until)
        }.sorted { ($0.deferredUntil, $0.routineId) < ($1.deferredUntil, $1.routineId) }
    }
}


/// One process-wide answer to "is the App foreground and is the silent-audio
/// keep-alive active". The App writes the two flags from its scene-phase and
/// keep-alive owners; the information service reads them without importing the
/// App's ChatModel (the macOS eval harness compiles the same production files).
@MainActor
public final class BotPresenceCenter {
    public struct Context: Sendable, Equatable {
        public var appActive: Bool
        public var keepingAlive: Bool

        public static let foreground = Context(appActive: true, keepingAlive: false)

        public init(appActive: Bool, keepingAlive: Bool) {
            self.appActive = appActive
            self.keepingAlive = keepingAlive
        }
    }

    public static let shared = BotPresenceCenter()

    public private(set) var appActive = true
    public private(set) var keepingAlive = false

    public func update(appActive: Bool? = nil, keepingAlive: Bool? = nil) {
        if let appActive { self.appActive = appActive }
        if let keepingAlive { self.keepingAlive = keepingAlive }
    }

    public func context() -> Context {
        Context(appActive: appActive, keepingAlive: keepingAlive)
    }
}

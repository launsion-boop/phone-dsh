// SPDX-License-Identifier: MIT

import Foundation

/// One routine-due notification the host asks the system to keep for a Bot.
///
/// This is not a proactive result notification and does not consume the
/// frequency fuse. It exists so the user still learns that a routine is due
/// after the App is suspended or killed. The field set is frozen by
/// `spec/bot/v2/routine-notification.schema.json`.
public struct RoutineScheduledNotification: Codable, Sendable, Equatable, Identifiable {
    public var identifier: String
    public var botId: String
    public var routineId: String
    public var title: String
    public var body: String
    public var fireAt: Int64
    public var deepLink: String

    public var id: String { identifier }

    public init(identifier: String, botId: String, routineId: String,
                title: String = "例行任务到期", body: String, fireAt: Int64,
                deepLink: String) {
        self.identifier = identifier
        self.botId = botId
        self.routineId = routineId
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.deepLink = deepLink
    }

    public init(botId: String, routineId: String, routineTitle: String, fireAt: Int64) {
        let title = String(routineTitle.prefix(120))
        self.init(
            identifier: Self.identifier(botId: botId, routineId: routineId, fireAt: fireAt),
            botId: botId, routineId: routineId,
            body: String("「\(title)」到点，点开运行。".prefix(200)),
            fireAt: fireAt,
            deepLink: BotRoutineDeepLink.make(botId: botId, routineId: routineId))
    }

    public static func identifier(botId: String, routineId: String, fireAt: Int64) -> String {
        "routine-due:\(botId):\(routineId):\(fireAt)"
    }
}

/// The deep link carried by a routine-due notification. Unlike a proactive
/// result, a routine has no result row before it runs, so this link targets
/// the routine's row in the Bot information page.
public enum BotRoutineDeepLink {
    public static func make(botId: String, routineId: String) -> String {
        "phonedsh://bot/\(escape(botId))/routine/\(escape(routineId))"
    }

    public static func parse(_ value: String) -> (botId: String, routineId: String)? {
        let prefix = "phonedsh://bot/"
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[1] == "routine",
              let botID = parts[0].removingPercentEncoding,
              let routineID = parts[2].removingPercentEncoding,
              !botID.isEmpty, !routineID.isEmpty else { return nil }
        return (botID, routineID)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Host seam for the system notification center. Tests inject a fake; the
/// production implementation is `UNUserNotificationRoutineScheduling`.
public protocol RoutineNotificationScheduling: Sendable {
    func schedule(_ notification: RoutineScheduledNotification) async throws
    func pendingIdentifiers(prefix: String) async -> [String]
    func cancel(identifiers: [String]) async
}

#if canImport(UserNotifications)
import UserNotifications

public final class UNUserNotificationRoutineScheduling: RoutineNotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func schedule(_ notification: RoutineScheduledNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo["deepLink"] = notification.deepLink
        content.userInfo["botId"] = notification.botId
        content.userInfo["routineId"] = notification.routineId
        content.userInfo["fireAt"] = notification.fireAt
        content.userInfo["notificationKind"] = "routine-due"

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(notification.fireAt) / 1000))
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notification.identifier,
                                            content: content, trigger: trigger)
        try await center.add(request)
    }

    public func pendingIdentifiers(prefix: String) async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
            }
        }
    }

    public func cancel(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
#endif

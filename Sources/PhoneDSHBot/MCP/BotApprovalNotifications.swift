// SPDX-License-Identifier: MIT

import Foundation

/// One durable approval the App should remind the user about when they are
/// away from the Bot page. This is a local presentation record, not a durable
/// wire event; the durable source is the existing `approval.requested`.
public struct BotApprovalNotificationRecord: Codable, Sendable, Equatable {
    public var approvalID: String
    public var botID: String
    public var action: String
    public var detail: String
    public var command: String
    public var requestedAt: Int64
    public var expiresAt: Int64

    public init(approvalID: String, botID: String, action: String,
                detail: String = "", command: String = "",
                requestedAt: Int64, expiresAt: Int64) {
        self.approvalID = approvalID
        self.botID = botID
        self.action = action
        self.detail = detail
        self.command = command
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

/// A pre-scheduled approval reminder. The identifier is stable per approval so
/// a decision can cancel exactly one reminder.
public struct BotApprovalScheduledNotification: Codable, Sendable, Equatable, Identifiable {
    public var identifier: String
    public var botID: String
    public var approvalID: String
    public var title: String
    public var body: String
    public var fireAt: Int64
    public var deepLink: String

    public var id: String { identifier }

    public init(identifier: String, botID: String, approvalID: String,
                title: String, body: String, fireAt: Int64, deepLink: String) {
        self.identifier = identifier
        self.botID = botID
        self.approvalID = approvalID
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.deepLink = deepLink
    }

    public static func identifier(botID: String, approvalID: String) -> String {
        "approval-pending:\(botID):\(approvalID)"
    }

    /// The stable row id `BotSessionLogProjection` assigns to the approval
    /// card, so the notification opens the exact card in the chat transcript.
    public static func rowID(botID: String, approvalID: String) -> String {
        "e-\(botID)-approval-\(approvalID)"
    }

    public static func deepLink(botID: String, approvalID: String) -> String {
        "phonedsh://bot/\(escape(botID))/row/\(escape(rowID(botID: botID, approvalID: approvalID)))"
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum BotApprovalNotificationPlanner {
    public static let identifierPrefix = "approval-pending:"
    /// Do not race the in-app card with a banner the user is already looking
    /// at. A user who backgrounds the App during the delay still gets the
    /// reminder; one who answers first cancels it.
    public static let defaultDelayMilliseconds: Int64 = 60_000
    /// iOS keeps at most 64 pending notifications per application. Leave room
    /// for routine due reminders and other system notifications.
    public static let maximumPendingNotifications = 48

    public static func notification(
        for record: BotApprovalNotificationRecord,
        now: Int64,
        delayMs: Int64 = BotApprovalNotificationPlanner.defaultDelayMilliseconds
    ) -> BotApprovalScheduledNotification {
        let action = record.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "有待办的审批"
        let body: String
        if action.isEmpty {
            body = "有一项操作在等你批准或拒绝。点开处理后，任务会继续或结束。"
        } else {
            body = "「\(String(action.prefix(80)))」在等你批准或拒绝。点开处理后，任务会继续或结束。"
        }
        return BotApprovalScheduledNotification(
            identifier: BotApprovalScheduledNotification.identifier(
                botID: record.botID, approvalID: record.approvalID),
            botID: record.botID, approvalID: record.approvalID,
            title: title, body: String(body.prefix(200)),
            fireAt: max(now, record.requestedAt) + max(0, delayMs),
            deepLink: BotApprovalScheduledNotification.deepLink(
                botID: record.botID, approvalID: record.approvalID))
    }

    public static func desired(
        records: [BotApprovalNotificationRecord],
        now: Int64,
        delayMs: Int64 = BotApprovalNotificationPlanner.defaultDelayMilliseconds
    ) -> [BotApprovalScheduledNotification] {
        records
            .map { notification(for: $0, now: now, delayMs: delayMs) }
            .sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
            .prefix(maximumPendingNotifications)
            .map { $0 }
    }
}

/// Host seam for the system notification center. Tests inject a fake; the
/// production implementation is `UNUserNotificationApprovalScheduling`.
public protocol BotApprovalNotificationScheduling: Sendable {
    func schedule(_ notification: BotApprovalScheduledNotification) async throws
    func pendingIdentifiers(prefix: String) async -> [String]
    func cancel(identifiers: [String]) async
}

#if canImport(UserNotifications)
import UserNotifications

public final class UNUserNotificationApprovalScheduling: BotApprovalNotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func schedule(_ notification: BotApprovalScheduledNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo["deepLink"] = notification.deepLink
        content.userInfo["botId"] = notification.botID
        content.userInfo["approvalID"] = notification.approvalID
        content.userInfo["notificationKind"] = "approval-pending"
        let seconds = max(1, Double(notification.fireAt - Int64(Date().timeIntervalSince1970 * 1_000)) / 1_000)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
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

/// Reconciles the system's pending approval reminders with the durable
/// approval set. A decision/expiry removes the reminder; a System purge or
/// process restart re-registers the still-pending ones.
public actor BotApprovalNotificationReconciler {
    private let scheduling: any BotApprovalNotificationScheduling
    private let now: @Sendable () -> Int64
    private let delayMs: Int64
    private var scheduled: [String: BotApprovalScheduledNotification] = [:]

    public init(scheduling: any BotApprovalNotificationScheduling,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                },
                delayMs: Int64 = BotApprovalNotificationPlanner.defaultDelayMilliseconds) {
        self.scheduling = scheduling
        self.now = now
        self.delayMs = max(0, delayMs)
    }

    @discardableResult
    public func sync(_ records: [BotApprovalNotificationRecord]) async -> Int {
        let desired = BotApprovalNotificationPlanner.desired(
            records: records, now: now(), delayMs: delayMs)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
        let prefix = BotApprovalNotificationPlanner.identifierPrefix
        let live = Set(await scheduling.pendingIdentifiers(prefix: prefix))
        let stale = live.union(scheduled.keys).subtracting(desiredByID.keys)
        if !stale.isEmpty {
            await scheduling.cancel(identifiers: Array(stale).sorted())
            for id in stale { scheduled.removeValue(forKey: id) }
        }
        var registered = 0
        for notification in desired {
            if live.contains(notification.identifier) || scheduled[notification.identifier] == notification {
                continue
            }
            do {
                try await scheduling.schedule(notification)
                scheduled[notification.identifier] = notification
                registered += 1
            } catch {
                scheduled.removeValue(forKey: notification.identifier)
            }
        }
        return registered
    }

    public func pendingSnapshot() -> [BotApprovalScheduledNotification] {
        scheduled.values.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
    }
}

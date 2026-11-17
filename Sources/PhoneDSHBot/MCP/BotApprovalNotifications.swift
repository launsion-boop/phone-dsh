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
    /// A device-app install card is a short, live request the Bot is blocked
    /// on (and the Worker call dies with the card). The user is likely on
    /// another screen, so remind much sooner than for a routine approval.
    public static let deviceAppInstallDelayMilliseconds: Int64 = 10_000
    /// `BotToolEffect.tool` / approval `action` of the device-app install card.
    public static let deviceAppInstallAction = "DeviceAppInstall"
    /// iOS keeps at most 64 pending notifications per application. Leave room
    /// for routine due reminders and other system notifications.
    public static let maximumPendingNotifications = 48

    /// The app title on a device-app install card: the `应用：<title>（…）`
    /// line of the effect detail (`DeviceAppToolEffects.installEffect`).
    static func deviceAppTitle(detail: String) -> String? {
        for line in detail.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("应用：") else { continue }
            var name = String(text.dropFirst("应用：".count))
            if let open = name.firstIndex(where: { $0 == "（" || $0 == "(" }) {
                name = String(name[..<open])
            }
            name = name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : String(name.prefix(40))
        }
        return nil
    }

    static func isDeviceAppInstall(_ record: BotApprovalNotificationRecord) -> Bool {
        record.action.trimmingCharacters(in: .whitespacesAndNewlines) == deviceAppInstallAction
    }

    /// `delayMs == nil` uses the per-approval default (10 s for a device-app
    /// install, 60 s otherwise); a value overrides every record.
    public static func notification(
        for record: BotApprovalNotificationRecord,
        now: Int64,
        delayMs: Int64? = nil
    ) -> BotApprovalScheduledNotification {
        let action = record.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let isInstall = isDeviceAppInstall(record)
        let delay = delayMs ?? (isInstall ? deviceAppInstallDelayMilliseconds : defaultDelayMilliseconds)
        var title = "有待办的审批"
        let body: String
        if isInstall {
            title = "有应用在等你确认"
            if let app = deviceAppTitle(detail: record.detail) {
                body = "「\(app)」在等你点「允许」，才会装到设备上"
            } else {
                body = "有一个应用在等你点「允许」，才会装到设备上"
            }
        } else if action.isEmpty {
            body = "有一项操作在等你批准或拒绝。点开处理后，任务会继续或结束。"
        } else {
            body = "「\(String(action.prefix(80)))」在等你批准或拒绝。点开处理后，任务会继续或结束。"
        }
        return BotApprovalScheduledNotification(
            identifier: BotApprovalScheduledNotification.identifier(
                botID: record.botID, approvalID: record.approvalID),
            botID: record.botID, approvalID: record.approvalID,
            title: title, body: String(body.prefix(200)),
            fireAt: max(now, record.requestedAt) + max(0, delay),
            deepLink: BotApprovalScheduledNotification.deepLink(
                botID: record.botID, approvalID: record.approvalID))
    }

    public static func desired(
        records: [BotApprovalNotificationRecord],
        now: Int64,
        delayMs: Int64? = nil
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

public enum BotNotificationAuthorizationState: Sendable, Equatable {
    case notDetermined, authorized, denied
}

/// Optional capability of a scheduling seam: ask the user for notification
/// permission. The reconciler asks at most once, at the first device-app
/// install approval, and never waits for the answer.
public protocol BotApprovalNotificationAuthorizing: Sendable {
    func authorizationState() async -> BotNotificationAuthorizationState
    func requestAuthorization() async
}

public enum BotApprovalNotificationPermission {
    /// Why the App asks. iOS' own dialog cannot carry custom text; hosts that
    /// can show a pre-prompt use this wording.
    public static let reason = "设备应用安装需要你点「允许」。打开通知后，你在别的页面也能收到提醒，不会错过确认。"
    public static let askedDefaultsKey = "pdsh.approvalNotificationPermissionAsked"
}

#if canImport(UserNotifications)
import UserNotifications

extension UNUserNotificationApprovalScheduling: BotApprovalNotificationAuthorizing {
    public func authorizationState() async -> BotNotificationAuthorizationState {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }
}

public final class UNUserNotificationApprovalScheduling: BotApprovalNotificationScheduling, @unchecked Sendable {
    fileprivate let center: UNUserNotificationCenter

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
    private let delayMs: Int64?
    private let askedDefaults: UserDefaults
    private var permissionAsked = false
    private var scheduled: [String: BotApprovalScheduledNotification] = [:]

    public init(scheduling: any BotApprovalNotificationScheduling,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                },
                delayMs: Int64? = nil,
                askedDefaults: UserDefaults = .standard) {
        self.scheduling = scheduling
        self.now = now
        self.delayMs = delayMs.map { max(0, $0) }
        self.askedDefaults = askedDefaults
    }

    /// Asks for notification permission once, the first time a device-app
    /// install approval is pending. Returns whether a request was made. Never
    /// throws and never repeats (also across launches): iOS shows its dialog
    /// once anyway, and a refusal must not stop the flow.
    @discardableResult
    func requestPermissionIfNeeded(for records: [BotApprovalNotificationRecord]) async -> Bool {
        guard !permissionAsked,
              records.contains(where: BotApprovalNotificationPlanner.isDeviceAppInstall),
              !askedDefaults.bool(forKey: BotApprovalNotificationPermission.askedDefaultsKey),
              let authorizing = scheduling as? any BotApprovalNotificationAuthorizing else { return false }
        permissionAsked = true
        askedDefaults.set(true, forKey: BotApprovalNotificationPermission.askedDefaultsKey)
        guard await authorizing.authorizationState() == .notDetermined else { return false }
        await authorizing.requestAuthorization()
        return true
    }

    @discardableResult
    public func sync(_ records: [BotApprovalNotificationRecord]) async -> Int {
        if !permissionAsked,
           records.contains(where: BotApprovalNotificationPlanner.isDeviceAppInstall) {
            // Detached: the system dialog waits for the user and must not hold
            // the runtime tick that calls `sync`.
            Task { [self] in await requestPermissionIfNeeded(for: records) }
        }
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

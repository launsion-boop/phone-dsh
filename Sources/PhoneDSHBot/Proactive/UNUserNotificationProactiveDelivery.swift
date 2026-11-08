// SPDX-License-Identifier: MIT

#if canImport(UserNotifications)
import Foundation
import UserNotifications

public protocol BotProactiveNotificationCenter: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: BotProactiveNotificationCenter {}

public enum BotProactiveNotificationError: Error, LocalizedError, Equatable {
    case missingDedupeKey
    case missingDeepLink

    public var errorDescription: String? {
        switch self {
        case .missingDedupeKey: return "proactive notification requires a stable dedupe key"
        case .missingDeepLink: return "proactive notification requires a row deep link"
        }
    }
}

public final class UNUserNotificationProactiveDelivery: ProactiveDelivering, @unchecked Sendable {
    private let center: any BotProactiveNotificationCenter

    public init(center: any BotProactiveNotificationCenter = UNUserNotificationCenter.current()) {
        self.center = center
    }

    public func deliver(_ notification: ProactiveNotification) async throws -> ProactiveDeliveryResult {
        guard !notification.dedupeKey.isEmpty else { throw BotProactiveNotificationError.missingDedupeKey }
        guard let deepLink = notification.deepLink, !deepLink.isEmpty else {
            throw BotProactiveNotificationError.missingDeepLink
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo["deepLink"] = deepLink
        content.userInfo["dedupeKey"] = notification.dedupeKey
        let request = UNNotificationRequest(identifier: notification.dedupeKey, content: content, trigger: nil)
        try await center.add(request)
        return ProactiveDeliveryResult(delivered: true, channel: notification.channel)
    }
}
#endif

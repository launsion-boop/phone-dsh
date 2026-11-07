// SPDX-License-Identifier: MIT

import Foundation
import UserNotifications

public struct BotUserNotification: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String
    public var deepLink: String

    public init(identifier: String, title: String, body: String, deepLink: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.deepLink = deepLink
    }
}

public protocol BotUserNotificationCenter: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: BotUserNotificationCenter {}

public protocol BotUserNotificationDelivering: Sendable {
    func deliver(_ notification: BotUserNotification) async throws -> String
}

public final class UNUserNotificationBotDelivery: BotUserNotificationDelivering, @unchecked Sendable {
    private let center: any BotUserNotificationCenter

    public init(center: any BotUserNotificationCenter = UNUserNotificationCenter.current()) {
        self.center = center
    }

    @discardableResult
    public func deliver(_ notification: BotUserNotification) async throws -> String {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo["deepLink"] = notification.deepLink
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try await center.add(request)
        return notification.identifier
    }

    public static func deepLink(from response: UNNotificationResponse) -> String? {
        response.notification.request.content.userInfo["deepLink"] as? String
    }
}

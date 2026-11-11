// SPDX-License-Identifier: MIT

import Foundation
import Observation
import UserNotifications

/// Delivers a tapped local notification's deep link into the App. The router
/// is installed at launch and only stores the URL; the native shell owns tab
/// switching and the Bot page owns presentation.
@MainActor
@Observable
final class BotNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BotNotificationRouter()

    private(set) var pendingDeepLink: URL?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = self
    }

    func takePendingDeepLink() -> URL? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let link = response.notification.request.content.userInfo["deepLink"] as? String
        if let link, let url = URL(string: link) {
            Task { @MainActor in
                BotNotificationRouter.shared.pendingDeepLink = url
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Routine due reminders and interrupt notifications are useful while
        // the App is open; leave the system sound choice to the content.
        completionHandler([.banner, .sound])
    }
}

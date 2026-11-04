// SPDX-License-Identifier: MIT

import ProbeKit
import UserNotifications

final class PersonalAgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: AppDeepLink.notificationName, object: url)
        }
    }
}

final class PersonalAgentNotificationSender: LocalNotificationSending {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func send(_ request: LocalNotificationRequest) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw PersonalAgentNotificationError.notAuthorized
        }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = ["deepLink": request.deepLink.absoluteString]
        if let verifiedAt = request.verifiedAt {
            content.userInfo["verifiedAt"] = verifiedAt.timeIntervalSince1970
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }
}

enum PersonalAgentNotificationError: Error {
    case notAuthorized
}

extension PersonalAgentNotificationError: LocalizedError {
    var errorDescription: String? { "尚未允许本地通知，未发送。" }
}

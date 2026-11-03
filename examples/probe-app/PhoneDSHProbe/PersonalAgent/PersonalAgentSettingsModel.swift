// SPDX-License-Identifier: MIT

import Foundation
import Observation
import UserNotifications

enum PersonalAgentNotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case unavailable

    var allowsNotifications: Bool {
        self == .authorized || self == .provisional
    }
}

protocol PersonalAgentNotificationCentering: Sendable {
    func authorization() async -> PersonalAgentNotificationAuthorization
    func requestAuthorization() async throws -> Bool
}

struct SystemPersonalAgentNotificationCenter: PersonalAgentNotificationCentering {
    func authorization() async -> PersonalAgentNotificationAuthorization {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

@MainActor
@Observable
final class PersonalAgentNotificationSettings {
    @ObservationIgnored private let center: any PersonalAgentNotificationCentering

    private(set) var authorization: PersonalAgentNotificationAuthorization = .notDetermined
    private(set) var isLoaded = false
    var requiresSystemSettings = false
    var errorMessage: String?

    var isEnabled: Bool { authorization.allowsNotifications }

    init(center: any PersonalAgentNotificationCentering = SystemPersonalAgentNotificationCenter()) {
        self.center = center
    }

    func refresh() async {
        authorization = await center.authorization()
        isLoaded = true
    }

    func setEnabled(_ enabled: Bool) async {
        errorMessage = nil
        requiresSystemSettings = false
        guard enabled else {
            await refresh()
            requiresSystemSettings = isEnabled
            return
        }
        do {
            _ = try await center.requestAuthorization()
            await refresh()
            requiresSystemSettings = !isEnabled
        } catch {
            await refresh()
            errorMessage = error.localizedDescription
        }
    }
}

enum PersonalAgentAutomationSummary {
    static func enabledCount(statuses: [String]) -> Int {
        statuses.filter { $0 == "active" }.count
    }
}

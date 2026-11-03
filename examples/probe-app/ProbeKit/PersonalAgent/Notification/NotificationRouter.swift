// SPDX-License-Identifier: MIT

import Foundation

public struct PersonalNotification: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let body: String
    public let route: AppRoute
    public let verifiedAt: Date?

    public init(id: UUID = UUID(), title: String, body: String, route: AppRoute, verifiedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.route = route
        self.verifiedAt = verifiedAt
    }
}

public struct LocalNotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let deepLink: URL
    public let verifiedAt: Date?

    public init(identifier: String, title: String, body: String, deepLink: URL, verifiedAt: Date?) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.deepLink = deepLink
        self.verifiedAt = verifiedAt
    }
}

public protocol LocalNotificationSending: Sendable {
    func send(_ request: LocalNotificationRequest) async throws
}

public struct RoutedPersonalNotification: Sendable, Equatable {
    public let notification: PersonalNotification
    public let request: LocalNotificationRequest
    public let sentAt: Date

    public init(notification: PersonalNotification, request: LocalNotificationRequest, sentAt: Date) {
        self.notification = notification
        self.request = request
        self.sentAt = sentAt
    }
}

public actor NotificationRouter: FollowUpNotificationDelivering {
    private let sender: any LocalNotificationSending
    public private(set) var sent: [RoutedPersonalNotification] = []

    public init(sender: any LocalNotificationSending) {
        self.sender = sender
    }

    public func deliver(_ notification: PersonalNotification) async throws {
        let request = LocalNotificationRequest(identifier: notification.id.uuidString,
                                               title: notification.title, body: notification.body,
                                               deepLink: Self.deepLink(for: notification.route),
                                               verifiedAt: notification.verifiedAt)
        try await sender.send(request)
        sent.append(RoutedPersonalNotification(notification: notification, request: request, sentAt: Date()))
    }

    public static func deepLink(for route: AppRoute) -> URL {
        let string: String
        switch route {
        case .chat(let focus):
            switch focus {
            case .followUp(let id): string = "phonedsh://chat/follow-up/\(id.uuidString)"
            case .operation(let id): string = "phonedsh://chat/operation/\(id.uuidString)"
            case .message(let id): string = "phonedsh://chat/message/\(id.uuidString)"
            case nil: string = "phonedsh://chat"
            }
        case .dsh(let sessionID, let approvalID):
            var components = URLComponents(string: "phonedsh://dsh")!
            components.queryItems = [sessionID.map { URLQueryItem(name: "session", value: $0) },
                                     approvalID.map { URLQueryItem(name: "approval", value: $0) }].compactMap { $0 }
            string = components.string!
        case .discover(let focus):
            switch focus {
            case .connector(let id): string = "phonedsh://discover/connector/\(id)"
            case .plugin(let id): string = "phonedsh://discover/plugin/\(id)"
            case .device(let id): string = "phonedsh://discover/device/\(id)"
            case nil: string = "phonedsh://discover"
            }
        case .profile(let focus):
            string = "phonedsh://profile/\(focus.map(Self.profilePath) ?? "")"
        }
        return URL(string: string)!
    }

    public static func route(forDeepLink url: URL) -> AppRoute? {
        guard url.scheme == "phonedsh", let host = url.host else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch host {
        case "chat":
            guard let first = parts.first else { return .chat(focus: nil) }
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            switch first {
            case "follow-up": return .chat(focus: .followUp(id))
            case "operation": return .chat(focus: .operation(id))
            case "message": return .chat(focus: .message(id))
            default: return nil
            }
        case "dsh":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return .dsh(sessionID: items.first(where: { $0.name == "session" })?.value,
                        approvalID: items.first(where: { $0.name == "approval" })?.value)
        case "discover":
            guard let first = parts.first else { return .discover(nil) }
            guard parts.count == 2 else { return nil }
            switch first {
            case "connector": return .discover(.connector(parts[1]))
            case "plugin": return .discover(.plugin(parts[1]))
            case "device": return .discover(.device(parts[1]))
            default: return nil
            }
        case "profile":
            guard let first = parts.first else { return .profile(nil) }
            switch first {
            case "memory": return .profile(.memory)
            case "model": return .profile(.model)
            case "permissions": return .profile(.permissions)
            case "privacy": return .profile(.privacy)
            case "engine": return .profile(.engine)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func profilePath(_ focus: ProfileFocus) -> String {
        switch focus {
        case .memory: return "memory"
        case .model: return "model"
        case .permissions: return "permissions"
        case .privacy: return "privacy"
        case .engine: return "engine"
        }
    }
}

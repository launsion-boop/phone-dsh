// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit

enum AppDeepLink {
    static let notificationName = Notification.Name("PhoneDSH.PersonalAgent.AppRoute")

    static func parse(_ url: URL) -> AppRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let hasPath = !components.path.isEmpty && components.path != "/"
        if hasPath, components.scheme?.lowercased() == "phonedsh",
           let route = NotificationRouter.route(forDeepLink: url) {
            return route
        }
        if hasPath, components.scheme?.lowercased() == "pdsh" {
            var normalized = components
            normalized.scheme = "phonedsh"
            if let url = normalized.url, let route = NotificationRouter.route(forDeepLink: url) { return route }
        }
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                uniquingKeysWith: { first, _ in first })
        switch components.host?.lowercased() ?? components.path.lowercased() {
        case "chat":
            if let raw = values["followUp"], let id = UUID(uuidString: raw) { return .chat(focus: .followUp(id)) }
            if let raw = values["operation"], let id = UUID(uuidString: raw) { return .chat(focus: .operation(id)) }
            if let raw = values["message"], let id = UUID(uuidString: raw) { return .chat(focus: .message(id)) }
            return .chat(focus: nil)
        case "dsh":
            return .dsh(sessionID: values["session"] ?? values["sessionID"], approvalID: values["approval"])
        case "discover":
            if let id = values["connector"] { return .discover(.connector(id)) }
            if let id = values["plugin"] { return .discover(.plugin(id)) }
            if let id = values["device"] { return .discover(.device(id)) }
            return .discover(nil)
        case "profile":
            switch values["focus"] {
            case "memory": return .profile(.memory)
            case "model": return .profile(.model)
            case "permissions": return .profile(.permissions)
            case "privacy": return .profile(.privacy)
            case "engine": return .profile(.engine)
            default: return .profile(nil)
            }
        default:
            return nil
        }
    }

    static func launchRoute(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppRoute? {
        guard let index = arguments.firstIndex(of: "-appRoute"), index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1]).flatMap(parse)
    }
}

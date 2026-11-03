// SPDX-License-Identifier: MIT

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chat, dsh, discover, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: NativeText("Chat", "Chat")
        case .dsh: "DSH"
        case .discover: NativeText("发现", "Discover")
        case .profile: NativeText("个人", "Profile")
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .dsh: "checklist"
        case .discover: "square.grid.2x2"
        case .profile: "person"
        }
    }

    var accessibilityIdentifier: String { "app.tab.\(rawValue)" }
}

enum AppShellMode: String, Sendable {
    case legacy, v4

    static var current: AppShellMode {
        resolve(arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment,
                defaults: .standard)
    }

    static func resolve(arguments: [String], environment: [String: String],
                        defaults: UserDefaults) -> AppShellMode {
        for (index, argument) in arguments.enumerated() {
            if argument == "-PDSH_SHELL", index + 1 < arguments.count,
               let mode = AppShellMode(rawValue: arguments[index + 1]) {
                return mode
            }
            for prefix in ["PDSH_SHELL=", "-PDSH_SHELL=", "--PDSH_SHELL="] {
                if argument.hasPrefix(prefix),
                   let mode = AppShellMode(rawValue: String(argument.dropFirst(prefix.count))) {
                    return mode
                }
            }
        }
        if let value = environment["PDSH_SHELL"], let mode = AppShellMode(rawValue: value) {
            return mode
        }
        if let value = defaults.string(forKey: "PDSH_SHELL"), let mode = AppShellMode(rawValue: value) {
            return mode
        }
        #if DEBUG
        return .v4
        #else
        return .legacy
        #endif
    }
}

enum AppDockMetrics {
    static let height: CGFloat = 64
    static let horizontalInset: CGFloat = 16
    static let groupSpacing: CGFloat = 12
    static let bottomSpacing: CGFloat = 12
    static var reservedHeight: CGFloat { height + bottomSpacing }
}

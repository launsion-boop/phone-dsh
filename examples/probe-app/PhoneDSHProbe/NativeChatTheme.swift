// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

// Native equivalents of the pinned DSH light/dark design tokens.
enum NativeChatTheme {
    static let primary = color(light: 0x111114, dark: 0xF4F4F5)
    static let secondary = color(light: 0x66666B, dark: 0xA1A1AA)
    static let tertiary = color(light: 0x9A9AA2, dark: 0x81858C)
    static let caption = color(light: 0xADB2B8, dark: 0x81858C)
    static let background = Color(.systemBackground)
    static let input = color(light: 0xFFFFFF, dark: 0x242426)
    static let selector = color(light: 0xF2F3F5, dark: 0x343437)
    static let code = color(light: 0xF6F6F8, dark: 0x1D1D20)
    static let codeBanner = color(light: 0xE9E9ED, dark: 0x2C2C30)
    static let inlineCode = color(light: 0xF0F0F3, dark: 0x303034)
    static let border = color(light: 0xE4E4E8, dark: 0x3A3A3E)
    static let borderLight = color(light: 0xEEEFF1, dark: 0x303034)
    static let accent = color(light: 0x3964FE, dark: 0x679EFE)
    static let success = color(light: 0x27865A, dark: 0x55B986)
    static let danger = color(light: 0xC0392B, dark: 0xF07568)
    static let warning = color(light: 0xB45309, dark: 0xE5A44E)

    static let bodySize: CGFloat = 14
    static let messageContentMargin: CGFloat = 20
    static let messageLineSpacing: CGFloat = 5
    static let messageParagraphSpacing: CGFloat = 20
    static let messageListSpacing: CGFloat = 10

    static func bodyFont() -> Font { .system(size: bodySize) }
    static func messageBodyFont() -> Font { NativeChatPreferences.shared.font(for: .text) }
    static func secondaryFont() -> Font { .system(size: 13) }
    static func captionFont() -> Font { .system(size: 12) }
    static func codeFont(size: CGFloat? = nil) -> Font {
        if let size { return .system(size: size, design: .monospaced) }
        return NativeChatPreferences.shared.font(for: .code)
    }
    static func terminalFont() -> Font { NativeChatPreferences.shared.font(for: .terminal) }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

struct NativeChatIcon: View {
    enum Name {
        case think, search, read, terminal, edit, code, sparkle
        case copy, check, close, chevronDown, branch, database, gauge
        case thumbsUp, thumbsDown, share, plus, shield

        var asset: String? {
            switch self {
            case .think: "DSHThink"
            case .copy: "DSHCopy"
            case .check: "DSHCheck"
            case .close: "DSHClose"
            case .chevronDown: "DSHChevronDown"
            case .search: "DSHSearch"
            case .read: "DSHRead"
            case .terminal: "DSHTerminal"
            case .edit: "DSHEdit"
            case .code: "DSHCode"
            case .sparkle: "DSHSparkle"
            case .branch: "DSHBranch"
            case .database: "DSHDatabase"
            case .gauge: "DSHGauge"
            default: nil
            }
        }

        var fallback: String {
            switch self {
            case .thumbsUp: "hand.thumbsup"
            case .thumbsDown: "hand.thumbsdown"
            case .share: "square.and.arrow.up"
            case .plus: "plus"
            case .shield: "lock.shield"
            default: "circle"
            }
        }
    }

    let name: Name
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let asset = name.asset {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
            } else {
                Image(systemName: name.fallback)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

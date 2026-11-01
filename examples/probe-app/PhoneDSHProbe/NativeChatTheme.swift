// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

// Native equivalents of the pinned DSH light/dark design tokens.
// NativeParityTokens is the source of truth; this facade keeps existing call
// sites compiling while the session page migrates to the official values.
enum NativeChatTheme {
    static let primary = NativeParityTokens.labelPrimary
    static let secondary = NativeParityTokens.labelSecondary
    static let tertiary = NativeParityTokens.labelTertiary
    static let caption = NativeParityTokens.labelCaption
    static let background = Color(.systemBackground)
    static let input = NativeParityTokens.input
    static let selector = NativeParityTokens.selector
    static let code = NativeParityTokens.codeBlock
    static let codeBanner = NativeParityTokens.codeBanner
    static let inlineCode = NativeParityTokens.inlineCode
    static let border = NativeParityTokens.borderL2
    static let borderLight = NativeParityTokens.borderL1
    static let accent = NativeParityTokens.accent
    static let success = NativeParityTokens.success
    static let danger = NativeParityTokens.error
    static let warning = NativeParityTokens.warning
    static let bubble = NativeParityTokens.userBubble
    static let planChipBG = NativeParityTokens.planChipBG
    static let planChipInk = NativeParityTokens.planChipInk
    static let deepDiving = NativeParityTokens.deepDiving

    static func bodyFont() -> Font { NativeChatPreferences.shared.font(for: .text) }
    static func messageBodyFont() -> Font { NativeChatPreferences.shared.font(for: .text) }
    static func secondaryFont() -> Font { .system(size: NativeParityTokens.secondarySize) }
    static func captionFont() -> Font { .system(size: NativeParityTokens.captionSize) }
    static func codeFont(size: CGFloat? = nil) -> Font {
        if let size { return .system(size: size, design: .monospaced) }
        return NativeChatPreferences.shared.font(for: .code)
    }
    static func terminalFont() -> Font { NativeChatPreferences.shared.font(for: .terminal) }

    static var bodyLineSpacing: CGFloat {
        let size = CGFloat(NativeChatPreferences.shared.textFontSize)
        return max(0, NativeParityTokens.bodyLineHeight - UIFont.systemFont(ofSize: size).lineHeight)
    }

    // PR11 phone typography: the message body uses an explicit paragraph,
    // list and line spacing instead of the web card's 24pt line box alone.
    static let messageContentMargin: CGFloat = 20
    static let messageParagraphSpacing: CGFloat = 20
    static let messageListSpacing: CGFloat = 10
    /// Keep the message body on the official 24pt line box at every preferred
    /// text size. A fixed 5pt is only right for the 17pt phone default; at the
    /// 402pt baseline (14pt) it leaves a 22pt line and tool rows drift.
    static var messageLineSpacing: CGFloat {
        let size = CGFloat(NativeChatPreferences.shared.textFontSize)
        return max(0, NativeParityTokens.bodyLineHeight - UIFont.systemFont(ofSize: size).lineHeight)
    }

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

// SPDX-License-Identifier: MIT
// NativeParityTokens: the official DSH session-line design values, resolved for
// a 402pt phone viewport. This is the single source of truth for the new
// parity views; `NativeChatTheme` delegates here so existing call sites keep
// compiling while the old ad-hoc values are retired.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2), CSS px == iOS pt
// at a 402pt viewport. Values come from the shipped web-app CSS; see
// docs/receipts/ios-session-audit/00-MASTER.md §6 and the axis reports.

import SwiftUI
import UIKit

enum NativeParityTokens {

    // MARK: - Semantic colors (light / dark)

    static let labelPrimary = color(light: 0x0F1115, dark: 0xF9FAFB)
    static let labelSecondary = color(light: 0x61666B, dark: 0xCFD3D6)
    static let labelTertiary = color(light: 0x81858C, dark: 0xADB2B8)
    static let labelCaption = color(light: 0xADB2B8, dark: 0x81858C)

    static let surface = color(light: 0xFFFFFF, dark: 0x151517)
    static let input = color(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let menu = color(light: 0xF8F9FA, dark: 0x303136)
    static let selector = color(light: 0xF5F6F7, dark: 0x353638)
    static let bubble = color(light: 0xEDF3FE, dark: 0x2C2C2E)
    static let menuSolid = color(light: 0xF8F9FA, dark: 0x303136)

    static let borderL1 = rgba(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let borderL2 = rgba(light: 0x000000, lightAlpha: 0.10, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let borderL3 = rgba(light: 0x000000, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.16)
    static let borderL4 = rgba(light: 0x000000, lightAlpha: 0.16, dark: 0xFFFFFF, darkAlpha: 0.20)

    static let codeBlock = color(light: 0xF9FAFB, dark: 0x1B1B1E)
    static let codeBanner = color(light: 0xF5F6F7, dark: 0x232325)
    static let inlineCode = color(light: 0xF5F6F7, dark: 0x2A2A2C)

    static let accent = color(light: 0x3964FE, dark: 0x679EFE)
    static let accentInfoFill = color(light: 0x3964FE, dark: 0x679EFE)
    static let error = color(light: 0xEC1313, dark: 0xF25A5A)
    static let success = color(light: 0x22C55E, dark: 0x22C55E)
    static let warning = color(light: 0xDD8629, dark: 0xDD8629)
    static let warningSurface = color(light: 0xFEF5E7, dark: 0x27241F)
    static let warningInk = color(light: 0xDD8629, dark: 0xF5B45A)
    static let turnTriggerBG = color(light: 0xF9FAFB, dark: 0x1B1B1E)
    static let planChipBG = color(light: 0xE4EDFD, dark: 0x34415B)
    static let planChipInk = color(light: 0x4176E6, dark: 0x7AAAFF)
    static let deepDiving = color(light: 0x345EBA, dark: 0x7D9ADE)
    static let userBubble = color(light: 0xEDF3FE, dark: 0x2C2C2E)

    // MARK: - Type scale

    static let bodySize: CGFloat = 14
    static let bodyLineHeight: CGFloat = 24
    static let secondarySize: CGFloat = 13
    static let secondaryLineHeight: CGFloat = 24
    static let captionSize: CGFloat = 12
    static let captionLineHeight: CGFloat = 18
    static let codeSize: CGFloat = 11
    static let codeLineHeight: CGFloat = 19
    static let chipSize: CGFloat = 13
    static let chipLineHeight: CGFloat = 20
    static let titleSize: CGFloat = 15
    static let headerTitleSize: CGFloat = 14
    static let headerTitleWeight: Font.Weight = .medium

    /// SwiftUI renders its own default leading, so the official line-height is
    /// expressed as the extra leading to add to `.system(size:)`.
    static var bodyLineSpacing: CGFloat {
        max(0, bodyLineHeight - UIFont.systemFont(ofSize: bodySize).lineHeight)
    }
    /// Official user bubble line-height is 22, not the body's 24.
    static var userBubbleLineSpacing: CGFloat {
        max(0, 22 - UIFont.systemFont(ofSize: bodySize).lineHeight)
    }
    /// `ui-mobile` forces a 16px composer font to prevent iOS focus zoom,
    /// while the card keeps the 24px line box.
    static let composerFontSize: CGFloat = 16
    static let composerLineHeight: CGFloat = 24
    static var composerLineSpacing: CGFloat {
        max(0, composerLineHeight - UIFont.systemFont(ofSize: composerFontSize).lineHeight)
    }
    static var secondaryLineSpacing: CGFloat {
        max(0, secondaryLineHeight - UIFont.systemFont(ofSize: secondarySize).lineHeight)
    }
    static var codeLineSpacing: CGFloat {
        max(0, codeLineHeight - UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular).lineHeight)
    }

    // MARK: - Layout (402pt)

    /// Transcript column: 402 - 2 * (composer clearance 16 + 16) = 338.
    static let contentWidth: CGFloat = 338
    /// Composer card: 402 - 2 * 16 = 370.
    static let composerWidth: CGFloat = 370
    static let composerHeight: CGFloat = 98
    static let userBubbleMaxWidth: CGFloat = 277
    static let headerHeight: CGFloat = 50
    static let turnProcessHeight: CGFloat = 33
    static let toolRowHeight: CGFloat = 24
    static let todoDockHeight: CGFloat = 36
    static let todoListMaxHeight: CGFloat = 180
    static let questionMaxHeight: CGFloat = 520
    static let questionOptionMinHeight: CGFloat = 40
    static let planCardHeight: CGFloat = 60
    static let subagentMenuWidth: CGFloat = 336

    // MARK: - Radii

    static let radiusXS: CGFloat = 4
    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 12
    static let radiusLG: CGFloat = 16
    static let radiusXL: CGFloat = 20
    static let radiusPanel: CGFloat = 28

    // MARK: - Spacing

    static let flowGap: CGFloat = 6
    static let responseGap: CGFloat = 12
    static let turnGap: CGFloat = 16
    static let transcriptSide: CGFloat = 32
    static let composerSide: CGFloat = 16

    // MARK: - Helpers

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
        })
    }

    static func rgba(light: UInt32, lightAlpha: CGFloat,
                     dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let value = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
        })
    }
}

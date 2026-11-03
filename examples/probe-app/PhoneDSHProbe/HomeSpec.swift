// SPDX-License-Identifier: MIT
// HomeSpec: the home (任务 tab) design values from
// docs/design/ios-home-design-spec.md, measured at 430×932pt. Margins stay
// fixed on other widths; the content column is the screen width minus 40.
// Light values only: the reference recording has no dark mode yet, so dark
// falls back to the existing parity palette where one exists.

import SwiftUI
import UIKit

enum HomeSpec {

    // MARK: - Grid

    /// Floating chrome (nav buttons, composer) sits 16pt from the screen edge.
    static let chromeInset: CGFloat = 16
    /// Reading content (messages, cards, tables) sits 20pt from the edge.
    static let contentInset: CGFloat = 20
    /// The nav row starts 8pt below the top safe area.
    static let navTop: CGFloat = 8
    /// Tab bar content height above the bottom safe area.
    static let tabBarHeight: CGFloat = 50

    // MARK: - Colors

    static let page = NativeParityTokens.color(light: 0xF7F7F7, dark: 0x101012)
    static let surface = NativeParityTokens.color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let userBubble = NativeParityTokens.color(light: 0xE8E8E8, dark: 0x2C2C2E)
    static let primaryButton = NativeParityTokens.color(light: 0x191919, dark: 0xF2F2F2)
    static let primaryButtonInk = NativeParityTokens.color(light: 0xFFFFFF, dark: 0x111111)
    static let textPrimary = NativeParityTokens.color(light: 0x1A1A1A, dark: 0xF2F2F2)
    static let textSecondary = NativeParityTokens.color(light: 0x555555, dark: 0xB8B8BD)
    static let textTertiary = NativeParityTokens.color(light: 0x717171, dark: 0x9C9CA2)
    static let textSubtle = NativeParityTokens.color(light: 0x7D7D7D, dark: 0x8E8E93)
    static let textPlaceholder = NativeParityTokens.color(light: 0x888888, dark: 0x7C7C82)
    static let inputPlaceholder = NativeParityTokens.color(light: 0x8B8B8B, dark: 0x7C7C82)
    static let iconMuted = NativeParityTokens.color(light: 0xA9A9A9, dark: 0x6C6C70)
    static let success = NativeParityTokens.color(light: 0x3DC979, dark: 0x3DC979)
    static let borderList = NativeParityTokens.color(light: 0xE2E2E2, dark: 0x2E2E32)

    // MARK: - Type (size / weight / line height)

    static let navTitleSize: CGFloat = 17.5
    static let navTitleLine: CGFloat = 22
    static let navSubtitleSize: CGFloat = 14.5
    static let navSubtitleLine: CGFloat = 20
    static let bodySize: CGFloat = 16
    static let bodyLine: CGFloat = 24
    static let processSize: CGFloat = 15
    static let listItemSize: CGFloat = 14
    static let listItemLine: CGFloat = 22
    static let tabLabelSize: CGFloat = 11

    // MARK: - Spacing

    /// Between transcript blocks (process rows, paragraphs, cards).
    static let blockGap: CGFloat = 20
    /// After a user bubble, and between paragraphs.
    static let paragraphGap: CGFloat = 16
    /// From a process row to the card it opens.
    static let disclosureGap: CGFloat = 8

    // MARK: - Sizes

    static let navButton: CGFloat = 44
    static let navPillWidth: CGFloat = 92
    static let navIcon: CGFloat = 22
    static let processRowHeight: CGFloat = 24
    static let processIcon: CGFloat = 18
    static let listRowHeight: CGFloat = 22
    static let composerOpenMinHeight: CGFloat = 104
    static let sendButton: CGFloat = 36
    static let composerIcon: CGFloat = 24
    static let tabIcon: CGFloat = 28

    // MARK: - Radii

    static let bubbleRadius: CGFloat = 24
    static let listCardRadius: CGFloat = 18
    static let composerOpenRadius: CGFloat = 24

    // MARK: - Helpers

    /// Extra leading that puts `size` text on a `lineHeight` line box.
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - UIFont.systemFont(ofSize: size).lineHeight)
    }

    /// The user bubble: 24pt corners with the top-trailing corner square,
    /// pointing at the speaker.
    static var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: bubbleRadius,
                               bottomLeadingRadius: bubbleRadius,
                               bottomTrailingRadius: bubbleRadius,
                               topTrailingRadius: 0,
                               style: .continuous)
    }
}

/// True for rows drawn inside a list card: they drop to the 14/22 list
/// style instead of the 15/24 process-row style.
private struct HomeListRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var homeListRow: Bool {
        get { self[HomeListRowKey.self] }
        set { self[HomeListRowKey.self] = newValue }
    }
}

extension View {
    /// Floating controls (nav buttons): black 5%, blur 10, y 2.
    func homeFloatingShadow() -> some View {
        shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }

    /// The composer card: black 8%, blur 16, y 4.
    func homeComposerShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }

    /// White list card behind an opened process group: 1pt #E2E2E2, r18,
    /// 8pt vertical and 12pt horizontal padding.
    func homeListCard() -> some View {
        environment(\.homeListRow, true)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeSpec.surface,
                        in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HomeSpec.listCardRadius, style: .continuous)
                .strokeBorder(HomeSpec.borderList, lineWidth: 1))
    }
}

/// UIKit chrome every pushed page and sheet shares, set once at launch so
/// secondary pages follow HomeSpec without each one restyling itself: the
/// #F7F7F7 page behind lists (rows stay white), a flat navigation bar with no
/// hairline and 17pt semibold #1A1A1A titles, and black segmented selection.
enum HomeAppearance {
    static func apply() {
        let page = dynamic(light: 0xF7F7F7, dark: 0x101012)
        let ink = dynamic(light: 0x1A1A1A, dark: 0xF2F2F2)
        let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)

        UITableView.appearance().backgroundColor = page
        UICollectionView.appearance().backgroundColor = page

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = page
        bar.shadowColor = .clear
        bar.titleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        bar.largeTitleTextAttributes = [
            .foregroundColor: ink,
            .font: UIFont.systemFont(ofSize: 30, weight: .bold),
        ]
        let navigation = UINavigationBar.appearance()
        navigation.standardAppearance = bar
        navigation.scrollEdgeAppearance = bar
        navigation.compactAppearance = bar
        navigation.tintColor = ink

        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = surface
        segmented.setTitleTextAttributes([.foregroundColor: ink], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: ink,
                                          .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
                                         for: .selected)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension View {
    /// Grouped settings-style list (or Form) on the HomeSpec page: white
    /// inset rows on #F7F7F7, 16pt body text, 48pt minimum rows, monochrome
    /// controls. Section headers and footers keep the system 13pt gray.
    func homeGroupedList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HomeSpec.page)
            .font(.system(size: HomeSpec.bodySize))
            .foregroundStyle(HomeSpec.textPrimary)
            .environment(\.defaultMinListRowHeight, 48)
            .tint(HomeSpec.textPrimary)
    }

    /// Sheets: grabber visible and the HomeSpec page behind the content.
    func homeSheetChrome() -> some View {
        presentationDragIndicator(.visible)
            .presentationBackground(HomeSpec.page)
    }
}

/// Black capsule for a page's one main action (启动引擎, 去配置…): 50pt tall,
/// 16pt semibold white label; dims when disabled.
struct HomePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
            .foregroundStyle(HomeSpec.primaryButtonInk)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(HomeSpec.primaryButton.opacity(isEnabled ? 1 : 0.25), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Small gray capsule tag (默认, 运行中…): 12pt medium on #E8E8E8.
struct HomeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HomeSpec.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(HomeSpec.userBubble, in: Capsule())
    }
}

/// Form row with the label on the left (16pt, fixed column) and the editor
/// filling the rest, the phone-settings layout for text fields.
struct HomeFieldRow<Field: View>: View {
    let title: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: HomeSpec.bodySize))
                .foregroundStyle(HomeSpec.textPrimary)
                .frame(width: 92, alignment: .leading)
            field()
                .font(.system(size: HomeSpec.bodySize))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


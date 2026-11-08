// SPDX-License-Identifier: MIT
// BotCardKit: the one card system every Bot card is built from, on the home
// design spec (HomeSpec). A card is a white r18 list card with a 1pt #E2E2E2
// edge and 16pt padding. Inside, text uses four sizes only:
//
//   eyebrow  13 medium  #888   what the card is (选择 · 进度 · 文档 …)
//   title    16 semibold #1A1A1A, 24 line
//   body     15 regular  #555, 22 line   summaries, help, details
//   row      15 regular  #1A1A1A, 22 line   list rows inside a card
//   meta     13 regular  #888, 18 line   counts, sites, sizes, times
//
// Rows are at least 44pt with 0.5pt hairlines between them; glyphs are 17pt
// in a 20pt column (or a 36pt gray tile for objects); buttons are 44pt
// capsules. Color is monochrome: green and red mark only success and failure.

import SwiftUI

enum BotCardMetrics {
    static let padding: CGFloat = 16
    static let radius: CGFloat = HomeSpec.listCardRadius
    static let rowMinHeight: CGFloat = 44
    static let glyphColumn: CGFloat = 20
    static let tile: CGFloat = 36
    static let buttonHeight: CGFloat = 44
    /// Eyebrow → title → body.
    static let headingGap: CGFloat = 4
    /// Between the heading and the card's content, and between blocks.
    static let blockGap: CGFloat = 12
}

extension View {
    func botCardEyebrow() -> some View {
        font(.system(size: 13, weight: .medium)).foregroundStyle(HomeSpec.textPlaceholder)
    }

    func botCardTitle() -> some View {
        font(.system(size: HomeSpec.bodySize, weight: .semibold))
            .lineSpacing(HomeSpec.lineSpacing(size: HomeSpec.bodySize, lineHeight: HomeSpec.bodyLine))
            .foregroundStyle(HomeSpec.textPrimary)
    }

    func botCardBody() -> some View {
        font(.system(size: HomeSpec.processSize))
            .lineSpacing(HomeSpec.lineSpacing(size: HomeSpec.processSize, lineHeight: 22))
            .foregroundStyle(HomeSpec.textSecondary)
    }

    func botCardRow(weight: Font.Weight = .regular) -> some View {
        font(.system(size: HomeSpec.processSize, weight: weight))
            .lineSpacing(HomeSpec.lineSpacing(size: HomeSpec.processSize, lineHeight: 22))
            .foregroundStyle(HomeSpec.textPrimary)
    }

    func botCardMeta() -> some View {
        font(.system(size: 13))
            .lineSpacing(HomeSpec.lineSpacing(size: 13, lineHeight: 18))
            .foregroundStyle(HomeSpec.textPlaceholder)
    }
}

/// The card surface: white, r18, 1pt #E2E2E2, 16pt padding, full column.
struct BotCardSurface<Content: View>: View {
    var padding: CGFloat = BotCardMetrics.padding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeSpec.surface,
                        in: RoundedRectangle(cornerRadius: BotCardMetrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BotCardMetrics.radius, style: .continuous)
                .strokeBorder(HomeSpec.borderList, lineWidth: 1))
    }
}

/// Card state, shown as a tag at the end of the eyebrow line.
enum BotCardTone {
    case neutral, success, danger, warning

    var ink: Color {
        switch self {
        case .neutral: HomeSpec.textPrimary
        case .success: HomeSpec.success
        case .danger: NativeParityTokens.error
        case .warning: NativeParityTokens.warning
        }
    }
}

/// The 20pt gray capsule tag (进行中 · 已完成 · 高风险 …); 12pt medium.
struct BotCardTag: View {
    let text: String
    var tone: BotCardTone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(tone == .neutral ? HomeSpec.userBubble : tone.ink.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

/// Eyebrow line (icon + kind, optional trailing tag or view), the title,
/// then the body text: the top of every card.
struct BotCardHeading<Trailing: View>: View {
    var icon: String
    var eyebrow: String
    var title: String?
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: BotCardMetrics.headingGap) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(eyebrow)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .botCardEyebrow()
            .frame(minHeight: 20)
            if let title, !title.isEmpty {
                Text(title)
                    .botCardTitle()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .botCardBody()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BotCardHeading where Trailing == EmptyView {
    init(icon: String, eyebrow: String, title: String? = nil, detail: String? = nil) {
        self.init(icon: icon, eyebrow: eyebrow, title: title, detail: detail) { EmptyView() }
    }
}

/// 0.5pt hairline between rows; `inset` lines it up with the row text.
struct BotCardDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(HomeSpec.borderList)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// A list row inside a card: optional 17pt glyph in a 20pt column, the
/// 15pt label (no line cap) with an optional 13pt detail, a trailing view.
struct BotCardRow<Leading: View, Trailing: View>: View {
    var label: String
    var detail: String?
    var labelInk: Color = HomeSpec.textPrimary
    var strikethrough = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .botCardRow()
                    .foregroundStyle(labelInk)
                    .strikethrough(strikethrough)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .botCardMeta()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: BotCardMetrics.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A 17pt glyph centered in the 20pt row column.
struct BotCardGlyph: View {
    let systemImage: String
    var ink: Color = HomeSpec.textSecondary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(ink)
            .frame(width: BotCardMetrics.glyphColumn)
            .accessibilityHidden(true)
    }
}

/// A 36pt gray tile with an 17pt glyph, for files, links and routines.
struct BotCardTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(width: BotCardMetrics.tile, height: BotCardMetrics.tile)
            .background(HomeSpec.userBubble.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Card buttons: 44pt capsules, 15pt semibold. Primary is black, secondary
/// gray, plain is a text button that keeps a 44pt target.
struct BotCardButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            configuration.label
                .font(.system(size: HomeSpec.processSize, weight: .semibold))
                .foregroundStyle(HomeSpec.primaryButtonInk)
                .frame(maxWidth: .infinity)
                .frame(height: BotCardMetrics.buttonHeight)
                .background(HomeSpec.primaryButton.opacity(isEnabled ? 1 : 0.25), in: Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
        case .secondary:
            configuration.label
                .font(.system(size: HomeSpec.processSize, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary.opacity(isEnabled ? 1 : 0.4))
                .frame(maxWidth: .infinity)
                .frame(height: BotCardMetrics.buttonHeight)
                .background(HomeSpec.userBubble, in: Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
        case .plain:
            configuration.label
                .font(.system(size: HomeSpec.processSize, weight: .medium))
                .foregroundStyle(HomeSpec.textPrimary.opacity(isEnabled ? 1 : 0.4))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.55 : 1)
        }
    }
}

/// A pressed row dims, like a tapped list cell.
struct BotCardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// 4pt progress track: #E8E8E8 behind the ink fill, percent on the right.
struct BotCardProgressBar: View {
    let percent: Int
    var ink: Color = HomeSpec.textPrimary

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(HomeSpec.userBubble)
                    Capsule().fill(ink)
                        .frame(width: geometry.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(height: 4)
            Text("\(percent)%")
                .botCardMeta()
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("完成进度 \(percent)%")
    }
}

/// One status vocabulary for steps and tasks.
enum BotCardStepState {
    case done, active, pending, failed, skipped

    init(_ raw: String) {
        switch raw {
        case "done", "completed", "complete", "success", "ok", "sent": self = .done
        case "active", "running", "in_progress", "working": self = .active
        case "failed", "error", "failure", "blocked": self = .failed
        case "skipped": self = .skipped
        default: self = .pending
        }
    }

    var glyph: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted.circle"
        case .pending: "circle"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    var ink: Color {
        switch self {
        case .done, .active: HomeSpec.textPrimary
        case .failed: NativeParityTokens.error
        case .pending, .skipped: HomeSpec.iconMuted
        }
    }
}

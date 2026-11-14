// SPDX-License-Identifier: MIT
// BotCardKit: the one card system every Bot card is built from, on the home
// design spec (HomeSpec). A card is a white r16 list card with a 1pt #E2E2E2
// edge and 12pt padding, capped at the Bot reply's 86% content width. Inside,
// text uses this compact scale only:
//
//   eyebrow  12 medium  #888   what the card is (选择 · 进度 · 文档 …)
//   title    15 semibold #1A1A1A, 22 line
//   body     14 regular  #555, 20 line   summaries, help, details
//   row      14 regular  #1A1A1A, 20 line   list rows inside a card
//   meta     12 regular  #888, 18 line   counts, sites, sizes, times
//
// Rows are at least 44pt with 0.5pt hairlines between them; glyphs are 17pt
// in a 20pt column (or a 40pt tinted tile for objects); buttons are 44pt.

import PhoneDSHBot
import SwiftUI
import UIKit

enum BotCardMetrics {
    // MARK: - Shared width

    /// Bot replies and cards both stop at this share of the transcript column.
    /// The column itself (and its 20pt inset) belongs to `BotChatPage`.
    static let contentWidthRatio: CGFloat = 0.86

    // MARK: - Card surface

    static let padding: CGFloat = 12
    static let radius: CGFloat = 16
    static let rowMinHeight: CGFloat = 44
    static let glyphColumn: CGFloat = 20
    static let tile: CGFloat = 32
    static let buttonHeight: CGFloat = 44
    /// Eyebrow → title → body.
    static let headingGap: CGFloat = 4
    /// Between the heading and the card's content, and between blocks.
    static let blockGap: CGFloat = 10

    // MARK: - Type (size / line height)

    static let titleSize: CGFloat = 15
    static let titleLine: CGFloat = 22
    static let bodySize: CGFloat = 14
    static let bodyLine: CGFloat = 20
    static let metaSize: CGFloat = 12
    static let metaLine: CGFloat = 18
}

/// Semantic card palette from the approved v07 preview. Dynamic colors keep
/// the same category separation in both appearances without borrowing any
/// external design-system tokens.
enum BotCardCategory {
    case choice, work, document, approval, notice

    var ink: Color {
        switch self {
        case .choice: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.58, green: 0.72, blue: 1, alpha: 1) : UIColor(red: 0.15, green: 0.37, blue: 0.81, alpha: 1) })
        case .work: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.55, green: 0.84, blue: 0.73, alpha: 1) : UIColor(red: 0.14, green: 0.48, blue: 0.39, alpha: 1) })
        case .document: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.79, green: 0.67, blue: 0.98, alpha: 1) : UIColor(red: 0.47, green: 0.31, blue: 0.74, alpha: 1) })
        case .approval: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.94, green: 0.76, blue: 0.48, alpha: 1) : UIColor(red: 0.58, green: 0.38, blue: 0.09, alpha: 1) })
        case .notice: HomeSpec.textSecondary
        }
    }

    var wash: Color { ink.opacity(0.09) }
}

extension View {
    func botCardEyebrow() -> some View {
        font(.system(size: BotCardMetrics.metaSize, weight: .medium))
            .foregroundStyle(HomeSpec.textPlaceholder)
    }

    func botCardTitle() -> some View {
        font(.system(size: BotCardMetrics.titleSize, weight: .semibold))
            .lineSpacing(HomeSpec.lineSpacing(size: BotCardMetrics.titleSize,
                                             lineHeight: BotCardMetrics.titleLine))
            .foregroundStyle(HomeSpec.textPrimary)
    }

    func botCardBody() -> some View {
        font(.system(size: BotCardMetrics.bodySize))
            .lineSpacing(HomeSpec.lineSpacing(size: BotCardMetrics.bodySize,
                                             lineHeight: BotCardMetrics.bodyLine))
            .foregroundStyle(HomeSpec.textSecondary)
    }

    func botCardRow(weight: Font.Weight = .regular) -> some View {
        font(.system(size: BotCardMetrics.bodySize, weight: weight))
            .lineSpacing(HomeSpec.lineSpacing(size: BotCardMetrics.bodySize,
                                             lineHeight: BotCardMetrics.bodyLine))
            .foregroundStyle(HomeSpec.textPrimary)
    }

    func botCardMeta() -> some View {
        font(.system(size: BotCardMetrics.metaSize))
            .lineSpacing(HomeSpec.lineSpacing(size: BotCardMetrics.metaSize,
                                             lineHeight: BotCardMetrics.metaLine))
            .foregroundStyle(HomeSpec.textPlaceholder)
    }
}

/// The shared width rule for the Bot's own content: reply text and every card
/// stop at 86% of the column, leading aligned, and stay content-sized when
/// narrower instead of filling the column.
struct BotContentWidth<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        BotAdaptiveBubbleLayout(ratio: BotCardMetrics.contentWidthRatio, trailing: false) {
            content
        }
    }
}

/// Shared by the Bot reply bubble, every card, and the user bubble (with its
/// own 0.80 cap): propose the capped width, then place the content-sized child
/// on the leading or trailing edge.
///
/// The layout is deliberately a pure function of the column **width**. The
/// keyboard and safe-area changes alter the available height, and forwarding
/// that height to the content made the child report a different natural height
/// between passes; the lazy transcript then kept re-measuring the same cards.
/// `BotAdaptiveBubbleGeometry` (PhoneDSHBot) owns the decision so the SwiftPM
/// tests can prove it.
struct BotAdaptiveBubbleLayout: Layout {
    /// The last content measurement, tagged with the parent width it was
    /// taken for. Placement reuses it only for the same width.
    ///
    /// Both dimensions are kept: a trailing bubble must start at
    /// `bounds.maxX - measuredWidth`. Using the ratio **cap** there left a
    /// short user message floating at the 20% mark (the 2026-11-13 field
    /// sample: a tapped 建议下一步 bubble sat left of the trailing edge while
    /// its right side stayed empty). The cap is a maximum, not the width.
    struct Cache: Equatable {
        var parentWidth: CGFloat = 0
        var contentSize: CGSize = .zero
        var measured = false
    }

    let ratio: CGFloat
    let trailing: Bool

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let width = proposal.width else {
            // No column width yet. Return the content's ideal size instead of
            // collapsing to zero: a 0 → content-height flip is another
            // needless placement pass. The bubble is exactly the ideal size,
            // so that is also the parent width placement will see.
            let ideal = child.sizeThatFits(.unspecified)
            cache = Cache(parentWidth: ideal.width, contentSize: ideal, measured: true)
            return BotAdaptiveBubbleGeometry.bubbleSize(availableWidth: ideal.width,
                                                        contentHeight: ideal.height)
        }
        let contentProposal = BotAdaptiveBubbleGeometry.contentProposal(
            availableWidth: width, availableHeight: proposal.height, ratio: ratio)
        let content = child.sizeThatFits(ProposedViewSize(width: contentProposal?.width,
                                                          height: contentProposal?.height))
        cache = Cache(parentWidth: width, contentSize: content, measured: true)
        return BotAdaptiveBubbleGeometry.bubbleSize(availableWidth: width,
                                                     contentHeight: content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        guard let child = subviews.first, bounds.width > 0 else { return }
        let placementWidth = BotAdaptiveBubbleGeometry.contentWidth(
            availableWidth: bounds.width, ratio: ratio) ?? bounds.width
        let contentSize: CGSize
        if cache.measured, abs(cache.parentWidth - bounds.width) <= 0.5 {
            contentSize = cache.contentSize
        } else {
            // The cache was measured for another width; measure once against
            // this one instead of trusting a stale height or width.
            let measured = child.sizeThatFits(ProposedViewSize(width: placementWidth, height: nil))
            contentSize = measured
            cache = Cache(parentWidth: bounds.width, contentSize: measured, measured: true)
        }
        // Trailing placement uses the measured width. A content-sized short
        // bubble then ends exactly on the trailing edge instead of starting at
        // the width cap's left edge. Placing with that same width keeps a
        // no-column-width measurement (which used the content's ideal size)
        // from being re-wrapped against a smaller cap.
        let x = BotAdaptiveBubbleGeometry.contentOriginX(
            bounds: bounds, contentWidth: contentSize.width, trailing: trailing)
        child.place(at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: contentSize.width, height: contentSize.height))
    }
}

/// A card surface: white, r16, 1pt #E2E2E2, 12pt padding. It takes the width
/// its content asks for; the parent `BotContentWidth` supplies the 86% cap.
struct BotCardSurface<Content: View>: View {
    var padding: CGFloat = BotCardMetrics.padding
    var category: BotCardCategory = .work
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(LinearGradient(colors: [category.wash.opacity(0.48), HomeSpec.surface],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: BotCardMetrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BotCardMetrics.radius, style: .continuous)
                .strokeBorder(category.ink.opacity(0.18), lineWidth: 1))
            .overlay(alignment: .top) {
                category.ink.frame(height: 3)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: BotCardMetrics.radius, style: .continuous))
    }
}

/// Card state, shown as a tag at the end of the eyebrow line.
enum BotCardTone {
    case neutral, success, danger, warning, choice

    var ink: Color {
        switch self {
        case .neutral: HomeSpec.textPrimary
        case .success: HomeSpec.success
        case .danger: NativeParityTokens.error
        case .warning: NativeParityTokens.warning
        case .choice: BotCardCategory.choice.ink
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
/// then the body text: the top of every card. Title and detail default to two
/// lines; longer text gets an explicit 展开/收起 control instead of stretching
/// the whole card.
struct BotCardHeading<Trailing: View>: View {
    var icon: String
    var eyebrow: String
    var title: String?
    var detail: String?
    var titleLineLimit: Int? = 2
    var detailLineLimit: Int? = 2
    var category: BotCardCategory = .work
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: BotCardMetrics.headingGap) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(category.ink)
                    .frame(width: 28, height: 28)
                    .background(category.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(eyebrow)
                    .foregroundStyle(category.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .font(.system(size: BotCardMetrics.metaSize, weight: .semibold))
            .frame(minHeight: 20)
            if let title, !title.isEmpty {
                overflowText(title, limit: titleLineLimit, style: .title)
            }
            if let detail, !detail.isEmpty {
                overflowText(detail, limit: detailLineLimit, style: .body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func overflowText(_ text: String, limit: Int?,
                              style: BotCardHeadingTextStyle) -> some View {
        if let limit, limit > 0 {
            BotCardExpandableText(text: text, style: style, lineLimit: limit)
        } else {
            style.apply(to: Text(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension BotCardHeading where Trailing == EmptyView {
    init(icon: String, eyebrow: String, title: String? = nil, detail: String? = nil) {
        self.init(icon: icon, eyebrow: eyebrow, title: title, detail: detail) { EmptyView() }
    }
}

private enum BotCardHeadingTextStyle {
    case title, body

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        switch self {
        case .title: content.botCardTitle()
        case .body: content.botCardBody()
        }
    }
}

private struct BotCardTextHeightsKey: PreferenceKey {
    static var defaultValue = BotCardTextHeights()
    static func reduce(value: inout BotCardTextHeights, nextValue: () -> BotCardTextHeights) {
        let next = nextValue()
        value.full = max(value.full, next.full)
        value.limited = max(value.limited, next.limited)
    }
}

/// Holds the in-flight heading measurement outside SwiftUI state.
/// `onPreferenceChange` runs inside the layout transaction; writing even a
/// task handle to `@State` there dirties the graph that is measuring the card
/// and can keep the lazy transcript placing subviews. Only this plain class is
/// mutated during the callback; the visible state is written by the deferred
/// task, after layout.
private final class BotCardTextMeasurementBox {
    private var measurement = BotCardTextMeasurement()
    private var task: Task<Void, Never>?

    func report(_ next: BotCardTextHeights,
                apply: @escaping (BotCardTextHeights) -> Void) {
        guard measurement.report(next) else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self,
                  let value = self.measurement.commit() else { return }
            apply(value)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Clamped title/detail text with a real truncation check: the hidden
/// full-height copy is measured against the clamped copy, so the control only
/// appears when the text actually exceeds its line limit.
private struct BotCardExpandableText: View {
    let text: String
    let style: BotCardHeadingTextStyle
    let lineLimit: Int
    @State private var expanded = false
    /// The visible result of the last committed measurement.
    @State private var showsExpansionControl = false
    @State private var measurement = BotCardTextMeasurementBox()

    private var canExpand: Bool { showsExpansionControl }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            style.apply(to: Text(text))
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(alignment: .topLeading) { fullHeightProbe }
                .background { limitedHeightProbe }
                .onPreferenceChange(BotCardTextHeightsKey.self) { next in
                    measurement.report(next) { heights in
                        let shows = heights.needsExpansionControl
                        if shows != showsExpansionControl { showsExpansionControl = shows }
                    }
                }
                .onDisappear { measurement.cancel() }
            if canExpand || expanded {
                Button(expanded ? "收起" : "展开") {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                }
                .font(.system(size: BotCardMetrics.metaSize, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .buttonStyle(.plain)
                .frame(minHeight: 28)
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("bot.card.heading.expand")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullHeightProbe: some View {
        style.apply(to: Text(text))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BotCardTextHeightsKey.self,
                                           value: BotCardTextHeights(full: proxy.size.height))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var limitedHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BotCardTextHeightsKey.self,
                                   value: BotCardTextHeights(limited: proxy.size.height))
        }
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
/// 14pt label (no line cap) with an optional 12pt detail, a trailing view.
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

/// The one grey line an interactive card settles into: a small tinted glyph,
/// the outcome, and its context after a dot, with no surface, border or
/// button, so handled cards recede behind the conversation. The model owns
/// all text and precedence; this view only draws it.
struct BotCardSettledLine: View {
    let settlement: BotCardSettlement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: settlement.glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(settlement.tone.ink.opacity(0.8))
                .accessibilityHidden(true)
            (Text(settlement.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(HomeSpec.textSecondary)
             + detailText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bot.card.settled")
    }

    private var detailText: Text {
        guard let detail = settlement.detail, !detail.isEmpty else { return Text("") }
        let body = Text(detail)
        return Text(" · ")
            .font(.system(size: 13))
            .foregroundColor(HomeSpec.textTertiary)
            + (settlement.monospacedDetail ? body.font(.system(size: 12, design: .monospaced))
                                           : body.font(.system(size: 13)))
            .foregroundColor(HomeSpec.textTertiary)
    }
}

extension BotCardSettlementTone {
    var ink: Color {
        switch self {
        case .neutral: HomeSpec.textSecondary
        case .success: HomeSpec.success
        }
    }
}

/// A 32pt gray tile with an 17pt glyph, for files, links and routines.
struct BotCardTile: View {
    let systemImage: String
    var category: BotCardCategory = .work

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(category.ink)
            .frame(width: BotCardMetrics.tile, height: BotCardMetrics.tile)
            .background(category.wash,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Fixed square document mark with a format label; its footprint never flexes
/// when a filename or neighboring text wraps.
struct BotCardFileTile: View {
    let fileName: String
    var mime: String?
    var category: BotCardCategory = .document
    @Environment(\.colorScheme) private var colorScheme

    private var format: String {
        let ext = ((fileName as NSString).pathExtension).uppercased()
        switch ext {
        case "PDF": return "PDF"
        case "MD", "MARKDOWN", "MDOWN": return "MD"
        case "HTML", "HTM": return "HTML"
        case "TXT", "TEXT", "LOG": return "TXT"
        case "DOC", "DOCX": return "DOCX"
        case "RTF": return "RTF"
        case "JSON", "JSONL": return "JSON"
        case "CSV", "TSV": return "CSV"
        default:
            if mime?.localizedCaseInsensitiveContains("pdf") == true { return "PDF" }
            if mime?.localizedCaseInsensitiveContains("markdown") == true { return "MD" }
            if mime?.localizedCaseInsensitiveContains("html") == true { return "HTML" }
            if mime?.hasPrefix("text/") == true { return "TXT" }
            return ext.isEmpty ? "FILE" : String(ext.prefix(4))
        }
    }

    private var formatInk: Color {
        let light: UIColor
        let dark: UIColor
        switch format {
        case "PDF": (light, dark) = (UIColor(red: 0.77, green: 0.29, blue: 0.27, alpha: 1), UIColor(red: 1, green: 0.55, blue: 0.51, alpha: 1))
        case "MD": (light, dark) = (UIColor(red: 0.47, green: 0.31, blue: 0.74, alpha: 1), UIColor(red: 0.79, green: 0.67, blue: 0.98, alpha: 1))
        case "HTML": (light, dark) = (UIColor(red: 0.72, green: 0.40, blue: 0.13, alpha: 1), UIColor(red: 1, green: 0.68, blue: 0.39, alpha: 1))
        case "TXT": (light, dark) = (UIColor(red: 0.29, green: 0.48, blue: 0.64, alpha: 1), UIColor(red: 0.57, green: 0.75, blue: 0.91, alpha: 1))
        case "DOCX": (light, dark) = (UIColor(red: 0.20, green: 0.40, blue: 0.74, alpha: 1), UIColor(red: 0.56, green: 0.72, blue: 1, alpha: 1))
        case "RTF": (light, dark) = (UIColor(red: 0.57, green: 0.38, blue: 0.66, alpha: 1), UIColor(red: 0.80, green: 0.65, blue: 0.89, alpha: 1))
        case "JSON": (light, dark) = (UIColor(red: 0.58, green: 0.45, blue: 0.15, alpha: 1), UIColor(red: 0.91, green: 0.76, blue: 0.40, alpha: 1))
        case "CSV": (light, dark) = (UIColor(red: 0.22, green: 0.49, blue: 0.36, alpha: 1), UIColor(red: 0.52, green: 0.78, blue: 0.63, alpha: 1))
        default: (light, dark) = (UIColor(red: 0.47, green: 0.31, blue: 0.74, alpha: 1), UIColor(red: 0.79, green: 0.67, blue: 0.98, alpha: 1))
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(category.wash)
            Image(systemName: "doc")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(formatInk)
                .offset(y: -4)
            Text(format)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(formatInk, in: Capsule())
                .offset(y: 3)
        }
        .frame(width: 44, height: 44)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Card buttons: 44pt capsules, 15pt semibold. Primary is black, secondary
/// gray, plain is a text button that keeps a 44pt target.
struct BotCardButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            configuration.label
                .font(.system(size: HomeSpec.processSize, weight: .semibold))
                .foregroundStyle(tint == nil ? HomeSpec.primaryButtonInk : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: BotCardMetrics.buttonHeight)
                .background((tint ?? HomeSpec.primaryButton).opacity(isEnabled ? 1 : 0.25), in: Capsule())
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

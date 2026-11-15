// SPDX-License-Identifier: MIT

import SwiftUI

/// The one activity surface in the Bot chat: a three-dot bubble at the
/// bottom-leading corner of the transcript. It carries the same sentence the
/// old line under the header showed, plus the silver glint.
///
/// Visibility is not owned here. `BotChatPage` reads its single
/// `BotHeaderPresence` and mounts this view only when
/// `presence.showsActivityBubble`; the page also reserves this view's `height`
/// band at all times, so a turn starting, settling or changing phase never
/// moves a message, the transcript viewport or the composer. The band never
/// takes hit tests.
///
/// Style: the Bot answer bubble's surface/border/shape and 12pt inset, three
/// 6pt `textSecondary` dots with the 1.2s staggered pulse, then the one-line
/// 13pt medium activity sentence (silver, or the danger tint for a failure)
/// with the same moving-highlight mask as `BotActivityLine`.
///
/// Sizing: the surface hugs the sentence and stops at `maxWidth` (the page
/// passes 86% of the transcript column); the tail truncates. The height is a
/// constant 32, inside the 30–34 band, so a longer activity can only change
/// width. The glint animates a mask offset only; dot motion only changes
/// opacity/scale, so neither can resize the bubble or the reserved band.
struct BotActivityBubble: View {
    /// Reserved band height, visible or not: 13pt text (18pt line box) plus
    /// 7pt vertical inset each side = 32, inside the 30–34 band.
    static let height: CGFloat = 32
    /// Same width cap as Bot replies and cards (86% of the transcript column).
    static let maxWidthRatio = BotCardMetrics.contentWidthRatio
    /// The bubble is only mounted with a line, but an empty resolved sentence
    /// still says what the three dots mean.
    static let fallbackText = "正在回复"

    /// The lifecycle's sentence, exactly what `BotHeaderPresence.line` carries.
    let activity: BotActivity
    /// Waiting for the user or reporting a failure: no glint.
    var quiet = false
    /// A failure: danger tint.
    var problem = false
    /// Width cap from the page; `.infinity` (unmeasured) leaves the sentence
    /// uncapped.
    var maxWidth: CGFloat = .infinity

    var body: some View {
        BotActivityText(activity: activity) { resolved in
            let text = resolved.isEmpty ? Self.fallbackText : resolved
            HStack(spacing: 8) {
                BotActivityDots()
                // The sentence, not the bubble, is the 13pt silver text: the
                // shimmer mask is built from this text's own bounds.
                BotActivityShimmerText(
                    text: text,
                    quiet: quiet || problem,
                    ink: problem ? BotUIPalette.danger : BotActivityShimmerText.silver,
                    fillsWidth: false,
                    animatesSwap: false)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
            .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList,
                                                         lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("bot.activity.bubble")
            // The cap comes after the surface: this flexible wrapper only
            // narrows the sentence's proposed width, so the visible bubble
            // still hugs short text instead of filling the 86% column.
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }
}

/// Three 6pt dots on the required 1.2s staggered loop. Motion touches no
/// layout: only opacity/scale animate, the frames stay constant. Reduce Motion
/// keeps the dots static (no pulse, no scale).
private struct BotActivityDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private static let dotSize: CGFloat = 6
    private static let gap: CGFloat = 5
    /// 0.6s each way with `autoreverses` = the required 1.2s loop.
    private static let pulseHalf: Double = 0.6
    /// 0.18s between neighbours, so all three are out of phase in one loop.
    private static let stagger: Double = 0.18

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                dot(index)
            }
        }
        .accessibilityHidden(true)
        .onAppear { restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
    }

    private func dot(_ index: Int) -> some View {
        let paused = reduceMotion
        return Circle()
            .fill(HomeSpec.textSecondary)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .opacity(paused ? 0.55 : (pulsing ? 1 : 0.32))
            .scaleEffect(paused ? 1 : (pulsing ? 1 : 0.82))
            .animation(paused ? nil
                       : .easeInOut(duration: Self.pulseHalf)
                           .repeatForever(autoreverses: true)
                           .delay(Double(index) * Self.stagger),
                       value: pulsing)
    }

    /// Reset without animation, then start the loop only when motion is
    /// allowed. The per-dot `.animation` above carries the stagger.
    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { pulsing = false }
        guard !reduceMotion else { return }
        pulsing = true
    }
}

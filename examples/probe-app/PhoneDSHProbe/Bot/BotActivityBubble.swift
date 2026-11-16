// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// The one activity surface in the Bot chat: a compact bubble at the
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
/// Style: the existing Bot surface, border and shape around a readable
/// 16pt medium sentence. A quiet highlight keeps the base text fully legible.
///
/// Sizing: the surface hugs the sentence and stops at `maxWidth` (the page
/// passes 94% of the transcript column); the tail truncates. The height is a
/// constant for the current Dynamic Type setting, so a longer activity can
/// only change width. Text swaps never contribute a second intrinsic width.
struct BotActivityBubble: View {
    static let height: CGFloat = 38
    static let lineHeight: CGFloat = 22
    static let fontSize: CGFloat = 16
    /// Room for a normal 10–20-character task sentence at the larger type size.
    static let maxWidthRatio: CGFloat = 0.94
    static func bandHeight(forLineHeight value: CGFloat) -> CGFloat {
        max(height, value + 16)
    }
    /// The lifecycle's sentence, exactly what `BotHeaderPresence.line` carries.
    let activity: BotActivity
    /// Waiting for the user or reporting a failure: no glint.
    var quiet = false
    /// A failure: danger tint.
    var problem = false
    /// Width cap from the page; `.infinity` (unmeasured) leaves the sentence
    /// uncapped.
    var maxWidth: CGFloat = .infinity

    @ScaledMetric(relativeTo: .callout) private var scaledFontSize = BotActivityBubble.fontSize
    @ScaledMetric(relativeTo: .callout) private var scaledLineHeight = BotActivityBubble.lineHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.botActivityPrefersCrossFade) private var crossFadeOverride

    private var dotSize: CGFloat { max(5, scaledFontSize * 0.3125) }
    private var dotWidth: CGFloat { dotSize * 4.6 }
    private var animated: Bool { !reduceMotion && pageActive && !quiet && !problem }
    private var animatesGeometry: Bool {
        animated && !(crossFadeOverride ?? UIAccessibility.prefersCrossFadeTransitions)
    }

    var body: some View {
        BotActivityText(activity: activity, urgent: quiet || problem) { text, presented in
            // Use the state the timing machine is actually showing, not a
            // newer incoming state still waiting in its 800ms window.
            let dots = !problem && (text.isEmpty || presented?.category == .thinking
                                    || presented?.category == .replying)
            let label = dots
                ? (presented?.category == .replying ? "Bot 正在生成答复" : "等待 Bot 回应")
                : text
            measurement(text: text, dots: dots)
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    if dots {
                        BotActivityDots(diameter: dotSize, height: scaledLineHeight,
                                        animated: animated)
                            .transition(animated ? .opacity : .identity)
                    } else {
                        BotActivityShimmerText(
                            text: text, quiet: quiet || problem,
                            ink: problem ? BotActivityShimmerText.failureInk : BotActivityShimmerText.silver,
                            fillsWidth: false, animatesSwap: true,
                            height: scaledLineHeight, fontSize: scaledFontSize)
                            .transition(animated ? .opacity : .identity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(animated ? .easeOut(duration: 0.22) : nil,
                           value: dots ? "dots" : text)
            }
            .clipped()
            .padding(.horizontal, 12)
            .frame(height: Self.bandHeight(forLineHeight: scaledLineHeight))
            .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
            .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList,
                                                         lineWidth: 0.5))
            .accessibilityHidden(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("bot.activity.bubble")
            // The cap comes after the surface: this flexible wrapper only
            // narrows the sentence's proposed width, so the visible bubble
            // still hugs short text instead of filling the 94% column.
            .frame(maxWidth: maxWidth, alignment: .leading)
            .animation(animatesGeometry ? .easeOut(duration: 0.22) : nil,
                       value: dots ? "dots" : text)
        }
    }

    /// Only current content measures the surface. Removed text cannot hold
    /// the previous width while a small dots bubble is fading in.
    @ViewBuilder private func measurement(text: String, dots: Bool) -> some View {
        if dots {
            Color.clear.frame(width: dotWidth, height: scaledLineHeight)
        } else {
            Text(text)
                .font(.system(size: scaledFontSize,
                              weight: legibilityWeight == .bold ? .bold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .hidden()
                .frame(height: scaledLineHeight)
        }
    }
}

/// A local visual cue for waiting/replying, never a transcript message or
/// model-generated placeholder. Its fixed geometry cannot move the band.
private struct BotActivityDots: View {
    let diameter: CGFloat
    let height: CGFloat
    let animated: Bool
    @Environment(\.botActivityPrefersCrossFade) private var crossFadeOverride

    var body: some View {
        let crossFade = crossFadeOverride ?? UIAccessibility.prefersCrossFadeTransitions
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.25
            HStack(spacing: diameter * 0.8) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = animated ? max(0, sin(phase - Double(index) * 0.65)) : 0
                    Circle()
                        .fill(BotActivityShimmerText.silver)
                        .frame(width: diameter, height: diameter)
                        .opacity(animated ? 0.75 + 0.25 * pulse : 1)
                        .offset(y: animated && !crossFade
                                ? -CGFloat(pulse) * min(2, diameter * 0.4) : 0)
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

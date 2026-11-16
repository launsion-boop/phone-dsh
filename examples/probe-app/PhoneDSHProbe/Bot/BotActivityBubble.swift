// SPDX-License-Identifier: MIT

import SwiftUI

/// The one activity surface in the Bot chat: a compact bubble at the
/// bottom-leading corner of the transcript. It carries the same sentence the
/// old line under the header showed, plus the silver glint.
///
/// Visibility is not owned here. `BotChatPage` reads its single
/// `BotHeaderPresence` and mounts this view only when
/// `presence.showsActivityBubble`; the page also reserves this view's `height`
/// band at all times, so a turn starting, settling or changing phase never
/// moves a message, the transcript viewport or the composer. So that a long
/// sentence stays readable, only the bubble's own frame is tappable; the
/// reserved band around it is hit-transparent like before.
///
/// Style: the Bot answer bubble's surface/border/shape and 12pt inset around
/// the one-line 13pt medium activity sentence (silver, or the danger tint for
/// a failure) with the same moving-highlight mask as `BotActivityLine`. The
/// sentence's own silver sweep is the only activity cue; there are no dots.
///
/// Sizing: the surface hugs the sentence and stops at `maxWidth` (the page
/// passes 86% of the transcript column); the tail truncates. The height is a
/// constant 32, inside the 30–34 band, so a longer activity can only change
/// width. The glint animates a mask offset only, so it cannot resize the
/// bubble or the reserved band. Truncation is visual only: the accessibility
/// label keeps the whole sentence, and a tap opens the same resolved sentence
/// in a selectable, scrollable sheet so paths, URLs and `#174` stay readable.
struct BotActivityBubble: View {
    /// Reserved band height, visible or not: 13pt text (18pt line box) plus
    /// 7pt vertical inset each side = 32, inside the 30–34 band.
    static let height: CGFloat = 32
    /// Same width cap as Bot replies and cards (86% of the transcript column).
    static let maxWidthRatio = BotCardMetrics.contentWidthRatio
    /// The bubble is only mounted with a line, but an empty resolved sentence
    /// still says what the activity means.
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
    /// The resolved sentence captured at tap time; `nil` closes the sheet.
    @State private var fullText: String?

    init(activity: BotActivity, quiet: Bool = false, problem: Bool = false,
         maxWidth: CGFloat = .infinity) {
        self.activity = activity
        self.quiet = quiet
        self.problem = problem
        self.maxWidth = maxWidth
    }

    var body: some View {
        BotActivityText(activity: activity) { resolved in
            let text = resolved.isEmpty ? Self.fallbackText : resolved
            // The sentence, not the bubble, is the 13pt silver text: the
            // shimmer mask is built from this text's own bounds. No dots: the
            // moving highlight itself is the activity cue.
            BotActivityShimmerText(
                text: text,
                quiet: quiet || problem,
                ink: problem ? BotUIPalette.danger : BotActivityShimmerText.silver,
                fillsWidth: false,
                animatesSwap: false)
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
            .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList,
                                                         lineWidth: 0.5))
            // The surface itself is the whole tap target; the flexible frame
            // below stays layout-only and does not take hits.
            .contentShape(HomeSpec.botBubbleShape)
            .onTapGesture { fullText = text }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityHint("查看完整进展")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("bot.activity.bubble")
            // The cap comes after the surface: this flexible wrapper only
            // narrows the sentence's proposed width, so the visible bubble
            // still hugs short text instead of filling the 86% column.
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { fullText != nil },
                                    set: { if !$0 { fullText = nil } })) {
            BotActivityFullTextView(text: fullText ?? "")
        }
    }
}

/// The readable form of a visually truncated activity sentence. It is a
/// separate surface on purpose: the bubble keeps its fixed 32pt band and the
/// transcript/composer never re-layout because this sheet opened.
private struct BotActivityFullTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityIdentifier("bot.activity.fullText")
            }
            .navigationTitle("完整进展")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("bot.activity.fullText.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

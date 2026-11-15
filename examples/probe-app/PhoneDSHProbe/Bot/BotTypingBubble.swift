// SPDX-License-Identifier: MIT

import SwiftUI

/// The Bot's three-dot "typing" bubble at the bottom-leading corner of the
/// transcript: the echo of the one activity line under the header.
///
/// Visibility is not owned here. `BotChatPage` reads its single
/// `BotHeaderPresence` and mounts this view only for
/// `presence.showsTypingBubble`, the same lifecycle that decides whether the
/// activity line is drawn. The page also reserves this view's `height` band at
/// all times, so a turn starting or settling never moves a message, the
/// transcript viewport or the composer; the band never takes hit tests.
///
/// Style: the Bot answer bubble's surface/border/shape and 12pt inset, three
/// 6pt `textSecondary` dots with a staggered opacity+scale pulse on a 1.2s
/// loop. Reduced motion keeps the dots static (no pulse, no scale).
struct BotTypingBubble: View {
    /// Reserved band height, visible or not. Dot 6 + 12pt vertical inset each
    /// side = 30.
    static let height: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 5
    /// 0.6s each way with `autoreverses` = the required 1.2s loop.
    private static let pulseHalf: Double = 0.6
    /// 0.18s between neighbours, so all three are out of phase in one loop.
    private static let stagger: Double = 0.18

    var body: some View {
        HStack(spacing: Self.dotGap) {
            ForEach(0..<3, id: \.self) { index in
                dot(index)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
        .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在回复")
        .accessibilityIdentifier("bot.typing.bubble")
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

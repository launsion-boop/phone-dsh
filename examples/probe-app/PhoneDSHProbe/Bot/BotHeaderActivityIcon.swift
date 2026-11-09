// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// The 14pt activity mark inside the centered Bot header capsule. It mirrors
/// dsh-bot's header `AgentActivity`:
/// - thinking / streaming before any body: three dots breathing in sequence
///   (1.2s, opacity .35→1→.35, 0.2s apart);
/// - tool-running: a pencil breathing .72↔1 over 1.4s;
/// - pending approval: a red `!`;
/// - idle: the caller renders nothing.
/// Reduce Motion freezes every variant at full opacity.
struct BotHeaderActivityIcon: View {
    enum Style {
        case dots
        case pencil
        case alert
    }

    let style: Style

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive

    private let side: CGFloat = 14

    var body: some View {
        Group {
            switch style {
            case .alert:
                Text("!")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NativeParityTokens.error)
            case .dots:
                if reduceMotion || !pageActive {
                    dots(at: 0, animated: false)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        dots(at: timeline.date.timeIntervalSinceReferenceDate, animated: true)
                    }
                }
            case .pencil:
                if reduceMotion || !pageActive {
                    pencil(opacity: 1)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        pencil(opacity: pencilOpacity(at: timeline.date.timeIntervalSinceReferenceDate))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func dots(at time: TimeInterval, animated: Bool) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(HomeSpec.textSecondary)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(animated ? dotOpacity(index, at: time) : 1)
            }
        }
    }

    private func pencil(opacity: Double) -> some View {
        Image(systemName: "pencil")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HomeSpec.textSecondary)
            .opacity(opacity)
    }

    /// One 1.2s breath; neighbouring dots start 0.2s later. The cosine keeps
    /// the endpoints at .35 (not a linear sawtooth).
    private func dotOpacity(_ index: Int, at time: TimeInterval) -> Double {
        let period = 1.2
        var phase = ((time - Double(index) * 0.2).truncatingRemainder(dividingBy: period)) / period
        if phase < 0 { phase += 1 }
        return 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * Double.pi))
    }

    private func pencilOpacity(at time: TimeInterval) -> Double {
        let period = 1.4
        var phase = time.truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        return 0.72 + 0.28 * (0.5 - 0.5 * cos(phase * 2 * Double.pi))
    }
}

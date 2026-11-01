// SPDX-License-Identifier: MIT
// NativeRunningStatus: the transcript-level running clock — 14×14 mark +
// shimmering `深度求索中，用时 …` in the official deep-diving blue, optionally
// preceded by the 0.5pt divider.
//
// Official baseline: deepseek-harness 7be5505b0b, `RunningStatus.tsx`,
// `RunningWhaleTail.tsx`, `ChatView.module.css` (`.running*`),
// `locale.ts` (`chat.deepDiving*`). Contract:
// docs/receipts/ios-session-audit/05-timeline.md §2.5 (T-03).
// 402pt values: 12/22 text, `rgb(52,94,186)` (`NativeParityTokens.deepDiving`),
// 14×14 mark, 6pt gap, divider 0.5pt with 8pt top / 10pt bottom margins.

import Foundation
import SwiftUI

// MARK: - Local shimmer

/// SwiftUI stand-in for the official `TextShimmer` (a highlight band swept
/// across the glyphs). Parameters mirrored: 1.5s linear sweep, 105° band with
/// 40%–60% stops, highlight `rgba(0,0,0,0.3)` light / `rgba(255,255,255,0.45)`
/// dark. The official `steps(48, end)` easing, one-shot 0.3s delay and
/// animation-fill keyframes are not reproduced (tracked as T-13); reduced
/// motion removes the sweep entirely, as official `.decoration` does.
///
/// Shared by `NativeRunningStatus` and `NativeProcessGroupHeader`.
struct NativeTurnShimmerText: View {
    let text: String
    var active: Bool
    var font: Font = .system(size: NativeParityTokens.bodySize)
    var color: Color = NativeParityTokens.labelTertiary
    /// Optional fixed line box, so a row can reproduce an official line-height
    /// without depending on UIKit font metrics.
    var lineHeight: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    /// Official `--dsw-alias-label-shimmer`.
    private static let highlight = NativeParityTokens.rgba(
        light: 0x000000, lightAlpha: 0.30,
        dark: 0xFFFFFF, darkAlpha: 0.45)

    private var isAnimating: Bool { active && !reduceMotion }

    var body: some View {
        ZStack(alignment: .leading) {
            label
                .foregroundStyle(color)
            if isAnimating {
                label
                    .foregroundStyle(Self.highlight)
                    .mask { sweep }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: lineHeight, alignment: .leading)
        .onAppear { restart() }
        .onChange(of: active) { _, _ in restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// A full-width gradient whose 40–60% band is translated across the text.
    private var sweep: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.4),
                    .init(color: .black, location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing)
            .frame(width: proxy.size.width)
            .offset(x: phase * proxy.size.width)
        }
    }

    private func restart() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { phase = -1 }
        guard isAnimating else { return }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

// MARK: - Running status

/// The session-level running row. Mount it only while the session is running;
/// the caller owns the 12pt flow gap above it.
struct NativeRunningStatus: View {
    /// `turn/start.time` for the open Turn; `nil` before that event arrives.
    var startedAt: Date?
    /// Official `.runningDivider` shows only when the previous visible row is
    /// not `user` / `steering` / `turn-trigger`; the caller decides and passes
    /// the result (do not draw a divider between an input and the status).
    var showsDivider: Bool = true
    /// Fixed clock for previews and tests. `nil` ticks every second.
    var fixedNow: Date?

    /// Official copy (`locale.ts:89-90`).
    static let deepDivingLabel = "深度求索中"
    static let deepDivingForPrefix = "深度求索中，用时 "
    /// A leading space then three U+00B7 middle dots — not an ellipsis.
    static let deepDivingForSuffix = " \u{00B7}\u{00B7}\u{00B7}"

    @State private var scheduleStart = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                divider
            }
            if let fixedNow = fixedNow {
                statusRow(now: fixedNow)
            } else {
                TimelineView(.periodic(from: scheduleStart, by: 1)) { context in
                    statusRow(now: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A constant label: VoiceOver announces the state, never the ticking
        // duration (official role=status only carries `chat.deepDiving`).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.deepDivingLabel)
    }

    /// The official label for a given clock. `formatRunDuration` floors the
    /// elapsed time at one second, so the first second already reads `1秒`.
    static func label(startedAt: Date?, now: Date) -> String {
        guard let startedAt = startedAt else { return deepDivingLabel }
        let elapsed = now.timeIntervalSince(startedAt)
        return deepDivingForPrefix + NativeRunDuration.string(elapsed: elapsed) + deepDivingForSuffix
    }

    private func statusRow(now: Date) -> some View {
        HStack(alignment: .center, spacing: 6) {
            whale
            NativeTurnShimmerText(
                text: Self.label(startedAt: startedAt, now: now),
                active: true,
                font: .system(size: NativeParityTokens.captionSize).monospacedDigit(),
                color: NativeParityTokens.deepDiving,
                lineHeight: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Approximation: the official mark is the custom 14×14 whale-tail path
    /// (`RunningWhaleTail.tsx` / `running-whale@2x.png`). SF Symbols has no
    /// whale glyph, so `fish` stands in at the same 14×14 box, tinted with the
    /// row's deep-diving color; it is static because the SF glyph cannot be
    /// masked into the official animated asset.
    private var whale: some View {
        Image(systemName: "fish")
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundStyle(NativeParityTokens.deepDiving)
            .accessibilityHidden(true)
    }

    /// Official `color-mix(border-l1 75%, border-l2)`.
    private static let dividerColor = NativeParityTokens.rgba(
        light: 0x000000, lightAlpha: 0.055,
        dark: 0xFFFFFF, darkAlpha: 0.075)

    private var divider: some View {
        Rectangle()
            .fill(Self.dividerColor)
            .frame(height: 0.5)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }
}

#if DEBUG

private struct NativeRunningStatusPreview: View {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("无 start（深度求索中），有分隔线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: nil, showsDivider: true, fixedNow: Self.start)
                Text("用时 12秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: Self.start, fixedNow: Self.start.addingTimeInterval(12))
                Text("用时 1分5秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: Self.start, fixedNow: Self.start.addingTimeInterval(65))
                Text("用时 1小时1分1秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: Self.start, fixedNow: Self.start.addingTimeInterval(3661))
                Text("上一条是输入：不画分隔线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: Self.start,
                                    showsDivider: false,
                                    fixedNow: Self.start.addingTimeInterval(12))
                Text("实时每秒 tick")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeRunningStatus(startedAt: Date().addingTimeInterval(-12))
            }
            .frame(width: NativeParityTokens.contentWidth, alignment: .leading)
            .padding(32)
        }
    }
}

struct NativeRunningStatus_Previews: PreviewProvider {
    static var previews: some View {
        NativeRunningStatusPreview()
    }
}

#endif

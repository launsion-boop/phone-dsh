// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHBot

/// The one live-status line above the Bot composer: a 20pt fish in its real
/// state, then one secondary line that sweeps a soft highlight and fades /
/// lifts / scales on every change. It never captures touches.
struct BotActivityLine: View {
    let activity: BotActivity
    let fishState: BotFishLifecycle
    var appearance: BotFishAppearance = .classic

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var rotationTask: Task<Void, Never>?

    private var phrases: [String] {
        switch activity.status {
        case .thinking: return ["思考中…", "整理思绪…", "准备下一步…"]
        case .toolRunning: return ["处理中…", "执行工具…", "整理结果…"]
        case .streaming: return ["整理回复…", "组织内容…"]
        }
    }

    private var text: String {
        if !activity.detail.isEmpty { return activity.detail }
        return phrases[index % phrases.count]
    }

    var body: some View {
        HStack(spacing: 8) {
            BotFishView(state: fishState, size: 20, appearance: appearance)
                .accessibilityHidden(true)
            BotActivityShimmerText(text: text)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("bot.activity.line")
        .onAppear { startRotation() }
        .onDisappear {
            rotationTask?.cancel()
            rotationTask = nil
        }
        .onChange(of: activity.status) { _, _ in resetRotation() }
        .onChange(of: activity.detail) { _, _ in resetRotation() }
    }

    private func resetRotation() {
        index = 0
        startRotation()
    }

    private func startRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        guard activity.detail.isEmpty else { return }
        rotationTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard !Task.isCancelled else { return }
                index += 1
            }
        }
    }
}

/// 13/18 secondary text with the DSH running-row shimmer sweep. The text
/// itself enters with opacity 0→1, y 2→0 and scale .985→1.
private struct BotActivityShimmerText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    private var isAnimating: Bool { !reduceMotion }

    private static let highlight = NativeParityTokens.rgba(
        light: 0x000000, lightAlpha: 0.30,
        dark: 0xFFFFFF, darkAlpha: 0.45)

    var body: some View {
        ZStack(alignment: .leading) {
            label
                .foregroundStyle(HomeSpec.textSecondary)
            if isAnimating {
                label
                    .foregroundStyle(Self.highlight)
                    .mask { sweep }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 18, alignment: .leading)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.22),
                   value: text)
        .onAppear { restart() }
        .onChange(of: text) { _, _ in restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.tail)
            .id(text)
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .offset(y: 2))
                    .combined(with: .scale(scale: 0.985)),
                removal: .opacity))
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

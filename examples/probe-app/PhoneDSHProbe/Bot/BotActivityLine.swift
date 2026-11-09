// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHBot

/// The one live-status line above the Bot composer: a 28pt fish in its real
/// state that also floats gently, then one secondary line that crossfades on
/// every change and breathes while it stays the same, under a soft highlight
/// sweep. It never captures touches.
struct BotActivityLine: View {
    let activity: BotActivity
    let fishState: BotFishLifecycle
    var appearance: BotFishAppearance = .classic

    static let fishSize: CGFloat = 28

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
        HStack(spacing: 10) {
            BotActivityFloatingFish(state: fishState, appearance: appearance)
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

/// The status fish: its own state animation, plus a slow float and breath so
/// the line reads as alive even when the state does not change.
private struct BotActivityFloatingFish: View {
    let state: BotFishLifecycle
    let appearance: BotFishAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        BotFishView(state: state, size: BotActivityLine.fishSize, appearance: appearance)
            .offset(y: reduceMotion ? 0 : (up ? -2 : 1))
            .scaleEffect(reduceMotion ? 1 : (up ? 1.04 : 0.98))
            .onAppear { start() }
            .onChange(of: reduceMotion) { _, _ in start() }
    }

    private func start() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { up = false }
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            up = true
        }
    }
}

/// 14/20 secondary text. A change fades the old line out and the new one in
/// with a small lift; while the words stay the same the line breathes between
/// 55% and 100% opacity, under the DSH running-row shimmer sweep.
private struct BotActivityShimmerText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    @State private var dim = false

    private static let highlight = NativeParityTokens.rgba(
        light: 0x000000, lightAlpha: 0.30,
        dark: 0xFFFFFF, darkAlpha: 0.45)

    var body: some View {
        ZStack(alignment: .leading) {
            line(text)
                .id(text)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity.combined(with: .offset(y: -4))))
        }
        .frame(height: 20, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: text)
        .opacity(reduceMotion ? 1 : (dim ? 0.55 : 1))
        .onAppear { restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 14))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(HomeSpec.textSecondary)
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    Text(value)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Self.highlight)
                        .mask { sweep }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
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
        withTransaction(reset) {
            phase = -1
            dim = false
        }
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

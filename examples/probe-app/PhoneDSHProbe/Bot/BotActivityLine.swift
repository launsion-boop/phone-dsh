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
    var reaction: BotFishReaction?

    static let fishSize: CGFloat = 28

    @Environment(\.botPageActive) private var pageActive
    @State private var line = BotActivityLineState()
    @State private var clockTask: Task<Void, Never>?

    private var text: String { line.text }

    var body: some View {
        HStack(spacing: 10) {
            BotActivityFloatingFish(state: fishState, appearance: appearance, reaction: reaction)
                .accessibilityHidden(true)
            BotActivityShimmerText(text: text)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("bot.activity.line")
        .onAppear { receive(activity) }
        .onDisappear {
            clockTask?.cancel()
            clockTask = nil
        }
        .onChange(of: activity) { _, next in receive(next) }
        .onChange(of: pageActive) { _, _ in
            clockTask?.cancel()
            clockTask = nil
            if pageActive { receive(activity) }
        }
    }

    /// Hand the factory's activity to the timing machine, then keep one clock
    /// task parked at the next rotation/pending/minute boundary.
    private func receive(_ next: BotActivity) {
        line.receive(next, at: BotActivityLineState.now)
        scheduleClock()
    }

    private func scheduleClock() {
        clockTask?.cancel()
        clockTask = nil
        guard pageActive, let deadline = line.nextDeadline else { return }
        clockTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let target = line.nextDeadline else { return }
                let delay = max(0, target - BotActivityLineState.now)
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !Task.isCancelled else { return }
                line.tick(at: BotActivityLineState.now)
            }
        }
    }
}

/// The status fish: its own state animation, plus a slow float and breath so
/// the line reads as alive even when the state does not change.
private struct BotActivityFloatingFish: View {
    let state: BotFishLifecycle
    let appearance: BotFishAppearance
    let reaction: BotFishReaction?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive
    @State private var up = false

    var body: some View {
        BotFishView(state: state, size: BotActivityLine.fishSize,
                    appearance: appearance, reaction: reaction)
            .offset(y: reduceMotion || !pageActive ? 0 : (up ? -2 : 1))
            .scaleEffect(reduceMotion || !pageActive ? 1 : (up ? 1.04 : 0.98))
            .onAppear { start() }
            .onChange(of: reduceMotion) { _, _ in start() }
            .onChange(of: pageActive) { _, _ in start() }
    }

    private func start() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { up = false }
        guard !reduceMotion, pageActive else { return }
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
    @Environment(\.botPageActive) private var pageActive
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
        .animation(reduceMotion || !pageActive ? nil : .easeInOut(duration: 0.35), value: text)
        .opacity(reduceMotion || !pageActive ? 1 : (dim ? 0.55 : 1))
        .onAppear { restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
        .onChange(of: pageActive) { _, _ in restart() }
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 14))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(HomeSpec.textSecondary)
            .overlay(alignment: .leading) {
                if !reduceMotion && pageActive {
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
        guard !reduceMotion, pageActive else { return }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

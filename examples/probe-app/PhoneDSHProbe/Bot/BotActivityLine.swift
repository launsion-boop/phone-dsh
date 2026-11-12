// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHBot

/// The one live-status line, centered right under the Bot header capsule.
/// The header fish above it is the only avatar and carries the motion; this
/// view is just the words: one 13/18 secondary line that slides and fades on
/// every change and breathes while it stays the same, under a soft highlight
/// sweep. It never captures touches.
struct BotActivityLine: View {
    let activity: BotActivity
    /// Waiting for the user: keep the words still (no shimmer, no breath).
    var quiet = false

    @Environment(\.botPageActive) private var pageActive
    @State private var line = BotActivityLineState()
    @State private var clockTask: Task<Void, Never>?

    private var text: String { line.text }

    var body: some View {
        BotActivityShimmerText(text: text, quiet: quiet)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
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
        guard pageActive, line.nextDeadline != nil else { return }
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

/// 13/18 centered secondary text. A change slides the old words up and out
/// and the new ones up and in, with a short fade and blur, on one spring so
/// a quick run of changes stays continuous. Both lines are centered in the
/// same box, so a width change never shifts the line sideways. While the
/// words stay the same the line breathes between 70% and 100% opacity under
/// the DSH running-row shimmer sweep.
private struct BotActivityShimmerText: View {
    let text: String
    let quiet: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive
    @State private var phase: CGFloat = -1
    @State private var dim = false

    private static let height: CGFloat = 18

    private static let highlight = NativeParityTokens.rgba(
        light: 0x000000, lightAlpha: 0.30,
        dark: 0xFFFFFF, darkAlpha: 0.45)

    private var animated: Bool { !reduceMotion && pageActive }
    /// Shimmer and breathing only while the Bot is doing something.
    private var ambient: Bool { animated && !quiet }

    var body: some View {
        ZStack {
            line(text)
                .id(text)
                .transition(animated ? .asymmetric(
                    insertion: .modifier(active: BotStatusSwap(offset: 8, blur: 2, opacity: 0),
                                         identity: BotStatusSwap.identity),
                    removal: .modifier(active: BotStatusSwap(offset: -8, blur: 2, opacity: 0),
                                       identity: BotStatusSwap.identity))
                    : .identity)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .clipped()
        .animation(animated ? .spring(response: 0.42, dampingFraction: 0.9) : nil, value: text)
        .opacity(ambient ? (dim ? 0.7 : 1) : 1)
        .onAppear { restart() }
        .onChange(of: reduceMotion) { _, _ in restart() }
        .onChange(of: pageActive) { _, _ in restart() }
        .onChange(of: quiet) { _, _ in restart() }
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(HomeSpec.textSecondary)
            .overlay {
                if ambient {
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
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
        guard ambient else { return }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

/// Offset + blur + opacity for one status swap.
private struct BotStatusSwap: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    static let identity = BotStatusSwap(offset: 0, blur: 0, opacity: 1)

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHBot

/// The one live-status line, centered right under the Bot header capsule.
/// The header fish above it is the only avatar and carries the motion; this
/// view is a passive 13/18 silver-gray line with a fixed activity point.
/// Only its local highlight sweeps while work is active.
struct BotActivityLine: View {
    let activity: BotActivity
    /// Waiting for the user: keep the words still (no shimmer, no breath).
    var quiet = false
    /// A failure report: quiet, in the danger tint.
    var problem = false

    @Environment(\.botPageActive) private var pageActive
    @State private var line = BotActivityLineState()
    @State private var clockTask: Task<Void, Never>?

    private var text: String { line.text }

    var body: some View {
        GeometryReader { proxy in
            let textWidth = min(text.size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium)]).width,
                                max(0, proxy.size.width - 13))
            HStack(spacing: 8) {
                Circle()
                    .fill(problem ? BotUIPalette.danger : BotActivityShimmerText.silver)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                BotActivityShimmerText(text: text, quiet: quiet || problem,
                                       ink: problem ? BotUIPalette.danger : BotActivityShimmerText.silver)
                    .frame(width: textWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: proxy.size.height)
        }
        .frame(height: 18)
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

/// 13/18 centered secondary text. A change moves the old words up and out
/// and the new ones up and in, with a short fade. Both lines are centered in the
/// same box, so a width change never shifts the line sideways. While the
/// words stay the same, a separate silver highlight sweeps over fully readable
/// base text.
private struct BotActivityShimmerText: View {
    let text: String
    let quiet: Bool
    let ink: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive
    @State private var phase: CGFloat = -1
    private static let height: CGFloat = 18

    fileprivate static let silver = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 184/255, green: 190/255, blue: 199/255, alpha: 1)
            : UIColor(red: 105/255, green: 113/255, blue: 124/255, alpha: 1)
    })

    private static let highlight = NativeParityTokens.rgba(
        light: 0xFFFFFF, lightAlpha: 0.78,
        dark: 0xFFFFFF, darkAlpha: 0.68)

    private var animated: Bool { !reduceMotion && pageActive && !quiet }
    /// Shimmer and breathing only while the Bot is doing something.
    private var ambient: Bool { animated && !quiet }

    var body: some View {
        ZStack {
            line(text)
                .id(text)
                .transition(animated ? .asymmetric(
                    insertion: .modifier(active: BotStatusSwap(offset: 3, blur: 0, opacity: 0),
                                         identity: BotStatusSwap.identity),
                    removal: .modifier(active: BotStatusSwap(offset: -3, blur: 0, opacity: 0),
                                       identity: BotStatusSwap.identity))
                    : .identity)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .clipped()
        .animation(animated ? .easeOut(duration: 0.25) : nil, value: text)
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
            .foregroundStyle(ink)
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
        }
        guard ambient else { return }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1
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

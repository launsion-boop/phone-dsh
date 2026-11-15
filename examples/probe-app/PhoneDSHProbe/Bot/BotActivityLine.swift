// SPDX-License-Identifier: MIT

import SwiftUI
import PhoneDSHBot

/// The legacy centered live-status line. The Bot chat page no longer mounts
/// it — the one activity surface there is `BotActivityBubble` — but the view
/// stays compiled so another page can reuse it without duplicating the
/// timing machine or the glint.
struct BotActivityLine: View {
    let activity: BotActivity
    /// Waiting for the user: keep the words still (no shimmer, no breath).
    var quiet = false
    /// A failure report: quiet, in the danger tint.
    var problem = false

    var body: some View {
        // One stable frame: the line fills the width it is given, the dot is
        // the fixed activity point and the words are centered inside the
        // remaining box. No string measurement enters layout, so a rotation,
        // minute-suffix or activity tick can never resize or re-center the
        // line (and nothing it floats over is asked to lay out again).
        BotActivityText(activity: activity) { text in
            HStack(spacing: 8) {
                Circle()
                    .fill(problem ? BotUIPalette.danger : BotActivityShimmerText.silver)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                BotActivityShimmerText(
                    text: text,
                    quiet: quiet || problem,
                    ink: problem ? BotUIPalette.danger : BotActivityShimmerText.silver)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("bot.activity.line")
        }
    }
}

/// The timing half shared by every activity surface: receives the lifecycle's
/// `BotActivity`, resolves it through `BotActivityLineState` (800ms
/// latest-wins, generic-phrase rotation, `· N 分钟`) and hands the current
/// sentence to its content. One clock task sleeps until the next deadline, so
/// the resolved words are identical wherever the activity is drawn and no
/// per-frame work or string measurement enters layout.
struct BotActivityText<Content: View>: View {
    private let activity: BotActivity
    private let content: (String) -> Content

    @Environment(\.botPageActive) private var pageActive
    @State private var line: BotActivityLineState
    @State private var clockTask: Task<Void, Never>?

    init(activity: BotActivity, @ViewBuilder content: @escaping (String) -> Content) {
        self.activity = activity
        self.content = content
        // Resolve the first sentence before the first body pass: the bubble's
        // accessibility label (and its visible words) must not flash the
        // fallback for one frame while `onAppear` runs.
        var initial = BotActivityLineState()
        initial.receive(activity, at: BotActivityLineState.now)
        _line = State(initialValue: initial)
    }

    var body: some View {
        content(line.text)
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

/// 13/18 activity text. A change moves the old words up and out and the new
/// ones up and in, with a short fade. Both lines are centered in the same box,
/// so a width change never shifts the line sideways. While the words stay the
/// same, a separate silver highlight sweeps over fully readable base text.
///
/// `fillsWidth` is true for the legacy centered line and false for the bubble,
/// which sizes to its sentence. `animatesSwap` is false in the bubble so a new
/// sentence changes width only once instead of holding the max of the old and
/// new strings for the duration of a transition.
struct BotActivityShimmerText: View {
    let text: String
    let quiet: Bool
    let ink: Color
    var fillsWidth = true
    var animatesSwap = true
    var height: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botPageActive) private var pageActive

    static let silver = Color(uiColor: UIColor { traits in
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
    private var swaps: Bool { animated && animatesSwap }

    var body: some View {
        ZStack {
            line(text)
                .id(text)
                .transition(swaps ? .asymmetric(
                    insertion: .modifier(active: BotStatusSwap(offset: 3, blur: 0, opacity: 0),
                                         identity: BotStatusSwap.identity),
                    removal: .modifier(active: BotStatusSwap(offset: -3, blur: 0, opacity: 0),
                                       identity: BotStatusSwap.identity))
                    : .identity)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil,
               minHeight: height, maxHeight: height)
        .clipped()
        .animation(swaps ? .easeOut(duration: 0.25) : nil, value: text)
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
    /// The band position comes from the timeline, not from a state animation:
    /// the line appears inside a transition, and a `repeatForever` animation
    /// started in `onAppear` can be absorbed by that insertion and never run,
    /// which leaves the highlight parked off-screen (the "glint disappeared"
    /// report). A timeline is also layout-neutral: it only changes the mask's
    /// offset, never the text's size or position.
    private var sweep: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !ambient)) { timeline in
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
                .offset(x: BotActivitySweep.phase(at: timeline.date) * proxy.size.width)
            }
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

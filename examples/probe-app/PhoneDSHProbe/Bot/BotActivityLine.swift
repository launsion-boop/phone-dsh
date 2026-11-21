// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import PhoneDSHBot

/// Capture previews can force crossfade without changing a device setting.
/// Production leaves this nil and follows UIKit's iOS 14+ preference.
private struct BotActivityCrossFadeKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var botActivityPrefersCrossFade: Bool? {
        get { self[BotActivityCrossFadeKey.self] }
        set { self[BotActivityCrossFadeKey.self] = newValue }
    }
}

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
        BotActivityText(activity: activity, urgent: quiet || problem) { text, _ in
            HStack(spacing: 8) {
                Circle()
                    .fill(problem ? BotActivityShimmerText.failureInk : BotActivityShimmerText.silver)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                BotActivityShimmerText(
                    text: text,
                    quiet: quiet || problem,
                    ink: problem ? BotActivityShimmerText.failureInk : BotActivityShimmerText.silver)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(false)
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
    private let urgent: Bool
    private let content: (String, BotActivity?) -> Content

    @Environment(\.botPageActive) private var pageActive
    @State private var line: BotActivityLineState
    @State private var clockTask: Task<Void, Never>?

    init(activity: BotActivity, urgent: Bool = false,
         @ViewBuilder content: @escaping (String, BotActivity?) -> Content) {
        self.activity = activity
        self.urgent = urgent
        self.content = content
        // Resolve the first sentence before the first body pass: the bubble's
        // accessibility label (and its visible words) must not flash the
        // fallback for one frame while `onAppear` runs.
        var initial = BotActivityLineState()
        initial.receive(activity, at: BotActivityLineState.now)
        _line = State(initialValue: initial)
    }

    var body: some View {
        let presented = presentedLine
        content(presented.text, presented.activity)
            .onAppear { receive(activity) }
            .onDisappear {
                clockTask?.cancel()
                clockTask = nil
            }
            .onChange(of: activity) { _, next in receive(next) }
            .onChange(of: urgent) { _, _ in receive(activity) }
            .onChange(of: pageActive) { _, _ in
                clockTask?.cancel()
                clockTask = nil
                if pageActive { receive(activity) }
            }
    }

    /// Make an urgent sentence visible in the same render that changes its
    /// tone, before the onChange callback updates the stored timing state.
    private var presentedLine: BotActivityLineState {
        guard urgent, line.activity != activity else { return line }
        var current = line
        current.receive(activity, at: BotActivityLineState.now, immediately: true)
        return current
    }

    /// Hand the factory's activity to the timing machine, then keep one clock
    /// task parked at the next rotation/pending/minute boundary.
    private func receive(_ next: BotActivity) {
        // An error or a request for the user must not recolor an old pending
        // sentence for the remainder of the normal 800ms dwell window.
        line.receive(next, at: BotActivityLineState.now, immediately: urgent)
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

/// Stable text measurement with an overlay-only, short vertical crossfade.
/// Outgoing words never hold the old width, so a content-hugging bubble does
/// not resize a second time when its transition completes. The base text is
/// always readable; the sweep is a subtle accent, not an opacity pulse.
struct BotActivityShimmerText: View {
    let text: String
    let quiet: Bool
    let ink: Color
    var fillsWidth = true
    var animatesSwap = true
    var height: CGFloat = 18
    var fontSize: CGFloat = 13

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botActivityPrefersCrossFade) private var crossFadeOverride
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.botPageActive) private var pageActive
    @State private var systemPrefersCrossFade = false

    static let silver = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 195/255, green: 202/255, blue: 212/255, alpha: 1)
            : UIColor(red: 83/255, green: 96/255, blue: 109/255, alpha: 1)
    })

    static let failureInk = NativeParityTokens.color(light: 0xC0392B, dark: 0xF25A5A)

    private static let highlight = NativeParityTokens.rgba(
        light: 0xFFFFFF, lightAlpha: 0.12,
        dark: 0xFFFFFF, darkAlpha: 0.30)

    private var animated: Bool { !reduceMotion && pageActive && !quiet }
    /// Shimmer and breathing only while the Bot is doing something.
    private var ambient: Bool { animated && !quiet }
    private var swaps: Bool { animated && animatesSwap }

    private var font: Font {
        .system(size: fontSize, weight: legibilityWeight == .bold ? .bold : .medium)
    }

    private var swapTransition: AnyTransition {
        guard swaps else { return .identity }
        if crossFadeOverride ?? systemPrefersCrossFade { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: BotStatusSwap(offset: 3, opacity: 0),
                                 identity: BotStatusSwap.identity),
            removal: .modifier(active: BotStatusSwap(offset: -3, opacity: 0),
                               identity: BotStatusSwap.identity))
    }

    var body: some View {
        Text(text)
        .font(font)
        .lineLimit(1)
        .truncationMode(.tail)
        .hidden()
        .accessibilityHidden(true)
        .frame(maxWidth: fillsWidth ? .infinity : nil,
               minHeight: height, maxHeight: height)
        .overlay(alignment: fillsWidth ? .center : .leading) {
            ZStack(alignment: fillsWidth ? .center : .leading) {
                line(text).id(text).transition(swapTransition)
            }
            .frame(maxWidth: .infinity, alignment: fillsWidth ? .center : .leading)
        }
        .clipped()
        .animation(swaps ? .easeOut(duration: 0.22) : nil, value: text)
        .onAppear { systemPrefersCrossFade = UIAccessibility.prefersCrossFadeTransitions }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.prefersCrossFadeTransitionsStatusDidChange)) { _ in
            systemPrefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            systemPrefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
        }
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(ink)
            .overlay {
                if ambient {
                    Text(value)
                        .font(font)
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

/// Small, clipped movement and opacity for one status swap; never blur text.
private struct BotStatusSwap: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    static let identity = BotStatusSwap(offset: 0, opacity: 1)

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .opacity(opacity)
    }
}

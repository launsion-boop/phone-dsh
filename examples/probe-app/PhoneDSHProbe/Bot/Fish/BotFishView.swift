// SPDX-License-Identifier: MIT

// SwiftUI façade for the native 大肥鱼 renderer. This is the frozen interface
// shared with the Bot page:
//
//     BotFishView(state: BotFishLifecycle, size: CGFloat,
//                 appearance: BotFishAppearance = .classic,
//                 still: Bool = false, allowsPoke: Bool = false)

import Combine
import SwiftUI
import UIKit
import PhoneDSHBot

struct BotFishView: View {
    let state: BotFishLifecycle
    let size: CGFloat
    let appearance: BotFishAppearance
    let still: Bool
    let allowsPoke: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.botFishPaused) private var botFishPaused
    @State private var engine = BotFishEngine()
    @State private var isVisible = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The frame kept on screen while the timeline is stopped. The renderer
    /// owns the pixels; this is just the last display-ready composition.
    @State private var frozenFrame: BotFishFrame?

    init(state: BotFishLifecycle, size: CGFloat,
         appearance: BotFishAppearance = .classic,
         still: Bool = false, allowsPoke: Bool = false) {
        self.state = state
        self.size = size
        self.appearance = appearance
        self.still = still
        self.allowsPoke = allowsPoke
    }

    private var side: CGFloat { max(1, size) }

    /// Hard pause conditions. These never render unless the view has not
    /// painted yet (the one-shot `.task` below paints that first frame), so a
    /// backgrounded / hidden / low-power avatar contributes no samples at all.
    private var hardPaused: Bool {
        // The Bot tab stays mounted while another tab is selected, and it is
        // mounted while the app is in the background. NativeShell derives this
        // key from the selected tab and AppModel.isSceneActive, so the avatar
        // stops scheduling frames and keeps whatever it painted last without
        // observing scene phase itself.
        if botFishPaused { return true }
        if !isVisible { return true }
        if still || reduceMotion || lowPowerMode { return true }
        return false
    }

    /// 20fps is the animation cap; the tiny 28/32/40pt avatars use 15fps,
    /// where the upstream motion amplitudes are already boosted 2.2×.
    private var frameInterval: Double {
        size <= BotFishRenderer.motionBoostSmallSize ? 1.0 / 15.0 : 1.0 / 20.0
    }

    /// Re-evaluated after a pause-condition, lifecycle or appearance change so
    /// a frozen avatar paints the new state exactly once.
    private var pauseTaskID: String {
        "\(hardPaused)-\(state.rawValue)-\(appearance.color.rawValue)"
            + "-\(appearance.hairstyle.rawValue)-\(still)-\(reduceMotion)"
            + "-\(displayScale)-\(lowPowerMode)-\(isVisible)"
    }

    var body: some View {
        Group {
            if hardPaused {
                frameLayers(frozenFrame ?? engine.currentFrame)
            } else {
                TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                    frameLayers(engine.advance(at: timeline.date, state: state,
                                               still: still, reduced: reduceMotion,
                                               size: side, displayScale: displayScale,
                                               appearance: appearance))
                }
            }
        }
        .frame(width: side, height: side)
        // Like the upstream circle avatar, the fish sits directly on whatever
        // surface hosts it. The renderer already draws only the 416px circle
        // crop at display resolution.
        .clipShape(Circle())
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: pauseTaskID) {
            await syncPauseState()
        }
        .gesture(
            TapGesture().onEnded {
                guard allowsPoke, !still else { return }
                engine.poke()
            },
            including: allowsPoke && !still ? .all : .none
        )
        .accessibilityLabel("Bot 头像")
    }

    @ViewBuilder
    private func frameLayers(_ frame: BotFishFrame?) -> some View {
        if let frame {
            ZStack {
                frame.base
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                frame.face
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
            }
            // The renderer's pose pivot is source (256, 350) inside the
            // (48, 30, 416, 416) crop: (0.5, 320/416) in view points.
            .scaleEffect(x: frame.pose.scaleX, y: frame.pose.scaleY, anchor: Self.pivot)
            .rotationEffect(.degrees(frame.pose.roll), anchor: Self.pivot)
            .offset(x: frame.pose.offsetX, y: frame.pose.offsetY)
            .compositingGroup()
            .opacity(frame.alpha)
        } else {
            Image("BotAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
        }
    }

    private static let pivot = UnitPoint(x: 0.5,
                                         y: 320.0 / BotFishRenderer.cropSide)

    @MainActor
    private func syncPauseState() async {
        guard hardPaused else {
            engine.resetClock()
            frozenFrame = nil
            return
        }
        guard isVisible else {
            frozenFrame = engine.currentFrame
            return
        }
        // Paint one frame for a newly paused avatar (still / reduced motion /
        // a state change while backgrounded) and keep it.
        let frame = engine.advance(at: Date(), state: state, still: still,
                                   reduced: reduceMotion, size: side,
                                   displayScale: displayScale, appearance: appearance)
        frozenFrame = frame ?? engine.currentFrame
    }
}

private struct BotFishPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the Bot tab is off-screen or the app is not active.
    /// `BotFishView` pauses its TimelineView and keeps the last frame instead
    /// of rendering at 15–20fps.
    var botFishPaused: Bool {
        get { self[BotFishPausedKey.self] }
        set { self[BotFishPausedKey.self] = newValue }
    }
}

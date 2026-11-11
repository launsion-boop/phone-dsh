// SPDX-License-Identifier: MIT

// SwiftUI façade for the native 大肥鱼 renderer. This is the frozen interface
// shared with the Bot page:
//
//     BotFishView(state: BotFishLifecycle, size: CGFloat,
//                 appearance: BotFishAppearance = .classic,
//                 crowned: Bool = false,
//                 still: Bool = false, allowsPoke: Bool = false,
//                 reaction: BotFishReaction? = nil,
//                 motionProfile: BotFishMotionProfile = .standard,
//                 workStyle: BotFishWorkStyle = .generic)

import Combine
import SwiftUI
import UIKit
import PhoneDSHBot

struct BotFishView: View {
    let state: BotFishLifecycle
    let size: CGFloat
    let appearance: BotFishAppearance
    /// Main-Bot crown. It changes the cached static base and the circle crop
    /// (448px at (32, 10)), so the whole view repaints once when it flips.
    let crowned: Bool
    let still: Bool
    let allowsPoke: Bool
    /// Agent-driven cosmetic overlay. The lifecycle `state` stays the base;
    /// the renderer plays one action clip or a 4 s face expression and then
    /// falls back to the lifecycle state.
    let reaction: BotFishReaction?
    /// `.standard` is upstream behaviour. `.lively` is the app-only status
    /// line profile (30fps + louder clips); it never reaches production
    /// lifecycle code.
    let motionProfile: BotFishMotionProfile
    /// App-only `.working` sub-style; ignored for other lifecycle states and
    /// for `.standard`.
    let workStyle: BotFishWorkStyle

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
         crowned: Bool = false,
         still: Bool = false, allowsPoke: Bool = false,
         reaction: BotFishReaction? = nil,
         motionProfile: BotFishMotionProfile = .standard,
         workStyle: BotFishWorkStyle = .generic) {
        self.state = state
        self.size = size
        self.appearance = appearance
        self.crowned = crowned
        self.still = still
        self.allowsPoke = allowsPoke
        self.reaction = reaction
        self.motionProfile = motionProfile
        self.workStyle = workStyle
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

    /// Standard: 20fps cap, tiny 28/32/40pt avatars 15fps (the upstream
    /// amplitudes are boosted there). Lively: 30fps cap. This view only draws
    /// the timeline while `hardPaused` is false, so paused/hidden/low-power/
    /// reduced-motion avatars still render one frozen frame and schedule none.
    private var frameInterval: Double {
        if motionProfile == .lively { return 1.0 / 30.0 }
        return size <= BotFishRenderer.motionBoostSmallSize ? 1.0 / 15.0 : 1.0 / 20.0
    }

    /// Re-evaluated after a pause-condition, lifecycle, appearance, crown or
    /// reaction change so a frozen avatar paints the new state exactly once.
    private var pauseTaskID: String {
        "\(hardPaused)-\(state.rawValue)-\(appearance.color.rawValue)"
            + "-\(appearance.hairstyle.rawValue)-\(crowned)-\(still)-\(reduceMotion)"
            + "-\(displayScale)-\(lowPowerMode)-\(isVisible)"
            + "-\(reaction?.id ?? "")"
            + "-\(motionProfile.rawValue)-\(workStyle.rawValue)"
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
                                               appearance: appearance, crowned: crowned,
                                               reaction: reaction,
                                               profile: motionProfile,
                                               workStyle: workStyle))
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
            // (48, 30, 416, 416) normal crop or the (32, 10, 448, 448) crowned
            // crop: (0.5, 320/416) or (0.5, 340/448) in view points.
            .scaleEffect(x: frame.pose.scaleX, y: frame.pose.scaleY, anchor: pivot)
            .rotationEffect(.degrees(frame.pose.roll), anchor: pivot)
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

    private var pivot: UnitPoint {
        UnitPoint(x: 0.5,
                  y: (crowned ? 340.0 : 320.0)
                    / (crowned ? BotFishRenderer.crownedCropSide : BotFishRenderer.cropSide))
    }

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
                                   displayScale: displayScale, appearance: appearance,
                                   crowned: crowned, reaction: reaction,
                                   profile: motionProfile, workStyle: workStyle)
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

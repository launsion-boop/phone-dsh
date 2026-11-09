// SPDX-License-Identifier: MIT

// SwiftUI façade for the native 大肥鱼 renderer. This is the frozen interface
// shared with the Bot page:
//
//     BotFishView(state: BotFishLifecycle, size: CGFloat,
//                 still: Bool = false, allowsPoke: Bool = false)

import SwiftUI
import UIKit
import PhoneDSHBot

struct BotFishView: View {
    let state: BotFishLifecycle
    let size: CGFloat
    let still: Bool
    let allowsPoke: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.botFishPaused) private var botFishPaused
    @State private var engine = BotFishEngine()
    /// Re-evaluates the timeline after a poke or an environment change while
    /// the schedule was paused.
    @State private var refreshToken = 0
    @State private var isVisible = false

    init(state: BotFishLifecycle, size: CGFloat, still: Bool = false, allowsPoke: Bool = false) {
        self.state = state
        self.size = size
        self.still = still
        self.allowsPoke = allowsPoke
    }

    private var side: CGFloat { max(1, size) }

    private var paused: Bool {
        // The Bot tab stays mounted while another tab is selected. NativeShell
        // sets this key on that tab, so an invisible Bot tab stops scheduling
        // frames and keeps whatever it painted last.
        if botFishPaused { return true }
        if !isVisible { return true }
        // Always allow one frame so `still`, reduced-motion and static states
        // are painted before the schedule freezes.
        if !engine.hasRendered { return false }
        if still || reduceMotion || scenePhase != .active { return true }
        _ = refreshToken
        return !engine.needsAnimation
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            let image = engine.advance(at: timeline.date, state: state,
                                       still: still, reduced: reduceMotion,
                                       size: side, displayScale: displayScale)
            layers(image)
        }
        // A paused `TimelineView` keeps its last content; changing identity on
        // a frozen input forces exactly one new frame (still / reduced motion /
        // a new lifecycle state while paused).
        .id("\(state.rawValue)-\(still)-\(reduceMotion)")
        .frame(width: side, height: side)
        .onAppear {
            isVisible = true
            engine.configure(state: state, still: still, reduced: reduceMotion)
            engine.resetClock()
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: state) { _, _ in
            engine.configure(state: state, still: still, reduced: reduceMotion)
            engine.resetClock()
            refreshToken &+= 1
        }
        .onChange(of: still) { _, _ in
            engine.configure(state: state, still: still, reduced: reduceMotion)
            engine.resetClock()
            refreshToken &+= 1
        }
        .onChange(of: reduceMotion) { _, _ in
            engine.configure(state: state, still: still, reduced: reduceMotion)
            engine.resetClock()
            refreshToken &+= 1
        }
        .onChange(of: scenePhase) { _, _ in
            engine.resetClock()
            refreshToken &+= 1
        }
        .onChange(of: displayScale) { _, _ in
            // A moved window can change the backing scale; the renderer
            // rebuilds its display-sized buffers on the next frame.
            engine.resetClock()
            refreshToken &+= 1
        }
        .onChange(of: botFishPaused) { _, isPaused in
            guard !isPaused else { return }
            engine.resetClock()
            refreshToken &+= 1
        }
        .gesture(
            TapGesture().onEnded {
                guard allowsPoke, !still else { return }
                engine.poke()
                refreshToken &+= 1
            },
            including: allowsPoke && !still ? .all : .none
        )
        .accessibilityLabel("Bot 头像")
    }

    @ViewBuilder
    private func layers(_ image: UIImage?) -> some View {
        if let image {
            Canvas { context, canvasSize in
                // The renderer already rasterises only the 416px circle crop
                // at this view's display scale, so the canvas draws 1:1.
                context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: canvasSize)))
                context.draw(Image(uiImage: image),
                             in: CGRect(origin: .zero, size: canvasSize))
            }
            .background(Color.white)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        } else {
            Image("BotAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .background(Color.white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        }
    }
}

private struct BotFishPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the Bot tab is off-screen. `BotFishView` pauses its
    /// `TimelineView` and keeps the last frame instead of rendering at 30fps.
    var botFishPaused: Bool {
        get { self[BotFishPausedKey.self] }
        set { self[BotFishPausedKey.self] = newValue }
    }
}

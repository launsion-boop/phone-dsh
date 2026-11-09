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
                                       still: still, reduced: reduceMotion)
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
                let width = canvasSize.width
                let cropScale = width / 416
                let destination = CGRect(
                    x: -48 * cropScale,
                    y: -30 * cropScale,
                    width: 512 * cropScale,
                    height: 512 * cropScale
                )
                context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: canvasSize)))
                context.draw(Image(uiImage: image), in: destination)
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

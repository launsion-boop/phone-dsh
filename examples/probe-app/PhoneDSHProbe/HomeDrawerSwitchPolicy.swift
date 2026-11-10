// SPDX-License-Identifier: MIT
// The drawer's session-tap decision. It lives outside the view so the
// "paint now, close first, switch after" behaviour — and the last-tap-wins
// rollback it depends on — has a regression test of its own.

import Foundation

enum HomeDrawerSwitchPolicy {
    /// One session identity as the drawer row and the chat header display it.
    struct Session: Equatable {
        let id: String
        let title: String
    }

    /// The session the last tap asked for. Every switch completion carries the
    /// generation it started with; a newer tap makes the old completion stale.
    struct Pending: Equatable {
        let target: Session
        let generation: Int
    }

    enum Tap: Equatable {
        /// The tapped row is already the open session, or the drawer is already
        /// switching to it. Close the drawer and start no second switch.
        case close
        /// The drawer closes in this frame and the switch runs in the
        /// background. `target` is marked selected before the close animation.
        case beginSwitch(Session)
    }

    /// When the switch worker may start after a tap. The tap itself only paints
    /// the optimistic selection/title; the heavy open is released later.
    enum StartGate: Equatable {
        /// The phone drawer closes in 0.22s. Starting the open in the tap frame
        /// makes its synchronous work swallow that animation, so the worker
        /// waits for the close completion.
        case afterDrawerClosed
        /// The wide sidebar never closes. Yielding one runloop is enough to let
        /// SwiftUI commit the tap frame before the worker starts.
        case nextRunloop
    }

    /// The event that releases a gated switch.
    enum StartEvent: Equatable {
        case drawerClosed
        case runloopYielded
    }

    /// The phone drawer's close animation. `HomeDrawer` uses this duration and
    /// starts the switch from the animation's completion handler.
    static let closeDuration: TimeInterval = 0.22

    /// Decide a tap without touching any UI state.
    static func tap(_ target: Session,
                    currentSessionID: String?,
                    pending: Pending?) -> Tap {
        if pending?.target.id == target.id { return .close }
        if pending == nil, currentSessionID == target.id { return .close }
        return .beginSwitch(target)
    }

    /// The phone drawer closes in the tap frame; the wide persistent sidebar
    /// only updates the selection and never hides.
    static func closesDrawer(isPersistent: Bool) -> Bool {
        !isPersistent
    }

    /// Which release event this layout needs.
    static func startGate(isPersistent: Bool) -> StartGate {
        isPersistent ? .nextRunloop : .afterDrawerClosed
    }

    /// True when `event` releases the switch. The phone drawer starts only on
    /// its close completion; the persistent sidebar starts on the first runloop
    /// yield and never waits for a close.
    static func startsSwitch(_ gate: StartGate, on event: StartEvent) -> Bool {
        switch gate {
        case .afterDrawerClosed: return event == .drawerClosed
        case .nextRunloop: return event == .runloopYielded
        }
    }

    /// The target that must be drawn while a switch is pending: the tapped
    /// session, never the old one. This is what makes the header title change
    /// in the same frame as the tap.
    static func displayed(current: Session?, pending: Pending?) -> Session? {
        pending?.target ?? current
    }

    static func isLatest(_ generation: Int, latest: Int) -> Bool {
        generation == latest
    }

    /// The session to adopt after a successful open. A completion from a
    /// superseded tap returns nil and must not touch the page.
    static func committed(_ pending: Pending?,
                          generation: Int,
                          latest: Int) -> Session? {
        guard let pending, pending.generation == generation,
              isLatest(generation, latest: latest) else { return nil }
        return pending.target
    }

    /// The session to restore after a failed open. The old selection is never
    /// overwritten until the switch succeeds, so rollback just stops showing
    /// the pending target. A superseded completion returns nil.
    static func rolledBack(current: Session?,
                           pending: Pending?,
                           generation: Int,
                           latest: Int) -> Session? {
        guard let pending, pending.generation == generation,
              isLatest(generation, latest: latest) else { return nil }
        return current
    }
}

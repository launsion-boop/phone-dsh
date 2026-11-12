// SPDX-License-Identifier: MIT
// The drawer's 新会话 availability policy. It lives outside the view so the
// difference between a transient session switch (`busy`) and a real running
// turn has a regression test of its own.

import CoreGraphics
import Foundation

enum HomeDrawerNewSessionPolicy {
    /// One line of the 13pt reason text. The drawer always lays this row out,
    /// so a reason appearing or disappearing cannot move the session list.
    static let reasonLineHeight: CGFloat = 16

    enum Reason: Equatable {
        case engineNotStarted
        case turnRunning

        var text: String {
            switch self {
            case .engineNotStarted: NativeText("引擎未启动", "Engine not started")
            case .turnRunning: NativeText("本轮结束后可用", "Available after this turn")
            }
        }
    }

    /// Why the capsule shows a reason below it. `busy` is deliberately absent:
    /// opening another session flips it for one brief transition, and showing
    /// "本轮结束后可用" for that pushed the list down and back up.
    ///
    /// W1: a boot in progress is not "引擎未启动". The capsule stays disabled
    /// for the short start, but the reason line must not claim a stopped engine
    /// while the Worker is starting.
    static func reason(isStarted: Bool,
                       turnRunning: Bool,
                       keepingAlive: Bool,
                       engineStarting: Bool = false) -> Reason? {
        if !isStarted, !engineStarting { return .engineNotStarted }
        if turnRunning || keepingAlive { return .turnRunning }
        return nil
    }

    /// The capsule stays disabled for the transient switch; it only stops
    /// drawing a reason for it.
    static func isDisabled(isStarted: Bool, busy: Bool, turnRunning: Bool, keepingAlive: Bool) -> Bool {
        !isStarted || busy || turnRunning || keepingAlive
    }
}

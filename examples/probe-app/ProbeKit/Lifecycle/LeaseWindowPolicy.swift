// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — when to end a granted wake window.
//
// host §10.2.3 `parkMarginMs` is the latest stop point, not a mandatory wait.
// A push or BGTask window must be released as soon as its work is done: park
// immediately when no turn is in flight; while one runs, let it finish or stop
// at `deadline − parkMarginMs`, whichever comes first; a foreground return
// hands control back to foreground eligibility, and the OS expiration handler
// always parks immediately.

import Foundation

public enum LeaseWindowAction: Equatable, Sendable {
    /// The App is in the foreground: eligibility no longer comes from the
    /// lease, so release the window without parking.
    case releaseForeground
    /// Nothing is running: park now and release the window.
    case parkNow
    /// A turn is in flight and the latest stop point is still ahead: wait.
    case wait
}

public enum LeaseWindowPolicy {
    public static func action(isForeground: Bool, turnInFlight: Bool,
                              nowMs: Int64, deadlineMs: Int64,
                              parkMarginMs: Int64 = EngineLaunchThresholds.parkMarginMs) -> LeaseWindowAction {
        if isForeground { return .releaseForeground }
        guard turnInFlight else { return .parkNow }
        let latestStop = deadlineMs - parkMarginMs
        return nowMs < latestStop ? .wait : .parkNow
    }
}

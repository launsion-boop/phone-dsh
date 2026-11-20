// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the closed set of causes that may ask the iOS host to
// run engine work.
//
// host contract `spec/host/v1/README.md` §10.2 (P06). The enum is closed: a new
// channel adds a value here and updates the shared golden
// (`spec/host/v1/golden/engine-launch.json`) through the contract owner — never
// a free-form string at a call site.

import Foundation

/// Why the App was woken (PLAN §2.2). One value per channel, never a payload.
public enum WakeReason: String, CaseIterable, Codable, Sendable, Equatable {
    /// A process launch with no foreground scene yet (cold start).
    case coldLaunch
    /// The App became active again (scene phase `.active`).
    case foreground
    /// The phone unlocked (protected data became available).
    case unlock
    /// A cloud-task push asked this phone to run queued work.
    case cloudTaskPush
    /// The TonoLink board's wake word / wake event.
    case boardWake
    /// Another trusted BLE device's request.
    case bleRequest
    /// A request that arrived on a local listener (Bot MCP HTTP, LAN relay).
    case lanRequest
    /// The paired PC's relay asked this phone to continue work.
    case pcLinkRequest
    /// `BGProcessingTask` execution window.
    case bgProcessing
    /// The user tapped a routine notification.
    case routineNotificationTap
    /// A host status probe saw a healthy engine again after recovery.
    case engineRecovered
}

/// Thresholds shared by the decision function and every caller.
///
/// PROVISIONAL: `minLeaseForColdBootMs` / `minLeaseForResumeMs` are the PLAN
/// §2.3 values; `ios-wake-spike` re-measures them on a device and the contract
/// owner freezes the final numbers in host §10.2. Do not copy them into a
/// second table.
public enum EngineLaunchThresholds {
    /// No host: a cold boot needs at least this much remaining lease.
    public static let minLeaseForColdBootMs: Int64 = 20_000
    /// A parked host: a resume needs at least this much remaining lease.
    public static let minLeaseForResumeMs: Int64 = 8_000
    /// Park the host and end the OS window this long before the lease deadline.
    public static let parkMarginMs: Int64 = 5_000
    /// ReadySweep step 3 skips its cloud pull when a pass ran this recently.
    public static let cloudPullFreshnessMs: Int64 = 30_000
}

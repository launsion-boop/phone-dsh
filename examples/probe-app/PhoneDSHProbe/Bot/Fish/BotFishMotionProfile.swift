// SPDX-License-Identifier: MIT

import Foundation

/// Animation budget for one `BotFishView`.
///
/// `.standard` is the upstream-compatible profile every existing avatar uses
/// (idle header, drawer, profile, empty state, gallery). It is not allowed to
/// change its output when `.lively` is added.
///
/// `.lively` is the app-only running profile: a 30 fps ceiling and a
/// louder, hand-tuned clip set that still runs on the same renderer. Only the
/// Bot header fish opts in, and only while a turn is running.
enum BotFishMotionProfile: String, CaseIterable {
    case standard
    case lively
}

/// App-only working sub-style. This is *not* a lifecycle state: it never
/// enters `BotFishLifecycle`, the FishDirector schema or the runtime event
/// mapping. It only picks the keyframe clip that a `.lively` avatar plays
/// while the lifecycle is `.working`.
enum BotFishWorkStyle: String, CaseIterable {
    /// The default working rhythm: nod, body sway and a periodic squash.
    case generic
    /// Eyes sweep a line while the head turns with them.
    case reading
    /// Head looks left and right while the eyes move quickly.
    case searching
    /// Faster nod, like typing commands.
    case running
    /// Head down plus a small fast shake.
    case writing
}

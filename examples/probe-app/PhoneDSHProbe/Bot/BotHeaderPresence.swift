// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// The single lifecycle behind the Bot header: the 32pt fish, its motion
/// profile and the one status line under it are all read from here, so the
/// header has no second badge, dot or icon that could disagree with them.
///
/// Phases, in priority order:
/// - `working`: a turn is running (from the local send until stop/final/
///   turn end). The line shows the turn's activity, the fish plays the
///   `.lively` clip set with the category's work style. A pending approval
///   inside the turn becomes the static `等你确认` line and the fish's own
///   `alerting` state.
/// - `waitingForYou`: no turn is running but an approval is still pending.
///   The line stays on a static `等你确认` (or `N 项等你确认`) and the fish
///   keeps `alerting` with the calm `.standard` motion.
/// - `idle`: no line; the fish follows its normal lifecycle.
///
/// Unanswered question/next-step cards do not hold the header: they are
/// suggestions already visible in the transcript.
struct BotHeaderPresence: Equatable {
    enum Phase: Equatable {
        case idle
        case working
        case waitingForYou
    }

    var phase: Phase
    /// What the status line under the avatar shows; nil hides the line.
    var line: BotActivity?
    var fishState: BotFishLifecycle
    var motion: BotFishMotionProfile
    var workStyle: BotFishWorkStyle

    /// The line is calm (no shimmer, no breathing) when the Bot is waiting
    /// for the user rather than doing something.
    var lineIsQuiet: Bool { line?.category == .waiting }

    static func resolve(turnActive: Bool,
                        lineActivity: BotActivity?,
                        pendingApprovals: Int,
                        fishState: BotFishLifecycle) -> BotHeaderPresence {
        if turnActive, let activity = lineActivity {
            return BotHeaderPresence(
                phase: .working,
                line: activity,
                fishState: workingFish(fishState),
                motion: .lively,
                workStyle: BotActivityPhrases.workStyle(for: activity.category))
        }
        if pendingApprovals > 0 {
            let text = pendingApprovals == 1 ? "" : "\(pendingApprovals) 项等你确认"
            return BotHeaderPresence(
                phase: .waitingForYou,
                line: BotActivity(status: .thinking, detail: text, category: .waiting),
                fishState: fishState,
                motion: .standard,
                workStyle: .generic)
        }
        return BotHeaderPresence(phase: .idle, line: nil, fishState: fishState,
                                 motion: .standard, workStyle: .generic)
    }

    /// Between the send and the host's first event the projection may still
    /// say idle/sleeping; a working header should already look busy.
    private static func workingFish(_ state: BotFishLifecycle) -> BotFishLifecycle {
        switch state {
        case .idle, .sleeping, .standby, .waking, .done:
            return .thinking
        default:
            return state
        }
    }
}

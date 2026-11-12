// SPDX-License-Identifier: MIT

import Foundation

/// How the Bot transcript's rows are mounted inside the scroll view.
///
/// The field loop was in SwiftUI's lazy-placement machinery
/// (`LazySubviewPlacements.updateValue/placeSubviews`): the transcript has
/// content-sized rows, the keyboard and the growing composer change the
/// viewport, and a programmatic bottom scroll is in flight at the same time.
/// The lazy stack keeps re-estimating and re-placing the same rows.
///
/// `eager` (the default) mounts a plain `VStack`, so every loaded row has an
/// exact height and there is no estimate/placement feedback. The loaded window
/// is capped (`BotChatPage.eagerRowLimit`); older loaded rows stay one tap away
/// behind the same "加载更早" affordance, and `hasMoreHistory` still pages from
/// the runtime.
///
/// `lazy` keeps the previous `LazyVStack` so the same build can be A/B sampled
/// by the tester:
///
///     SIMCTL_CHILD_PDSH_BOT_TRANSCRIPT_STACK=lazy \
///       xcrun simctl launch --terminate-running-process <UDID> dev.phone-dsh.probe
///
/// XCUITest can set the same key in `launchEnvironment`.
enum BotTranscriptStackMode: String {
    case eager
    case lazy

    static let current: BotTranscriptStackMode = {
        let raw = ProcessInfo.processInfo.environment["PDSH_BOT_TRANSCRIPT_STACK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let mode = raw.flatMap(BotTranscriptStackMode.init(rawValue:)) ?? .eager
        NSLog("[bot-transcript] stack=%@ (PDSH_BOT_TRANSCRIPT_STACK=%@)",
              mode.rawValue, raw ?? "unset")
        return mode
    }()
}

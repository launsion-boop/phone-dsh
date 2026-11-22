// SPDX-License-Identifier: MIT

import PhoneDSHBot

/// Which pending rows an automatic unit-start replay may dispatch
/// (spec/bot/v1/store.md §10.5, PC-20261122-bot-queued-send-replay).
///
/// Only a `chat` send the user just made is delivered on its own: that is the
/// promise of the queued line (「待发送，引擎就绪后自动发出」). Older rows and other
/// kinds stay retained and never start an unsolicited turn at launch.
enum BotPendingActionReplayWindow {
    /// 15 minutes, measured from the start of the replay pass.
    static let maxAgeMilliseconds: Int64 = 900_000

    static func replayable(_ records: [BotPendingActionRecord], nowMS: Int64) -> [BotUserAction] {
        records.filter { record in
            record.action.kind == .chat && nowMS - record.createdAtMS <= maxAgeMilliseconds
        }.map(\.action)
    }
}

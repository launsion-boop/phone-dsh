// SPDX-License-Identifier: MIT

import Foundation

/// The Bot roster read from `agents-index.json` plus the repaired main-Bot
/// pointer from `runtime-settings.json`.
///
/// `bots` keeps the on-disk insertion order and includes hidden Bots; the
/// sidebar consumes `visibleBots`. The main Bot is a pointer, not a record
/// flag, and `mainBotID` is the value after dangling/empty-pointer repair.
public struct BotRoster: Equatable, Sendable {
    public var bots: [BotProfile]
    public var mainBotID: String?

    public init(bots: [BotProfile], mainBotID: String?) {
        self.bots = bots
        self.mainBotID = mainBotID
    }

    /// The roster in insertion order without Bots the user hid from the
    /// sidebar. The main Bot is included when it is visible.
    public var visibleBots: [BotProfile] {
        bots.filter { !$0.hiddenByUser }
    }
}

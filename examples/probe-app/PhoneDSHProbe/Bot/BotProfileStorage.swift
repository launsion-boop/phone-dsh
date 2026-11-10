// SPDX-License-Identifier: MIT

import Foundation

/// The one App-side location of `agents-index.json` and
/// `runtime-settings.json`. Both the composition root and the fixture checks
/// resolve the profile directory through this value.
enum BotProfileStorage {
    static func directory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("PhoneDSHBot", isDirectory: true)
    }
}

enum BotSelectionDefaults {
    static let key = "phoneDSH.bot.selectedBotID"
}

/// Cross-actor view of the currently selected Bot. The roster model owns the
/// write side; the team host and the unread router read it without hopping to
/// the MainActor.
actor BotSelectionStore {
    private var selected: String?

    init(selected: String? = nil) { self.selected = selected }

    func set(_ botID: String?) { selected = botID }
    func current() -> String? { selected }
}

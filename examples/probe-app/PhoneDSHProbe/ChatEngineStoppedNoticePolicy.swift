// SPDX-License-Identifier: MIT
// The chat page's duplicate "引擎停了" line. When the transcript already shows
// the no-engine empty state (whose own headline and start button say the same
// thing), the top error line is noise; once a conversation is on screen the
// line is the only warning, so it stays.

import Foundation

enum ChatEngineStoppedNoticePolicy {
    /// The engine-stopped failure family `ChatModel` reports: `"引擎停了"` and
    /// `"引擎停了：<cause>"`. Other failures keep their own banner.
    static func isEngineStoppedMessage(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "引擎停了"
            || trimmed.hasPrefix("引擎停了：")
            || trimmed.hasPrefix("引擎停了:")
    }

    /// `engineEmptyStateVisible` is the transcript's case A card: no items and
    /// no started host (starting counts; the card reads 正在启动…).
    static func shouldShow(message: String,
                           engineEmptyStateVisible: Bool) -> Bool {
        !(engineEmptyStateVisible && isEngineStoppedMessage(message))
    }
}

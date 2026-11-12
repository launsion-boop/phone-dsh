// SPDX-License-Identifier: MIT

import Foundation

/// Visibility rule for a durable `ui.notice` row.
///
/// `tone` is a presentation hint (error/denial use the danger style, info is
/// neutral), not a reason to hide the row. The session-epoch continuation
/// notice is an info notice and must render; dropping it by tone leaves the
/// durable row invisible even though the projection is correct (F3).
public enum BotNoticeVisibility {
    public static func isVisible(tone: String?, text: String) -> Bool {
        _ = tone
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

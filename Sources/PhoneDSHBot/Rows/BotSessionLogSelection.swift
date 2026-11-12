// SPDX-License-Identifier: MIT

import Foundation

/// Chooses the session log a row projection reads for the current main-session
/// epoch. The App's `BotProductionEnvironment` keeps an optional log URL for
/// the session it was connected to; after an S6 epoch switch that cached value
/// belongs to the archived session, and using it would keep the chat page on
/// the old history (F3).
public enum BotSessionLogSelection {
    /// - Parameters:
    ///   - sessionID: The current main session.
    ///   - explicit: The URL cached by the environment, if any.
    ///   - latest: Resolver that locates the newest `session.v*.jsonl` for a
    ///     session id.
    public static func logURL(
        sessionID: String,
        explicit: URL?,
        latest: (String) -> URL?
    ) -> URL? {
        // The cache is valid only while it still names this session's own
        // directory. `session.v4.jsonl` lives under
        // `materialized/home/sessions/<sessionID>/`; an explicit URL from a
        // previous epoch has the old id and must be replaced by the current
        // session's newest log.
        guard let explicit else { return latest(sessionID) }
        let parent = explicit.deletingLastPathComponent()
        // A materialized session log has the id as its directory name. A
        // staging/test URL outside `sessions/` is the caller's explicit
        // authority and is kept as-is (the BotE2E production checks stage one
        // such file in a temporary directory).
        let isMaterializedSessionLog =
            parent.deletingLastPathComponent().lastPathComponent == "sessions"
        if !isMaterializedSessionLog || parent.lastPathComponent == sessionID {
            return explicit
        }
        return latest(sessionID)
    }
}

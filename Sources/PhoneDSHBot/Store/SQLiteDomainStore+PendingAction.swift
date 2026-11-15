// SPDX-License-Identifier: MIT

import Foundation

/// Canonical payload codec for `bot_pending_actions`.
///
/// The outbox row is an implementation detail of the store, so this codec is
/// internal: no public wire type is added or changed. It reuses
/// `BotUserAction`'s own `Codable` conformance, which means every kind is
/// replayable (chat text + attachments, card answer ids/value, card dismiss,
/// approval ids/decision/digest, stop-task thread id) and the decoder's
/// existing field rules (no `customText`, no `text` on `cardAnswer`, no
/// attachments outside `chat`) also protect a replayed payload.
enum BotPendingActionCodec {
    static func encode(_ action: BotUserAction) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(action)
    }

    /// Decodes one stored payload. The failure names only the nonce: the
    /// payload holds user text and paths, so it must never be echoed into an
    /// error or a log line.
    static func decode(_ payload: Data, nonce: String) throws -> BotUserAction {
        do {
            return try JSONDecoder().decode(BotUserAction.self, from: payload)
        } catch {
            throw SQLiteDomainStoreError.corrupted(
                "pending action \(nonce) payload is not decodable")
        }
    }
}

/// One pending row with the metadata replay needs (ordering and the attempt
/// budget). The action payload itself stays decoded through the same codec as
/// `pendingActions(botID:)`.
public struct BotPendingActionRecord: Sendable, Equatable {
    public var action: BotUserAction
    public var createdAtMS: Int64
    public var attempts: Int

    public init(action: BotUserAction, createdAtMS: Int64, attempts: Int) {
        self.action = action
        self.createdAtMS = createdAtMS
        self.attempts = attempts
    }
}

extension SQLiteDomainStore {
    /// Persists an action before its remote turn starts.
    ///
    /// The row is written in its own transaction, so a process kill or a hung
    /// transport after this call leaves the action replayable. Recording the
    /// same `(botID, nonce)` twice keeps the original row (created time and
    /// attempt count) instead of resetting it: a retry is not a new action.
    public func recordPendingAction(_ action: BotUserAction, now: Int64? = nil) throws {
        try ensureOpen()
        guard !action.botID.isEmpty, !action.nonce.isEmpty else {
            throw SQLiteDomainStoreError.invalidConfiguration(
                "pending action requires a botID and a nonce")
        }
        let payload = try BotPendingActionCodec.encode(action)
        try withTransaction {
            try database.execute(
                """
                INSERT INTO bot_pending_actions(bot_id, nonce, payload, created_at_ms, attempts)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(bot_id, nonce) DO NOTHING
                """,
                bindings: [
                    .text(action.botID), .text(action.nonce), .blob(payload),
                    .integer(now ?? clock()),
                ])
        }
    }

    /// Pending actions for one Bot in replay order: oldest first, nonce as the
    /// tie-breaker so two rows written in the same millisecond stay stable.
    ///
    /// A row that no longer decodes is `corrupted`; the normal paths only ever
    /// write `BotPendingActionCodec.encode` bytes, so this is real damage and
    /// the caller must leave the row alone rather than guess at it.
    public func pendingActions(botID: String) throws -> [BotUserAction] {
        try pendingActionRecords(botID: botID).map(\.action)
    }

    /// Pending rows plus their metadata, in replay order: oldest first, nonce as
    /// the tie-breaker. A row that no longer decodes is `corrupted`; the normal
    /// paths only ever write `BotPendingActionCodec.encode` bytes, so this is
    /// real damage and the caller must leave the row alone rather than guess.
    public func pendingActionRecords(botID: String) throws -> [BotPendingActionRecord] {
        try ensureOpen()
        let rows = try database.query(
            """
            SELECT nonce, payload, created_at_ms, attempts FROM bot_pending_actions
            WHERE bot_id = ? ORDER BY created_at_ms ASC, nonce ASC
            """,
            bindings: [.text(botID)])
        return try rows.map { row in
            guard let nonce = row["nonce"]?.text, let payload = row["payload"]?.blob,
                  let createdAt = row["created_at_ms"]?.integer,
                  let attempts = row["attempts"]?.integer else {
                throw SQLiteDomainStoreError.corrupted("invalid pending action row")
            }
            let action = try BotPendingActionCodec.decode(payload, nonce: nonce)
            guard action.botID == botID, action.nonce == nonce else {
                throw SQLiteDomainStoreError.corrupted(
                    "pending action \(nonce) does not match its row")
            }
            return BotPendingActionRecord(action: action, createdAtMS: createdAt,
                                          attempts: Int(attempts))
        }
    }

    /// Whether one action key still has a pending row. Used by the dispatcher to
    /// tell "already committed and already cleared" from "committed but the
    /// prompt/cleanup never happened".
    func hasPendingAction(botID: String, nonce: String) throws -> Bool {
        try ensureOpen()
        let rows = try database.query(
            "SELECT 1 AS present FROM bot_pending_actions WHERE bot_id = ? AND nonce = ?",
            bindings: [.text(botID), .text(nonce)])
        return !rows.isEmpty
    }

    /// Deletes one consumed pending action. Returns `false` when the row was
    /// already gone; callers treat both outcomes as "no longer pending".
    @discardableResult
    public func clearPendingAction(botID: String, nonce: String) throws -> Bool {
        try withTransaction {
            try database.execute(
                "DELETE FROM bot_pending_actions WHERE bot_id = ? AND nonce = ?",
                bindings: [.text(botID), .text(nonce)])
            return try database.query("SELECT changes() AS changed")
                .first?["changed"]?.integer == 1
        }
    }

    /// Counts one failed dispatch attempt for a still-pending action and
    /// returns the new count (nil when the row is already gone). The count is
    /// diagnostic and survives reopen; replay does not use it as a hard limit,
    /// because an unplayable action must stay available for a later launch.
    @discardableResult
    public func bumpPendingActionAttempt(botID: String, nonce: String) throws -> Int? {
        try withTransaction {
            try database.execute(
                """
                UPDATE bot_pending_actions SET attempts = attempts + 1
                WHERE bot_id = ? AND nonce = ?
                """,
                bindings: [.text(botID), .text(nonce)])
            return try database.query(
                "SELECT attempts FROM bot_pending_actions WHERE bot_id = ? AND nonce = ?",
                bindings: [.text(botID), .text(nonce)])
                .first?["attempts"]?.integer.map(Int.init)
        }
    }
}

// SPDX-License-Identifier: MIT

import Foundation

extension SQLiteDomainStore {
    public func eventID(botID: String, nonce: String) throws -> String? {
        try ensureOpen()
        return try nonceEventID(botID: botID, nonce: nonce)
    }

    @discardableResult
    public func performAndRecord(
        action: BotUserAction,
        plan: BotUserActionPlan
    ) async throws -> BotActionResult {
        try withTransaction {
            if let eventID = try nonceEventID(botID: action.botID, nonce: action.nonce) {
                return .duplicate(eventID: eventID)
            }
            if let invalid = BotUserActionValidation.validate(action) { return invalid }

            try BotEventEnvelopeCodec.validate(plan.event, mode: .append)
            guard !BotEventEnvelopeCodec.isEphemeral(plan.event.type),
                  plan.event.principal.botId == action.botID else {
                throw SQLiteDomainStoreError.invalidTransition("action event must be durable and belong to the action bot")
            }
            let conflictingEvents = try database.query(
                "SELECT event_id FROM bot_events WHERE event_id = ?",
                bindings: [.text(plan.event.eventId)])
            guard conflictingEvents.isEmpty else {
                throw SQLiteDomainStoreError.invalidTransition("action eventId already exists: \(plan.event.eventId)")
            }

            var effectKeys = Set<String>()
            for effect in plan.effects {
                guard effectKeys.insert(effect.effectKey).inserted else {
                    throw SQLiteDomainStoreError.invalidTransition("duplicate effectKey in action plan: \(effect.effectKey)")
                }
                guard try effectRecord(forKey: effect.effectKey) == nil else {
                    throw SQLiteDomainStoreError.invalidTransition("action effectKey already exists: \(effect.effectKey)")
                }
            }

            let sequence = try insertDurableEvents([plan.event])[0]
            for effect in plan.effects {
                _ = try enqueueEffectInTransaction(effect)
            }
            try database.execute(
                """
                INSERT INTO bot_user_action_nonces(bot_id, nonce, event_id, created_commit_seq)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(action.botID), .text(action.nonce), .text(plan.event.eventId),
                    .integer(Int64(sequence)),
                ])
            try checkCrashPoint("user-action-nonce")
            return .accepted(eventID: plan.event.eventId)
        }
    }

    private func nonceEventID(botID: String, nonce: String) throws -> String? {
        let rows = try database.query(
            """
            SELECT event_id, created_commit_seq FROM bot_user_action_nonces
            WHERE bot_id = ? AND nonce = ?
            """,
            bindings: [.text(botID), .text(nonce)])
        guard let row = rows.first else { return nil }
        guard let eventID = row["event_id"]?.text,
              let createdCommitSeq = row["created_commit_seq"]?.integer else {
            throw SQLiteDomainStoreError.corrupted("invalid bot_user_action_nonces row")
        }
        let events = try database.query(
            "SELECT commit_seq FROM bot_events WHERE event_id = ?", bindings: [.text(eventID)])
        guard events.first?["commit_seq"]?.integer == createdCommitSeq else {
            throw SQLiteDomainStoreError.corrupted("user action nonce does not reference its committed event")
        }
        return eventID
    }
}

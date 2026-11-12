// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

/**
 * The exact P25 schema v3 DDL (`spec/bot/v1/store.md` §3). The statements are
 * split because a trigger body contains `;`; the string content and object
 * names are normative.
 */
public object BotStoreSchema {
    public val V3_STATEMENTS: List<String> = listOf(
        """
        CREATE TABLE IF NOT EXISTS bot_event_headers (
            commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
            event_id TEXT NOT NULL UNIQUE,
            event_type TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            payload_size INTEGER NOT NULL CHECK (payload_size >= 0),
            header_meta BLOB NOT NULL
        )
        """.trimIndent(),
        """
        CREATE TRIGGER IF NOT EXISTS bot_event_headers_reject_update
        BEFORE UPDATE ON bot_event_headers BEGIN
            SELECT RAISE(ABORT, 'bot_event_headers is append-only');
        END
        """.trimIndent(),
        """
        CREATE TRIGGER IF NOT EXISTS bot_event_headers_reject_delete
        BEFORE DELETE ON bot_event_headers BEGIN
            SELECT RAISE(ABORT, 'bot_event_headers is append-only');
        END
        """.trimIndent(),
        """
        CREATE TABLE IF NOT EXISTS bot_event_payloads (
            commit_seq INTEGER PRIMARY KEY REFERENCES bot_event_headers(commit_seq),
            payload BLOB,
            erased_at INTEGER,
            erasure_commit_seq INTEGER REFERENCES bot_event_headers(commit_seq),
            CHECK ((payload IS NULL AND erased_at IS NOT NULL AND erasure_commit_seq IS NOT NULL)
                   OR (payload IS NOT NULL AND erased_at IS NULL AND erasure_commit_seq IS NULL))
        )
        """.trimIndent(),
        """
        CREATE TRIGGER IF NOT EXISTS bot_event_payloads_erase_only
        BEFORE UPDATE ON bot_event_payloads
        WHEN NOT (OLD.payload IS NOT NULL AND NEW.payload IS NULL
                  AND NEW.erased_at IS NOT NULL AND NEW.erasure_commit_seq IS NOT NULL)
        BEGIN
            SELECT RAISE(ABORT, 'bot_event_payloads only supports erasure');
        END
        """.trimIndent(),
        """
        CREATE TRIGGER IF NOT EXISTS bot_event_payloads_reject_delete
        BEFORE DELETE ON bot_event_payloads BEGIN
            SELECT RAISE(ABORT, 'bot_event_payloads rows are never deleted');
        END
        """.trimIndent(),
        """
        CREATE VIEW IF NOT EXISTS bot_events AS
        SELECT h.commit_seq AS commit_seq,
               h.event_id AS event_id,
               h.event_type AS event_type,
               CAST(json_set(
                   h.header_meta,
                   '$.data',
                   CASE WHEN p.payload IS NULL
                        THEN json_object('${'$'}erased', json('true'),
                                         '${'$'}erasureCommitSeq', p.erasure_commit_seq)
                        ELSE json(CAST(p.payload AS TEXT))
                   END
               ) AS BLOB) AS payload
        FROM bot_event_headers AS h
        LEFT JOIN bot_event_payloads AS p ON p.commit_seq = h.commit_seq
        """.trimIndent(),
        """
        CREATE TABLE IF NOT EXISTS bot_effects (
            effect_key TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            operation TEXT NOT NULL,
            target TEXT NOT NULL,
            canonical_resource TEXT NOT NULL,
            args_digest TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            idempotent INTEGER NOT NULL,
            retry_policy TEXT NOT NULL,
            max_attempts INTEGER NOT NULL CHECK (max_attempts > 0),
            generation INTEGER NOT NULL CHECK (generation > 0),
            not_before INTEGER,
            state TEXT NOT NULL,
            attempt INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            enqueued_commit_seq INTEGER,
            lease_owner TEXT,
            lease_expires_at INTEGER,
            started_at INTEGER,
            last_error TEXT,
            error_class TEXT,
            result_ref TEXT,
            applied_at INTEGER,
            reconciliation_reason TEXT,
            updated_at INTEGER NOT NULL
        )
        """.trimIndent(),
        """
        CREATE INDEX IF NOT EXISTS bot_effects_lease_candidates
        ON bot_effects(state, not_before, enqueued_commit_seq, effect_key)
        """.trimIndent(),
        """
        CREATE TABLE IF NOT EXISTS bot_effect_inbox (
            receiver TEXT NOT NULL,
            effect_key TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            attempt INTEGER NOT NULL CHECK (attempt > 0),
            applied_at INTEGER NOT NULL,
            result_ref TEXT,
            PRIMARY KEY(receiver, effect_key, generation)
        )
        """.trimIndent(),
        """
        CREATE INDEX IF NOT EXISTS bot_effect_inbox_lookup
        ON bot_effect_inbox(receiver, effect_key, generation DESC)
        """.trimIndent(),
        """
        CREATE TABLE IF NOT EXISTS bot_user_action_nonces (
            bot_id TEXT NOT NULL,
            nonce TEXT NOT NULL,
            event_id TEXT NOT NULL UNIQUE REFERENCES bot_event_headers(event_id),
            created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
            PRIMARY KEY(bot_id, nonce)
        )
        """.trimIndent(),
    )

    public fun create(driver: BotSqlDriver) {
        for (statement in V3_STATEMENTS) driver.execute(statement)
    }
}

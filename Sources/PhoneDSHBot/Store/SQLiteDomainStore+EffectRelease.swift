// SPDX-License-Identifier: MIT

import Foundation

extension SQLiteDomainStore {
    /// Returns a leased effect whose kind is known but has no registered
    /// executor to `pending` (executor contract, `spec/bot/v1/store.md`
    /// §9.5/§9.7). The lease is cleared; `attempt`, `attempts` and
    /// `generation` are preserved; `not_before` becomes the normal retry
    /// delay for the attempt that was taken. No durable event is written:
    /// the lease's `effect.attempted` event is the only record, because no
    /// effect outcome occurred.
    @discardableResult
    public func release(_ lease: BotEffectLease) async throws -> BotEffectState {
        try withTransaction {
            let rows = try database.query(
                """
                SELECT state, attempt, generation, lease_owner, retry_policy
                FROM bot_effects WHERE effect_key = ?
                """,
                bindings: [.text(lease.effectKey)])
            guard let row = rows.first,
                  let stateText = row["state"]?.text,
                  let state = BotEffectState(rawValue: stateText),
                  let attempt = row["attempt"]?.integer,
                  let generation = row["generation"]?.integer,
                  let policy = row["retry_policy"]?.text else {
                throw SQLiteDomainStoreError.unknownEffect(lease.effectKey)
            }
            guard Int(generation) == lease.generation, Int(attempt) == lease.attempt,
                  row["lease_owner"]?.text == lease.leaseOwner else {
                throw SQLiteDomainStoreError.staleLease(lease.effectKey)
            }
            guard state == .leased else {
                throw SQLiteDomainStoreError.invalidTransition(
                    "effect \(lease.effectKey) is \(state.rawValue), not leased")
            }
            let now = clock()
            let notBefore = now + Self.effectRetryDelayMs(policy: policy, attempt: lease.attempt)
            try database.execute(
                """
                UPDATE bot_effects SET state = 'pending', not_before = ?, last_error = ?,
                    lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
                WHERE effect_key = ?
                """,
                bindings: [
                    .integer(notBefore), .text("no registered executor"), .integer(now),
                    .text(lease.effectKey),
                ])
            return .pending
        }
    }

    /// Same formula as the outbox's `fail` path (`spec/bot/v1/store.md` §9.5).
    /// `SQLiteDomainStoreTests` pins both call sites together.
    static func effectRetryDelayMs(policy: String, attempt: Int) -> Int64 {
        guard policy == "network-idempotent" else { return 0 }
        let exponent = max(0, min(8, attempt - 1))
        return min(Int64(1_000 * (1 << exponent)), 300_000)
    }
}

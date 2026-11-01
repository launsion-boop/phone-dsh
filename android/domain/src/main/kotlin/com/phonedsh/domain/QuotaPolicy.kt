// Per-domain byte quotas: injected policy, absolute, never evicting.
// SPDX-License-Identifier: MIT
//
// spec/v1/budgets.md §5 fixes the *rule* for every quota-managed store: the
// quota is absolute (a handoff or restore never raises it), overflow is an
// explicit failure and data is never silently dropped. That table has no
// DomainStore row — it budgets the WAL, the response log, the journal and
// video/ — so the number here is a policy the composition root passes in, not a
// spec constant. The default exists only so a host that has not decided yet
// still fails closed at a finite bound instead of growing without limit.

package com.phonedsh.domain

/**
 * The absolute byte budget of each domain.
 *
 * A quota is per domain, not per store: filling `memory` must not block a
 * `session` checkpoint. Implementations must return a positive number for every
 * domain, including one that has never been written, so [DomainStore.usageBytes]
 * and [DomainStore.quotaBytes] can always be compared.
 */
fun interface QuotaPolicy {
    /** The absolute quota of [domain] in bytes; must be greater than zero. */
    fun quotaBytes(domain: String): Long

    companion object {
        /**
         * The fallback quota, 64 MiB per domain.
         *
         * This is **not** a spec number: §5 has no DomainStore row. It is a
         * conservative bound for structured records (not media: raw audio and
         * files are kept outside the domain store per the PRD) and it is
         * expected to be replaced by an owner decision. Until then it keeps the
         * "never grow unbounded, never drop silently" rule intact.
         */
        const val DEFAULT_QUOTA_BYTES: Long = 64L * 1024L * 1024L

        /** The same quota for every domain. */
        fun uniform(bytes: Long): QuotaPolicy {
            require(bytes > 0L) { "a domain quota must be positive, was $bytes" }
            return QuotaPolicy { bytes }
        }

        /**
         * [values] overrides for named domains and [defaultBytes] for the rest.
         *
         * Every override must be positive; a zero or negative quota would mean
         * "every write fails", which is a bug at the call site rather than a
         * usable policy.
         */
        fun perDomain(
            values: Map<String, Long>,
            defaultBytes: Long = DEFAULT_QUOTA_BYTES,
        ): QuotaPolicy {
            require(defaultBytes > 0L) { "the default domain quota must be positive, was $defaultBytes" }
            values.forEach { (domain, bytes) ->
                require(domain.isNotBlank()) { "a quota override needs a non-blank domain name" }
                require(bytes > 0L) { "the quota of domain \"$domain\" must be positive, was $bytes" }
            }
            val overrides = HashMap(values)
            return QuotaPolicy { domain -> overrides[domain] ?: defaultBytes }
        }
    }
}

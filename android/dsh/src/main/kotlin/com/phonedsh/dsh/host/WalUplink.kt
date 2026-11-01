// phone-dsh — :dsh / com.phonedsh.dsh.host: the one value that ties wal/1 to its watermark.
// SPDX-License-Identifier: MIT
//
// ---- why this type exists ---------------------------------------------------
// A host HELLO has two members that have to agree: `caps` says whether the host
// speaks `wal/1`, and `next_mseq`/`acked_mseq`/`durable_mseq` say what the WAL
// behind that capability reports. Advertising `wal/1` with a not-wired watermark
// tells the worker to resume a log the host does not have; carrying a real
// watermark without `wal/1` hides an ability the host does have.
//
// [WalUplink] makes both mismatches unrepresentable instead of merely illegal:
//  * [HostHello] no longer takes `caps` and `watermark` as separate arguments;
//    it takes one [WalUplink] and derives both members from it.
//  * [Up] has no capability argument at all — it always names `channel/1` and
//    `wal/1` — and it can only be built from a §4.1-legal `Observed` watermark
//    plus a [VfsSink.Wired] proof. Only a VFS sink that finished recovery can
//    mint that proof, and neither the proof's constructor nor the sink's
//    `open` is public, so code outside `:dsh` cannot construct [Up].
//  * [Down] has no watermark argument at all — it always carries
//    [MseqWatermark.NotWired] and the channel-only capability set.
// A caller therefore cannot spell "wal/1 without a watermark", "a watermark
// without wal/1", or "wal/1 before the VFS sink exists".

package com.phonedsh.dsh.host

/**
 * The WAL half of a host HELLO: the capability and the watermark, as one value.
 *
 * Only the two cases below exist, and each owns both members. See the file
 * comment for why this is a type and not two constructor arguments.
 */
sealed interface WalUplink {
    /** The `caps` member that goes with [watermark]. */
    val capabilities: HostCapabilities

    /** The three mseq numbers that go with [capabilities]. */
    val watermark: MseqWatermark

    /**
     * The WAL is attached, recovery succeeded, the VFS sink is wired and the
     * numbers can be sent.
     *
     * The constructor is private and [of] is the only factory: `wal/1` is
     * added here, never passed in, and the watermark must be a legal §4.1
     * [MseqWatermark.Observed] before this value exists.
     *
     * @property observed the watermark read from the recovered log.
     */
    class Up private constructor(
        val observed: MseqWatermark.Observed,
    ) : WalUplink {
        override val capabilities: HostCapabilities = HostCapabilities(
            setOf(HostCapabilities.CHANNEL, HostCapabilities.WAL),
        )

        override val watermark: MseqWatermark get() = observed

        companion object {
            /**
             * Builds the "WAL is on" value.
             *
             * @throws IllegalArgumentException when [observed] cannot be sent in
             *   a §4.1 HELLO. The facade checks the same rule before calling, so
             *   this is a programming-error guard, not a recovery path.
             */
            internal fun of(observed: MseqWatermark.Observed, @Suppress("UNUSED_PARAMETER") wired: VfsSink.Wired): Up {
                require(observed.satisfiesHelloRules) {
                    "wal/1 requires a §4.1-legal watermark (next_mseq >= 1, " +
                        "next_mseq > acked_mseq, durable_mseq <= acked_mseq); was " +
                        "next_mseq=${observed.nextMseq}, acked_mseq=${observed.ackedMseq}, " +
                        "durable_mseq=${observed.durableMseq}"
                }
                return Up(observed)
            }
        }
    }

    /**
     * The WAL is not attached for this boot: no log was injected, recovery
     * failed, the VFS sink was not wired, or the recovered watermark could not
     * be sent.
     *
     * The capability set is [HostCapabilities.CURRENT] and the watermark is
     * [MseqWatermark.NotWired] by construction; [reason] is the token-free,
     * path-free explanation the facade logs. It is *not* a message to the
     * worker.
     *
     * @property reason why `wal/1` is off, safe to log.
     */
    class Down private constructor(
        val reason: String,
    ) : WalUplink {
        override val capabilities: HostCapabilities = HostCapabilities.CURRENT

        override val watermark: MseqWatermark = MseqWatermark.NotWired

        companion object {
            /** Builds the "WAL is off" value; [reason] must be token-free. */
            internal fun of(reason: String): Down = Down(reason)
        }
    }

    companion object {
        /**
         * The WAL is on, backed by [observed] and a wired [VfsSink].
         *
         * [wired] is a capability proof, not a flag: only [VfsSink] can mint it,
         * and only after a successful recovery. There is no overload without
         * it, so code outside `:dsh` cannot advertise `wal/1` before the VFS
         * sink exists.
         *
         * @throws IllegalArgumentException when [observed] violates §4.1.
         */
        fun up(observed: MseqWatermark.Observed, wired: VfsSink.Wired): Up =
            Up.of(observed, wired)

        /**
         * The WAL is off for [reason]; the HELLO carries no `wal/1` and a
         * not-wired watermark.
         */
        fun down(reason: String): Down = Down.of(reason)
    }
}

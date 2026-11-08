// phone-dsh — :dsh / com.phonedsh.dsh.host: the host HELLO of channel.md §4.1.
// SPDX-License-Identifier: MIT
//
// ---- what this file is, and is not ----------------------------------------
// It is the host side of the handshake: a typed value for the nine members of
// channel.md §4.1 and one call into the single Wire codec (`:core`'s Rust codec
// through JNI). There is no second frame layout, no Kotlin canonical JSON and no
// CRC here; `WireCodec.encode` owns all of that, and the authoritative
// `fields` dialect is `spec/v1/golden/README.md` §1.
//
// ---- provenance, not decoration -------------------------------------------
// Every number in a HELLO has to come from somewhere real. The values that have
// no source yet are visible as such in three places at once: the value itself,
// the KDoc below, and the log line the facade writes when it sends the frame.
//   * `boot_id`      real: [BootId] mints 128 random bits per process boot.
//   * `caps` + `next_mseq` / `acked_mseq` / `durable_mseq`: one [WalUplink]
//                    plus one [ExecCapability]. `wal/1` appears only through
//                    [WalUplink.Up], which also carries the
//                    [MseqWatermark.Observed] recovery produced; `exec/1` and
//                    its `accelerator:*` entries appear only through an
//                    [ExecCapability.Available], which cannot be empty. The
//                    three mseq members have exactly one source, [WalUplink].
//   * `session_epoch`  not wired: no persisted session counter exists yet, so 0
//                    ("no session incarnation has been established").
//   * `fence`        the host is the fence authority; no handoff has ever run, so
//                    the local generation and wal_seq are 0. `owner` is the
//                    constant authority label, validated against §4.1 syntax.
//
// The demo's packaged worker (`worker-entry.js`, `parseHostHello`) requires
// `["channel/1","wal/1","exec/1"]`, `next_mseq >= 1` and
// `next_mseq > acked_mseq`. This host now has a real WAL and a real `phone`
// accelerator behind exec, so those three strings can all be true; that is the
// capability gate, not a promise that a full turn runs (the worker still needs
// a model request and the rest of the demo path).

package com.phonedsh.dsh.host

import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.wire.WireCodec

/**
 * The execution-authority fence a host HELLO carries (§4.1).
 *
 * `owner` is 1–64 characters of `[A-Za-z0-9._:-]`; `generation` and `wal_seq`
 * are non-negative. The host is the fence authority, so a local host that has
 * never handed authority away reports generation 0 and wal_seq 0 — zero here is
 * the statement "no handoff and no WAL epoch has happened", not a guess.
 */
data class HostFence(
    val owner: String,
    val generation: Long,
    val walSeq: Long,
) {
    init {
        require(OWNER_PATTERN.matches(owner)) {
            "fence.owner must match ${OWNER_PATTERN.pattern}, was \"$owner\""
        }
        require(generation >= 0L) { "fence.generation must be non-negative, was $generation" }
        require(walSeq >= 0L) { "fence.wal_seq must be non-negative, was $walSeq" }
    }

    /** The `fence` member of §4.1, in canonical member order. */
    fun toJson(): String =
        "{\"generation\":$generation,\"owner\":${jsonString(owner)},\"wal_seq\":$walSeq}"

    companion object {
        /** channel.md §6 / §4.1: `owner` is `[A-Za-z0-9._:-]{1,64}`. */
        val OWNER_PATTERN: Regex = Regex("[A-Za-z0-9._:-]{1,64}")

        /**
         * The local authority label.
         *
         * It matches the golden `hello-host-1.json` fence owner; the phone is the
         * only authority holder until a handoff exists, so the label is a fact
         * about the topology rather than a device identifier (which would need
         * [com.phonedsh.platform.SecureStore] and does not exist yet).
         */
        const val LOCAL_OWNER: String = "phone"

        /** Generation 0, wal_seq 0: no handoff, no closed WAL epoch. */
        val LOCAL: HostFence = HostFence(owner = LOCAL_OWNER, generation = 0L, walSeq = 0L)
    }
}

/**
 * The host's advertised capabilities (channel.md §4.1 "Capabilities").
 *
 * `channel/1` is mandatory; `wal/1`, `exec/1` and `accelerator:<name>` are the
 * only other strings §4.1 defines ("Other capability strings are reserved"), so
 * this type rejects anything else instead of letting a typo become a capability.
 *
 * [CURRENT] is what the host can *actually* do today:
 *
 * - `channel/1` — the ordered loopback channel really is up: [HostChannel] answers
 *   a worker HELLO with this frame, `:net`'s `LoopbackServer` carries it, and the
 *   Rust codec frames it. Implementation: `HostChannel.onBinary` below,
 *   `android/net/.../loopback/LoopbackServer.kt`, `android/core/.../WireCodec.kt`.
 * - `wal/1` — **conditional**: the facade owns a real
 *   `com.phonedsh.log.WorkspaceLog` behind [HostWal] and a [VfsSink] that
 *   decodes `VFS_MUT`, appends it to that log and answers `VFS_ACK(level = 1)`;
 *   a `VFS_BARRIER(want_level = 2)` is answered only by an epoch close. When
 *   `start()` recovers the log and the recovered watermark satisfies §4.1,
 *   [WalUplink.Up] advertises this capability together with that `Observed`
 *   watermark. No injected log, a failed recovery, an unsendable watermark or a
 *   sink that never opened keeps it absent through [WalUplink.Down]. The
 *   packaged worker also requires `exec/1`, so this capability does not by
 *   itself let a turn run.
 * - `exec/1` — **conditional**: [HostChannel] decodes `0x20 EXEC_REQ`, calls
 *   [com.phonedsh.dsh.exec.ExecBridge.onRequest] and sends every `0x21 EXEC_EVT`
 *   back. The capability itself comes from
 *   [com.phonedsh.dsh.exec.ExecCapability], which has no zero-tool `Available`
 *   value, so `exec/1` can only be advertised when at least one executable tool
 *   was registered. This lane registers `phone` (`phone info`).
 * - `accelerator:*` — **conditional**: one entry per executable tool in
 *   [com.phonedsh.dsh.exec.ExecCapability.Available]. Only the names of
 *   `exec.md` §3 / channel.md §4.1 are accepted; `phone` is the first one this
 *   host really runs, and `ssh` / `scp` appear only when the composition root
 *   registers the native SSH tool.
 *
 * A host that later gains one of the remaining capabilities extends
 * [WalUplink] (for the WAL half) or [ExecCapability] (for the exec half); it
 * never passes a loose string set to [DefaultPhoneDshHost].
 */
data class HostCapabilities(val values: Set<String>) {
    init {
        require(values.isNotEmpty()) { "a host HELLO advertises at least $CHANNEL" }
        require(CHANNEL in values) {
            "a host HELLO must advertise $CHANNEL; channel.md §4.1 requires it"
        }
        for (capability in values) {
            require(isDefined(capability)) {
                "capability \"$capability\" is not defined by channel.md §4.1 " +
                    "(allowed: $CHANNEL, $WAL, $EXEC, accelerator:<name>); other strings are reserved"
            }
        }
    }

    /** The `caps` array in a stable order: the three core caps first, then accelerators. */
    fun toHelloList(): List<String> = buildList {
        for (capability in CORE_ORDER) if (capability in values) add(capability)
        addAll(values.filter { it !in CORE_ORDER }.sorted())
    }

    /** `[channel/1]`, safe to log and to show. */
    fun describe(): String = toHelloList().joinToString(prefix = "[", postfix = "]")

    companion object {
        /** `channel/1`: the ordered channel and the HELLO exchange. */
        const val CHANNEL: String = "channel/1"

        /**
         * `wal/1`: a real WAL and VFS sink are attached and the HELLO carries
         * the watermark.
         *
         * The sink decodes `VFS_MUT`, appends to the WAL and emits
         * `VFS_ACK(level = 1)`; level 2 comes only from an epoch close. The
         * capability is decided by [WalUplink] from recovery plus the sink's
         * `Wired` proof, not from a string a caller passes in.
         */
        const val WAL: String = "wal/1"

        /** `exec/1`: EXEC_REQ is dispatched and answered with EXEC_EVT. */
        const val EXEC: String = "exec/1"

        /** The only accelerator names §4.1 defines (the same set as `ToolSet.ACCELERATORS`). */
        val ACCELERATORS: Set<String> =
            setOf("rg", "jaq", "ts-parse", "ts-query", "phone", "ctx", "ssh", "scp", "adb")

        private val CORE_ORDER: List<String> = listOf(CHANNEL, WAL, EXEC)

        /**
         * The static baseline: the channel only (see the KDoc above).
         *
         * `wal/1` is never added by mutating this set; [WalUplink.Up] builds the
         * two-capability set it owns, and [WalUplink.Down] uses this value.
         */
        val CURRENT: HostCapabilities = HostCapabilities(setOf(CHANNEL))

        private fun isDefined(capability: String): Boolean =
            capability in CORE_ORDER ||
                (capability.startsWith(ACCELERATOR_PREFIX) &&
                    capability.removePrefix(ACCELERATOR_PREFIX) in ACCELERATORS)

        private const val ACCELERATOR_PREFIX = "accelerator:"
    }
}

/**
 * The three mseq watermarks a host HELLO carries (channel.md §4.1, D17).
 *
 * `next_mseq = max(last_mseq, WAL tail) + 1`, `acked_mseq` is the effective tail
 * and `durable_mseq` the `durable_upto` of the last closed epoch, so
 * `durable_mseq <= acked_mseq < next_mseq` holds whenever a log is behind these
 * numbers. [provenance] is logged with every HELLO so a stale or absent watermark
 * is visible in the field, not just in a comment.
 */
sealed interface MseqWatermark {
    /** `max(last_mseq, WAL tail) + 1` (D17); the mseq the first mutation receives. */
    val nextMseq: Long

    /** The effective tail; the highest level-1-acked mseq. */
    val ackedMseq: Long

    /** `durable_upto` of the last closed epoch. */
    val durableMseq: Long

    /** Where the three numbers came from; printed with every HELLO. */
    val provenance: String

    /**
     * `true` when the values satisfy §4.1: `next_mseq >= 1`,
     * `next_mseq > acked_mseq` and `durable_mseq <= acked_mseq`.
     *
     * [NotWired] is `false` on purpose: it says so out loud instead of looking
     * like a valid empty log.
     */
    val satisfiesHelloRules: Boolean
        get() = nextMseq >= MIN_NEXT_MSEQ && nextMseq > ackedMseq && durableMseq <= ackedMseq

    /**
     * A watermark read from a real log.
     *
     * The constructor only rejects negative values; the §4.1 relations are
     * reported through [satisfiesHelloRules] so the wiring can decide `wal/1`
     * without re-deriving them. [WalUplink.Up] refuses a value that does not
     * satisfy them, so a mid-repair watermark never reaches the wire.
     */
    data class Observed(
        override val nextMseq: Long,
        override val ackedMseq: Long,
        override val durableMseq: Long,
    ) : MseqWatermark {
        init {
            require(nextMseq >= 0L) { "next_mseq must be non-negative, was $nextMseq" }
            require(ackedMseq >= 0L) { "acked_mseq must be non-negative, was $ackedMseq" }
            require(durableMseq >= 0L) { "durable_mseq must be non-negative, was $durableMseq" }
        }

        override val provenance: String get() = "mseq-watermark: observed (wal recovery)"
    }

    /**
     * No WAL is attached for this boot.
     *
     * The HELLO therefore carries 0 / 0 / 0 and says `mseq-watermark: not-wired`
     * in the log. [WalUplink.Down] always pairs this with the channel-only
     * capability set; a recovered log replaces it with [Observed] and `wal/1`.
     * It is deliberately *not* a plausible-looking 41/42.
     */
    data object NotWired : MseqWatermark {
        override val nextMseq: Long = 0L
        override val ackedMseq: Long = 0L
        override val durableMseq: Long = 0L
        override val provenance: String = "mseq-watermark: not-wired"
    }

    /**
     * A provably empty log: `last_mseq = 0` and no WAL tail, so the D17 formula
     * gives `next_mseq = 1` and the effective tail is 0.
     *
     * Only correct when nothing has ever been appended to this workspace's WAL,
     * which is why it is not the default. Pass it from the wiring that owns an
     * empty workspace (and replace it with [Observed] as soon as the WAL lane
     * can answer).
     */
    data object EmptyLog : MseqWatermark {
        override val nextMseq: Long = 1L
        override val ackedMseq: Long = 0L
        override val durableMseq: Long = 0L
        override val provenance: String = "mseq-watermark: empty-log (D17 on an empty log)"
    }

    companion object {
        /** §4.1: `next_mseq` is at least 1 (the first mutation gets mseq 1). */
        const val MIN_NEXT_MSEQ: Long = 1L
    }
}

/**
 * A host HELLO as a value, plus its one encoding path.
 *
 * The capability list is derived from two typed lanes: the WAL half comes from
 * [wal] (which also owns the three mseq watermarks), and the exec half comes from
 * [exec]. Neither is a loose string set, so this class cannot hold `wal/1` with a
 * not-wired watermark, nor `exec/1` without an executable accelerator. The
 * watermark has exactly one source, [wal].
 *
 * [encode] goes through [WireCodec], so the bytes are produced by the Rust
 * `pdsh-wire` crate; decoding them with [WireCodec.decode] has to return the same
 * members, which is what the HELLO test asserts.
 */
data class HostHello(
    val bootId: String,
    val sessionEpoch: Long,
    val fence: HostFence,
    val wal: WalUplink,
    /** The `exec/1` contribution; [ExecCapability.Unavailable] contributes nothing. */
    val exec: ExecCapability = ExecCapability.Unavailable,
    /** `channel.md` §4.1: the only protocol version this host speaks. */
    val proto: Int = PROTO,
) {
    init {
        require(BootId.isValid(bootId)) {
            "boot_id must be ${BootId.LENGTH} lowercase hex characters, was \"$bootId\""
        }
        require(sessionEpoch >= 0L) { "session_epoch must be non-negative, was $sessionEpoch" }
        require(proto == PROTO) { "this host speaks proto $PROTO only, was $proto" }
    }

    /** The `caps` member: the WAL lane's set ∪ the exec lane's set. */
    val capabilities: HostCapabilities
        get() = HostCapabilities(wal.capabilities.values + exec.caps())

    /** The three mseq members, derived from [wal] only. */
    val watermark: MseqWatermark get() = wal.watermark

    /** The `caps` array, stable order. */
    val caps: List<String> get() = capabilities.toHelloList()

    /**
     * The `fields` object of §4.1, host variant, in canonical member order.
     *
     * Every member the table marks "host: yes" is present; `last_mseq` is
     * worker-only and is deliberately absent.
     */
    fun fieldsJson(): String = buildString {
        append('{')
        append("\"acked_mseq\":").append(watermark.ackedMseq)
        append(",\"boot_id\":").append(jsonString(bootId))
        append(",\"caps\":[")
        caps.forEachIndexed { index, capability ->
            if (index > 0) append(',')
            append(jsonString(capability))
        }
        append(']')
        append(",\"durable_mseq\":").append(watermark.durableMseq)
        append(",\"fence\":").append(fence.toJson())
        append(",\"next_mseq\":").append(watermark.nextMseq)
        append(",\"proto\":").append(proto)
        append(",\"role\":").append(jsonString(ROLE))
        append(",\"session_epoch\":").append(sessionEpoch)
        append('}')
    }

    /** The frame JSON [WireCodec.encode] takes: a `type` plus the `fields` object. */
    fun frameJson(): String = "{\"type\":\"HELLO\",\"fields\":" + fieldsJson() + '}'

    /**
     * The whole HELLO frame for [seq].
     *
     * @throws com.phonedsh.wire.WireException the codec refused the fields.
     * @throws com.phonedsh.wire.WireUnavailable the JNI library is not packaged;
     *   [HostChannel] catches this and keeps the page alive.
     */
    fun encode(seq: Long = HELLO_SEQ): ByteArray = WireCodec.encode(frameJson(), seq)

    companion object {
        /** channel.md §4.1: `proto` is 1 for this spec version. */
        const val PROTO: Int = 1

        /** `"host"`, §4.1. */
        const val ROLE: String = "host"

        /** HELLO is the first frame of each direction, so its `seq` is 1 (§4.1, §7). */
        const val HELLO_SEQ: Long = 1L
    }
}

/**
 * A JSON string literal for the members this file writes.
 *
 * The values are already constrained (`boot_id` is hex, a fence owner matches
 * `[A-Za-z0-9._:-]+`, capabilities come from a fixed vocabulary), but escaping is
 * still done here so a future caller-supplied string cannot break the object.
 */
private fun jsonString(value: String): String = buildString {
    append('"')
    for (character in value) {
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else ->
                if (character < ' ') {
                    append("\\u00")
                    append(HEX[(character.code ushr 4) and 0x0F])
                    append(HEX[character.code and 0x0F])
                } else {
                    append(character)
                }
        }
    }
    append('"')
}

private const val HEX = "0123456789abcdef"

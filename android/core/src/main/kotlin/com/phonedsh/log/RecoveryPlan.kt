// The facts, records and D11 plan projection of one wal/ directory.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.wire.NativeWal

/**
 * The verified facts of one present `wal/<name>.xlwal`, as `NativeWal.scanSegment`
 * reports them and `NativeWal.planRecovery` consumes them.
 *
 * A torn tail is already excluded from [lastMutationMseq] and reported in
 * [tornTail]; `wal.md` §10 only lets the newest segment be torn.
 */
internal data class SegmentFacts(
    val name: WalSegmentName,
    val headerOk: Boolean,
    val corrupt: Boolean,
    val firstMseq: Long,
    val firstMutationMseq: Long?,
    val lastMutationMseq: Long,
    val epochClose: Long?,
    val tornTail: Truncation?,
) {
    /** `wal.md` §7: a segment is listed when it holds a mutation or a close. */
    val hasRecords: Boolean
        get() = firstMutationMseq != null || epochClose != null

    /** The plan's `wal_dir[]` entry. */
    fun toJson(): JsonObject {
        val members = sortedMapOf<String, JsonValue>()
        members["name"] = JsonString(name.manifestFile)
        members["header_ok"] = JsonBool(headerOk)
        members["corrupt"] = JsonBool(corrupt)
        members["first_mseq"] = JsonNumber(firstMseq.toString())
        members["first_mutation_mseq"] = firstMutationMseq
            ?.let { JsonNumber(it.toString()) } ?: JsonNull
        members["last_mutation_mseq"] = JsonNumber(lastMutationMseq.toString())
        members["epoch_close"] = epochClose?.let { JsonNumber(it.toString()) } ?: JsonNull
        members["torn_tail"] = tornTail?.let { truncation ->
            val entry = sortedMapOf<String, JsonValue>()
            entry["keep_len"] = JsonNumber(truncation.keepLen.toString())
            entry["dropped_bytes"] = JsonNumber(truncation.droppedBytes.toString())
            JsonObject(entry)
        } ?: JsonNull
        return JsonObject(members)
    }

    companion object {
        /**
         * A present segment with no readable header, for the listed-segment
         * half of `wal.md` §10 step 1. The planner then applies the
         * missing-segment rule using the manifest's recorded mseq range.
         */
        fun unreadable(name: WalSegmentName): SegmentFacts = SegmentFacts(
            name = name,
            headerOk = false,
            corrupt = false,
            firstMseq = 0,
            firstMutationMseq = null,
            lastMutationMseq = 0,
            epochClose = null,
            tornTail = null,
        )
    }
}

/**
 * One scan of `wal/`: the facts [RecoveryPlanner] consumes, plus the
 * zero-length files `wal.md` §7.2 lets recovery drop.
 *
 * A zero-length file has no header and no record. It is not a [SegmentFacts]
 * entry unless the manifest lists it (then the listed-missing rule applies);
 * an unlisted one is excluded from the plan and deleted after recovery's
 * manifest write, the "manifest before deletion" order of §7.2.
 *
 * @property facts the present segment files the planner must place.
 * @property zeroLength every present zero-length segment file, in name order.
 */
internal data class WalDirectoryScan(
    val facts: List<SegmentFacts>,
    val zeroLength: List<WalSegmentName>,
)

/** A coded failure inside the plan (`WAL_CORRUPT` or a format diagnostic). */
internal data class WalFailure(val code: String, val detail: String)

/**
 * The `NativeWal.planRecovery` projection of `wal.md` §7.2/D11.
 *
 * Every field is a decision; the I/O is [WorkspaceLog]'s. `stale` is
 * deliberately **not** an unlink list in this implementation: the revised
 * §7.2 retains and re-lists a stale segment, so the only consumer here is the
 * verification report.
 */
internal data class RecoveryPlan(
    val replaySegments: List<WalSegmentName>,
    val truncate: List<Truncation>,
    val dropMissing: List<WalSegmentName>,
    val adopt: List<WalSegmentName>,
    val stale: List<WalSegmentName>,
    val rebuildManifest: Boolean,
    val fullReconcile: Boolean,
    val clearReconcileMarker: Boolean,
    val manifestTailDisagreement: Boolean,
    val effectiveTail: Long,
    val nextMseq: Long,
    val nextEpoch: Int,
    val failure: WalFailure?,
) {
    val ok: Boolean
        get() = failure == null
}

/** Scans one segment file into [SegmentFacts] through the native scanner. */
internal object WalScanner {
    /** `scanSegment` of the whole segment file (header included). */
    fun scan(name: WalSegmentName, bytes: ByteArray): SegmentFacts {
        val context = name.manifestFile
        val value = WalJson.objectOf(WalJson.parse(NativeWal.scanSegment(bytes)), context)
        val tornTail = (value["torn_tail"] as? JsonObject)?.let { tail ->
            Truncation(
                segment = name,
                keepLen = WalJson.long(tail, "keep_len", "$context torn_tail"),
                droppedBytes = WalJson.long(tail, "dropped_bytes", "$context torn_tail"),
            )
        }
        return SegmentFacts(
            name = name,
            headerOk = WalJson.boolean(value, "header_ok", context),
            // `chain_error` is the §3/§4 record-order violation. The streaming
            // replay no longer asks the kernel for the whole record list (that
            // is the P19 OOM), so this verdict is what keeps a hole inside one
            // segment a `WAL_CORRUPT` instead of a replay that silently stops
            // at the gap.
            corrupt = WalJson.boolean(value, "corrupt", context) ||
                value["chain_error"] is JsonObject,
            firstMseq = WalJson.long(value, "first_mseq", context),
            firstMutationMseq = WalJson.optionalLong(value, "first_mutation_mseq", context),
            lastMutationMseq = WalJson.long(value, "last_mutation_mseq", context),
            epochClose = WalJson.optionalLong(value, "epoch_close", context),
            tornTail = tornTail,
        )
    }
}

/** Runs the D11 planner and projects its JSON back into [RecoveryPlan]. */
internal object RecoveryPlanner {
    /**
     * @param facts every present segment's facts, in `<epoch,segment>` order.
     * @param manifestJson the checkpoint's JSON text, or `null` for the
     *   missing-manifest rule (`wal.md` §7.2).
     * @param reconcileMarker whether `reconcile.inprogress` exists.
     */
    fun plan(
        facts: List<SegmentFacts>,
        manifestJson: String?,
        reconcileMarker: Boolean,
    ): RecoveryPlan {
        val input = sortedMapOf<String, JsonValue>()
        input["wal_dir"] = JsonArray(facts.map { it.toJson() })
        input["manifest"] = if (manifestJson == null) {
            JsonNull
        } else {
            JsonValue.parse(manifestJson)
        }
        input["reconcile_marker"] = JsonBool(reconcileMarker)
        val plan = WalJson.objectOf(
            WalJson.parse(NativeWal.planRecovery(JsonObject(input).toJsonText())),
            "recovery plan",
        )
        return RecoveryPlan(
            replaySegments = WalJson.strings(plan, "replay_segments", "recovery plan")
                .map { WalSegmentName.require(it) },
            truncate = WalJson.arrayOf(
                WalJson.member(plan, "truncate", "recovery plan"),
                "recovery plan truncate",
            ).map { value ->
                val entry = WalJson.objectOf(value, "recovery plan truncate")
                Truncation(
                    segment = WalSegmentName.require(WalJson.string(entry, "name", "truncate")),
                    keepLen = WalJson.long(entry, "keep_len", "truncate"),
                    droppedBytes = WalJson.long(entry, "dropped_bytes", "truncate"),
                )
            },
            dropMissing = WalJson.strings(plan, "drop_missing", "recovery plan")
                .map { WalSegmentName.require(it) },
            adopt = WalJson.strings(plan, "adopt", "recovery plan")
                .map { WalSegmentName.require(it) },
            stale = WalJson.strings(plan, "stale", "recovery plan")
                .map { WalSegmentName.require(it) },
            rebuildManifest = WalJson.boolean(plan, "rebuild_manifest", "recovery plan"),
            fullReconcile = WalJson.boolean(plan, "full_reconcile", "recovery plan"),
            clearReconcileMarker = WalJson.boolean(plan, "clear_reconcile_marker", "recovery plan"),
            manifestTailDisagreement = WalJson.boolean(
                plan,
                "manifest_tail_disagreement",
                "recovery plan",
            ),
            effectiveTail = WalJson.long(plan, "effective_tail", "recovery plan"),
            nextMseq = WalJson.long(plan, "next_mseq", "recovery plan"),
            nextEpoch = WalJson.long(plan, "next_epoch", "recovery plan").toInt(),
            failure = (plan["fail"] as? JsonObject)?.let { failure ->
                WalFailure(
                    code = WalJson.string(failure, "code", "recovery plan fail"),
                    detail = WalJson.string(failure, "detail", "recovery plan fail"),
                )
            },
        )
    }

    private fun JsonValue.toJsonText(): String = toJsonString()
}

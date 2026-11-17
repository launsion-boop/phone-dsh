// SPDX-License-Identifier: MIT
// The pure rules of the external admission journal
// (spec/host/v1/external-admission.md sections 1 to 4, revision
// external-admission-v1). No clock, no file, no engine: every function is a
// value in, a value out, so the shared vectors in
// spec/host/v1/fixtures/external-admission-v1.json can be run against exactly
// the code the journal calls.
package com.phonedsh.probe.admission

internal enum class AdmissionDecision { INVALID, DUPLICATE, CONFLICT, CAPACITY, ADMITTED }

internal sealed interface AdmissionRetry {
    /** `dispatching → admitted` with the new attempt count and the earliest next attempt. */
    data class Again(val attempts: Int, val nextAttemptAtMs: Long) : AdmissionRetry

    /** One more attempt would exceed the bound: `dispatching → failed` with `retry_exhausted`. */
    data object Exhausted : AdmissionRetry
}

internal enum class AdmissionSweepAction { KEEP, EXPIRE, UNKNOWN, DELETE }

internal object AdmissionPolicy {
    const val MAX_TEXT_BYTES: Int = 16_384
    const val MIN_TTL_MS: Long = 1_000L
    const val MAX_TTL_MS: Long = 604_800_000L
    const val MAX_PENDING: Int = 256
    const val MAX_ENTRIES: Int = 2_048
    const val MAX_ATTEMPTS: Int = 12
    const val TOMBSTONE_MS: Long = 86_400_000L
    const val LINKED_TIMEOUT_MS: Long = 1_209_600_000L
    const val PASS_LIMIT: Int = 16
    const val RETRY_EXHAUSTED: String = "retry_exhausted"
    const val EXPIRED: String = "expired"

    private const val FIRST_BACKOFF_MS: Long = 3_000L
    private const val MAX_BACKOFF_MS: Long = 300_000L

    // ----------------------------------------------------------------- identity

    /**
     * `lowercase_hex(SHA-256(principal ‖ 0x00 ‖ source.kind ‖ 0x00 ‖ source.id ‖ 0x00 ‖ sourceRequestId))`,
     * all UTF-8. The only dedupe key and the file name.
     */
    fun admissionId(principal: String, source: AdmissionSource, sourceRequestId: String): String {
        val parts = listOf(principal, source.kind.wire, source.id, sourceRequestId)
        val bytes = java.io.ByteArrayOutputStream()
        parts.forEachIndexed { index, part ->
            if (index > 0) bytes.write(0)
            bytes.write(part.toByteArray(Charsets.UTF_8))
        }
        return AdmissionCodec.sha256Hex(bytes.toByteArray())
    }

    /** `lowercase_hex(SHA-256(UTF-8 text))`. */
    fun contentSha256(text: String): String = AdmissionCodec.sha256Hex(text.toByteArray(Charsets.UTF_8))

    // ---------------------------------------------------------------- admission

    /**
     * The record this request would become when admitted at [nowMs], or null
     * when a field breaks the schema, the text is over the UTF-8 byte bound, or
     * the time to live is outside 1 s … 7 days. Null is the `invalid` result.
     */
    fun candidate(request: AdmissionRequest, downstreamId: String, nowMs: Long): AdmissionRecord? {
        val record = AdmissionRecord(
            admissionId = admissionId(request.principal, request.source, request.sourceRequestId),
            principal = request.principal,
            source = request.source,
            sourceRequestId = request.sourceRequestId,
            target = request.target,
            contentSha256 = contentSha256(request.text),
            text = request.text,
            downstreamId = downstreamId,
            admittedAtMs = nowMs,
            expiresAtMs = request.expiresAtMs,
            stage = AdmissionStage.ADMITTED,
            attempts = 0,
        )
        try {
            AdmissionCodec.validate(record)
        } catch (_: AdmissionInvalidRecordException) {
            return null
        }
        if (request.text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) return null
        val ttl = request.expiresAtMs - nowMs
        if (ttl < MIN_TTL_MS || ttl > MAX_TTL_MS) return null
        return record
    }

    /**
     * The decision for a valid [candidate], in the order of the contract table:
     * an [existing] record with this `admissionId` (any stage) is a duplicate
     * when target and content digest are equal and a conflict otherwise; only
     * then capacity. [pendingCount] counts `admitted` and `dispatching` records,
     * [directoryEntries] every entry of the directory of any kind.
     */
    fun decide(
        candidate: AdmissionRecord,
        existing: AdmissionRecord?,
        pendingCount: Int,
        directoryEntries: Int,
    ): AdmissionDecision {
        if (existing != null) {
            val same = existing.target == candidate.target && existing.contentSha256 == candidate.contentSha256
            return if (same) AdmissionDecision.DUPLICATE else AdmissionDecision.CONFLICT
        }
        if (pendingCount >= MAX_PENDING || directoryEntries >= MAX_ENTRIES) return AdmissionDecision.CAPACITY
        return AdmissionDecision.ADMITTED
    }

    // ------------------------------------------------------------------- stages

    /** The ten edges of section 3. No other edge exists and none leaves a terminal stage. */
    fun allows(from: AdmissionStage, to: AdmissionStage): Boolean = when (from) {
        AdmissionStage.ADMITTED -> to == AdmissionStage.DISPATCHING || to == AdmissionStage.EXPIRED ||
            to == AdmissionStage.CANCELLED || to == AdmissionStage.FAILED
        AdmissionStage.DISPATCHING -> to == AdmissionStage.LINKED || to == AdmissionStage.ADMITTED ||
            to == AdmissionStage.FAILED
        AdmissionStage.LINKED -> to == AdmissionStage.COMPLETED || to == AdmissionStage.FAILED ||
            to == AdmissionStage.UNKNOWN
        else -> false
    }

    /**
     * A definite downstream failure after [attempts] earlier ones, seen at
     * [nowMs]: the delay is `min(3000·2^(attempts−1), 300000)` of the new count.
     */
    fun retry(attempts: Int, nowMs: Long): AdmissionRetry {
        val next = attempts + 1
        if (next > MAX_ATTEMPTS) return AdmissionRetry.Exhausted
        val delay = minOf(FIRST_BACKOFF_MS shl (next - 1), MAX_BACKOFF_MS)
        return AdmissionRetry.Again(next, nowMs + delay)
    }

    // -------------------------------------------------------------------- sweep

    fun sweep(record: AdmissionRecord, nowMs: Long): AdmissionSweepAction = when {
        record.stage == AdmissionStage.ADMITTED ->
            if (nowMs >= record.expiresAtMs) AdmissionSweepAction.EXPIRE else AdmissionSweepAction.KEEP
        record.stage == AdmissionStage.LINKED ->
            if (nowMs >= record.admittedAtMs + LINKED_TIMEOUT_MS) AdmissionSweepAction.UNKNOWN else AdmissionSweepAction.KEEP
        record.stage.isTerminal -> {
            // A terminal record always carries settledAtMs; one that somehow does
            // not is kept, never deleted on a guess.
            val settled = record.settledAtMs
            if (settled != null && nowMs >= maxOf(record.expiresAtMs, settled + TOMBSTONE_MS)) {
                AdmissionSweepAction.DELETE
            } else {
                AdmissionSweepAction.KEEP
            }
        }
        else -> AdmissionSweepAction.KEEP
    }

    // ----------------------------------------------------------------- dispatch

    /**
     * The records one pass may dispatch, in order: pending, not an `admitted`
     * record past its expiry, not waiting for a later `nextAttemptAtMs`; FIFO by
     * (`admittedAtMs`, `admissionId`); at most 16. A `dispatching` record is
     * included whatever its expiry: it is resolved by repeating the downstream
     * write, never by expiring it.
     */
    fun dispatchOrder(records: List<AdmissionRecord>, nowMs: Long): List<AdmissionRecord> =
        records
            .filter { it.stage.isPending }
            .filterNot { it.stage == AdmissionStage.ADMITTED && nowMs >= it.expiresAtMs }
            .filter { (it.nextAttemptAtMs ?: 0L) <= nowMs }
            .sortedWith(compareBy<AdmissionRecord> { it.admittedAtMs }.thenBy { it.admissionId })
            .take(PASS_LIMIT)
}

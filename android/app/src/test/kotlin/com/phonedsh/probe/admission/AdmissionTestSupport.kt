// SPDX-License-Identifier: MIT
// Shared support for the external admission tests: the frozen fixture, real
// record files seeded the way an earlier process would have left them, and a
// mutable clock.
package com.phonedsh.probe.admission

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.probe.outbox.DurableFileStore
import com.phonedsh.probe.outbox.HostSpec
import java.io.File

internal object AdmissionSpec {
    const val T0: Long = 1_794_700_000_000L
    const val DAY: Long = 86_400_000L

    val fixture: JsonObject by lazy { HostSpec.obj("spec/host/v1/fixtures/external-admission-v1.json") }
    val schema: JsonObject by lazy { HostSpec.obj("spec/host/v1/schema/admission-record.schema.json") }

    val GOLDENS = listOf(
        "admission-record-admitted.json",
        "admission-record-dispatching-retry.json",
        "admission-record-linked.json",
        "admission-record-completed.json",
        "admission-record-expired-bot.json",
    )

    val VOICE = AdmissionSource(
        AdmissionSourceKind.TONOLINK_VOICE,
        "74818345ab25ec804caef585fbd5dcaffff56f39865de74c295924656a64f262",
    )
    val CLOUD = AdmissionSource(AdmissionSourceKind.CLOUD_TASK, "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a")

    /** A lowercase UUIDv4 that is a pure function of [index], so a test can name the id it expects. */
    fun uuid(index: Int): String = "00000000-0000-4000-8000-%012d".format(index)

    fun request(
        requestId: String = "req-1",
        text: String = "现在几点了？",
        target: AdmissionTarget = AdmissionTarget.DshSession("gb-main"),
        principal: String = "local",
        source: AdmissionSource = VOICE,
        expiresAtMs: Long = T0 + DAY,
        downstreamId: String? = uuid(1),
    ) = AdmissionRequest(principal, source, requestId, target, text, expiresAtMs, downstreamId)

    /** A valid record in [stage] for a request of its own, as the journal itself would have written it. */
    fun recordIn(
        stage: AdmissionStage,
        requestId: String = "seed-${stage.wire}",
        target: AdmissionTarget = AdmissionTarget.DshSession("gb-main"),
        admittedAtMs: Long = T0,
        expiresAtMs: Long = T0 + DAY,
        attempts: Int = 0,
        nextAttemptAtMs: Long? = null,
        downstreamId: String = uuid(7),
        text: String = "run the tests\n",
    ): AdmissionRecord {
        val pending = stage.isPending
        return AdmissionRecord(
            admissionId = AdmissionPolicy.admissionId("local", VOICE, requestId),
            principal = "local",
            source = VOICE,
            sourceRequestId = requestId,
            target = target,
            contentSha256 = AdmissionPolicy.contentSha256(text),
            text = if (pending) text else null,
            downstreamId = downstreamId,
            admittedAtMs = admittedAtMs,
            expiresAtMs = expiresAtMs,
            stage = stage,
            attempts = attempts,
            lastError = if (pending && attempts > 0) "downstream_unavailable" else null,
            nextAttemptAtMs = if (pending) nextAttemptAtMs else null,
            linkedAtMs = if (stage in setOf(AdmissionStage.LINKED, AdmissionStage.COMPLETED, AdmissionStage.UNKNOWN)) {
                admittedAtMs + 900
            } else {
                null
            },
            settledAtMs = if (stage.isTerminal) admittedAtMs + 9_800 else null,
        )
    }
}

internal class TestClock(var now: Long = AdmissionSpec.T0) : () -> Long {
    override fun invoke(): Long = now
}

/** One journal directory under a temporary root, with helpers that write files without the journal. */
internal class AdmissionSandbox(val root: File) {
    val directory: File get() = File(root, "admissions")

    fun journal(clock: () -> Long, files: DurableFileStore = DurableFileStore(), newUuid: (() -> String)? = null) =
        if (newUuid == null) {
            ExternalAdmissionJournal(root, nowMs = clock, files = files)
        } else {
            ExternalAdmissionJournal(root, nowMs = clock, files = files, newUuid = newUuid)
        }

    fun file(admissionId: String): File = File(directory, "$admissionId.json")

    /** Writes [value] as the record file of [admissionId], exactly as given. */
    fun seedRaw(admissionId: String, value: JsonValue): File = seedBytes("$admissionId.json", value.toJsonString())

    fun seed(record: AdmissionRecord): File = seedBytes("${record.admissionId}.json", AdmissionCodec.encode(record))

    fun seedBytes(name: String, text: String): File {
        directory.mkdirs()
        return File(directory, name).apply { writeText(text, Charsets.UTF_8) }
    }

    /** Every file of the directory with its exact bytes, for "nothing changed" assertions. */
    fun snapshot(): Map<String, String> =
        (directory.listFiles() ?: emptyArray()).associate { it.name to it.readText(Charsets.UTF_8) }.toSortedMap()

    fun reset() {
        root.deleteRecursively()
        root.mkdirs()
    }
}

internal fun AdmissionResult.name(): String = when (this) {
    is AdmissionResult.Admitted -> "admitted"
    is AdmissionResult.Duplicate -> "duplicate"
    AdmissionResult.Conflict -> "conflict"
    AdmissionResult.Capacity -> "capacity"
    AdmissionResult.Invalid -> "invalid"
    is AdmissionResult.Storage -> "storage"
}

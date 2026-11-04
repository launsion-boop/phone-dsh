// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `ubuntu.exec` job lane.
// SPDX-License-Identifier: MIT
//
// ---- what this class is -----------------------------------------------------
// The host half of bridge.md §12: it admits a job, writes its record, drives the
// state machine of §12.3, applies §12.7's limits and answers §12.8's status. It
// owns no adapter and no seal; both are seams, because a mock must be able to
// prove the *ordering* a real environment cannot be asked to prove.
//
// ---- the four orderings that are the point of the file ----------------------
// 1. **Seal before contact.** No adapter is reached unless the seal returned
//    [UbuntuSealResult.Sealed] (§12.3 row 5). A seal failure is therefore a job
//    that never ran, and the test asserts the adapter's `startCount` stays 0.
// 2. **Restore before terminal.** Every path out of the window restores, then
//    reads the tripwire, then writes one terminal record holding `seal` and
//    `internalAccessObserved`. `internalAccessObserved` can therefore never
//    describe an open window.
// 3. **Drain record before drain completion.** [beginDrain] persists the move to
//    `reclaiming` *before* [finishDrain] waits, so a status poll taken during the
//    drain can never answer `remote` for a job the host has already abandoned.
//    That is not a nicety: the record is the audit, and a `remote` a host has
//    walked away from is the audit lying (§12.9).
// 4. **Verdict before bytes.** The artifact precheck runs once, at `reclaiming`,
//    and picks the terminal state. A caller therefore learns "the job succeeded
//    but the ingest failed" before any byte moves, and a refusal can never leave
//    half a file behind (§12.7).
//
// ---- recovery, and what it is allowed to claim -----------------------------
// [recover] applies §12.3's boot table: `admitted`/`sealing` were never contacted
// so they are `not_started`; `handingOff` cannot be replayed so it is `unknown`;
// `remote` **stays `remote`** and resumes polling (the adapter is the authority,
// exactly as budgets.md §3 keeps a persisted `Remote`); `reclaiming` resumes its
// idempotent pull. A resumed job re-seals first, and a seal that will not re-form
// fails it with `outcome: unknown` — the command may already have run, so
// `not_started` would be a claim the host cannot support.
//
// ---- what the mock does *not* do -------------------------------------------
// There is no proot, no rootfs, no mount table and no real chmod here. The seal
// is the caller's seam; the "workspace" is a directory under [vfsRoot]; the
// mutation sink stands in for the Worker's VFS sink. Every one of those is named
// as a stand-in in the class that owns it, so no reader mistakes this for the
// real environment.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Clock
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What `ubuntu.exec` answered (bridge.md §12.3's "which refusals create a record"). */
sealed interface UbuntuSubmit {
    /** The job exists; it may already be terminal (an unresolvable env is a job failure). */
    data class Accepted(val job: UbuntuJobRecord) : UbuntuSubmit

    /** Nothing was recorded; [bridgeCode] is the §5 error code the page puts in the envelope. */
    data class Refused(val bridgeCode: String, val message: String) : UbuntuSubmit
}

/** One `ubuntu.fetch` answer (bridge.md §12.8). */
sealed interface UbuntuFetch {
    /**
     * Bytes `[offset, offset + chunk.size)`, at most 512 KiB decoded.
     *
     * [limits] is the JobRef's published bound set: the page needs the declared
     * `fileLimitBytes` and the workspace bucket to refuse an impossible write
     * *before* it moves a byte (a refusal that starts writing is a truncation).
     */
    data class Chunk(
        val jobId: String,
        val name: String,
        val offset: Long,
        val bytes: Long,
        val eof: Boolean,
        val chunk: ByteArray,
        val limits: UbuntuJobLimits,
    ) : UbuntuFetch

    /** A resource refusal; the same shape `artifacts[].refusal` has. */
    data class Refused(
        val jobId: String,
        val name: String,
        val refusal: UbuntuVfsRefusal,
        val limits: UbuntuJobLimits,
    ) : UbuntuFetch

    /** A §5 error the page answers with the error envelope. */
    data class Unavailable(
        val jobId: String,
        val name: String,
        val bridgeCode: String,
        val message: String,
    ) : UbuntuFetch
}

/** One page-side ingest (the reference loop §12.7 describes). */
sealed interface UbuntuIngest {
    /** [mutations] is what the page emitted, in order; [chunks] is what it fetched. */
    data class Ingested(
        val jobId: String,
        val name: String,
        val path: String,
        val bytes: Long,
        val mutations: List<UbuntuMutation>,
        val chunks: Int,
    ) : UbuntuIngest

    /** [refusal] is `channel.md` §4.8's own refusal, not a new vocabulary. */
    data class Refused(val jobId: String, val name: String, val refusal: UbuntuVfsRefusal) : UbuntuIngest

    /** A §5 error; nothing was written. */
    data class Failed(
        val jobId: String,
        val name: String,
        val bridgeCode: String,
        val message: String,
    ) : UbuntuIngest
}

/**
 * Where the page's VFS mutations land.
 *
 * The real page calls the Worker's VFS sink; the mock writes to a directory. The
 * seam exists so an emitted mutation is an event a test can see, not a plan a
 * test has to trust.
 */
fun interface UbuntuMutationSink {
    suspend fun write(path: String, mutation: UbuntuMutation, data: ByteArray)
}

/** The `ubuntu.exec` job lane (bridge.md §12). */
class UbuntuJobLane(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val store: UbuntuJobStore,
    private val adapters: Map<String, UbuntuAdapter>,
    private val seal: UbuntuSeal,
    private val budgets: ControllerBudgets,
    /** The directory `/dsh` maps to; the default artifact path is resolved under it. */
    private val vfsRoot: Path,
    private val sink: UbuntuMutationSink,
    private val workspaceUsedBytes: () -> Long = { 0L },
    private val admissionOpen: () -> Boolean = { true },
    private val availableMemoryBytes: () -> Long? = { null },
    private val snapshotBytes: (workspace: String) -> Long = { workspaceUsedBytes() },
    /**
     * Whether the host recorded memory-pressure evidence after the job's last
     * transition (§12.9).
     *
     * A boot that finds a non-terminal job can say "the process died"; it may say
     * "the system reclaimed it" only when something observed the pressure. A cause
     * is named from evidence, because the audit is testimony.
     */
    private val memoryPressureEvidence: () -> Boolean = { false },
    private val pollIntervalMs: Long = 20L,
    private val stopGraceMillis: Long = budgets.drainDeadlineMillis,
    private val logger: HostLog = HostLog.None,
) {
    private val mutex = Mutex()
    private val jobs = LinkedHashMap<String, UbuntuJobRecord>()
    private val argvs = mutableMapOf<String, List<String>>()
    private val stops = mutableMapOf<String, String>()

    @Volatile
    private var draining = false

    // ---- the three entry points ------------------------------------------

    /**
     * Admits a job and returns its `JobRef` (bridge.md §12.2).
     *
     * One non-terminal job per workspace: a second is `BRIDGE_BUSY` and creates
     * no record, because two guests do not fit the app-process row. That bound
     * is a **resource** fact and stays where it is; the approval gate's
     * *session* scope is a separate axis and never widens it (design §3
     * layer 1's own note: concurrency is not the approval granularity).
     *
     * @param approval the session decision that admitted this job. It is part
     *   of the audit line, so a record with a gate refusal cause must carry it.
     */
    suspend fun submit(
        request: UbuntuExecRequest,
        approval: UbuntuJobApproval? = null,
    ): UbuntuSubmit {
        val answer = mutex.withLock {
            val live = jobs.values.firstOrNull { !it.terminal }
            if (live != null) {
                return@withLock UbuntuSubmit.Refused(
                    BRIDGE_BUSY,
                    "job ${live.jobId} is still ${live.state.wire} for this workspace",
                )
            }
            val adapter = adapters[request.env]
            val now = clock.nowMillis()
            val record = UbuntuJobRecord(
                jobId = "uj-" + UUID.randomUUID().toString().replace("-", ""),
                env = request.env,
                state = UbuntuJobState.ADMITTED,
                seq = 1,
                createdAtMs = now,
                updatedAtMs = now,
                egress = false,
                authorityExited = null,
                argvDigest = digest(request.argv),
                argvLength = request.argv.size,
                cwd = request.cwd,
                workspace = request.workspace,
                limits = UbuntuJobLimits.of(
                    budgets,
                    configuredFileLimitBytes = adapter?.fileLimitBytes ?: UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES,
                    rssLimitBytes = adapter?.rssLimitBytes,
                ),
                label = request.label,
                exitCode = null,
                logTail = "",
                artifacts = emptyList(),
                failure = null,
                internalAccessObserved = null,
                seal = UbuntuSealState.PENDING,
                sealReason = null,
                jobTimeoutMs = request.jobTimeoutMs,
                approval = approval,
            )
            if (!store.save(record)) {
                return@withLock UbuntuSubmit.Refused(BRIDGE_FAILED, "the job record could not be persisted")
            }
            jobs[record.jobId] = record
            argvs[record.jobId] = request.argv
            UbuntuSubmit.Accepted(record)
        }
        if (answer is UbuntuSubmit.Accepted) {
            val jobId = answer.job.jobId
            // Launched outside the lock: the lane takes the same mutex.
            scope.launch { drive(jobId) }
        }
        return answer
    }

    /**
     * Writes one terminal record for a job the approval gate refused.
     *
     * No adapter is contacted and no state is entered: the record is born
     * `failed` with `outcome = not_started`, which is exactly what happened. It
     * still uses the job store's one record shape, because the user's decision
     * ("I declined this session") is testimony the audit must keep — a
     * `ubuntu.status` of this id answers it, and the log line alone would not
     * survive a restart.
     *
     * @param request the command that was asked for.
     * @param failure the gate's failure (`approval_denied` / `approval_unavailable`).
     * @param approval the decision itself.
     * @returns the saved record, or `null` when the store refused the write.
     */
    suspend fun recordRefusal(
        request: UbuntuExecRequest,
        failure: UbuntuJobFailure,
        approval: UbuntuJobApproval,
    ): UbuntuJobRecord? = mutex.withLock {
        val adapter = adapters[request.env]
        val now = clock.nowMillis()
        val record = UbuntuJobRecord(
            jobId = "uj-" + UUID.randomUUID().toString().replace("-", ""),
            env = request.env,
            state = UbuntuJobState.FAILED,
            seq = 1,
            createdAtMs = now,
            updatedAtMs = now,
            egress = false,
            authorityExited = null,
            argvDigest = digest(request.argv),
            argvLength = request.argv.size,
            cwd = request.cwd,
            workspace = request.workspace,
            limits = UbuntuJobLimits.of(
                budgets,
                configuredFileLimitBytes = adapter?.fileLimitBytes ?: UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES,
                rssLimitBytes = adapter?.rssLimitBytes,
            ),
            label = request.label,
            exitCode = null,
            logTail = "",
            artifacts = emptyList(),
            failure = failure,
            internalAccessObserved = null,
            seal = UbuntuSealState.PENDING,
            sealReason = null,
            jobTimeoutMs = request.jobTimeoutMs,
            approval = approval,
        )
        if (!store.save(record)) {
            logger.error("the approval refusal for env ${request.env} could not be persisted")
            return@withLock null
        }
        jobs[record.jobId] = record
        record
    }

    /** The current record, or `null` for a job this process never heard of. */
    suspend fun status(jobId: String): UbuntuJobRecord? = current(jobId)

    /** Every record this process knows, in job-id order. */
    suspend fun jobs(): List<UbuntuJobRecord> = mutex.withLock { jobs.values.sortedBy { it.jobId } }

    // ---- draining --------------------------------------------------------

    /**
     * §12.9's ordering: persist the move to `reclaiming` for every job that is
     * past `handingOff`, *then* ask the adapters to stop.
     *
     * Split from [finishDrain] on purpose. A single `drain()` would leave no
     * moment at which the ordering is observable, and the ordering is the
     * property: after this call returns, no status may answer `remote`.
     */
    suspend fun beginDrain(): List<String> {
        draining = true
        val live = mutex.withLock { jobs.values.filter { !it.terminal }.map { it.jobId } }
        for (jobId in live) {
            val record = current(jobId) ?: continue
            when (record.state) {
                // The lane fails these at its next checkpoint; it holds the seal,
                // so the cancel path is the one that restores it.
                UbuntuJobState.ADMITTED, UbuntuJobState.SEALING ->
                    stops[jobId] = UbuntuCause.HOST_DRAINING

                UbuntuJobState.HANDING_OFF -> {
                    stops[jobId] = UbuntuCause.HOST_DRAINING
                    adapters[record.env]?.stop(jobId)
                }

                UbuntuJobState.REMOTE -> {
                    stops[jobId] = UbuntuCause.HOST_DRAINING
                    move(jobId, UbuntuJobState.RECLAIMING)
                    adapters[record.env]?.stop(jobId)
                }

                UbuntuJobState.RECLAIMING -> {
                    stops[jobId] = UbuntuCause.HOST_DRAINING
                    adapters[record.env]?.stop(jobId)
                }

                else -> Unit
            }
        }
        return live
    }

    /**
     * Waits inside [deadlineMs] for every job to reach a terminal state, then
     * fails whatever is left.
     *
     * A job that never reached an adapter is `admission_closed`/`not_started`; a
     * job whose environment never acknowledged the stop is `provider_timeout` /
     * `outcome: unknown`, because the host cannot claim it stopped a command it
     * cannot observe.
     */
    suspend fun finishDrain(deadlineMs: Long = budgets.drainDeadlineMillis): List<UbuntuJobRecord> {
        val deadlineAt = clock.nowMillis() + deadlineMs
        while (true) {
            for (record in runnable()) {
                if (record.state == UbuntuJobState.ADMITTED || record.state == UbuntuJobState.SEALING) {
                    // A drain that arrives before the adapter did leaves a job that
                    // never ran: `failed`, with the cancel as its cause.
                    terminal(
                        jobId = record.jobId,
                        state = UbuntuJobState.FAILED,
                        failure = UbuntuFailures.cancelledBeforeStart(stopCause(record.jobId)),
                    )
                }
            }
            if (runnable().isEmpty()) break
            if (clock.nowMillis() >= deadlineAt) {
                for (record in runnable()) {
                    terminal(jobId = record.jobId, state = UbuntuJobState.FAILED, failure = UbuntuFailures.drainDeadline())
                }
                break
            }
            delay(DRAIN_POLL_MS)
        }
        return jobs()
    }

    /** [beginDrain] then [finishDrain]; the facade's single call. */
    suspend fun drain(deadlineMs: Long = budgets.drainDeadlineMillis): List<UbuntuJobRecord> {
        beginDrain()
        return finishDrain(deadlineMs)
    }

    /** A page cancel; `false` when there was nothing to stop. */
    suspend fun cancel(jobId: String): Boolean {
        val record = current(jobId) ?: return false
        if (record.terminal) return false
        stops[jobId] = UbuntuCause.PAGE_CANCEL
        return when (record.state) {
            UbuntuJobState.ADMITTED, UbuntuJobState.SEALING -> {
                stops[jobId] = UbuntuCause.PAGE_CANCEL
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.cancelledBeforeStart(UbuntuCause.PAGE_CANCEL)) != null
            }

            UbuntuJobState.HANDING_OFF -> continueStop(record)
            UbuntuJobState.REMOTE -> {
                move(jobId, UbuntuJobState.RECLAIMING)
                continueStop(record)
            }

            UbuntuJobState.RECLAIMING -> continueStop(record)
            else -> false
        }
    }

    // ---- boot ------------------------------------------------------------

    /**
     * Loads every persisted job and applies §12.3's boot table.
     *
     * The seal repair runs first: a process killed inside the window leaves the
     * internal roots at `chmod 000`, and a boot that resumed a job before
     * repairing that would read its own storage as a missing file.
     */
    suspend fun recover(): List<UbuntuJobRecord> {
        seal.repair()
        val loaded = store.loadAll()
        mutex.withLock { loaded.forEach { jobs[it.jobId] = it } }
        // The decisions are returned as they were made, before any resume coroutine
        // can move a record: a caller asking "what did the boot decide" must not
        // race the answer.
        val decisions = mutableListOf<UbuntuJobRecord>()
        for (record in loaded) {
            if (record.terminal) {
                decisions += record
                continue
            }
            when (val disposition = UbuntuJobState.bootDisposition(record.state)) {
                UbuntuBootDisposition.Keep -> {
                    if (!reseal(record)) {
                        decisions += current(record.jobId) ?: record
                        continue
                    }
                    decisions += current(record.jobId) ?: record
                    scope.launch {
                        val adapter = adapters[record.env]
                        if (adapter == null) {
                            terminal(record.jobId, UbuntuJobState.FAILED, UbuntuFailures.envUnavailable(record.env))
                        } else if (current(record.jobId)?.state == UbuntuJobState.REMOTE) {
                            pollUntilExit(record.jobId, adapter)
                        } else {
                            reclaim(record.jobId)
                        }
                    }
                }

                is UbuntuBootDisposition.Fail -> {
                    val cause = if (
                        disposition.outcome == UbuntuOutcome.UNKNOWN && memoryPressureEvidence()
                    ) {
                        UbuntuCause.MEMORY_RECLAIMED
                    } else {
                        disposition.cause
                    }
                    decisions += terminal(
                        jobId = record.jobId,
                        state = UbuntuJobState.FAILED,
                        // The disposition carries the outcome the host can prove:
                        // `not_started` when no adapter was ever contacted, `unknown`
                        // when the command may have run.
                        failure = UbuntuFailures.lost(cause, disposition.outcome),
                    ) ?: record
                }
            }
        }
        return decisions
    }

    // ---- artifact fetch and ingest ---------------------------------------

    /**
     * One `ubuntu.fetch` call: at most [UbuntuJobLimits.FETCH_CHUNK_BYTES]
     * decoded bytes, idempotent per `offset`.
     *
     * Offset 0 is where the resource prechecks run, so a refused artifact is
     * refused before the first byte rather than halfway through.
     */
    suspend fun fetchChunk(jobId: String, name: String, offset: Long = 0L): UbuntuFetch {
        val record = current(jobId)
            ?: return UbuntuFetch.Unavailable(jobId, name, BRIDGE_INVALID_PARAMS, "no job $jobId")
        if (!record.fetchable) {
            return UbuntuFetch.Unavailable(
                jobId,
                name,
                BRIDGE_BUSY,
                "the job is still ${record.state.wire}; there is no manifest to fetch from",
            )
        }
        val artifact = record.artifact(name)
            ?: return UbuntuFetch.Unavailable(jobId, name, BRIDGE_INVALID_PARAMS, "no artifact '$name'")
        artifact.refusal?.let { return UbuntuFetch.Refused(jobId, name, it, record.limits) }
        if (artifact.state == UbuntuArtifactState.MISSING) {
            return UbuntuFetch.Unavailable(
                jobId,
                name,
                BRIDGE_UNAVAILABLE,
                "the environment no longer has '$name'",
            )
        }
        if (offset < 0 || offset > artifact.bytes) {
            return UbuntuFetch.Unavailable(jobId, name, BRIDGE_INVALID_PARAMS, "offset $offset is outside the artifact")
        }
        if (offset == 0L) {
            val limitRefusal = precheckOne(artifact, record.limits)
            if (limitRefusal != null) return UbuntuFetch.Refused(jobId, name, limitRefusal, record.limits)
        }
        val adapter = adapters[record.env]
            ?: return UbuntuFetch.Unavailable(jobId, name, BRIDGE_UNAVAILABLE, "no adapter for '${record.env}'")
        val length = minOf(UbuntuJobLimits.FETCH_CHUNK_BYTES, artifact.bytes - offset).toInt()
        val chunk = adapter.readArtifact(jobId, name, offset, length)
        if (chunk == null) {
            update(jobId) { it.withArtifact(name) { artifactRecord -> artifactRecord.copy(state = UbuntuArtifactState.MISSING) } }
            return UbuntuFetch.Unavailable(jobId, name, BRIDGE_UNAVAILABLE, "the environment no longer has '$name'")
        }
        return UbuntuFetch.Chunk(jobId, name, offset, artifact.bytes, chunk.eof, chunk.bytes, record.limits)
    }

    /**
     * The page-side reference loop of §12.7: fetch in 512 KiB chunks, emit one
     * mutation per [UbuntuArtifactIngest.plan] entry.
     *
     * A refusal is returned before the file is opened, and the artifact's
     * recorded refusal is the same object the status reports.
     */
    suspend fun ingest(jobId: String, name: String, path: String? = null): UbuntuIngest {
        val record = current(jobId)
            ?: return UbuntuIngest.Failed(jobId, name, BRIDGE_INVALID_PARAMS, "no job $jobId")
        if (!record.fetchable) {
            return UbuntuIngest.Failed(
                jobId,
                name,
                BRIDGE_BUSY,
                "the job is still ${record.state.wire}; there is no manifest to fetch from",
            )
        }
        val artifact = record.artifact(name)
            ?: return UbuntuIngest.Failed(jobId, name, BRIDGE_INVALID_PARAMS, "no artifact '$name'")
        val target = path ?: defaultPath(jobId, name)
        if (!UbuntuArtifactIngest.isMutationPath(target)) {
            return UbuntuIngest.Failed(jobId, name, BRIDGE_INVALID_PARAMS, "'$target' is not a mutation path")
        }
        val owned = record.artifacts.any { it.path == target }
        if (!owned && Files.exists(vfsFile(target))) {
            return UbuntuIngest.Failed(
                jobId,
                name,
                BRIDGE_INVALID_PARAMS,
                "'$target' exists and was not written by this job",
            )
        }
        // The precheck at offset 0 is the only place a refusal can come from, and
        // it runs before anything is written.
        val first = fetchChunk(jobId, name, 0L)
        if (first is UbuntuFetch.Refused) {
            reviseToIngestRefused(jobId, name, first.refusal)
            return UbuntuIngest.Refused(jobId, name, first.refusal)
        }
        if (first is UbuntuFetch.Unavailable) {
            return UbuntuIngest.Failed(jobId, name, first.bridgeCode, first.message)
        }
        val mutations = UbuntuArtifactIngest.plan(artifact.bytes)
        var offset = 0L
        var chunks = 0
        for (mutation in mutations) {
            val data = ByteArrayOutputStream(mutation.length.toInt())
            while (data.size().toLong() < mutation.length) {
                val answer = fetchChunk(jobId, name, offset)
                when (answer) {
                    is UbuntuFetch.Chunk -> {
                        data.write(answer.chunk)
                        offset += answer.chunk.size
                        chunks += 1
                    }

                    is UbuntuFetch.Refused -> {
                        reviseToIngestRefused(jobId, name, answer.refusal)
                        return UbuntuIngest.Refused(jobId, name, answer.refusal)
                    }

                    is UbuntuFetch.Unavailable ->
                        return UbuntuIngest.Failed(jobId, name, answer.bridgeCode, answer.message)
                }
            }
            sink.write(target, mutation, data.toByteArray())
        }
        val size = try {
            Files.size(vfsFile(target))
        } catch (failure: IOException) {
            logger.error("artifact '$name' of ${jobId} is not on disk after the write")
            return UbuntuIngest.Failed(jobId, name, BRIDGE_FAILED, "the artifact is not on disk after the write")
        }
        if (size != artifact.bytes) {
            update(jobId) { it.withArtifact(name) { entry -> entry.copy(state = UbuntuArtifactState.PARTIAL, path = target) } }
            return UbuntuIngest.Failed(
                jobId,
                name,
                BRIDGE_FAILED,
                "wrote $size of ${artifact.bytes} bytes",
            )
        }
        update(jobId) {
            it.withArtifact(name) { entry ->
                entry.copy(state = UbuntuArtifactState.INGESTED, path = target)
            }
        }
        return UbuntuIngest.Ingested(jobId, name, target, size, mutations, chunks)
    }

    // ---- the state machine -----------------------------------------------

    private suspend fun drive(jobId: String) {
        try {
            val job = current(jobId) ?: return
            val adapter = adapters[job.env]
            if (adapter == null) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.envUnavailable(job.env))
                return
            }
            if (stops[jobId] != null) {
                // Nothing has reached an adapter yet, so this is a job that never
                // started, and its state says so.
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.cancelledBeforeStart(stopCause(jobId)))
                return
            }
            if (draining || !admissionOpen()) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.admissionClosed())
                return
            }
            val snapshot = snapshotBytes(job.workspace)
            if (snapshot > budgets.tmpBytes) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.snapshotTooLarge(snapshot, budgets.tmpBytes))
                return
            }
            val rss = job.limits.rssLimitBytes ?: budgets.appProcessBytes
            availableMemoryBytes()?.let { available ->
                if (available < rss) {
                    terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.memoryInsufficient(available, rss))
                    return
                }
            }
            if (!move(jobId, UbuntuJobState.SEALING)) return
            when (val sealed = seal.seal(jobId)) {
                is UbuntuSealResult.Failed -> {
                    // Fail-closed: the adapter is never contacted, and the seal's
                    // own rollback is the only cleanup left to attempt.
                    seal.restore(jobId)
                    update(jobId) {
                        it.copy(
                            seal = UbuntuSealState.FAILED,
                            sealReason = sealed.reason,
                            updatedAtMs = clock.nowMillis(),
                        )
                    }
                    terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.sealFailed(sealed.reason))
                    return
                }

                UbuntuSealResult.Sealed ->
                    update(jobId) {
                        it.copy(seal = UbuntuSealState.SEALED, sealReason = null, updatedAtMs = clock.nowMillis())
                    }
            }
            if (stops[jobId] != null) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.cancelledBeforeStart(stopCause(jobId)))
                return
            }
            if (draining || !admissionOpen()) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.admissionClosed())
                return
            }
            if (current(jobId)?.terminal == true) return
            if (!move(jobId, UbuntuJobState.HANDING_OFF)) return
            when (val ack = adapter.start(jobId, argvs[jobId] ?: emptyList(), job.cwd)) {
                is UbuntuStartAck.Refused -> {
                    terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.adapterRefused(ack.reason))
                    return
                }

                UbuntuStartAck.Accepted -> Unit
            }
            if (current(jobId)?.terminal == true) return
            if (!move(jobId, UbuntuJobState.REMOTE) { it.copy(egress = adapter.egress, authorityExited = adapter.authorityExited) }) {
                return
            }
            pollUntilExit(jobId, adapter)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            logger.error("job $jobId lane stopped on ${failure.javaClass.simpleName}")
            terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.lost(UbuntuCause.HOST_LOST))
        } finally {
            argvs.remove(jobId)
        }
    }

    private suspend fun pollUntilExit(jobId: String, adapter: UbuntuAdapter) {
        val startedAtMs = current(jobId)?.createdAtMs ?: clock.nowMillis()
        while (true) {
            val record = current(jobId) ?: return
            if (record.terminal) return
            when (val status = adapter.poll(jobId)) {
                is UbuntuAdapterStatus.Running -> {
                    if (status.logTail.isNotEmpty()) {
                        update(jobId) {
                            it.copy(
                                logTail = UbuntuArtifactIngest.tail(status.logTail),
                                updatedAtMs = clock.nowMillis(),
                            )
                        }
                    }
                    val elapsed = clock.nowMillis() - startedAtMs
                    if (stops[jobId] == null && elapsed >= record.jobTimeoutMs) {
                        requestStop(jobId, UbuntuCause.JOB_TIMEOUT, adapter)
                    } else if (stops[jobId] != null && elapsed >= record.jobTimeoutMs + stopGraceMillis) {
                        // The environment never reported an exit, so the host does
                        // not know whether the command ran: `unknown`, not `lost`.
                        terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.jobTimeout())
                        return
                    }
                    delay(pollIntervalMs)
                }

                is UbuntuAdapterStatus.Exited -> {
                    observeExit(jobId, status)
                    return
                }

                UbuntuAdapterStatus.Gone -> {
                    terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.adapterGone())
                    return
                }

                is UbuntuAdapterStatus.Failed ->
                    terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.adapterFailed(status.reason))
            }
            if (current(jobId)?.terminal == true) return
        }
    }

    private suspend fun observeExit(jobId: String, status: UbuntuAdapterStatus.Exited) {
        if (status.artifacts.size > MANIFEST_MAX_ENTRIES) {
            // §12.7: a manifest over the bound is refused, never truncated — a
            // shortened manifest is a wrong one.
            terminal(
                jobId,
                UbuntuJobState.FAILED,
                UbuntuFailures.adapterFailed("${status.artifacts.size} artifacts"),
            )
            return
        }
        val artifacts = status.artifacts.map { line ->
            UbuntuArtifactRecord(
                name = line.name,
                bytes = line.bytes,
                sha256 = line.sha256,
                state = UbuntuArtifactState.AVAILABLE,
            )
        }
        val tail = UbuntuArtifactIngest.tail(status.logTail)
        update(jobId) { record ->
            val withExit = record.copy(
                exitCode = status.exitCode,
                logTail = tail,
                artifacts = artifacts,
                updatedAtMs = clock.nowMillis(),
            )
            when {
                record.state == UbuntuJobState.RECLAIMING -> withExit.copy(seq = record.seq + 1)
                UbuntuJobState.canMove(record.state, UbuntuJobState.RECLAIMING) ->
                    withExit.copy(state = UbuntuJobState.RECLAIMING, seq = record.seq + 1)

                else -> {
                    logger.error("job $jobId: ${record.state.wire} cannot reclaim an observed exit")
                    record
                }
            }
        }
        reclaim(jobId)
    }

    private suspend fun reclaim(jobId: String) {
        val record = current(jobId) ?: return
        if (record.state != UbuntuJobState.RECLAIMING) return
        if (record.exitCode == null) {
            // A drain moved the record to `reclaiming` before the exit arrived (or a
            // boot found it there). The exit is still the adapter's to report, so go
            // back and observe it rather than inventing one.
            val adapter = adapters[record.env]
            if (adapter == null) {
                terminal(jobId, UbuntuJobState.FAILED, UbuntuFailures.envUnavailable(record.env))
                return
            }
            pollUntilExit(jobId, adapter)
            return
        }
        val stop = stops[jobId]
        if (stop == UbuntuCause.HOST_DRAINING || stop == UbuntuCause.PAGE_CANCEL) {
            // The command ran and was stopped, so the outcome is `cancelled` and the
            // observed exit code is still recorded.
            terminal(jobId, UbuntuJobState.CANCELLED, UbuntuFailures.cancelled(stop))
            return
        }
        val prechecked = UbuntuArtifactIngest.precheck(record.artifacts, record.limits, workspaceUsedBytes())
        val refused = prechecked.any { it.state == UbuntuArtifactState.REFUSED }
        terminal(
            jobId = jobId,
            state = if (refused) UbuntuJobState.INGEST_REFUSED else UbuntuJobState.SUCCEEDED,
            failure = null,
            artifacts = prechecked,
        )
    }

    // ---- record writes ---------------------------------------------------

    private suspend fun current(jobId: String): UbuntuJobRecord? = mutex.withLock {
        jobs[jobId] ?: store.load(jobId)?.also { jobs[it.jobId] = it }
    }

    private suspend fun runnable(): List<UbuntuJobRecord> =
        mutex.withLock { jobs.values.filter { !it.terminal } }

    private suspend fun move(
        jobId: String,
        target: UbuntuJobState,
        transform: (UbuntuJobRecord) -> UbuntuJobRecord = { it },
    ): Boolean {
        var moved = false
        update(jobId) { record ->
            if (!UbuntuJobState.canMove(record.state, target)) {
                logger.error("job $jobId: ${record.state.wire} -> ${target.wire} has no edge in bridge.md §12.3")
                record
            } else {
                moved = true
                transform(record).copy(
                    state = target,
                    seq = record.seq + 1,
                    updatedAtMs = clock.nowMillis(),
                )
            }
        }
        return moved
    }

    /**
     * Closes the window and writes one terminal record.
     *
     * The restore happens *before* the record is written and the tripwire is read
     * between them, so the written `internalAccessObserved` always describes a
     * window that is already closed (§12.8).
     */
    private suspend fun terminal(
        jobId: String,
        state: UbuntuJobState,
        failure: UbuntuJobFailure?,
        artifacts: List<UbuntuArtifactRecord>? = null,
    ): UbuntuJobRecord? {
        val before = current(jobId) ?: return null
        var sealState = before.seal
        var sealReason = before.sealReason
        var observed = before.internalAccessObserved
        if (before.seal == UbuntuSealState.SEALED) {
            when (val restored = seal.restore(jobId)) {
                UbuntuSealResult.Sealed -> {
                    sealState = UbuntuSealState.RESTORED
                    sealReason = null
                    observed = seal.observed(jobId)
                }

                is UbuntuSealResult.Failed -> {
                    // The job's outcome stands — an exit code is a fact — while
                    // `seal` says the workspace is not protected (§12.8).
                    sealState = UbuntuSealState.FAILED
                    sealReason = restored.reason
                    observed = null
                }
            }
        }
        if (before.state == state) return before
        if (!UbuntuJobState.canMove(before.state, state)) {
            logger.error("job $jobId: ${before.state.wire} -> ${state.wire} has no edge in bridge.md §12.3")
            return before
        }
        return update(jobId) { record ->
            record.copy(
                state = state,
                failure = failure,
                artifacts = artifacts ?: record.artifacts,
                seal = sealState,
                sealReason = sealReason,
                internalAccessObserved = observed,
                seq = record.seq + 1,
                updatedAtMs = clock.nowMillis(),
            )
        }
    }

    private suspend fun update(
        jobId: String,
        transform: (UbuntuJobRecord) -> UbuntuJobRecord,
    ): UbuntuJobRecord? = mutex.withLock {
        val current = jobs[jobId] ?: store.load(jobId)?.also { jobs[jobId] = it } ?: return@withLock null
        val next = transform(current)
        if (next === current) return@withLock current
        if (!store.save(next)) {
            // The durable record is the answer; an in-memory move the disk does
            // not have would be a status the next boot contradicts.
            logger.error("job $jobId could not be persisted; keeping the previous record")
            return@withLock current
        }
        jobs[jobId] = next
        next
    }

    // ---- small helpers ---------------------------------------------------

    private suspend fun requestStop(jobId: String, cause: String, adapter: UbuntuAdapter) {
        stops[jobId] = cause
        adapter.stop(jobId)
    }

    private suspend fun continueStop(record: UbuntuJobRecord): Boolean = adapters[record.env]?.stop(record.jobId) ?: false

    private suspend fun reseal(record: UbuntuJobRecord): Boolean {
        if (record.seal != UbuntuSealState.SEALED) return true
        return when (val sealed = seal.seal(record.jobId)) {
            UbuntuSealResult.Sealed -> {
                update(record.jobId) { it.copy(seal = UbuntuSealState.SEALED, sealReason = null, updatedAtMs = clock.nowMillis()) }
                true
            }

            is UbuntuSealResult.Failed -> {
                terminal(record.jobId, UbuntuJobState.FAILED, UbuntuFailures.sealLost(sealed.reason))
                false
            }
        }
    }

    private fun stopCause(jobId: String): String = stops[jobId] ?: UbuntuCause.PAGE_CANCEL

    /**
     * §12.3 row 15: a fetch refused after the job already reported `succeeded`.
     *
     * Only a resource refusal revises the record, only from `succeeded`, and only
     * once — the point is that the record stops being wrong, not that a terminal
     * state becomes provisional.
     */
    private suspend fun reviseToIngestRefused(jobId: String, name: String, refusal: UbuntuVfsRefusal) {
        update(jobId) { record ->
            val entry = record.artifact(name)
            if (entry == null || entry.state != UbuntuArtifactState.AVAILABLE) {
                record
            } else {
                val marked = record.withArtifact(name) { it.copy(state = UbuntuArtifactState.REFUSED, refusal = refusal) }
                if (record.state == UbuntuJobState.SUCCEEDED) {
                    marked.copy(state = UbuntuJobState.INGEST_REFUSED)
                } else {
                    marked
                }
            }
        }
    }

    private fun precheckOne(artifact: UbuntuArtifactRecord, limits: UbuntuJobLimits): UbuntuVfsRefusal? {
        if (artifact.bytes > limits.fileLimitBytes) {
            return UbuntuVfsRefusal(UbuntuVfsRefusal.FILE_TOO_LARGE, limits.fileLimitBytes, artifact.bytes)
        }
        val used = workspaceUsedBytes()
        if (used + artifact.bytes > limits.workspaceLimitBytes) {
            return UbuntuVfsRefusal(UbuntuVfsRefusal.QUOTA_EXCEEDED, limits.workspaceLimitBytes, artifact.bytes)
        }
        return null
    }

    private fun defaultPath(jobId: String, name: String): String = "/dsh/workspace/$ARTIFACT_DIR/$jobId/$name"

    private fun vfsFile(path: String): Path = vfsRoot.resolve(path.removePrefix("/dsh/"))

    private fun UbuntuJobRecord.withArtifact(
        name: String,
        transform: (UbuntuArtifactRecord) -> UbuntuArtifactRecord,
    ): UbuntuJobRecord = copy(
        artifacts = artifacts.map { if (it.name == name) transform(it) else it },
        seq = seq + 1,
        updatedAtMs = clock.nowMillis(),
    )

    companion object {
        /** bridge.md §5's codes the lane may answer with; the enum is closed. */
        const val BRIDGE_BUSY = "BRIDGE_BUSY"
        const val BRIDGE_FAILED = "BRIDGE_FAILED"
        const val BRIDGE_INVALID_PARAMS = "BRIDGE_INVALID_PARAMS"
        const val BRIDGE_UNAVAILABLE = "BRIDGE_UNAVAILABLE"

        /** The directory the default artifact path lands in. */
        const val ARTIFACT_DIR = ".ubuntu"

        /** §12.7's manifest bound: more entries are refused, never truncated. */
        const val MANIFEST_MAX_ENTRIES = 32

        private const val DRAIN_POLL_MS = 5L

        init {
            // §12.7's two bounds must nest: a 512 KiB fetch chunk never crosses a
            // 15 MiB mutation boundary, which is why [ingest] needs no carry
            // buffer and why every mutation is exactly filled.
            require(UbuntuJobLimits.MUTATION_MAX_BYTES % UbuntuJobLimits.FETCH_CHUNK_BYTES == 0L) {
                "the fetch chunk must divide the mutation bound"
            }
        }

        /** The sha256 of the canonical JSON `argv` (channel.md §5), lowercase hex. */
        fun digest(argv: List<String>): String {
            val canonical = argv.joinToString(prefix = "[", postfix = "]", separator = ",") { canonicalString(it) }
            val bytes = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8))
            return bytes.joinToString("") { "%02x".format(it) }
        }

        private fun canonicalString(value: String): String = buildString {
            append('"')
            for (character in value) {
                when {
                    character == '"' -> append("\\\"")
                    character == '\\' -> append("\\\\")
                    character == '\b' -> append("\\b")
                    character == '\u000C' -> append("\\f")
                    character == '\n' -> append("\\n")
                    character == '\r' -> append("\\r")
                    character == '\t' -> append("\\t")
                    character < ' ' -> append("\\u%04x".format(character.code))
                    else -> append(character)
                }
            }
            append('"')
        }
    }
}

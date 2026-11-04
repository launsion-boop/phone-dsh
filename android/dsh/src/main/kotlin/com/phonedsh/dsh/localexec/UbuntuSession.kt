// phone-dsh — :dsh / com.phonedsh.dsh.localexec: one environment session, mock or real.
// SPDX-License-Identifier: MIT
//
// ---- why this seam exists ------------------------------------------------
// `ubuntu.exec` is not the environment: the lane owns the state machine and the
// audit, the adapter owns start/poll/stop/readArtifact, and a session is the
// object that binds one adapter to one durable job store and one seal. Until
// this file existed the only session was [MockUbuntuSession], built inside
// [UbuntuHostTool] with no injection point, so the production path could not
// name a real backend even when one was linked.
//
// The interface is deliberately small: the host tool needs `env`, `backend`,
// `sealIsMock`, availability, submission, status, the bounded terminal wait and
// close. It never needs the adapter type, so `:dsh` does not depend on
// `:platform-android` and the real adapter can live in the composition root.
//
// ---- backend is a session fact, never a constant -------------------------
// `backend` is the same string the Worker's probe answer and every status
// payload carry (`mock`, `proot`). It is not a protocol field: bridge.md §12
// already renders it as an unconstrained string. The host tool copies the
// session's value into every payload, so a real session can never answer
// `backend=mock` and a mock session can never be mistaken for a real one.
//
// ---- the store and the seal are injected ---------------------------------
// The mock keeps its per-process temp store and [MockUbuntuSeal]; the real
// composition root passes a durable job directory, [AndroidDurability] and the
// real `BuildSealUbuntu` adapter. None of that is chosen here.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import java.nio.file.Path
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/** One environment session (bridge.md §12.1's `env`, plus its backend name). */
interface UbuntuSession {
    /** The adapter's registry key; the job's `env` member. */
    val env: String

    /** The backend name every answer carries: `mock` or `proot`. */
    val backend: String

    /** `true` while the lane's seal is the mock one; see [UbuntuHostTool]. */
    val sealIsMock: Boolean

    /** `false` when the environment's binaries are absent or not executable. */
    val available: Boolean

    /** Why [available] is false, or `null` when it is true. */
    val unavailableReason: String?

    /** The lane, recovering this session's store on first use. */
    suspend fun lane(): UbuntuJobLane

    /** Submits one job (bridge.md §12.2). */
    suspend fun submit(request: UbuntuExecRequest, approval: UbuntuJobApproval? = null): UbuntuSubmit

    /** The current record, or `null` for a job this session never knew. */
    suspend fun status(jobId: String): UbuntuJobRecord?

    /** Waits for a terminal record, bounded; the last record otherwise. */
    suspend fun awaitTerminal(jobId: String, timeoutMs: Long): UbuntuJobRecord?

    /** Stops every non-terminal job and the adapter handles; returns the job ids. */
    suspend fun close(): List<String>
}

/**
 * The construction seam [UbuntuHostTool] and [com.phonedsh.dsh.host.HostExec] use.
 *
 * A plain class rather than a `fun interface`: the probe must be able to name
 * the backend before a session has been constructed (a construction failure is
 * still an answer about this build), so the backend is a property of the
 * factory. The factory body is cheap for both implementations: the real one
 * opens no file and downloads nothing until the first `run`.
 */
class UbuntuSessionFactory(
    /** The backend name a failed construction still reports. */
    val backend: String,
    private val newSession: () -> UbuntuSession,
) {
    fun create(): UbuntuSession = newSession()
}

/**
 * A lane-owning session over an injected adapter, store and seal.
 *
 * This is the production implementation; [MockUbuntuSession] is the same wiring
 * with mock defaults, and `ProotUbuntuSession` in `:app` is the real adapter's
 * facade. Keeping the lane wiring here (rather than in `:app`) is what lets the
 * JVM suite exercise the exact ordering the production path uses.
 *
 * @param adapter the environment; never null and never swapped after close.
 * @param seal the seal each job runs inside.
 * @param backend the honest backend name for every payload.
 * @param storeRoot the durable job-record directory.
 * @param durability the atomic-replace order for those records.
 * @param available whether the environment can start a command; a probe answer
 *   that says `false` must not register the Worker command.
 * @param unavailableReason the token the probe reports when [available] is false.
 */
open class HostUbuntuSession(
    private val clock: Clock,
    private val budgets: ControllerBudgets = ControllerBudgets.forTier(ControllerBudgets.DEFAULT_TIER),
    private val logger: HostLog = HostLog.None,
    private val adapter: UbuntuAdapter,
    private val seal: UbuntuSeal,
    override val backend: String,
    private val admissionOpen: () -> Boolean = { true },
    private val storeRoot: Path,
    private val durability: Durability,
    override val available: Boolean = true,
    override val unavailableReason: String? = null,
) : UbuntuSession {
    init {
        require(backend.isNotBlank()) { "a session names its backend" }
        require(available || unavailableReason != null) {
            "an unavailable environment names the reason"
        }
    }

    /** The adapter's registry key; also the adapter's answer on the probe. */
    override val env: String get() = adapter.env

    override val sealIsMock: Boolean get() = seal.isMock

    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var started: UbuntuJobLane? = null

    /** True once `close` ran; a later `lane` opens a fresh one over the same store. */
    var closed: Boolean = false
        private set

    override suspend fun lane(): UbuntuJobLane {
        if (closed) {
            started = null
            closed = false
        }
        started?.let { return it }
        val lane = UbuntuJobLane(
            scope = scope,
            clock = clock,
            store = UbuntuJobStore(storeRoot, durability, logger),
            adapters = mapOf(adapter.env to adapter),
            seal = seal,
            budgets = budgets,
            vfsRoot = storeRoot,
            sink = { _, _, _ -> Unit },
            admissionOpen = admissionOpen,
            logger = logger,
        )
        lane.recover()
        started = lane
        return lane
    }

    override suspend fun submit(
        request: UbuntuExecRequest,
        approval: UbuntuJobApproval?,
    ): UbuntuSubmit = lane().submit(request, approval)

    override suspend fun status(jobId: String): UbuntuJobRecord? = lane().status(jobId)

    override suspend fun awaitTerminal(jobId: String, timeoutMs: Long): UbuntuJobRecord? {
        val lane = lane()
        return withTimeoutOrNull(timeoutMs.coerceAtLeast(1L)) {
            while (true) {
                val record = lane.status(jobId) ?: return@withTimeoutOrNull null
                if (record.terminal) return@withTimeoutOrNull record
                delay(POLL_INTERVAL_MS)
            }
            @Suppress("UNREACHABLE_CODE")
            null
        } ?: lane.status(jobId)
    }

    /**
     * Close the environment (the Agent's `ubuntu close`).
     *
     * Every non-terminal job is cancelled through the lane first, so the
     * adapter receives the stop the state machine expects; then every known
     * job id is offered to the adapter once more, which is how a real adapter
     * removes a completed job's process entry. A mock's `stop` is harmless for
     * a terminal job.
     */
    override suspend fun close(): List<String> {
        val lane = started ?: run {
            closed = true
            return emptyList()
        }
        val stopped = lane.jobs().filter { !it.terminal }.map { it.jobId }
        for (jobId in stopped) lane.cancel(jobId)
        for (record in lane.jobs()) {
            try {
                adapter.stop(record.jobId)
            } catch (failure: Exception) {
                logger.warn(
                    "ubuntu close: ${failure.javaClass.simpleName} while releasing " +
                        "the adapter handle of ${record.jobId}",
                )
            }
        }
        closed = true
        return stopped
    }

    companion object {
        /** How often the host tool polls a running job. */
        private const val POLL_INTERVAL_MS: Long = 20L
    }
}

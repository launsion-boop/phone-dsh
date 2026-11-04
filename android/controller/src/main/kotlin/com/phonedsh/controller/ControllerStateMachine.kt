// phone-dsh Android — :controller D14 host state machine (budgets.md §1–§3).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

/**
 * The pure D14 host state machine.
 *
 * It owns exactly one of the nine [HostState] values and the admission derived
 * from it. It performs no I/O, reads no clock and starts no coroutine: every
 * signal arrives with a logical millisecond timestamp, and every accepted
 * transition returns the effects the facade must perform. That keeps the whole
 * table replayable on the JVM, including the golden perturbation fixtures.
 *
 * The transition table is budgets.md §2. Anything not listed there is rejected;
 * a rejection never changes state, admission or the transition log.
 *
 * The machine is not thread-safe: the facade serializes signals, and the
 * absence of internal scheduling is what makes the table testable on the JVM.
 */
class ControllerStateMachine private constructor(initialBoot: BootResult) {

    /** The D14 boot mapping that created this machine. */
    val initialBoot: BootResult = initialBoot

    /**
     * The current D14 state.
     *
     * `@Volatile`: the machine serialises [handle] behind the facade's signal
     * lock, but readers such as the host's periodic epoch-close lane run on a
     * different dispatcher thread and must observe the last accepted state
     * without taking that lock. A non-volatile read here is a data race the
     * periodic lane would silently interpret as "not Running".
     */
    @Volatile
    var state: HostState = initialBoot.state
        private set

    var bootDisposition: BootDisposition = initialBoot.disposition
        private set

    var bootReason: String = initialBoot.reason
        private set

    var lastFailure: ControllerFailure? = null
        private set

    var lastFailureDetail: String? = null
        private set

    /** When the current drain began, `null` outside `Draining`. */
    var drainStartedAtMillis: Long? = null
        private set

    /** The 20 s deadline armed on `Running -> Draining`, `null` outside `Draining`. */
    var drainDeadlineAtMillis: Long? = null
        private set

    /**
     * `true` once a deadline or a background-task expiry forced the close on
     * the current drain.
     *
     * At most one `FORCE_DRAIN_DEADLINE`/`CANCEL_IN_FLIGHT_REQUESTS` pair is
     * emitted per entry into `Draining`: a repeated force signal is a no-op,
     * so no effect consumer has to de-duplicate.
     */
    var drainDeadlineForced: Boolean = false
        private set

    /** `HandingOff` guard: the fence CAS installed the remote generation. */
    var isFenceInstalled: Boolean = false
        private set

    /** `Backoff` guard: the network path is satisfied. */
    var isNetworkPathSatisfied: Boolean = false
        private set

    /** `Backoff` guard: the `Retry-After` window elapsed. */
    var isRetryAfterElapsed: Boolean = false
        private set

    /** `Reclaiming` guard: the reclaim response was applied. */
    var isReclaimResponseApplied: Boolean = false
        private set

    var thermalPressure: ThermalPressure = ThermalPressure.NOMINAL
        private set

    var battery: BatterySnapshot = BatterySnapshot(levelPercent = null, charging = false, lowPowerMode = false)
        private set

    private val mutableTransitions = mutableListOf<TransitionRecord>()

    /** Every accepted transition, oldest first. Boot is not a transition. */
    val transitions: List<TransitionRecord> get() = mutableTransitions.toList()

    /** Admission is derived from the state; it is open only in `Running`. */
    val admission: Admission get() = state.admission

    /**
     * Feed one signal at logical time [atMillis]. Returns a transition, an
     * observation or a rejection; it never throws for an illegal signal.
     */
    fun handle(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        require(atMillis >= 0) { "atMillis must be non-negative, was $atMillis" }
        return when (signal) {
            is ControllerSignal.ScenePhaseChanged -> onScenePhase(signal, atMillis)
            is ControllerSignal.EngineStateChanged -> onEngineState(signal, atMillis)
            ControllerSignal.PlannedRestartRequested -> onPlannedRestart(signal, atMillis)
            ControllerSignal.DrainCompleted -> onDrainCompleted(signal, atMillis)
            ControllerSignal.DrainDeadlineElapsed -> onDrainDeadline(signal, atMillis)
            ControllerSignal.BackgroundTaskExpired -> onBackgroundTaskExpired(signal)
            is ControllerSignal.NetworkPathChanged -> onNetworkPath(signal, atMillis)
            is ControllerSignal.UpstreamUnavailable -> onUpstreamUnavailable(signal, atMillis)
            ControllerSignal.RetryAfterElapsed -> onRetryAfterElapsed(signal)
            is ControllerSignal.RetryProbeSucceeded -> onRetryProbeSucceeded(signal, atMillis)
            is ControllerSignal.LeaseCheckResult -> onLeaseCheckResult(signal, atMillis)
            ControllerSignal.HandoffRequested -> onHandoffRequested(signal, atMillis)
            ControllerSignal.HandoffFenceInstalled -> onHandoffFenceInstalled(signal)
            is ControllerSignal.HandoffCompleted -> onHandoffCompleted(signal, atMillis)
            ControllerSignal.HandoffFailed -> onHandoffFailed(signal, atMillis)
            ControllerSignal.ReclaimRequested -> onReclaimRequested(signal, atMillis)
            ControllerSignal.ReclaimResponseApplied -> onReclaimResponseApplied(signal)
            is ControllerSignal.ReclaimCompleted -> onReclaimCompleted(signal, atMillis)
            is ControllerSignal.FailureRaised -> onFailureRaised(signal, atMillis)
            ControllerSignal.UserReset -> onUserReset(signal, atMillis)
            is ControllerSignal.ThermalStateChanged -> onThermalState(signal)
            is ControllerSignal.BatteryChanged -> onBatteryChanged(signal)
        }
    }

    // ---- scene, engine, restart ---------------------------------------------------

    private fun onScenePhase(signal: ControllerSignal.ScenePhaseChanged, atMillis: Long): SignalOutcome =
        when {
            state == HostState.RUNNING && signal.phase == ScenePhase.BACKGROUND ->
                beginDraining(signal, atMillis)

            state == HostState.PARKED && signal.phase == ScenePhase.ACTIVE ->
                transition(
                    to = HostState.RECOVERING,
                    signal = signal,
                    atMillis = atMillis,
                    extraEffects = listOf(ControllerEffect.START_WORKER, ControllerEffect.VERIFY_LEASE),
                    reason = "parked_resume",
                )

            else -> rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "scenePhase(${signal.phase.wireName}) is not an edge out of ${state.wireName}",
            )
        }

    private fun beginDraining(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        drainStartedAtMillis = atMillis
        drainDeadlineAtMillis = atMillis + ControllerBudgets.DRAIN_DEADLINE_MILLIS
        drainDeadlineForced = false
        return transition(
            to = HostState.DRAINING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.ARM_DRAIN_DEADLINE,
                ControllerEffect.START_BACKGROUND_TASK,
            ),
        )
    }

    private fun onEngineState(signal: ControllerSignal.EngineStateChanged, atMillis: Long): SignalOutcome {
        if (signal.state != EngineHostState.TERMINATED) {
            return observed(
                signal,
                emptyList(),
                "engine ${signal.state.wireName} is an observation, not a D14 edge",
            )
        }
        return when {
            state == HostState.RUNNING && !signal.wasForeground -> rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "a background engine termination is not a Running -> Recovering edge",
            )

            state == HostState.RUNNING || state == HostState.DRAINING -> transition(
                to = HostState.RECOVERING,
                signal = signal,
                atMillis = atMillis,
                extraEffects = listOf(
                    ControllerEffect.CLOSE_EPOCH,
                    ControllerEffect.RESTART_WORKER,
                    ControllerEffect.VERIFY_LEASE,
                ),
            )

            else -> rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "engine termination is not an edge out of ${state.wireName}",
            )
        }
    }

    private fun onPlannedRestart(signal: ControllerSignal, atMillis: Long): SignalOutcome =
        when (state) {
            HostState.RUNNING, HostState.DRAINING -> transition(
                to = HostState.RECOVERING,
                signal = signal,
                atMillis = atMillis,
                extraEffects = listOf(
                    ControllerEffect.CLOSE_EPOCH,
                    ControllerEffect.RESTART_WORKER,
                    ControllerEffect.VERIFY_LEASE,
                ),
            )

            else -> rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a planned restart is not an edge out of ${state.wireName}",
            )
        }

    // ---- drain --------------------------------------------------------------------

    private fun onDrainCompleted(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.DRAINING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "drain completion is not an edge out of ${state.wireName}",
            )
        }
        return transition(
            to = HostState.PARKED,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.CLOSE_EPOCH,
                ControllerEffect.FSYNC_MATERIALIZED,
                ControllerEffect.STOP_WORKER,
            ),
        )
    }

    private fun onDrainDeadline(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.DRAINING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a drain deadline is not an edge out of ${state.wireName}",
            )
        }
        if (drainDeadlineForced) {
            return observed(
                signal,
                emptyList(),
                "the deadline was already forced on this drain; a duplicate deadline is a no-op",
            )
        }
        val deadline = drainDeadlineAtMillis
            ?: return rejected(signal, RejectionReason.GUARD_FAILED, "no drain deadline is armed")
        if (atMillis < deadline) {
            return rejected(
                signal,
                RejectionReason.DEADLINE_NOT_REACHED,
                "drain deadline is at $deadline ms, signal arrived at $atMillis ms",
            )
        }
        drainDeadlineForced = true
        return observed(
            signal,
            listOf(ControllerEffect.FORCE_DRAIN_DEADLINE, ControllerEffect.CANCEL_IN_FLIGHT_REQUESTS),
            "deadline forced; the epoch close still runs and the pending target continues",
        )
    }

    private fun onBackgroundTaskExpired(signal: ControllerSignal): SignalOutcome {
        if (state != HostState.DRAINING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a background task expiry is not an edge out of ${state.wireName}",
            )
        }
        if (drainDeadlineForced) {
            return observed(
                signal,
                emptyList(),
                "the deadline was already forced on this drain; a duplicate expiry is a no-op",
            )
        }
        drainDeadlineForced = true
        return observed(
            signal,
            listOf(ControllerEffect.FORCE_DRAIN_DEADLINE, ControllerEffect.CANCEL_IN_FLIGHT_REQUESTS),
            "expiry forces the 20 s deadline; the constant and the pending target are unchanged",
        )
    }

    // ---- network and backoff ------------------------------------------------------

    private fun onNetworkPath(
        signal: ControllerSignal.NetworkPathChanged,
        atMillis: Long,
    ): SignalOutcome {
        if (state == HostState.BACKOFF) {
            isNetworkPathSatisfied = signal.status == NetworkPathStatus.SATISFIED
            return observed(
                signal,
                emptyList(),
                "network path recorded for the Backoff guard; no D14 edge",
            )
        }
        if (state == HostState.RUNNING) {
            return when (signal.status) {
                NetworkPathStatus.UNSATISFIED -> {
                    isNetworkPathSatisfied = false
                    isRetryAfterElapsed = false
                    transition(
                        to = HostState.BACKOFF,
                        signal = signal,
                        atMillis = atMillis,
                        extraEffects = listOf(ControllerEffect.START_RETRY_SCHEDULE),
                    )
                }

                NetworkPathStatus.SATISFIED -> observed(
                    signal,
                    emptyList(),
                    "network path is already satisfied; no D14 edge",
                )

                NetworkPathStatus.REQUIRES_CONNECTION -> rejected(
                    signal,
                    RejectionReason.ILLEGAL_TRANSITION,
                    "only NWPath unsatisfied enters Backoff (budgets.md §2)",
                )
            }
        }
        return rejected(
            signal,
            RejectionReason.ILLEGAL_TRANSITION,
            "network path change is not an edge out of ${state.wireName}",
        )
    }

    private fun onUpstreamUnavailable(
        signal: ControllerSignal.UpstreamUnavailable,
        atMillis: Long,
    ): SignalOutcome {
        if (state != HostState.RUNNING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "an upstream failure is not an edge out of ${state.wireName}",
            )
        }
        if (signal.statusCode != 429 && signal.statusCode !in 500..599) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "only 429 or 5xx enters Backoff, was ${signal.statusCode}",
            )
        }
        isNetworkPathSatisfied = false
        isRetryAfterElapsed = false
        return transition(
            to = HostState.BACKOFF,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(ControllerEffect.START_RETRY_SCHEDULE),
        )
    }

    private fun onRetryAfterElapsed(signal: ControllerSignal): SignalOutcome {
        if (state != HostState.BACKOFF) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a Retry-After window is not an edge out of ${state.wireName}",
            )
        }
        isRetryAfterElapsed = true
        return observed(
            signal,
            emptyList(),
            "Retry-After elapsed; a satisfied path and one successful probe are still required",
        )
    }

    private fun onRetryProbeSucceeded(
        signal: ControllerSignal.RetryProbeSucceeded,
        atMillis: Long,
    ): SignalOutcome {
        if (state != HostState.BACKOFF) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a retry probe is not an edge out of ${state.wireName}",
            )
        }
        if (!signal.leaseVerified) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "Backoff -> Running requires a successful lease check",
            )
        }
        if (!isNetworkPathSatisfied) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the network path is not satisfied",
            )
        }
        if (!isRetryAfterElapsed) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the Retry-After window has not elapsed",
            )
        }
        return transition(
            to = HostState.RUNNING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.VERIFY_LEASE,
                ControllerEffect.SEND_FENCE,
                ControllerEffect.SEND_LIFECYCLE_OPEN,
            ),
        )
    }

    // ---- lease --------------------------------------------------------------------

    private fun onLeaseCheckResult(
        signal: ControllerSignal.LeaseCheckResult,
        atMillis: Long,
    ): SignalOutcome {
        if (state != HostState.RECOVERING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "lease verification is not an edge out of ${state.wireName}",
            )
        }
        if (!signal.verified) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "lease verification failed; admission stays closed",
            )
        }
        return transition(
            to = HostState.RUNNING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.VERIFY_LEASE,
                ControllerEffect.SEND_FENCE,
                ControllerEffect.SEND_LIFECYCLE_OPEN,
            ),
        )
    }

    // ---- handoff and reclaim ------------------------------------------------------

    private fun onHandoffRequested(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.RUNNING && state != HostState.DRAINING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a handoff decision is not an edge out of ${state.wireName}",
            )
        }
        isFenceInstalled = false
        return transition(
            to = HostState.HANDING_OFF,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(ControllerEffect.CLOSE_EPOCH, ControllerEffect.FREEZE_WAL_SEQ),
        )
    }

    private fun onHandoffFenceInstalled(signal: ControllerSignal): SignalOutcome {
        if (state != HostState.HANDING_OFF) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a fence installation is not an edge out of ${state.wireName}",
            )
        }
        isFenceInstalled = true
        return observed(
            signal,
            emptyList(),
            "fence CAS installed; the snapshot and segments may be transferred",
        )
    }

    private fun onHandoffCompleted(
        signal: ControllerSignal.HandoffCompleted,
        atMillis: Long,
    ): SignalOutcome {
        if (state != HostState.HANDING_OFF) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a handoff completion is not an edge out of ${state.wireName}",
            )
        }
        if (!isFenceInstalled) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the remote cannot hold authority before the fence CAS",
            )
        }
        if (!signal.remoteAdmissionOpen) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the remote admission is closed",
            )
        }
        return transition(
            to = HostState.REMOTE,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.REMOTE_HOLDS_AUTHORITY,
                ControllerEffect.KEEP_WAL_READ_ONLY,
            ),
        )
    }

    private fun onHandoffFailed(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.HANDING_OFF) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a handoff failure is not an edge out of ${state.wireName}",
            )
        }
        if (!isFenceInstalled) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "a handoff that never installed a fence has nothing to reclaim",
            )
        }
        isReclaimResponseApplied = false
        return transition(
            to = HostState.RECLAIMING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(ControllerEffect.POST_RECLAIM_TOKEN),
        )
    }

    private fun onReclaimRequested(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.REMOTE) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a reclaim request is not an edge out of ${state.wireName}",
            )
        }
        isReclaimResponseApplied = false
        return transition(
            to = HostState.RECLAIMING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(ControllerEffect.POST_RECLAIM_TOKEN),
        )
    }

    private fun onReclaimResponseApplied(signal: ControllerSignal): SignalOutcome {
        if (state != HostState.RECLAIMING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a reclaim response is not an edge out of ${state.wireName}",
            )
        }
        isReclaimResponseApplied = true
        return observed(
            signal,
            listOf(ControllerEffect.APPLY_RECLAIM_RESPONSE),
            "response applied; the new fence and the epoch close are still required",
        )
    }

    private fun onReclaimCompleted(
        signal: ControllerSignal.ReclaimCompleted,
        atMillis: Long,
    ): SignalOutcome {
        if (state != HostState.RECLAIMING) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "a reclaim completion is not an edge out of ${state.wireName}",
            )
        }
        if (!isReclaimResponseApplied) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the reclaim response was not applied",
            )
        }
        if (!signal.fencePersisted) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the new fence was not persisted",
            )
        }
        if (!signal.epochClosed) {
            return rejected(
                signal,
                RejectionReason.GUARD_FAILED,
                "the epoch was not closed",
            )
        }
        return transition(
            to = HostState.RECOVERING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.APPLY_RECLAIM_RESPONSE,
                ControllerEffect.VERIFY_LEASE,
            ),
        )
    }

    // ---- failure and reset --------------------------------------------------------

    private fun onFailureRaised(
        signal: ControllerSignal.FailureRaised,
        atMillis: Long,
    ): SignalOutcome {
        if (state == HostState.FAILED) {
            return observed(
                signal,
                emptyList(),
                "already Failed; the first failure reason is kept and there is no automatic exit",
            )
        }
        lastFailure = signal.reason
        lastFailureDetail = signal.detail
        return transition(
            to = HostState.FAILED,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.RECORD_FAILURE,
                ControllerEffect.KEEP_DURABLE_BYTES,
            ),
        )
    }

    private fun onUserReset(signal: ControllerSignal, atMillis: Long): SignalOutcome {
        if (state != HostState.FAILED) {
            return rejected(
                signal,
                RejectionReason.ILLEGAL_TRANSITION,
                "only a Failed host can be reset",
            )
        }
        lastFailure = null
        lastFailureDetail = null
        bootDisposition = BootDisposition.USER_RESET
        bootReason = "explicit_user_reset"
        return transition(
            to = HostState.RECOVERING,
            signal = signal,
            atMillis = atMillis,
            extraEffects = listOf(
                ControllerEffect.RE_RUN_RECOVERY,
                ControllerEffect.VERIFY_LEASE,
            ),
            reason = BootDisposition.USER_RESET.wireName,
        )
    }

    // ---- policy observations ------------------------------------------------------

    private fun onThermalState(signal: ControllerSignal.ThermalStateChanged): SignalOutcome {
        thermalPressure = signal.pressure
        val effects = when (signal.pressure) {
            ThermalPressure.NOMINAL -> emptyList()
            ThermalPressure.FAIR -> listOf(ControllerEffect.LIMIT_SUB_AGENTS)
            ThermalPressure.SERIOUS, ThermalPressure.CRITICAL -> listOf(
                ControllerEffect.NO_NEW_SUB_AGENTS,
                ControllerEffect.PAUSE_ACCELERATORS,
            )
        }
        return observed(
            signal,
            effects,
            "thermal pressure changes caps and accelerator policy, never a D14 state",
        )
    }

    private fun onBatteryChanged(signal: ControllerSignal.BatteryChanged): SignalOutcome {
        battery = signal.snapshot
        val effects = if (signal.snapshot.constrained) {
            listOf(ControllerEffect.LIMIT_SUB_AGENTS, ControllerEffect.NO_OPTIONAL_ACCELERATORS)
        } else {
            emptyList()
        }
        return observed(
            signal,
            effects,
            "battery pressure changes caps and accelerator policy, never a D14 state",
        )
    }

    // ---- internals ----------------------------------------------------------------

    private fun transition(
        to: HostState,
        signal: ControllerSignal,
        atMillis: Long,
        extraEffects: List<ControllerEffect>,
        reason: String? = null,
    ): SignalOutcome.Transitioned {
        val from = state
        val effects = buildList {
            add(
                if (to == HostState.RUNNING) ControllerEffect.OPEN_ADMISSION
                else ControllerEffect.CLOSE_ADMISSION,
            )
            addAll(extraEffects)
            add(ControllerEffect.PERSIST_HOST_STATE)
        }
        clearTransientGuards(from, to)
        state = to
        val record = TransitionRecord(
            from = from,
            to = to,
            signal = signal.label,
            atMillis = atMillis,
            admission = to.admission,
            effects = effects,
            reason = reason,
        )
        mutableTransitions += record
        return SignalOutcome.Transitioned(record)
    }

    private fun clearTransientGuards(from: HostState, to: HostState) {
        if (from == HostState.DRAINING) {
            drainStartedAtMillis = null
            drainDeadlineAtMillis = null
            drainDeadlineForced = false
        }
        if (to != HostState.HANDING_OFF) isFenceInstalled = false
        if (to != HostState.BACKOFF) {
            isNetworkPathSatisfied = false
            isRetryAfterElapsed = false
        }
        if (to != HostState.RECLAIMING) isReclaimResponseApplied = false
    }

    private fun observed(
        signal: ControllerSignal,
        effects: List<ControllerEffect>,
        note: String,
    ): SignalOutcome.Observed = SignalOutcome.Observed(signal.label, effects, note)

    private fun rejected(
        signal: ControllerSignal,
        reason: RejectionReason,
        detail: String,
    ): SignalOutcome.Rejected = SignalOutcome.Rejected(state, signal.label, reason, detail)

    companion object {
        /**
         * The D14 boot mapping:
         *
         * - persisted `Running`, `Draining`, `Recovering`, `Reclaiming` -> `Recovering`
         * - persisted `Parked` -> `Parked` (the `cold-start-after-reboot` fixture)
         * - persisted `Backoff` / `Remote` -> the same state (Swift reference)
         * - persisted `HandingOff` -> `Failed`: the CAS outcome cannot be proven
         * - persisted `Failed` -> `Failed`; only an explicit reset leaves it
         * - no persisted state -> `Recovering` (new workspace)
         *
         * The persisted `Parked`/`Backoff`/`Remote`/`HandingOff`/`Reclaiming`
         * rows are not edges in the D14 table (which only names `Running`,
         * `Draining`, `Recovering`, `Failed` and the empty workspace). They are
         * boot mappings borrowed from the Swift reference and the golden
         * `cold-start-after-reboot` fixture; boot is a pure label, not a
         * transition out of a live state.
         */
        fun boot(
            persistedState: HostState?,
            workspaceHasState: Boolean = false,
            persistedFailure: ControllerFailure? = null,
            persistedFailureDetail: String? = null,
        ): ControllerStateMachine {
            val state = bootState(persistedState)
            val disposition = when {
                persistedState == null && workspaceHasState -> BootDisposition.CRASH_RECOVERY
                persistedState == null -> BootDisposition.COLD_START
                persistedState == HostState.PARKED -> BootDisposition.PARKED_RESUME
                else -> BootDisposition.CRASH_RECOVERY
            }
            val reason = when {
                persistedState != null -> "persisted_${persistedState.wireName.lowercase()}"
                workspaceHasState -> "workspace_without_host_state"
                else -> "empty_workspace"
            }
            val effects = buildList {
                add(ControllerEffect.PERSIST_HOST_STATE)
                when (state) {
                    HostState.RECOVERING -> add(ControllerEffect.VERIFY_LEASE)
                    HostState.BACKOFF -> add(ControllerEffect.START_RETRY_SCHEDULE)
                    HostState.REMOTE -> add(ControllerEffect.KEEP_WAL_READ_ONLY)
                    HostState.FAILED -> {
                        add(ControllerEffect.RECORD_FAILURE)
                        add(ControllerEffect.KEEP_DURABLE_BYTES)
                    }

                    else -> Unit
                }
            }
            return ControllerStateMachine(
                BootResult(
                    state = state,
                    disposition = disposition,
                    reason = reason,
                    admission = state.admission,
                    effects = effects,
                ),
            ).also { machine ->
                // A persisted Failed record keeps the condition it failed on;
                // only an explicit reset clears it.
                if (state == HostState.FAILED) {
                    machine.lastFailure = persistedFailure
                    machine.lastFailureDetail = persistedFailureDetail
                }
            }
        }

        private fun bootState(persistedState: HostState?): HostState = when (persistedState) {
            null -> HostState.RECOVERING
            HostState.RUNNING,
            HostState.DRAINING,
            HostState.RECOVERING,
            HostState.RECLAIMING,
            -> HostState.RECOVERING

            HostState.PARKED -> HostState.PARKED
            HostState.BACKOFF -> HostState.BACKOFF
            HostState.REMOTE -> HostState.REMOTE
            HostState.HANDING_OFF -> HostState.FAILED
            HostState.FAILED -> HostState.FAILED
        }
    }
}

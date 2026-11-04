// phone-dsh — :dsh unit test: a boot from the persisted `Backoff` is not a dead end.
// SPDX-License-Identifier: MIT
//
// budgets.md §2's boot mapping keeps a persisted `Backoff` in `Backoff`, and
// §2 gives that state exactly one exit: `Backoff -> Running` when "Retry-After
// elapsed, network path satisfied, one probe succeeded". The window is a
// *duration that has already been spent* when the persisted `backoff_until_ms`
// is in the past — so a boot must not invent a new window, and it must not sit
// on a change event that already happened either. It arms the remainder (0 ms),
// observes the current path (the platform's first-frame `LifecycleSnapshot`
// carries it, `LifecycleSignals`' contract), runs the one probe and lets D14
// take the row.
//
// The defect these tests pin: a device that booted from a spent 0 ms `Backoff`
// left admission closed forever — every `EXEC_REQ` answered `admission_closed`
// while the chat still worked — and only deleting `host-state.json` produced a
// healthy start (L69, API 35). The last test is the guard on the other side:
// a *future* deadline is still honoured, so "reopen admission" never means
// "ignore the window".

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.testing.FakePlatform
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Test

class BackoffBootTest {
    // ---- 1. a spent window reopens admission as soon as the path is known ---

    /**
     * The persisted 0 ms `Backoff`, reproduced.
     *
     * `host-state.json` says `state = backoff` with `backoff_until_ms` long in
     * the past: the App was killed after the window ended. The device's network
     * path is satisfied and is reported in the boot snapshot. Admission must
     * open, so the next `EXEC_REQ` is not answered `admission_closed`.
     *
     * Reverse validation: make the retry lane wait for a *change* event (drop
     * the snapshot member, or reset `pathSatisfied` after arming without ever
     * reading the current value) and this test times out in `BACKOFF` with
     * admission `CLOSED` — the measured device state.
     */
    @Test
    fun aSpentPersistedWindowReopensAdmissionOnceThePathIsSatisfied() {
        FakePlatform(nowMillis = NOW).use { platform ->
            writeState(platform, HostState.BACKOFF, backoffUntilMillis = NOW - 60_000L)
            // The current reading the platform reports in its first-frame
            // snapshot (`LifecycleSignals`: "the first element every collector
            // receives is exactly one LifecycleSnapshot carrying the current
            // value of each signal the implementation can read").
            platform.emit(NetworkPath(available = true, expensive = false))

            val host = newHost(platform)
            host.start()
            try {
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                // The engine coming up is what the `Recovering` path waits for;
                // `Backoff` does not wait for it, so set it after ready.
                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))

                val state = runBlocking {
                    withTimeoutOrNull(5_000) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals(
                    "a spent Backoff window must reach Running once the path and the probe hold",
                    HostState.RUNNING,
                    state,
                )
                assertEquals(Admission.OPEN, host.controller.admission)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. the guard is a real fact, not a default -------------------------

    /**
     * Without a satisfied path the host stays closed — that is the fail-closed
     * half of D14, not the defect.
     *
     * A spent window does not prove the network came back, so the boot must not
     * feed a `NetworkPathChanged(SATISFIED)` it did not observe. The state stays
     * `Backoff` with admission closed until the path is reported.
     */
    @Test
    fun aSpentWindowWithoutASatisfiedPathKeepsAdmissionClosed() {
        FakePlatform(nowMillis = NOW).use { platform ->
            writeState(platform, HostState.BACKOFF, backoffUntilMillis = NOW - 60_000L)
            platform.emit(NetworkPath(available = false, expensive = false))

            val host = newHost(platform)
            host.start()
            try {
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))

                val opened = runBlocking {
                    withTimeoutOrNull(600) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals("an unsatisfied path is no `Backoff -> Running` row", null, opened)
                assertEquals(HostState.BACKOFF, host.controller.state)
                assertEquals(Admission.CLOSED, host.controller.admission)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. a future deadline is still honoured -----------------------------

    /**
     * The remaining window is the persisted deadline, not a fresh one and not
     * zero: a `backoff_until_ms` in the future keeps admission closed until it
     * passes, then the same probe opens it.
     */
    @Test
    fun aFuturePersistedDeadlineDelaysTheReopenUntilTheWindowEnds() {
        FakePlatform(nowMillis = NOW).use { platform ->
            val remaining = 400L
            writeState(platform, HostState.BACKOFF, backoffUntilMillis = NOW + remaining)
            platform.emit(NetworkPath(available = true, expensive = false))

            val host = newHost(platform)
            host.start()
            try {
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))

                // A short look before the window ends: still closed.
                val early = runBlocking {
                    withTimeoutOrNull(100) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals("the remaining window must not be ignored", null, early)
                assertEquals(Admission.CLOSED, host.controller.admission)

                val state = runBlocking {
                    withTimeoutOrNull(5_000) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals(HostState.RUNNING, state)
                assertEquals(Admission.OPEN, host.controller.admission)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 4. the same guard must not wait for a change that will not come ----

    /**
     * An upstream 429/5xx enters `Backoff` without the path having changed.
     *
     * `budgets.md` §2 gives `Backoff` one exit: "Retry-After elapsed, network
     * path satisfied, one probe succeeded". The path here is *already* satisfied
     * and the OS reports it only when it changes, so waiting for a new
     * observation is waiting forever: the window elapses, the probe would pass,
     * and admission never reopens — every `EXEC_REQ` is answered
     * `admission_closed` while the chat (the `/api` lane, which has no admission
     * gate) keeps working. The host already holds the fact; the fix is to hand
     * the machine its own observation instead of waiting for a duplicate.
     *
     * Reverse validation: remove the `lastPathStatus` feed in
     * [DefaultPhoneDshHost.dispatch] and this test times out in `BACKOFF` with
     * admission `CLOSED`.
     */
    @Test
    fun anUpstreamFailureReopensAdmissionOnThePathFactTheHostAlreadyHas() {
        FakePlatform(nowMillis = NOW).use { platform ->
            platform.emit(NetworkPath(available = true, expensive = false))

            val host = DefaultPhoneDshHost(
                engine = platform.engine,
                controller = ControllerStateMachine.boot(persistedState = null),
                clock = platform,
                signals = platform,
                notifier = platform,
                retryPolicy = RetryPolicy(
                    initialDelayMillis = 1L,
                    multiplier = 2,
                    maximumDelayMillis = 4L,
                    jitterFraction = 0.0,
                ),
                scope = CoroutineScope(Dispatchers.Unconfined),
                logger = HostLog.None,
            )
            host.start()
            try {
                runBlocking { withTimeout(5_000) { host.ready.first { it } } }
                platform.engine.setState(EngineHostState.Running("http://127.0.0.1:41234", 41234))
                runBlocking { withTimeout(5_000) { host.state.first { it == HostState.RUNNING } } }

                // The model edge answers 429: `Running -> Backoff`, and no
                // NetworkPath event follows because the path never changed.
                host.handle(ControllerSignal.UpstreamUnavailable(429))
                assertEquals(HostState.BACKOFF, host.controller.state)
                assertEquals(Admission.CLOSED, host.controller.admission)

                val state = runBlocking {
                    withTimeoutOrNull(5_000) { host.state.first { it == HostState.RUNNING } }
                }
                assertEquals(
                    "a 429 Backoff must leave on the path fact the host already observed",
                    HostState.RUNNING,
                    state,
                )
                assertEquals(Admission.OPEN, host.controller.admission)
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    /** Writes the record `HostStateStore.save` writes for a `Backoff` host. */
    private fun writeState(platform: FakePlatform, state: HostState, backoffUntilMillis: Long?) {
        val json = org.json.JSONObject()
            .put("version", HostStateStore.VERSION)
            .put("state", state.wireName)
            .put("updated_at_ms", platform.nowMillis())
            .put("reason", org.json.JSONObject.NULL)
            .put(
                "backoff_until_ms",
                backoffUntilMillis ?: org.json.JSONObject.NULL,
            )
            .put("boot_disposition", "cold_start")
            .put("boot_reason", "persisted_backoff")
        val file = platform.tempDir.resolve(HostStateStore.FILE_NAME)
        Files.createDirectories(file.parent)
        Files.write(file, json.toString().toByteArray(Charsets.UTF_8))
    }

    private fun newHost(platform: FakePlatform): DefaultPhoneDshHost {
        val store = HostStateStore(
            file = platform.tempDir.resolve(HostStateStore.FILE_NAME),
            durability = platform,
            clock = platform,
            logger = HostLog.None,
        )
        return DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(
                persistedState = store.load()?.state,
            ),
            clock = platform,
            signals = platform,
            notifier = platform,
            stateStore = store,
            scope = CoroutineScope(Dispatchers.Unconfined),
            logger = HostLog.None,
        )
    }

    private companion object {
        /** One wall-clock instant the persisted record and the fake clock share. */
        const val NOW: Long = 1_800_000_000_000L
    }
}

// phone-dsh — :engine / com.phonedsh.engine: the state machine behind DemoEngine.state.
// SPDX-License-Identifier: MIT
//
// One owner of EngineState, pure Kotlin (no android.*): WebViewEngine calls these
// transitions from the UI thread, and EngineLifecycleTest drives the very same
// class on the JVM. The transition table is the contract:
//
//   beginStart   : Stopped | Failed                -> Starting
//   markRunning  : Starting | Recovering           -> Running
//   markRecovering: Running                        -> Recovering  (counts a recovery)
//   markFailed   : Starting | Running | Recovering -> Failed
//   beginStop    : everything except Stopped       -> Stopped
//
// A transition that the table does not allow returns false and changes nothing;
// the caller logs it and keeps going, so a late callback cannot resurrect a
// stopped engine.

package com.phonedsh.engine

import com.phonedsh.platform.EngineHostState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicInteger

/** Serializes every state change of one engine instance. Thread-safe. */
class EngineLifecycle(private val logger: EngineLogger) {
    private val mutable = MutableStateFlow<EngineState>(EngineHostState.Stopped)
    private val recoveries = AtomicInteger()

    /** The same flow [DemoEngine.state] exposes. */
    val state: StateFlow<EngineState> = mutable.asStateFlow()

    /** How many renderer deaths were turned into a rebuild since construction. */
    val recoveryCount: Int get() = recoveries.get()

    /** The current state, reading the flow once. */
    fun snapshot(): EngineState = mutable.value

    /** `Stopped|Failed -> Starting`. True when this call owns the start. */
    fun beginStart(): Boolean =
        move(EngineHostState.Starting) { it == EngineHostState.Stopped || it is EngineHostState.Failed }

    /** `Starting|Recovering -> Running`. False when a stop/failure won the race. */
    fun markRunning(origin: String, port: Int): Boolean =
        move(EngineHostState.Running(origin, port)) {
            it == EngineHostState.Starting || it == EngineHostState.Recovering
        }

    /** `Running -> Recovering`; increments [recoveryCount] when it wins. */
    fun markRecovering(): Boolean {
        val moved = move(EngineHostState.Recovering) { it is EngineHostState.Running }
        if (moved) recoveries.incrementAndGet()
        return moved
    }

    /** `Starting|Running|Recovering -> Failed`. False when already Stopped/Failed. */
    fun markFailed(reason: String): Boolean =
        move(EngineHostState.Failed(reason)) {
            it == EngineHostState.Starting || it == EngineHostState.Recovering || it is EngineHostState.Running
        }

    /** Everything except `Stopped -> Stopped`. True when this call stopped something. */
    fun beginStop(): Boolean = move(EngineHostState.Stopped) { it != EngineHostState.Stopped }

    private fun move(next: EngineState, allowed: (EngineState) -> Boolean): Boolean {
        while (true) {
            val current = mutable.value
            if (!allowed(current)) return false
            if (!mutable.compareAndSet(current, next)) continue
            logger.info("state: ${EngineLogText.describe(current)} -> ${EngineLogText.describe(next)}")
            return true
        }
    }
}

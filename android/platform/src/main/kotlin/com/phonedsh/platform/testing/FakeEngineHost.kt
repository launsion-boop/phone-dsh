// A passive EngineHost double for JVM tests of :dsh and above.
// SPDX-License-Identifier: MIT

package com.phonedsh.platform.testing

import com.phonedsh.platform.EngineChannelStatus
import com.phonedsh.platform.EngineHandshake
import com.phonedsh.platform.EngineHost
import com.phonedsh.platform.EngineHostState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Records `start`/`stop` and lets a test drive the three flows directly.
 *
 * It does not emulate the transition table: a test that wants `Running` calls
 * [setState] with the exact snapshot it expects the facade to react to. That
 * keeps engine-recovery tests in `:engine` and facade tests in `:dsh` from
 * sharing a second, drifting implementation of the state machine.
 */
class FakeEngineHost(
    initialState: EngineHostState = EngineHostState.Stopped,
) : EngineHost {
    private val mutableState = MutableStateFlow(initialState)
    override val state: StateFlow<EngineHostState> = mutableState.asStateFlow()

    private val mutableChannel = MutableStateFlow(EngineChannelStatus())
    override val channel: StateFlow<EngineChannelStatus> = mutableChannel.asStateFlow()

    private val mutableHandshake = MutableStateFlow<EngineHandshake?>(null)
    override val handshake: StateFlow<EngineHandshake?> = mutableHandshake.asStateFlow()

    /** Number of `start()` calls observed; a repeat call still counts. */
    var startCount: Int = 0
        private set

    /** Number of `stop()` calls observed; a repeat call still counts. */
    var stopCount: Int = 0
        private set

    override fun start() {
        startCount += 1
    }

    override fun stop() {
        stopCount += 1
        mutableState.value = EngineHostState.Stopped
        mutableChannel.value = EngineChannelStatus()
        mutableHandshake.value = null
    }

    /** Publishes a lifecycle snapshot exactly as the test wrote it. */
    fun setState(value: EngineHostState) {
        mutableState.value = value
    }

    /** Publishes channel counters exactly as the test wrote them. */
    fun setChannel(value: EngineChannelStatus) {
        mutableChannel.value = value
    }

    /** Publishes or clears the merged HELLO summary. */
    fun setHandshake(value: EngineHandshake?) {
        mutableHandshake.value = value
    }
}

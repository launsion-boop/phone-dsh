// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.domain.connector.ble.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Process-owned single radio slot, independent Activity hosts and page leases. */
internal class BleScanCoordinator(internal val machine: BleScanMachine) {
    private val sessions = mutableSetOf<Page>()
    private var owner: Page? = null
    private var retainedOwner: Page? = null
    private var quarantine: BleScanFailure? = null
    private val events = ArrayDeque<() -> Unit>()
    private var processing = false

    init { machine.onChange = ::changed; machine.dispatch = ::submit }

    /** Drain nested callbacks only after the current transition is complete. */
    private fun submit(action: () -> Unit) {
        events.addLast(action)
        if (processing) return
        processing = true
        try { while (events.isNotEmpty()) events.removeFirst().invoke() }
        finally { processing = false }
    }

    fun host(requestPermission: (String) -> Unit): Host = Host(requestPermission)
    fun owns(session: BleScanSession): Boolean = owner === session

    inner class Host(requestPermission: (String) -> Unit) : BleScanSource {
        internal val processIdentity: Any get() = this@BleScanCoordinator
        private var requester: ((String) -> Unit)? = requestPermission
        private var destroyed = false
        private var lifecycleEpoch = 0L
        var started = false
            private set
        private val pages = mutableSetOf<Page>()
        override fun open(): BleScanSession = Page(this).also { page ->
            submit { pages.add(page); sessions.add(page); page.refresh() }
        }
        override fun hostStarted() {
            val epoch = ++lifecycleEpoch
            submit {
                if (destroyed || lifecycleEpoch != epoch) return@submit
                started = true
                pages.filter { it !== owner && it.state.value.phase == BleScanPhase.HOST_INACTIVE }.forEach { it.refresh() }
                if (owner?.host === this) machine.checkDeadline()
            }
        }
        override fun hostStopped() {
            lifecycleEpoch++
            started = false
            submit {
                pages.toList().forEach { page ->
                    if (owner === page) machine.stop() else page.refresh()
                }
            }
        }
        fun checkDeadline() { submit { if (started && owner?.host === this) machine.checkDeadline() } }
        fun permissionResult(key: String) { submit { machine.permissionResult(key) } }
        fun pendingPermissionKey(): String? = machine.pendingPermissionKey()
        /** Drop the Activity closure even if its system permission never returns. */
        fun destroy() {
            destroyed = true; requester = null; hostStopped()
            submit { pages.toList().forEach { it.close() } }
        }
        internal fun hasRequester(): Boolean = requester != null
        internal fun request(key: String) = (requester ?: error("Host is destroyed"))(key)
        internal fun forget(page: Page) { pages.remove(page) }
    }

    inner class Page(internal val host: Host) : BleScanSession {
        internal val mutable = MutableStateFlow(BleScanSnapshot())
        override val state: StateFlow<BleScanSnapshot> = mutable.asStateFlow()
        private var closed = false
        private var epoch = 0L

        override fun start() {
            val attempt = epoch
            submit {
            if (closed || epoch != attempt) return@submit
            if (quarantine != null) { refresh(); return@submit }
            if (!host.started) { refresh(); return@submit }
            if (owner != null && owner !== this) {
                val pending = machine.pendingPermissionKey() != null && machine.state.value.phase != BleScanPhase.REQUESTING_PERMISSION
                mutable.value = BleScanSnapshot(if (pending) BleScanPhase.PERMISSION_PENDING else BleScanPhase.BUSY)
                return@submit
            }
            if (owner == null) {
                // The previous page's labels are never retained beside a new scan.
                sessions.filter { it !== this }.forEach { it.clearCandidates() }
                machine.discardRetainedCandidates()
                retainedOwner = this
                owner = this
            }
            machine.start(host::request) { !closed && epoch == attempt && host.started }
            }
        }

        override fun stop() {
            if (closed) return
            epoch++
            submit { if (!closed && owner === this) machine.stop() }
        }
        override fun close() {
            if (closed) return
            closed = true; epoch++
            submit {
            if (owner === this) machine.close()
            if (retainedOwner === this) { machine.discardRetainedCandidates(); retainedOwner = null }
            clearCandidates(); host.forget(this); sessions.remove(this)
            }
        }
        internal fun clearCandidates() { mutable.value = mutable.value.copy(candidates = emptyList()) }
        internal fun refresh() {
            if (closed) return
            val reason = quarantine
            mutable.value = when {
                reason != null -> BleScanSnapshot(BleScanPhase.CLEANUP_REQUIRED, failure = reason)
                !host.started -> BleScanSnapshot(BleScanPhase.HOST_INACTIVE)
                owner != null && owner !== this -> BleScanSnapshot(BleScanPhase.BUSY)
                else -> BleScanSnapshot(BleScanPhase.IDLE)
            }
        }
    }

    private fun changed(snapshot: BleScanSnapshot) {
        val oldOwner = owner
        if (snapshot.phase == BleScanPhase.CLEANUP_REQUIRED) {
            quarantine = snapshot.failure ?: BleScanFailure.STOP_FAILED
            owner = null
            oldOwner?.mutable?.value = snapshot
            sessions.toList().forEach { it.refresh() }
            return
        }
        val terminal = snapshot.phase in setOf(BleScanPhase.STOPPED, BleScanPhase.PERMISSION_DENIED,
            BleScanPhase.BLUETOOTH_OFF, BleScanPhase.UNSUPPORTED, BleScanPhase.FAILED)
        if (terminal && machine.pendingPermissionKey() == null) {
            owner = null
            oldOwner?.mutable?.value = snapshot
            sessions.filter { it !== oldOwner && it.state.value.phase in setOf(BleScanPhase.BUSY, BleScanPhase.PERMISSION_PENDING) }
                .forEach { it.refresh() }
        } else oldOwner?.mutable?.value = snapshot
    }
}

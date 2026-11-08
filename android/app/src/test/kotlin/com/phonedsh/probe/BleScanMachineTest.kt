// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.domain.connector.ble.BleScanPhase
import com.phonedsh.domain.connector.ble.BleScanSession
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import org.junit.Assert.*
import org.junit.Test

private class ScanFixturePlatform : BleScanPlatform {
    var hasHardware = true; var powered = true; var granted = true
    var throwStart = false; var nowMs = 0L
    var onStart: (((Boolean) -> Unit) -> Unit)? = null
    var onPermission: ((String) -> Unit)? = null
    var starts = 0; var stops = 0; var requests = 0
    var startDone: ((Boolean) -> Unit)? = null
    var stopDone: ((Boolean) -> Unit)? = null
    var permissionKey: String? = null
    var callback: BleScanPlatform.Callback? = null
    var oldCallback: BleScanPlatform.Callback? = null
    var stoppedCallback: BleScanPlatform.Callback? = null
    var timer: (() -> Unit)? = null
    var oldTimer: (() -> Unit)? = null
    override fun supported() = hasHardware
    override fun enabled() = powered
    override fun permitted() = granted
    override fun requestPermission(key: String) { requests++; permissionKey = key; onPermission?.invoke(key) }
    override fun start(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) {
        oldCallback = this.callback; this.callback = callback; starts++
        if (throwStart) completion(false) else if (onStart != null) onStart!!.invoke(completion) else startDone = completion
    }
    override fun stop(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) {
        stops++; stoppedCallback = callback; stopDone = completion
    }
    override fun now() = nowMs
    override fun timeout(action: () -> Unit): () -> Unit {
        oldTimer = timer; timer = action
        return { /* retain timer so a late event can be delivered */ }
    }
}

class BleScanMachineTest {
    @Test fun sharedScenariosDriveProductionMachine() {
        val root = File(System.getProperty("pdsh.repo.root"))
        val cases = File(root, "spec/device/v1/golden/android-ble-discovery.jsonl").readLines().filter { it.isNotBlank() }
        assertEquals(32, cases.size)
        for (line in cases) {
            val row = JsonValue.parse(line) as JsonObject
            val id = (row["id"] as JsonString).value
            val platform = ScanFixturePlatform()
            val machine = BleScanMachine(platform)
            val coordinator = BleScanCoordinator(machine)
            var hostA = coordinator.host(platform::requestPermission).also { it.hostStarted() }
            val hostB = coordinator.host(platform::requestPermission).also { it.hostStarted() }
            var source: BleScanSession = hostA.open()
            val ownerB = hostB.open()
            val ownerA = source
            var view = source
            var firstCallback: BleScanPlatform.Callback? = null
            for (value in (row["steps"] as JsonArray).values) {
                val step = value as JsonObject
                val event = (step["event"] as JsonString).value
                when (event) {
                    "start", "start-while-permission-pending", "start-while-current-permission-pending" -> source.start()
                    "owner-A-start" -> ownerA.start()
                    "owner-B-start" -> ownerB.start()
                    "owner-A-stop" -> ownerA.stop()
                    "old-owner-A-close" -> ownerA.close()
                    "owner-A-host-stop", "old-owner-A-host-stop" -> hostA.hostStopped()
                    "owner-A-host-start" -> hostA.hostStarted()
                    "start-needs-permission" -> { platform.granted = false; source.start() }
                    "start-no-hardware" -> { platform.hasHardware = false; source.start() }
                    "start-radio-off" -> { platform.powered = false; source.start() }
                    "start-throws-security" -> { platform.throwStart = true; source.start() }
                    "start-returned", "start-returned-after-stop", "start-returned-after-failure", "start-returned-after-deadline", "start-returned-after-revocation" -> {
                        firstCallback = firstCallback ?: platform.callback
                        platform.startDone!!.invoke(true); platform.startDone = null
                    }
                    "start-throws-after-stop" -> { platform.startDone!!.invoke(false); platform.startDone = null }
                    "stop" -> source.stop()
                    "host-stop" -> hostA.hostStopped()
                    "close" -> source.close()
                    "close-and-recreate-source" -> { source.close(); hostA = coordinator.host(platform::requestPermission).also { it.hostStarted() }; source = hostA.open(); view = source }
                    "host-resume" -> hostA.hostStarted()
                    "screen-on" -> hostA.checkDeadline()
                    "permission-denied" -> hostA.permissionResult(platform.permissionKey!!)
                    "old-permission-granted", "current-permission-granted" -> { platform.granted = true; hostA.permissionResult(platform.permissionKey!!) }
                    "unknown-restored-permission" -> hostA.permissionResult("unowned")
                    "candidate", "early-candidate", "candidate-after-deadline" -> platform.callback!!.result("first", "name", -40)
                    "duplicate" -> platform.callback!!.result("first", "renamed", -50)
                    "old-candidate" -> (firstCallback ?: platform.callback)!!.result("old", "late", -50)
                    "fill-over-limit" -> repeat(110) { platform.callback!!.result("other-$it", "name", -55) }
                    "scan-failed", "early-scan-failed" -> platform.callback!!.failed()
                    "old-failure" -> firstCallback!!.failed()
                    "timeout" -> { platform.nowMs += 15_000; platform.timer!!.invoke() }
                    "old-timeout" -> platform.oldTimer!!.invoke()
                    "advance-clock-past-deadline" -> platform.nowMs += 15_001
                    "revoke-permission" -> platform.granted = false
                    "stop-returned" -> { platform.stopDone!!.invoke(true); platform.stopDone = null }
                    "stop-throws-security" -> { platform.stopDone!!.invoke(false); platform.stopDone = null }
                    else -> error("unknown event: $event in $id")
                }
                val visible = (step["view"] as? JsonString)?.value
                if (visible == "A") view = ownerA else if (visible == "B") view = ownerB
                val snapshot = view.state.value
                assertEquals("$id $event phase", (step["phase"] as JsonString).value, snapshot.phase.name)
                assertEquals("$id $event candidates", (step["candidates"] as JsonNumber).raw.toInt(), snapshot.candidates.size)
                assertEquals("$id $event starts", (step["starts"] as JsonNumber).raw.toInt(), platform.starts)
                assertEquals("$id $event stops", (step["stops"] as JsonNumber).raw.toInt(), platform.stops)
                (step["failure"] as? JsonString)?.let { assertEquals("$id $event failure", it.value, snapshot.failure?.name) }
                (step["callback_match"] as? JsonBool)?.let { assertEquals("$id $event callback", it.value, platform.callback === platform.stoppedCallback) }
                (step["active_owner"] as? JsonString)?.let {
                    val actual = when { coordinator.owns(ownerA) -> "A"; coordinator.owns(ownerB) -> "B"; else -> "none" }
                    assertEquals("$id $event owner", it.value, actual)
                }
            }
        }
    }

    @Test fun namesAreBoundedAndSurrogatesAreReplaced() {
        assertEquals("未命名 BLE 设备", safeName(null))
        assertEquals("a\uFFFDb\uFFFD", safeName("a\uD800b\uDC00"))
        assertEquals(128, safeName("😀".repeat(130)).codePointCount(0, safeName("😀".repeat(130)).length))
    }

    @Test fun oldPermissionResultReleasesDifferentOwnerWithoutStartingIt() {
        val platform = ScanFixturePlatform().apply { granted = false }
        val coordinator = BleScanCoordinator(BleScanMachine(platform))
        val aHost = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val bHost = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val a = aHost.open(); val b = bHost.open()
        a.start(); val key = platform.permissionKey!!; aHost.destroy()
        assertFalse(aHost.hasRequester())
        aHost.hostStarted(); a.start()
        assertEquals(0, platform.starts)
        b.start()
        assertEquals(BleScanPhase.PERMISSION_PENDING, b.state.value.phase)
        platform.granted = true; aHost.permissionResult(key)
        assertEquals(BleScanPhase.IDLE, b.state.value.phase)
        assertEquals(0, platform.starts)
        b.start(); assertEquals(1, platform.starts)
    }

    @Test fun unconfinedCollectorsCannotReenterPartialTransitions() {
        for (trigger in listOf(BleScanPhase.IDLE, BleScanPhase.REQUESTING_PERMISSION, BleScanPhase.STARTING)) {
            val platform = ScanFixturePlatform()
            val coordinator = BleScanCoordinator(BleScanMachine(platform))
            val host = coordinator.host(platform::requestPermission).also { it.hostStarted() }
            val page = host.open()
            if (trigger == BleScanPhase.IDLE) {
                page.start(); platform.startDone!!.invoke(true); page.stop(); platform.stopDone!!.invoke(true)
            }
            if (trigger == BleScanPhase.REQUESTING_PERMISSION) platform.granted = false
            val scope = CoroutineScope(Dispatchers.Unconfined)
            val startsBefore = platform.starts; val requestsBefore = platform.requests
            var armed = false; var called = false; var sideEffectsAtClose = -1
            scope.launch { page.state.collect {
                if (armed && !called && it.phase == trigger) {
                    called = true; page.close(); sideEffectsAtClose = platform.starts + platform.requests
                }
            } }
            armed = true; page.start()
            assertTrue("reentrant close at $trigger", called)
            assertEquals("no backend effects after close returns at $trigger", sideEffectsAtClose, platform.starts + platform.requests)
            assertEquals("no backend invocation after cancelled $trigger", startsBefore + requestsBefore, platform.starts + platform.requests)
            if (platform.startDone != null) { platform.startDone!!.invoke(true); platform.startDone = null }
            if (platform.stopDone != null) { platform.stopDone!!.invoke(true); platform.stopDone = null }
            if (platform.permissionKey != null) { platform.granted = true; host.permissionResult(platform.permissionKey!!) }
            assertFalse("old page remains owner at $trigger", coordinator.owns(page))
            assertTrue(page.state.value.candidates.isEmpty())
            scope.cancel()
        }

        val platform = ScanFixturePlatform()
        val coordinator = BleScanCoordinator(BleScanMachine(platform))
        val host = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val page = host.open(); page.start(); platform.startDone!!.invoke(true); page.stop()
        val scope = CoroutineScope(Dispatchers.Unconfined)
        var armed = false; var restarted = false
        scope.launch { page.state.collect { if (armed && !restarted && it.phase == BleScanPhase.STOPPED) { restarted = true; page.start() } } }
        armed = true; platform.stopDone!!.invoke(true)
        assertTrue(restarted); assertEquals(2, platform.starts)
        assertTrue("new generation must retain owner", coordinator.owns(page))
        assertEquals(BleScanPhase.STARTING, page.state.value.phase)
        scope.cancel()
    }

    @Test fun reentrantStopAndHostStopFencePlatformStart() {
        for (stopHost in listOf(false, true)) {
            val platform = ScanFixturePlatform()
            val coordinator = BleScanCoordinator(BleScanMachine(platform))
            val host = coordinator.host(platform::requestPermission).also { it.hostStarted() }
            val page = host.open()
            val scope = CoroutineScope(Dispatchers.Unconfined)
            var stopped = false
            scope.launch { page.state.collect {
                if (!stopped && it.phase == BleScanPhase.STARTING) {
                    stopped = true
                    if (stopHost) host.hostStopped() else page.stop()
                }
            } }
            page.start()
            assertTrue(stopped)
            assertEquals("start after reentrant stop", 0, platform.starts)
            assertFalse(coordinator.owns(page))
            scope.cancel()
        }
    }

    @Test fun queuedCallbacksAfterSynchronousRevocationOnlyCleanUp() {
        for (event in listOf("candidate", "failure", "timeout")) {
            val platform = ScanFixturePlatform()
            val coordinator = BleScanCoordinator(BleScanMachine(platform))
            val host = coordinator.host(platform::requestPermission).also { it.hostStarted() }
            val page = host.open(); page.start(); platform.startDone!!.invoke(true)
            val scope = CoroutineScope(Dispatchers.Unconfined)
            val phases = mutableListOf<BleScanPhase>()
            val names = mutableListOf<String>()
            var armed = true
            scope.launch { page.state.collect { snapshot ->
                phases.add(snapshot.phase); names.addAll(snapshot.candidates.map { it.name })
                if (armed && snapshot.candidates.any { it.name == "first" }) {
                    armed = false
                    when (event) {
                        "candidate" -> platform.callback!!.result("late-key", "late", -55)
                        "failure" -> platform.callback!!.failed()
                        else -> { platform.nowMs = 15_001; platform.timer!!.invoke() }
                    }
                    page.stop()
                }
            } }
            platform.callback!!.result("first-key", "first", -40)
            assertFalse("late candidate leaked", "late" in names)
            assertEquals(BleScanPhase.STOPPING, page.state.value.phase)
            platform.stopDone!!.invoke(true)
            assertEquals(BleScanPhase.STOPPED, page.state.value.phase)
            assertFalse("stale failure published", BleScanPhase.FAILED in phases)
            scope.cancel()
        }

        val platform = ScanFixturePlatform()
        val coordinator = BleScanCoordinator(BleScanMachine(platform))
        val host = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val page = host.open()
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val phases = mutableListOf<BleScanPhase>()
        scope.launch { page.state.collect { phases.add(it.phase) } }
        platform.onStart = { completion -> completion(true); page.stop() }
        page.start()
        assertEquals(BleScanPhase.STOPPING, page.state.value.phase)
        assertEquals(1, platform.stops)
        assertFalse("cancelled completion published scanning", BleScanPhase.SCANNING in phases)
        platform.stopDone!!.invoke(true)
        assertEquals(BleScanPhase.STOPPED, page.state.value.phase)
        scope.cancel()

        val permissionPlatform = ScanFixturePlatform().apply { granted = false }
        val permissionCoordinator = BleScanCoordinator(BleScanMachine(permissionPlatform))
        val permissionHost = permissionCoordinator.host(permissionPlatform::requestPermission).also { it.hostStarted() }
        val permissionPage = permissionHost.open()
        permissionPlatform.onPermission = { key ->
            permissionPlatform.granted = true
            permissionHost.permissionResult(key)
            permissionPage.stop()
        }
        permissionPage.start()
        assertEquals(0, permissionPlatform.starts)
        assertEquals(BleScanPhase.STOPPED, permissionPage.state.value.phase)
        assertFalse(permissionCoordinator.owns(permissionPage))
    }

    @Test fun duplicateCandidateUpdatesWithoutExposingPlatformKey() {
        val platform = ScanFixturePlatform(); val source = BleScanMachine(platform)
        source.start(); platform.startDone!!.invoke(true)
        platform.callback!!.result("private-address", "first", -40)
        val first = source.state.value.candidates.single()
        platform.callback!!.result("private-address", "second", -55)
        val second = source.state.value.candidates.single()
        assertEquals(first.id, second.id); assertNotEquals("private-address", second.id)
        assertEquals("second", second.name); assertEquals(-55, second.rssi)
        assertFalse(source.state.value.toString().contains("second"))
        source.close(); assertEquals(BleScanPhase.STOPPING, source.state.value.phase)
    }

    @Test fun disposedPageClearsOnlyItsOwnMachineCandidatesAndKeys() {
        val platform = ScanFixturePlatform(); val machine = BleScanMachine(platform)
        val coordinator = BleScanCoordinator(machine)
        val hostA = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val a = hostA.open(); a.start(); platform.startDone!!.invoke(true)
        platform.callback!!.result("private-A", "A", -20)
        a.stop(); platform.stopDone!!.invoke(true)
        assertEquals(1, machine.retainedKeyCount())
        a.close()
        assertEquals(0, machine.retainedKeyCount())
        assertTrue(machine.state.value.candidates.isEmpty())

        val old = hostA.open(); old.start(); platform.startDone!!.invoke(true)
        platform.callback!!.result("private-old", "old", -25)
        old.stop(); platform.stopDone!!.invoke(true)
        val hostB = coordinator.host(platform::requestPermission).also { it.hostStarted() }
        val b = hostB.open(); b.start(); platform.startDone!!.invoke(true)
        platform.callback!!.result("private-B", "B", -30)
        assertEquals(1, machine.retainedKeyCount())
        old.close()
        assertEquals(1, machine.retainedKeyCount())
        assertEquals("B", machine.state.value.candidates.single().name)
        assertEquals("B", b.state.value.candidates.single().name)
    }
}

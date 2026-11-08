// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.os.Bundle
import android.content.Context
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

private class RealRegistry : ActivityResultRegistry() {
    var lastRequest = -1
    var launches = 0
    override fun <I : Any?, O : Any?> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
        lastRequest = requestCode; launches++
    }
}

private class PermissionPlatform : BleScanPlatform {
    var request: (String) -> Unit = {}
    var granted = false
    var starts = 0
    var stopThrows = false
    var startThrows = false
    var startedCallback: BleScanPlatform.Callback? = null
    var stoppedCallback: BleScanPlatform.Callback? = null
    override fun supported() = true
    override fun enabled() = true
    override fun permitted() = granted
    override fun requestPermission(key: String) = request(key)
    override fun start(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) { starts++; startedCallback = callback; completion(!startThrows) }
    override fun stop(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) { stoppedCallback = callback; completion(!stopThrows) }
    override fun now() = 0L
    override fun timeout(action: () -> Unit): () -> Unit = {}
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BlePermissionRegistryTest {
    @Test fun activityRecreationGetsDistinctHostFacades() {
        val application = ApplicationProvider.getApplicationContext<Context>()
        val first = ProcessBleScan.host(application) { _, _ -> }
        val second = ProcessBleScan.host(application) { _, _ -> }
        assertNotSame(first, second)
        assertSame(first.processIdentity, second.processIdentity)
    }

    @Test fun actualProcessCoordinatorRetainsQuarantineAcrossHosts() {
        for (failStart in listOf(false, true)) {
            val platform = PermissionPlatform().apply { granted = true; stopThrows = !failStart; startThrows = failStart }
            val application = ApplicationProvider.getApplicationContext<Context>()
            val process = BleScanProcessOwner { platform }
            val oldHost = process.host(application, platform::requestPermission).also { it.hostStarted() }
            val first = oldHost.open(); first.start(); first.stop(); first.close(); oldHost.hostStopped()
            if (!failStart) assertSame(platform.startedCallback, platform.stoppedCallback)
            val newHost = process.host(application, platform::requestPermission).also { it.hostStarted() }
            val second = newHost.open(); second.start()
            assertEquals("CLEANUP_REQUIRED", second.state.value.phase.name)
            assertEquals(1, platform.starts)
        }
    }
    @Test fun restoredCachedResultIsDeliveredSynchronouslyWithoutRelaunch() {
        val first = RealRegistry()
        val firstBroker = BlePermissionRegistry(first) { }
        firstBroker.register("old-key", "android.permission.BLUETOOTH_SCAN")
        val saved = Bundle(); first.onSaveInstanceState(saved)
        val requestCode = first.lastRequest

        val restored = RealRegistry(); restored.onRestoreInstanceState(saved)
        assertTrue(restored.dispatchResult(requestCode, true))
        val received = mutableListOf<String>()
        val broker = BlePermissionRegistry(restored) { received.add(it) }
        broker.register("old-key", "android.permission.BLUETOOTH_SCAN")
        assertEquals(listOf("old-key"), received)
        assertEquals(0, restored.launches)
        assertTrue(broker.keys().isEmpty())
    }

    @Test fun oldAndNewRequestKeysKeepSeparateOwnership() {
        val registry = RealRegistry()
        val seen = mutableListOf<String>()
        val broker = BlePermissionRegistry(registry) { seen.add(it) }
        broker.register("old-key", "old")
        val old = registry.lastRequest
        broker.register("new-key", "new")
        val new = registry.lastRequest
        assertNotEquals(old, new)
        assertTrue(registry.dispatchResult(old, true))
        assertEquals(listOf("old-key"), seen)
        assertTrue(registry.dispatchResult(new, false))
        assertEquals(listOf("old-key", "new-key"), seen)
    }

    @Test fun rotatedAndUnownedCachedResultsNeverStartScanning() {
        val platform = PermissionPlatform()
        val source = BleScanMachine(platform)
        val first = RealRegistry()
        val broker = BlePermissionRegistry(first) { source.permissionResult(it) }
        platform.request = { broker.register(it, "android.permission.BLUETOOTH_SCAN") }
        source.start()
        val key = source.pendingPermissionKey()!!
        val saved = Bundle(); first.onSaveInstanceState(saved)
        val code = first.lastRequest
        source.stop() // Activity loss invalidates the old generation
        platform.granted = true
        val restored = RealRegistry(); restored.onRestoreInstanceState(saved)
        assertTrue(restored.dispatchResult(code, true))
        BlePermissionRegistry(restored) { source.permissionResult(it) }.register(key)
        assertEquals(0, platform.starts)
        assertEquals("STOPPED", source.state.value.phase.name)

        val freshPlatform = PermissionPlatform()
        val fresh = BleScanMachine(freshPlatform)
        val unowned = RealRegistry(); unowned.onRestoreInstanceState(saved)
        assertTrue(unowned.dispatchResult(code, true))
        BlePermissionRegistry(unowned) { fresh.permissionResult(it) }.register(key)
        assertEquals(0, freshPlatform.starts)
        assertEquals("IDLE", fresh.state.value.phase.name)
    }
}

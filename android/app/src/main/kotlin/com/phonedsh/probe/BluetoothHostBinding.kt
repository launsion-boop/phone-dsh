// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import android.content.ContextWrapper
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.util.UUID

private const val CONNECT_KEY_PREFIX = "pdsh-ble-connect-"

private tailrec fun Context.componentActivity(): ComponentActivity? = when (this) {
    is ComponentActivity -> this
    is ContextWrapper -> baseContext.componentActivity()
    else -> null
}

/**
 * Binds this Activity as one non-reusable scan host (android-ble-discovery.md):
 * its own permission launcher, ON_START/ON_STOP, and destroy on disposal. A
 * pending scan-permission key is re-registered after recreation so its answer is
 * consumed by its original owner; it never starts a scan by itself.
 */
@Composable
internal fun BindBluetoothHost(devices: AndroidBleDevices) {
    val activity = LocalContext.current.componentActivity() ?: return
    DisposableEffect(activity) {
        var host: BleScanCoordinator.Host? = null
        val registry = BlePermissionRegistry(activity.activityResultRegistry) { key ->
            if (key.startsWith(CONNECT_KEY_PREFIX)) devices.connectPermissionResult() else host?.permissionResult(key)
        }
        val bound = ProcessBleScan.host(activity) { key, permission -> registry.register(key, permission) }
        host = bound
        bound.pendingPermissionKey()?.let { registry.register(it) }
        devices.attachHost(bound) { permission -> registry.register(CONNECT_KEY_PREFIX + UUID.randomUUID(), permission) }
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> bound.hostStarted()
                Lifecycle.Event.ON_STOP -> bound.hostStopped()
                else -> Unit
            }
        }
        activity.lifecycle.addObserver(observer)
        onDispose {
            activity.lifecycle.removeObserver(observer)
            devices.detachHost(bound)
            bound.destroy()
        }
    }
}

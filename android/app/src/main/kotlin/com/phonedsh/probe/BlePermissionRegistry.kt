// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContracts

/** Request-specific keys survive Activity recreation and are never reused. */
internal class BlePermissionRegistry(
    private val registry: ActivityResultRegistry,
    private val onResult: (String) -> Unit,
) {
    private val launchers = mutableMapOf<String, ActivityResultLauncher<String>>()
    fun keys(): ArrayList<String> = ArrayList(launchers.keys)

    fun register(key: String, permission: String? = null) {
        if (launchers.containsKey(key)) return
        var delivered = false
        var launcher: ActivityResultLauncher<String>? = null
        val registered = registry.register(key, ActivityResultContracts.RequestPermission()) {
            delivered = true
            onResult(key)
            launcher?.unregister()
            launchers.remove(key)
        }
        launcher = registered
        if (delivered) registered.unregister() else {
            launchers[key] = registered
            if (permission != null) {
                try { registered.launch(permission) } catch (error: RuntimeException) {
                    launchers.remove(key); registered.unregister(); throw error
                }
            }
        }
    }
}

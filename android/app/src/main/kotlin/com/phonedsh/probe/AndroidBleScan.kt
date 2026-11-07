// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

/** The same owner class is used by the process singleton and deterministic tests. */
internal class BleScanProcessOwner(private val factory: (Context) -> BleScanPlatform) {
    private var coordinator: BleScanCoordinator? = null
    fun host(context: Context, request: (String) -> Unit): BleScanCoordinator.Host {
        if (coordinator == null) {
            val backend = factory(context.applicationContext)
            coordinator = BleScanCoordinator(BleScanMachine(backend))
        }
        return checkNotNull(coordinator).host(request)
    }
}

/** Owns the machine, scanner and unresolved callback for this entire process. */
internal object ProcessBleScan {
    private val process = BleScanProcessOwner(::AndroidBlePlatform)
    fun host(context: Context, request: (String, String) -> Unit): BleScanCoordinator.Host =
        process.host(context) { key ->
            val permission = if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_SCAN else Manifest.permission.ACCESS_FINE_LOCATION
            request(key, permission)
        }
}

internal class AndroidBlePlatform(private val context: Context) : BleScanPlatform {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val callbacks = IdentityHashMap<BleScanPlatform.Callback, Pair<BluetoothLeScanner, ScanCallback>>()
    private val manager get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val permission get() = if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_SCAN else Manifest.permission.ACCESS_FINE_LOCATION

    override fun supported(): Boolean = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) && manager?.adapter != null
    override fun enabled(): Boolean = manager?.adapter?.isEnabled == true
    override fun permitted(): Boolean = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    override fun requestPermission(key: String) { error("Permission must be requested by the owning host") }

    override fun start(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) {
        val scanner = manager?.adapter?.bluetoothLeScanner ?: throw IllegalStateException("BLE scanner unavailable")
        val pending = AtomicInteger()
        val failurePending = AtomicBoolean()
        val systemCallback = object : ScanCallback() {
            private fun enqueue(result: ScanResult) {
                // Bound posted candidate events independently of radio callback rate.
                if (pending.incrementAndGet() > 128) { pending.decrementAndGet(); return }
                main.post {
                    try { callback.result(result.device, result.scanRecord?.deviceName, result.rssi) }
                    finally { pending.decrementAndGet() }
                }
            }
            override fun onScanResult(callbackType: Int, result: ScanResult) { enqueue(result) }
            override fun onBatchScanResults(results: MutableList<ScanResult>) { results.forEach(::enqueue) }
            override fun onScanFailed(errorCode: Int) {
                if (failurePending.compareAndSet(false, true)) main.post {
                    try { callback.failed() } finally { failurePending.set(false) }
                }
            }
        }
        callbacks[callback] = scanner to systemCallback
        worker.execute {
            val success = try { scanner.startScan(systemCallback); true } catch (_: RuntimeException) { false }
            main.post { completion(success) }
        }
    }

    override fun stop(callback: BleScanPlatform.Callback, completion: (Boolean) -> Unit) {
        val pair = callbacks[callback] ?: throw IllegalStateException("Missing scan callback")
        worker.execute {
            val success = try { pair.first.stopScan(pair.second); true } catch (_: RuntimeException) { false }
            main.post {
                if (success) callbacks.remove(callback)
                completion(success)
            }
        }
    }
    override fun now(): Long = SystemClock.elapsedRealtime()
    override fun timeout(action: () -> Unit): () -> Unit {
        val runnable = Runnable(action)
        main.postDelayed(runnable, 15_000L)
        return { main.removeCallbacks(runnable) }
    }
}

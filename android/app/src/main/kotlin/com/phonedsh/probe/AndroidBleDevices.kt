// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.phonedsh.domain.connector.ble.BleScanPhase
import com.phonedsh.domain.connector.ble.BleScanSnapshot
import com.phonedsh.domain.connector.ble.StandardBleFailure
import com.phonedsh.domain.connector.ble.StandardBleProfile
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.BluetoothDeviceFact
import com.phonedsh.ui.page.BluetoothDevicePhase
import com.phonedsh.ui.page.BluetoothFacts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The Bluetooth devices page's process-owned store: scan through the existing
 * [BleScanCoordinator] lease and standard GATT per `spec/device/v1/android-standard-gatt.md`.
 *
 * Main-thread only. Every GATT callback is posted to the main looper and accepted
 * only for the [Conn] whose current [BluetoothGatt] delivered it. No Link channel,
 * task, identity, bonding or agent tool lives here (GAP-20 keeps those `target`).
 */
@SuppressLint("MissingPermission") // every platform call is guarded by connectPermitted()
internal class AndroidBleDevices(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutable = MutableStateFlow(BluetoothFacts(available = false, status = "打开此页后可扫描"))
    val facts: StateFlow<BluetoothFacts> = mutable.asStateFlow()

    private var host: BleScanCoordinator.Host? = null
    private var requestConnectPermission: ((String) -> Unit)? = null
    private var page: BleScanCoordinator.Page? = null
    /**
     * Mounted Bluetooth routes. An Activity recreation may dispose the old route
     * after the new one mounted, so visibility is a count, never a boolean.
     */
    private var visibleRoutes = 0
    private var pageJob: Job? = null
    private var scan = BleScanSnapshot()
    private val conns = LinkedHashMap<String, Conn>()
    private var message = ""

    private class PendingRead(val profile: StandardBleProfile, val characteristic: BluetoothGattCharacteristic, val timeout: Runnable)

    private inner class Conn(val id: String, var name: String, var rssi: Int, val device: BluetoothDevice) {
        var gatt: BluetoothGatt? = null
        var phase = BluetoothDevicePhase.IDLE
        var state = "未连接"
        val profiles = LinkedHashMap<StandardBleProfile, BluetoothGattCharacteristic>()
        val readings = LinkedHashMap<String, String>()
        var allowRead = false
        var allowAlert = false
        var pending: PendingRead? = null
        var connectDeadline: Runnable? = null
        val events = ArrayDeque<String>()
        fun event(text: String) { events.addLast(text); while (events.size > 5) events.removeFirst() }
    }

    // -- host binding ------------------------------------------------------

    fun attachHost(host: BleScanCoordinator.Host, requestConnect: (String) -> Unit) {
        this.host = host
        requestConnectPermission = requestConnect
        reconcile()
    }

    fun detachHost(host: BleScanCoordinator.Host) {
        if (this.host !== host) return
        this.host = null
        requestConnectPermission = null
        reconcile()
    }

    fun handle(action: PdshHostAction) {
        when (action) {
            is PdshHostAction.BluetoothPageVisible -> {
                visibleRoutes = (visibleRoutes + if (action.visible) 1 else -1).coerceAtLeast(0)
                reconcile()
            }
            is PdshHostAction.BluetoothScan -> if (action.start) page?.start() else page?.stop()
            is PdshHostAction.BluetoothConnect -> connect(action.id)
            is PdshHostAction.BluetoothDisconnect -> conns[action.id]?.let { close(it, "已断开") }
            is PdshHostAction.BluetoothGrant -> grant(action.id, action.read, action.alert)
            is PdshHostAction.BluetoothRead -> read(action.id, action.profile)
            is PdshHostAction.BluetoothAlert -> alert(action.id, action.level)
            else -> return
        }
        publish()
    }

    /** A system answer for the connect permission; the person taps 连接 again. */
    fun connectPermissionResult() {
        message = if (connectPermitted()) "已获得连接权限，请再次点击「连接并发现设备能力」" else "未获得蓝牙连接权限"
        publish()
    }

    /**
     * One page lease exists only while a route is mounted and owned by the current
     * host. A lease of another (destroyed) host is closed together with every
     * connection it led to; nothing survives into the new host's lease.
     */
    private fun reconcile() {
        val current = page
        val wanted = visibleRoutes > 0 && host != null
        if (current != null && (!wanted || current.host !== host)) {
            conns.values.toList().forEach { close(it, "未连接") }
            conns.clear()
            pageJob?.cancel(); pageJob = null
            current.close(); page = null
            scan = BleScanSnapshot()
            message = ""
        }
        if (wanted && page == null) {
            val opened = checkNotNull(host).open() as BleScanCoordinator.Page
            page = opened
            pageJob = scope.launch { opened.state.collect { scan = it; publish() } }
        }
        publish()
    }

    // -- connection --------------------------------------------------------

    private fun connectPermitted(): Boolean = Build.VERSION.SDK_INT < 31 ||
        context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun connect(id: String) {
        val existing = conns[id]
        if (existing != null && existing.phase != BluetoothDevicePhase.IDLE) return
        if (!connectPermitted()) {
            requestConnectPermission?.invoke(Manifest.permission.BLUETOOTH_CONNECT)
            message = "需要「附近设备」连接权限；授权后请再次点击连接"
            return
        }
        val lease = page ?: return
        val device = lease.platformKey(id) as? BluetoothDevice
        if (device == null) { message = "该扫描结果已失效，请重新扫描"; return }
        val candidate = scan.candidates.firstOrNull { it.id == id }
        lease.stop()
        val conn = Conn(id, candidate?.name ?: existing?.name ?: "未命名 BLE 设备", candidate?.rssi ?: existing?.rssi ?: 0, device)
        conns[id] = conn
        conn.phase = BluetoothDevicePhase.CONNECTING
        conn.state = "连接中"
        val deadline = Runnable { if (conns[id] === conn && conn.phase == BluetoothDevicePhase.CONNECTING) { close(conn, "连接或服务发现超时"); publish() } }
        conn.connectDeadline = deadline
        main.postDelayed(deadline, CONNECT_TIMEOUT_MS)
        val gatt = try {
            device.connectGatt(context, false, callbackFor(conn), BluetoothDevice.TRANSPORT_LE)
        } catch (_: RuntimeException) { null }
        if (gatt == null) { close(conn, "连接请求未提交"); return }
        conn.gatt = gatt
    }

    private fun current(conn: Conn, gatt: BluetoothGatt): Boolean = conns[conn.id] === conn && conn.gatt === gatt

    private fun callbackFor(conn: Conn) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (!current(conn, gatt)) return@post
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    conn.state = "已连接，正在发现服务"
                    val started = try { connectPermitted() && gatt.discoverServices() } catch (_: RuntimeException) { false }
                    if (!started) close(conn, "服务发现未提交")
                } else {
                    close(conn, if (status == BluetoothGatt.GATT_SUCCESS) "未连接" else "连接断开（GATT 状态 $status）")
                }
                publish()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                if (!current(conn, gatt) || conn.phase != BluetoothDevicePhase.CONNECTING) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { close(conn, "服务发现失败（GATT 状态 $status）"); publish(); return@post }
                conn.connectDeadline?.let { main.removeCallbacks(it) }; conn.connectDeadline = null
                conn.profiles.clear()
                for (service in gatt.services) for (characteristic in service.characteristics) {
                    val profile = StandardBleProfile.matching(service.uuid, characteristic.uuid) ?: continue
                    val needed = if (profile == StandardBleProfile.ALERT) {
                        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
                    } else {
                        BluetoothGattCharacteristic.PROPERTY_READ
                    }
                    if (characteristic.properties and needed != 0 && profile !in conn.profiles) conn.profiles[profile] = characteristic
                }
                conn.phase = BluetoothDevicePhase.CONNECTED
                conn.state = "已连接"
                conn.allowRead = false
                conn.allowAlert = false
                conn.event("发现标准能力：" + (conn.profiles.keys.joinToString { it.rawValue }.ifEmpty { "无" }))
                publish()
            }
        }

        override fun onServiceChanged(gatt: BluetoothGatt) {
            main.post { if (current(conn, gatt)) { close(conn, "设备服务已变化，请重新连接"); publish() } }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            val copy = value.copyOf()
            main.post { readResult(conn, gatt, characteristic, copy, status) }
        }

        @Deprecated("Pre-API-33 delivery; API 33+ uses the value overload above")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT >= 33) return
            @Suppress("DEPRECATION") val copy = characteristic.value?.copyOf() ?: ByteArray(0)
            main.post { readResult(conn, gatt, characteristic, copy, status) }
        }
    }

    private fun readResult(conn: Conn, gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
        if (!current(conn, gatt)) return
        val pending = conn.pending ?: return
        if (pending.characteristic !== characteristic) return
        conn.pending = null
        main.removeCallbacks(pending.timeout)
        val profile = pending.profile
        message = if (status != BluetoothGatt.GATT_SUCCESS) {
            val hint = if (status == GATT_INSUFFICIENT_AUTHENTICATION || status == GATT_INSUFFICIENT_ENCRYPTION) "；设备要求加密或配对" else ""
            "读取 ${profile.rawValue} 失败（GATT 状态 $status$hint）"
        } else {
            try {
                val text = profile.decode(value)
                conn.readings[profile.rawValue] = text + profile.unit
                "${profile.rawValue}: $text${profile.unit}"
            } catch (failure: StandardBleFailure) {
                "读取 ${profile.rawValue} 失败：${failure.message}"
            }
        }
        publish()
    }

    private fun grant(id: String, read: Boolean?, alert: Boolean?) {
        val conn = conns[id] ?: return
        if (conn.phase != BluetoothDevicePhase.CONNECTED) return
        if (read != null) conn.allowRead = read
        if (alert != null && StandardBleProfile.ALERT in conn.profiles) conn.allowAlert = alert
    }

    private fun read(id: String, profileName: String) {
        val conn = conns[id] ?: return
        val profile = StandardBleProfile.entries.firstOrNull { it.rawValue == profileName && it != StandardBleProfile.ALERT } ?: return
        val gatt = conn.gatt
        val characteristic = conn.profiles[profile]
        when {
            !conn.allowRead -> { message = "请先开启「允许读取标准数据」"; return }
            conn.phase != BluetoothDevicePhase.CONNECTED || gatt == null || characteristic == null -> { message = "读取不可用"; return }
            conn.pending != null -> { message = "蓝牙忙，请稍后再试"; return }
            !connectPermitted() -> { message = "未获得蓝牙连接权限"; return }
        }
        val timeout = Runnable {
            if (conns[id] === conn && conn.pending?.profile == profile) {
                message = "读取 ${profile.rawValue} 超时；已断开连接，避免迟到的结果被当成下一次读取"
                close(conn, "读取超时，已断开")
                publish()
            }
        }
        val submitted = try { gatt!!.readCharacteristic(characteristic) } catch (_: RuntimeException) { false }
        if (!submitted) { message = "读取未提交（蓝牙忙或不可用）"; return }
        conn.pending = PendingRead(profile, characteristic!!, timeout)
        main.postDelayed(timeout, READ_TIMEOUT_MS)
        message = "正在读取 ${profile.rawValue}…"
    }

    private fun alert(id: String, level: Int) {
        val conn = conns[id] ?: return
        val gatt = conn.gatt
        val characteristic = conn.profiles[StandardBleProfile.ALERT]
        if (!conn.allowAlert) { message = "请先开启「允许提醒控制」"; return }
        val command = try { StandardBleProfile.alertCommand(level) } catch (failure: StandardBleFailure) { message = failure.message ?: "提醒级别无效"; return }
        if (conn.phase != BluetoothDevicePhase.CONNECTED || gatt == null || characteristic == null || conn.pending != null || !connectPermitted()) {
            message = "提醒不可用或蓝牙忙"; return
        }
        val submitted = try {
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(characteristic, command, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    characteristic.value = command
                    gatt.writeCharacteristic(characteristic)
                }
            }
        } catch (_: RuntimeException) { false }
        message = if (submitted) StandardBleProfile.ALERT_SUBMITTED else "提醒未提交（蓝牙忙或不可用）"
    }

    /** Ends one generation: timers, pending read, platform object. Idempotent. */
    private fun close(conn: Conn, state: String) {
        conn.connectDeadline?.let { main.removeCallbacks(it) }; conn.connectDeadline = null
        conn.pending?.let { main.removeCallbacks(it.timeout); message = "读取 ${it.profile.rawValue} 未完成：连接已结束" }
        conn.pending = null
        val gatt = conn.gatt
        conn.gatt = null
        if (gatt != null) {
            try { if (connectPermitted()) gatt.disconnect() } catch (_: RuntimeException) {}
            try { if (connectPermitted()) gatt.close() } catch (_: RuntimeException) {}
        }
        conn.phase = BluetoothDevicePhase.IDLE
        conn.state = state
        conn.profiles.clear()
        conn.allowRead = false
        conn.allowAlert = false
    }

    // -- projection --------------------------------------------------------

    private fun scanStatus(snapshot: BleScanSnapshot): String = when (snapshot.phase) {
        BleScanPhase.IDLE -> "可以扫描附近 BLE 设备"
        BleScanPhase.HOST_INACTIVE -> "应用不在前台，暂不扫描"
        BleScanPhase.BUSY -> "另一个页面正在使用蓝牙扫描"
        BleScanPhase.REQUESTING_PERMISSION, BleScanPhase.PERMISSION_PENDING -> "等待蓝牙扫描授权"
        BleScanPhase.STARTING -> "正在启动扫描"
        BleScanPhase.SCANNING -> "正在扫描（最多 15 秒）· 已发现 ${snapshot.candidates.size} 个"
        BleScanPhase.STOPPING -> "正在停止扫描"
        BleScanPhase.STOPPED -> "扫描已停止 · 共 ${snapshot.candidates.size} 个"
        BleScanPhase.PERMISSION_DENIED -> "未获得蓝牙扫描权限"
        BleScanPhase.BLUETOOTH_OFF -> "蓝牙已关闭"
        BleScanPhase.UNSUPPORTED -> "此设备不支持 BLE"
        BleScanPhase.FAILED -> "扫描失败" + if (snapshot.failure != null) "（${snapshot.failure}）" else ""
        BleScanPhase.CLEANUP_REQUIRED -> "系统扫描未确认停止；请重启应用后再扫描"
    }

    private fun publish() {
        val shown = LinkedHashMap<String, BluetoothDeviceFact>()
        for ((id, conn) in conns) {
            if (conn.phase == BluetoothDevicePhase.IDLE && scan.candidates.none { it.id == id }) continue
            shown[id] = BluetoothDeviceFact(
                id = id, name = conn.name, rssi = conn.rssi, phase = conn.phase, state = conn.state,
                profiles = conn.profiles.keys.map { it.rawValue }, readings = conn.readings.toMap(),
                allowRead = conn.allowRead, allowAlert = conn.allowAlert, events = conn.events.toList(),
            )
        }
        for (candidate in scan.candidates) {
            if (candidate.id in shown) continue
            shown[candidate.id] = BluetoothDeviceFact(candidate.id, candidate.name, candidate.rssi)
        }
        mutable.value = BluetoothFacts(
            available = page != null,
            status = if (page == null) "打开此页后可扫描" else scanStatus(scan),
            scanning = scan.phase == BleScanPhase.STARTING || scan.phase == BleScanPhase.SCANNING,
            devices = shown.values.toList(),
            message = message,
        )
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 20_000L
        const val READ_TIMEOUT_MS = 10_000L
        private const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        private const val GATT_INSUFFICIENT_ENCRYPTION = 15

        @Volatile private var instance: AndroidBleDevices? = null
        fun get(context: Context): AndroidBleDevices =
            instance ?: synchronized(this) { instance ?: AndroidBleDevices(context.applicationContext).also { instance = it } }
    }
}

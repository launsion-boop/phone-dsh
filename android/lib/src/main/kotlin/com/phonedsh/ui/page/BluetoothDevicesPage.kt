// Bluetooth devices: foreground scan, standard GATT reads and Immediate Alert.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/BluetoothDevicesPage.swift`.
// Contract: `spec/ui/v1/pages/bluetooth-devices.json`; behaviour:
// `spec/device/v1/android-ble-discovery.md` and `android-standard-gatt.md`.
//
// Android implements the standard-GATT part only. The PDSH Link tool toggles
// (`允许工具：…`) and device tasks are not rendered: GAP-20 keeps the Android Link
// channel `target`. The grants gate this page's own buttons; no agent tool is
// exposed on Android, and the copy says so instead of repeating the iOS wording.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.Switch
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.surface.SettingsBodyRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame

/** Where one device's connection stands; the page never infers it from text. */
public enum class BluetoothDevicePhase { IDLE, CONNECTING, CONNECTED, UNAVAILABLE }

/**
 * One scanned or connected peripheral. [id] is the scan's random opaque id, never
 * a platform address; [name] and [rssi] are untrusted advertisement data.
 */
@Immutable
public data class BluetoothDeviceFact(
    public val id: String,
    public val name: String,
    public val rssi: Int,
    public val phase: BluetoothDevicePhase = BluetoothDevicePhase.IDLE,
    public val state: String = "未连接",
    /** Discovered standard profiles by wire name (`battery`, `alert`, …). */
    public val profiles: List<String> = emptyList(),
    public val readings: Map<String, String> = emptyMap(),
    public val allowRead: Boolean = false,
    public val allowAlert: Boolean = false,
    public val events: List<String> = emptyList(),
) {
    override fun toString(): String = "BluetoothDeviceFact(redacted, phase=$phase)"

    /** iOS `BluetoothDevicesPage.isVisible`: connected, capable or one of ours. */
    public val visibleByDefault: Boolean
        get() = phase != BluetoothDevicePhase.IDLE || profiles.isNotEmpty() || name.startsWith("PDSH")
}

/** The page's whole input, owned by the host. */
@Immutable
public data class BluetoothFacts(
    /** False when the host has no Bluetooth adapter wired (the page stays read-only). */
    public val available: Boolean = false,
    public val status: String = "蓝牙不可用",
    public val scanning: Boolean = false,
    public val devices: List<BluetoothDeviceFact> = emptyList(),
    /** The last read / alert result or failure (`结果`). */
    public val message: String = "",
) {
    override fun toString(): String = "BluetoothFacts(available=$available, scanning=$scanning, devices=${devices.size})"
}

@Composable
private fun grantStyle() = LocalUiType.current.body.copy(color = LocalUiTokens.current.colors.primary)

/**
 * One grant switch row's frame: the whole row is the toggle target (like
 * `SettingsToggleRow`), and the Switch inside only shows the state.
 */
@Composable
private fun grantRowModifier(tag: String, checked: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit): Modifier {
    val tokens = LocalUiTokens.current
    return Modifier
        .fillMaxWidth()
        .testTag(tag)
        .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onToggle)
        .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
        .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText)
}



@Composable
public fun BluetoothDevicesPage(
    facts: BluetoothFacts,
    onBack: () -> Unit,
    onScan: (start: Boolean) -> Unit,
    onConnect: (id: String) -> Unit,
    onDisconnect: (id: String) -> Unit,
    onGrantRead: (id: String, enabled: Boolean) -> Unit,
    onGrantAlert: (id: String, enabled: Boolean) -> Unit,
    onRead: (id: String, profile: String) -> Unit,
    onAlert: (id: String, level: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var showOtherDevices by remember { mutableStateOf(false) }
    val visible = facts.devices.filter { it.visibleByDefault }
    val hidden = facts.devices.filterNot { it.visibleByDefault }
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "蓝牙设备",
        onBack = onBack,
        rootTag = UiPageTags.BLUETOOTH_ROOT,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            LazyColumn(
                modifier = Modifier.fillMaxSize().testTag(UiPageTags.BLUETOOTH_LIST),
                verticalArrangement = Arrangement.Top,
            ) {
                item(key = "scan.status") { SettingsBodyRow(text = facts.status) }
                item(key = "scan.action") {
                    if (facts.scanning) {
                        InfoRow(
                            title = "停止扫描",
                            value = null,
                            modifier = Modifier.testTag(UiPageTags.BLUETOOTH_SCAN),
                            onClick = { onScan(false) },
                        )
                    } else {
                        InfoRow(
                            title = "扫描附近 BLE 设备",
                            value = null,
                            enabled = facts.available,
                            modifier = Modifier.testTag(UiPageTags.BLUETOOTH_SCAN),
                            onClick = { onScan(true) },
                        )
                    }
                }
                item(key = "scan.note") {
                    SettingsFootnoteRow(
                        text = "只在此页主动扫描。选择设备后发现标准服务；每次连接需单独授权 Agent 读取或提醒控制。设备名称和系统标识不代表已验证身份。",
                    )
                }
                item(key = "scan.android") {
                    SettingsFootnoteRow(text = "Android 上这些授权只控制本页的读取和提醒按钮，暂不向 Agent 开放蓝牙工具。")
                }
                visible.forEach { device ->
                    deviceSection(device, onConnect, onDisconnect, onGrantRead, onGrantAlert, onRead, onAlert)
                }
                if (hidden.isNotEmpty()) {
                    item(key = "other.toggle") {
                        // iOS toggles 展开 / 收起 in the button text; here the
                        // collapsible header's chevron carries the same state.
                        SectionHeader(
                            title = UiStrings.BLE_SHOW_OTHER_DEVICES.format(hidden.size),
                            expanded = showOtherDevices,
                            onToggle = { showOtherDevices = !showOtherDevices },
                        )
                    }
                    if (showOtherDevices) {
                        hidden.forEach { device ->
                            deviceSection(device, onConnect, onDisconnect, onGrantRead, onGrantAlert, onRead, onAlert)
                        }
                    }
                }
                if (facts.message.isNotEmpty()) {
                    item(key = "result.header") { SettingsSectionLabel("结果") }
                    item(key = "result.body") { SettingsBodyRow(text = facts.message) }
                }
                item(key = "scope.header") { SettingsSectionLabel("支持范围") }
                item(key = "scope.body") {
                    SettingsBodyRow(
                        text = "标准电量、环境温度 / 湿度、厂商 / 型号与 Immediate Alert。提醒是标准 Write Without Response，" +
                            "只能确认提交，不能确认硬件执行。Android 暂不支持 PDSH Link 工具扩展、设备派任务、音频、HID 控制、" +
                            "HomeKit / Matter 或私有 GATT 协议。",
                    )
                }
            }
        }
    }
}

private fun LazyListScope.deviceSection(
    device: BluetoothDeviceFact,
    onConnect: (String) -> Unit,
    onDisconnect: (String) -> Unit,
    onGrantRead: (String, Boolean) -> Unit,
    onGrantAlert: (String, Boolean) -> Unit,
    onRead: (String, String) -> Unit,
    onAlert: (String, Int) -> Unit,
) {
    val id = device.id
    item(key = "device.$id.header") { SettingsSectionLabel(device.name) }
    when (device.phase) {
        BluetoothDevicePhase.UNAVAILABLE -> {
            item(key = "device.$id.state") { SettingsBodyRow(text = device.state) }
            item(key = "device.$id.rssi") { SettingsFootnoteRow(text = "RSSI ${device.rssi}") }
        }
        BluetoothDevicePhase.IDLE -> {
            item(key = "device.$id.state") { SettingsBodyRow(text = "${device.state} · RSSI ${device.rssi}") }
            item(key = "device.$id.connect") {
                InfoRow(
                    title = "连接并发现设备能力",
                    value = null,
                    modifier = Modifier.testTag(UiPageTags.BLUETOOTH_CONNECT),
                    onClick = { onConnect(id) },
                )
            }
        }
        BluetoothDevicePhase.CONNECTING, BluetoothDevicePhase.CONNECTED -> {
            item(key = "device.$id.state") { SettingsBodyRow(text = "${device.state} · RSSI ${device.rssi}") }
            item(key = "device.$id.disconnect") {
                InfoRow(
                    title = "断开连接",
                    value = null,
                    modifier = Modifier.testTag(UiPageTags.BLUETOOTH_DISCONNECT),
                    onClick = { onDisconnect(id) },
                )
            }
            item(key = "device.$id.reauth") { SettingsFootnoteRow(text = "每次建立新连接后，请重新授权读取或提醒控制。") }
            item(key = "device.$id.grant.read") {
                val readEnabled = device.phase == BluetoothDevicePhase.CONNECTED
                Row(
                    modifier = grantRowModifier(UiPageTags.BLUETOOTH_GRANT_READ, device.allowRead, readEnabled) { onGrantRead(id, it) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(text = "允许读取标准数据", modifier = Modifier.weight(1f), style = grantStyle())
                    Switch(checked = device.allowRead, enabled = readEnabled, onCheckedChange = null)
                }
            }
            if ("alert" in device.profiles) {
                item(key = "device.$id.grant.alert") {
                    val alertEnabled = device.phase == BluetoothDevicePhase.CONNECTED
                    Row(
                        modifier = grantRowModifier(UiPageTags.BLUETOOTH_GRANT_ALERT, device.allowAlert, alertEnabled) { onGrantAlert(id, it) },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BasicText(text = "允许提醒控制（蜂鸣 / 震动）", modifier = Modifier.weight(1f), style = grantStyle())
                        Switch(checked = device.allowAlert, enabled = alertEnabled, onCheckedChange = null)
                    }
                }
                item(key = "device.$id.alert.0") {
                    InfoRow(title = "停止提醒", value = null, enabled = device.allowAlert, onClick = { onAlert(id, 0) })
                }
                item(key = "device.$id.alert.1") {
                    InfoRow(title = "轻度提醒", value = null, enabled = device.allowAlert, onClick = { onAlert(id, 1) })
                }
                item(key = "device.$id.alert.2") {
                    InfoRow(title = "高度提醒", value = null, enabled = device.allowAlert, onClick = { onAlert(id, 2) })
                }
            }
            device.profiles.filter { it != "alert" }.forEach { profile ->
                item(key = "device.$id.read.$profile") {
                    InfoRow(
                        title = UiStrings.BLE_READ_PROFILE.format(profile),
                        value = device.readings[profile],
                        enabled = device.allowRead,
                        modifier = Modifier.testTag("${UiPageTags.BLUETOOTH_READ}.$profile"),
                        onClick = { onRead(id, profile) },
                    )
                }
            }
            device.events.forEachIndexed { index, event ->
                item(key = "device.$id.event.$index") { SettingsFootnoteRow(text = event) }
            }
            if (device.phase == BluetoothDevicePhase.CONNECTED && device.profiles.isEmpty()) {
                item(key = "device.$id.none") { SettingsBodyRow(text = "尚未发现可用标准能力；厂商私有服务需要专用适配器。") }
            }
        }
    }
}

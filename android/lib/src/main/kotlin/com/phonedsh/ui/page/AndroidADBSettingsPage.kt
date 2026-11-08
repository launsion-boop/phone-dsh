// Android ADB: the saved LAN TCP/IP ADB target this phone controls, and its test.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/AndroidADBSettingsPage.swift`.
// Contract: `spec/ui/v1/pages/android-adb-settings.json`; behaviour:
// `spec/v1/native-mcp.md` (the android_* tools on this host's `/mcp/native`).
//
// The host (`:app` AndroidAdbHost) owns the saved target, the Keystore-wrapped
// RSA identity and the one Android operation slot; this page only edits drafts
// and sends 保存 / 测试连接 / 停止当前 Android 操作. The copy says 这台手机 where
// iOS says iPhone, and states the one iOS capability this host does not have
// (the Worker's `adb push/pull` file transfer).
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsBodyRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The host's saved target and the last operation's status line. */
@Immutable
public data class AndroidAdbFacts(
    /** False when this host has no ADB server wired; every control is then disabled. */
    public val available: Boolean = false,
    public val enabled: Boolean = false,
    public val host: String = "",
    public val port: Int = 5555,
    /** 连接状态; empty hides the section (iOS `!status.isEmpty`). */
    public val status: String = "",
    public val failed: Boolean = false,
    public val busy: Boolean = false,
    /** Bumped when the saved target changes, so the drafts re-read it. */
    public val revision: Int = 0,
) {
    override fun toString(): String = "AndroidAdbFacts(available=$available, enabled=$enabled, busy=$busy)"
}

/** The drafts the page sends; the host validates and parses [port]. */
@Immutable
public data class AndroidAdbDraft(public val enabled: Boolean, public val host: String, public val port: String)

@Composable
public fun AndroidADBSettingsPage(
    facts: AndroidAdbFacts,
    onBack: () -> Unit,
    onSave: (AndroidAdbDraft) -> Unit,
    onCheck: (AndroidAdbDraft) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var enabled by remember { mutableStateOf(facts.enabled) }
    var host by remember { mutableStateOf(facts.host) }
    var port by remember { mutableStateOf(facts.port.toString()) }
    LaunchedEffect(facts.revision) {
        enabled = facts.enabled
        host = facts.host
        port = facts.port.toString()
    }
    val draft = AndroidAdbDraft(enabled, host, port)
    val busy = facts.busy || !facts.available
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "Android ADB",
        onBack = onBack,
        rootTag = UiPageTags.ANDROID_ADB_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(UiPageTags.ANDROID_ADB_LIST),
            verticalArrangement = Arrangement.Top,
        ) {
            item(key = "control") {
                Row(
                    modifier = adbToggleModifier(enabled, facts.available) { enabled = it },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(text = "允许控制 Android", modifier = Modifier.weight(1f), style = adbLabelStyle())
                    Switch(checked = enabled, enabled = facts.available, onCheckedChange = null)
                }
            }
            item(key = "host") {
                AdbTextField(host, "Android IP 地址或主机名", KeyboardType.Uri, UiPageTags.ANDROID_ADB_HOST) { host = it }
            }
            item(key = "port") {
                AdbTextField(port, "ADB 端口", KeyboardType.Number, UiPageTags.ANDROID_ADB_PORT) { port = it }
            }
            item(key = "save") {
                InfoRow(
                    title = "保存",
                    value = null,
                    enabled = !busy,
                    modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_SAVE),
                    onClick = { onSave(draft) },
                )
            }
            item(key = "check") {
                InfoRow(
                    title = "测试连接",
                    value = if (facts.busy) "正在连接…" else null,
                    enabled = !busy && enabled,
                    modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_CHECK),
                    onClick = { onCheck(draft) },
                )
            }
            item(key = "cancel") {
                InfoRow(
                    title = "停止当前 Android 操作",
                    value = null,
                    enabled = facts.available,
                    modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_CANCEL),
                    onClick = onCancel,
                )
            }
            item(key = "footer") {
                SettingsFootnoteRow(
                    text = "可直接告诉模型“连接 Android 地址和端口”，由模型启用控制并保存连接，无需手动填写。保存后立即生效。" +
                        "模型可控制屏幕、查询和管理应用、安装或卸载 APK、读取日志和执行 Android shell。" +
                        "首次连接请解锁 Android，并允许这台手机的调试密钥。",
                )
            }
            if (facts.status.isNotEmpty()) {
                item(key = "status.header") { SettingsSectionLabel("连接状态") }
                item(key = "status.body") {
                    BasicText(
                        text = facts.status,
                        style = adbLabelStyle().copy(
                            color = if (facts.failed) LocalUiTokens.current.colors.danger else LocalUiTokens.current.colors.primary,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.ANDROID_ADB_STATUS)
                            .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH),
                    )
                }
            }
            item(key = "prepare.header") { SettingsSectionLabel("连接准备") }
            item(key = "prepare.lan") { SettingsBodyRow(text = "两台手机连接同一局域网，在 Android 上开启开发者选项和 USB 调试。") }
            item(key = "prepare.tcpip") {
                SettingsBodyRow(
                    text = "当前支持 TCP/IP ADB。首次可用电脑通过 USB 执行 adb tcpip 5555，再填入 Android 的 IP 地址。" +
                        "部分设备可直接开启网络 ADB；设备重启后可能需要重新开启。",
                )
            }
            item(key = "prepare.tls") {
                SettingsBodyRow(text = "Android 11+「无线调试」里的六位配对码和 TLS 端口暂不支持。这里填写 TCP/IP ADB 端口，通常为 5555。")
            }
            item(key = "prepare.ascii") {
                SettingsBodyRow(text = "文本输入支持可打印 ASCII。中文等 Unicode 输入需要 Android 输入法支持，当前会明确报错。")
            }
            item(key = "apps.header") { SettingsSectionLabel("应用与 APK") }
            item(key = "apps.say") {
                SettingsBodyRow(text = "可以说：列出 Android 上的第三方应用；查看某个应用的版本和权限；安装工作区里的 APK；卸载指定包名的应用。")
            }
            item(key = "apps.limits") {
                SettingsBodyRow(text = "支持工作区或 Android 本机上的单个 APK。工作区安装上限 128 MiB；暂不支持 AAB、XAPK、APKS 和拆分 APK 组合。")
            }
            item(key = "apps.scope") {
                SettingsBodyRow(text = "卸载应用和删除下载的 APK 文件是两种操作。应用管理默认作用于 Android 当前用户；清除应用数据会删除登录状态和本地数据。")
            }
            item(key = "apps.transfer") {
                SettingsFootnoteRow(text = "这台手机暂不支持 Worker 中的 adb push / adb pull 文件传输；请用 APK 安装或 Android shell 完成。")
            }
        }
    }
}

@Composable
private fun adbLabelStyle() = LocalUiType.current.body.copy(color = LocalUiTokens.current.colors.primary)

@Composable
private fun adbToggleModifier(checked: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit): Modifier {
    val tokens = LocalUiTokens.current
    return Modifier
        .fillMaxWidth()
        .testTag(UiPageTags.ANDROID_ADB_TOGGLE)
        .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onToggle)
        .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
        .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText)
}

/** One plain input row; not an action for the structure gate (no search IME action). */
@Composable
private fun AdbTextField(
    value: String,
    placeholder: String,
    keyboard: KeyboardType,
    tag: String,
    onValueChange: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        textStyle = settingsValueStyle().copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        decorationBox = { inner ->
            if (value.isEmpty()) {
                BasicText(text = placeholder, style = settingsValueStyle().copy(color = tokens.colors.tertiary))
            }
            inner()
        },
    )
}

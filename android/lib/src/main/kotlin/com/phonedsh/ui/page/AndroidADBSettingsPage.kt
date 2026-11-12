// Android ADB: the saved LAN TCP/IP ADB target this phone controls, and its test.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/AndroidADBSettingsPage.swift`.
// Contract: `spec/ui/v1/pages/android-adb-settings.json`; behaviour:
// `spec/v1/native-mcp.md` (the android_* tools on this host's `/mcp/native`).
//
// The host (`:app` AndroidAdbHost) owns the saved target, the Keystore-wrapped
// RSA identity and the one Android operation slot; this page only edits drafts
// and sends 保存 / 测试连接 / 停止当前 Android 操作. The discovery section only
// names a gesture (扫描局域网 / 连接 / 取消) and renders the host's candidate
// read; it never scans, connects or measures time itself.
//
// The copy says 这台手机 where iOS says iPhone, and states the one iOS
// capability this host does not have (the Worker's `adb push/pull` file
// transfer). Android's first discovery version has no Bonjour catalog; the
// host comment in `:app` `AndroidTvDiscovery` records that difference, and this
// page never claims a service name it was not handed.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import com.phonedsh.ui.surface.settingsFootnoteStyle
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The TV families the host's port evidence can distinguish (iOS `TVCandidate.Kind`). */
public enum class AndroidAdbCandidateKind(public val label: String) {
    ANDROID_TV("Android TV"),
    CAST("Google Cast"),
    AIRPLAY("AirPlay"),
    ROKU("Roku"),
    SMART_TV("智能电视"),
    UNKNOWN("未知类型"),
}

/**
 * One TV-shaped endpoint the host's scan found, reduced to what the page shows.
 *
 * `controllable` is evidence, not permission: it is true only when the ADB port
 * answered. An open media port on another port says "像电视", never "可控制".
 */
@Immutable
public data class AndroidAdbCandidate(
    /** Stable key; the host uses `host:port` like iOS `TVCandidate.id`. */
    public val id: String,
    public val host: String,
    public val port: Int,
    public val displayName: String,
    public val kind: AndroidAdbCandidateKind = AndroidAdbCandidateKind.UNKNOWN,
    public val controllable: Boolean = false,
)

/** Progress of one candidate connection, mirroring iOS `TVConnectPhase`. */
@Immutable
public sealed interface AndroidAdbConnectPhase {
    /** A dial/ADB attempt is running; no authorization prompt has been observed yet. */
    public data object Probing : AndroidAdbConnectPhase

    /** The TV has not accepted this phone's key yet; the host retries until 90 s. */
    public data class AwaitingAuthorization(public val elapsedSeconds: Int) : AndroidAdbConnectPhase

    /** The TV answered with its model and the target was saved. */
    public data class Connected(public val model: String) : AndroidAdbConnectPhase

    /** A non-authorization failure, or the authorization deadline, with its cause. */
    public data class Failed(public val message: String) : AndroidAdbConnectPhase
}

/** True while the row shows progress and 取消 instead of a fresh 连接. */
public val AndroidAdbConnectPhase.inProgress: Boolean
    get() = this is AndroidAdbConnectPhase.Probing || this is AndroidAdbConnectPhase.AwaitingAuthorization

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
    /** 发现的电视: the last scan's candidates, in the host's display order. */
    public val candidates: List<AndroidAdbCandidate> = emptyList(),
    /** True while the host's foreground scan runs (iOS `scanning`). */
    public val scanning: Boolean = false,
    /** Per-candidate phase, keyed by [AndroidAdbCandidate.id]; an absent key is idle. */
    public val connectionPhases: Map<String, AndroidAdbConnectPhase> = emptyMap(),
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
    onScan: () -> Unit,
    onConnect: (AndroidAdbCandidate) -> Unit,
    onCancelConnection: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // A fresh install starts with control enabled (傻瓜式 / full access); a
    // saved target that was explicitly turned off keeps that choice because
    // `host` is then non-empty. The switch is only a draft until 保存 / 连接,
    // so this never grants anything by itself.
    val freshTarget = facts.available && facts.host.isBlank() && facts.revision == 0
    var enabled by remember { mutableStateOf(facts.enabled || freshTarget) }
    var host by remember { mutableStateOf(facts.host) }
    var port by remember { mutableStateOf(facts.port.toString()) }
    LaunchedEffect(facts.revision) {
        enabled = facts.enabled || (facts.available && facts.host.isBlank() && facts.revision == 0)
        host = facts.host
        port = facts.port.toString()
    }
    val draft = AndroidAdbDraft(enabled, host, port)
    val busy = facts.busy || !facts.available
    val connecting = facts.connectionPhases.values.any { it.inProgress }
    // The host refuses a scan or a second connection while any ADB operation
    // holds its one slot, so the verbs are disabled for exactly that window
    // instead of looking live and silently doing nothing.
    val discoveryEnabled = facts.available && !facts.busy && !facts.scanning && !connecting
    // Foolproof default: opening the page starts one foreground scan. The
    // button remains for a manual refresh; the host ignores a second start
    // while it is already scanning, busy or connecting.
    LaunchedEffect(facts.available) {
        if (facts.available && !facts.busy && !facts.scanning && !connecting) onScan()
    }
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
            item(key = "discover.header") {
                SettingsSectionLabel("发现的电视", tag = UiPageTags.ANDROID_ADB_DISCOVERED_SECTION)
            }
            item(key = "discover.scan") {
                InfoRow(
                    title = "扫描局域网",
                    value = null,
                    enabled = discoveryEnabled,
                    modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_SCAN),
                    onClick = onScan,
                )
            }
            if (facts.scanning) {
                item(key = "discover.scanning") {
                    SettingsFootnoteRow(
                        text = "正在查找局域网里的电视…",
                        modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_SCANNING),
                    )
                }
            }
            if (!facts.scanning && facts.candidates.isEmpty()) {
                item(key = "discover.empty") {
                    SettingsFootnoteRow(
                        text = "尚未发现电视。确认电视和这台手机连接同一 Wi-Fi，并在电视上开启网络调试；也可以手动添加地址。",
                        modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_SCAN_EMPTY),
                    )
                }
            }
            facts.candidates.forEach { candidate ->
                val phase = facts.connectionPhases[candidate.id]
                item(key = "discover.candidate.${candidate.id}") {
                    AdbCandidateRow(
                        candidate = candidate,
                        phase = phase,
                        connectEnabled = discoveryEnabled,
                        onConnect = onConnect,
                        onCancelConnection = onCancelConnection,
                    )
                }
            }
            item(key = "discover.footer") {
                SettingsFootnoteRow(
                    text = "只扫描这台手机当前 Wi-Fi 的局域网。开放端口只说明“像电视”，不代表已授权；连接后需要在电视上确认调试授权，" +
                        "等待授权时请保持此页打开。手动添加仍在下方可用。",
                )
            }
            item(key = "manual.header") {
                SettingsSectionLabel("手动添加（高级）", tag = UiPageTags.ANDROID_ADB_MANUAL_SECTION)
            }
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

/**
 * One discovered candidate: name, endpoint evidence, the host's phase, and the
 * two verbs. A row is never told a connection succeeded: 已连接 appears only
 * when the host's phase says so.
 */
@Composable
private fun AdbCandidateRow(
    candidate: AndroidAdbCandidate,
    phase: AndroidAdbConnectPhase?,
    connectEnabled: Boolean,
    onConnect: (AndroidAdbCandidate) -> Unit,
    onCancelConnection: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.ANDROID_ADB_CANDIDATE_PREFIX + candidate.id),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = candidate.displayName,
            style = adbLabelStyle(),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
        )
        BasicText(
            text = "${candidate.host}:${candidate.port} · ${candidate.kind.label} · ${adbControlLabel(candidate)}",
            style = settingsFootnoteStyle().copy(color = tokens.colors.textSecondary),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
        )
        when (phase) {
            AndroidAdbConnectPhase.Probing -> AdbPhaseText("正在连接…", candidate.id, tokens.colors.textSecondary)
            is AndroidAdbConnectPhase.AwaitingAuthorization ->
                AdbPhaseText(
                    "请在电视上点“允许”…（已等待 ${phase.elapsedSeconds} 秒）",
                    candidate.id,
                    tokens.colors.textSecondary,
                )
            is AndroidAdbConnectPhase.Connected -> AdbPhaseText("已连接：${phase.model}", candidate.id, tokens.colors.textSecondary)
            is AndroidAdbConnectPhase.Failed -> AdbPhaseText(phase.message, candidate.id, tokens.colors.danger)
            null -> Unit
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SessionTextAction(
                label = "连接",
                onClick = { onConnect(candidate) },
                tone = SessionActionTone.ACCENT,
                enabled = connectEnabled,
                modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + candidate.id),
            )
            if (phase != null && phase.inProgress) {
                SessionTextAction(
                    label = "取消",
                    onClick = onCancelConnection,
                    tone = SessionActionTone.DANGER,
                    modifier = Modifier.testTag(UiPageTags.ANDROID_ADB_CANCEL_CONNECT_PREFIX + candidate.id),
                )
            }
        }
    }
}

@Composable
private fun AdbPhaseText(text: String, candidateId: String, ink: androidx.compose.ui.graphics.Color) {
    BasicText(
        text = text,
        style = settingsFootnoteStyle().copy(color = ink),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.ANDROID_ADB_PHASE_PREFIX + candidateId)
            .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH),
    )
}

private fun adbControlLabel(candidate: AndroidAdbCandidate): String =
    // An answered ADB port is evidence, not authorization; only a completed
    // connection shows 可控制 (as the phase row). Matches the iOS label.
    if (candidate.controllable) "可尝试连接" else "可能不是电视"

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

// The SSH connection editor (iOS `SSHConnectionEditor` in SSHSettingsPage.swift).
// SPDX-License-Identifier: MIT
//
// Security rules carried over from the baseline (docs/native-ssh.md):
//   * nothing is trusted until the person reads the server's SHA-256 fingerprint
//     and confirms it in the dialog; 保存 stays disabled until then;
//   * changing the host or port clears the trusted key and any pending one;
//   * a key observed for an older host/port value is discarded, not shown.
// Android difference: a stored password / private key is never loaded back into
// this editor. The secret fields start empty; leaving them empty keeps the stored
// value when the authentication mode is unchanged. Secrets live only in plain
// `remember` state (never saved instance state) and in the save action.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SecretVisualTransformation
import com.phonedsh.ui.surface.SettingsBodyRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.secretInputSemantics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import java.util.UUID

private const val EDITOR_ROOT_TAG = "pdsh.ssh.editor"
private const val EDITOR_INSPECT_TAG = "pdsh.ssh.editor.inspect"
private const val EDITOR_SAVE_TAG = "pdsh.ssh.editor.save"
private const val EDITOR_TRUST_TAG = "pdsh.ssh.editor.trust"
private const val EDITOR_FIELD_TAG = "pdsh.ssh.editor.field."

/**
 * Edits one saved connection, or adds one when [connection] is `null`.
 *
 * @param onInspect asks the host to read the server key for (host, port).
 * @param onSave asks the host to validate and persist the draft.
 * @param onDelete asks the host to remove the connection and its credential.
 */
@Composable
public fun SSHConnectionEditor(
    connection: SSHConnectionFact?,
    facts: SSHFacts,
    onBack: () -> Unit,
    onInspect: (requestId: String, host: String, port: Int) -> Unit,
    onSave: (requestId: String, draft: SSHConnectionDraft) -> Unit,
    onDelete: (requestId: String, id: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var alias by remember { mutableStateOf(connection?.alias.orEmpty()) }
    var host by remember { mutableStateOf(connection?.host.orEmpty()) }
    var portText by remember { mutableStateOf((connection?.port ?: 22).toString()) }
    var username by remember { mutableStateOf(connection?.username.orEmpty()) }
    var usePrivateKey by remember { mutableStateOf(connection?.usePrivateKey ?: false) }
    var password by remember { mutableStateOf("") }
    var privateKey by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var trustedKey by remember { mutableStateOf(connection?.trustedHostKey.orEmpty()) }
    var trustedFingerprint by remember { mutableStateOf(connection?.fingerprint.orEmpty()) }
    var inspectRequest by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<SSHInspectionFact?>(null) }
    var saveRequest by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun clearTrust() {
        trustedKey = ""
        trustedFingerprint = ""
        pending = null
        inspectRequest = null
    }

    val inspection = facts.inspection
    LaunchedEffect(inspection) {
        if (inspection == null || inspection.requestId != inspectRequest) return@LaunchedEffect
        inspectRequest = null
        when {
            inspection.error.isNotEmpty() -> error = inspection.error
            // A key read for a host/port the person has since edited is stale.
            inspection.host == host.trim() && inspection.port == portText.toIntOrNull() -> pending = inspection
        }
    }
    val saveResult = facts.saveResult
    LaunchedEffect(saveResult) {
        if (saveResult == null || saveResult.requestId != saveRequest) return@LaunchedEffect
        saveRequest = null
        if (saveResult.ok) onBack() else error = saveResult.message
    }

    val busy = inspectRequest != null || saveRequest != null
    val stored = connection != null && connection.usePrivateKey == usePrivateKey
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = if (connection == null) "添加 SSH 连接" else connection.alias,
        onBack = onBack,
        rootTag = EDITOR_ROOT_TAG,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                item(key = "connection.header") { SettingsSectionLabel("连接") }
                item(key = "alias") { SshField("别名，例如 my-server", alias, { alias = it }, "alias") }
                item(key = "host") {
                    SshField("服务器地址", host, { host = it; clearTrust() }, "host")
                }
                item(key = "port") {
                    SshField(
                        "端口",
                        portText,
                        { value -> portText = value.filter { it.isDigit() }.take(5); clearTrust() },
                        "port",
                        keyboardType = KeyboardType.Number,
                    )
                }
                item(key = "username") { SshField("用户名", username, { username = it }, "username") }

                item(key = "auth.header") { SettingsSectionLabel("认证") }
                item(key = "auth.mode") {
                    SshToggleRow(label = "使用私钥", checked = usePrivateKey, onToggle = { usePrivateKey = it })
                }
                if (usePrivateKey) {
                    item(key = "key") {
                        SshField(
                            "OpenSSH 私钥（推荐 Ed25519）",
                            privateKey,
                            { privateKey = it },
                            "key",
                            secure = true,
                            singleLine = false,
                            hint = if (stored) "已保存；留空则保持不变" else null,
                        )
                    }
                    item(key = "passphrase") {
                        SshField(
                            "私钥口令（可选）",
                            passphrase,
                            { passphrase = it },
                            "passphrase",
                            secure = true,
                            hint = if (stored) "留空则保持已保存的口令" else null,
                        )
                    }
                    item(key = "key.note") {
                        SettingsFootnoteRow(
                            text = "粘贴完整的 OpenSSH 私钥（Ed25519 或 RSA）；RSA 使用 rsa-sha2 签名。加密私钥需填写口令；" +
                                "不支持 PEM / ECDSA / PuTTY 格式。",
                        )
                    }
                } else {
                    item(key = "password") {
                        SshField(
                            "密码",
                            password,
                            { password = it },
                            "password",
                            secure = true,
                            hint = if (stored) "已保存；留空则保持不变" else null,
                        )
                    }
                }

                item(key = "trust.header") { SettingsSectionLabel("服务器指纹") }
                if (trustedFingerprint.isNotEmpty()) {
                    item(key = "trust.value") { SettingsBodyRow(text = trustedFingerprint) }
                }
                item(key = "trust.inspect") {
                    InfoRow(
                        title = if (inspectRequest != null) "正在读取…" else "读取并核对指纹",
                        value = null,
                        enabled = !busy && facts.available,
                        modifier = Modifier.testTag(EDITOR_INSPECT_TAG),
                        onClick = {
                            val port = portText.toIntOrNull()
                            if (host.isBlank() || port == null || port !in 1..65535) {
                                error = "请填写服务器地址和端口。"
                            } else {
                                error = null
                                val id = UUID.randomUUID().toString()
                                inspectRequest = id
                                onInspect(id, host.trim(), port)
                            }
                        },
                    )
                }
                item(key = "trust.note") {
                    SettingsFootnoteRow(text = "请与服务器管理员提供的指纹核对。保存后只接受此密钥，服务器密钥改变时连接会失败。")
                }
                error?.let { message ->
                    item(key = "error") { SettingsBodyRow(text = message) }
                }
                item(key = "save") {
                    InfoRow(
                        title = "保存",
                        value = null,
                        enabled = !busy && trustedKey.isNotEmpty() && facts.available,
                        modifier = Modifier.testTag(EDITOR_SAVE_TAG),
                        onClick = {
                            val port = portText.toIntOrNull() ?: 0
                            val typedSecret = if (usePrivateKey) privateKey.isNotEmpty() else password.isNotEmpty()
                            if (!typedSecret && !stored) {
                                error = "请填写密码或私钥。"
                            } else {
                                error = null
                                val id = UUID.randomUUID().toString()
                                saveRequest = id
                                onSave(
                                    id,
                                    SSHConnectionDraft(
                                        id = connection?.id,
                                        alias = alias.trim(),
                                        host = host.trim(),
                                        port = port,
                                        username = username.trim(),
                                        usePrivateKey = usePrivateKey,
                                        trustedHostKey = trustedKey,
                                        password = if (usePrivateKey) "" else password,
                                        privateKey = if (usePrivateKey) privateKey else "",
                                        passphrase = if (usePrivateKey) passphrase else "",
                                    ),
                                )
                            }
                        },
                    )
                }
                if (connection != null) {
                    item(key = "delete") {
                        InfoRow(
                            title = "删除连接",
                            value = null,
                            enabled = !busy,
                            onClick = { confirmDelete = true },
                        )
                    }
                }
            }
        }
    }

    pending?.let { observed ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text("确认服务器指纹") },
            text = { Text(observed.fingerprint) },
            confirmButton = {
                TextButton(
                    modifier = Modifier.testTag(EDITOR_TRUST_TAG),
                    onClick = {
                        trustedKey = observed.key
                        trustedFingerprint = observed.fingerprint
                        pending = null
                    },
                ) { Text("确认并信任") }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text("取消") } },
        )
    }
    if (confirmDelete && connection != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("删除连接？") },
            text = { Text("将删除「${connection.alias}」及其保存的密码或私钥。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    val id = UUID.randomUUID().toString()
                    saveRequest = id
                    onDelete(id, connection.id)
                }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("取消") } },
        )
    }
}

@Composable
private fun SshField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    keyboardType: KeyboardType = KeyboardType.Ascii,
    secure: Boolean = false,
    singleLine: Boolean = true,
    hint: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = singleLine,
            textStyle = type.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            keyboardOptions = KeyboardOptions(keyboardType = if (secure) KeyboardType.Password else keyboardType, autoCorrectEnabled = false),
            visualTransformation = if (secure) SecretVisualTransformation else VisualTransformation.None,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .testTag(EDITOR_FIELD_TAG + tag)
                .then(if (secure) Modifier.secretInputSemantics() else Modifier)
                .semantics { contentDescription = label },
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        BasicText(text = label, style = type.body.copy(color = tokens.colors.tertiary))
                    }
                    inner()
                }
            },
        )
        if (hint != null) {
            BasicText(text = hint, style = type.caption.copy(color = tokens.colors.secondary))
        }
    }
}

@Composable
private fun SshToggleRow(label: String, checked: Boolean, onToggle: (Boolean) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onToggle)
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(text = label, modifier = Modifier.weight(1f), style = type.body.copy(color = tokens.colors.primary))
        Switch(checked = checked, onCheckedChange = null)
    }
}

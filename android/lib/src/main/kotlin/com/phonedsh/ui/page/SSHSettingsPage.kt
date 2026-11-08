// SSH hosts: the saved connections the native `ssh` / `scp` accelerators may use.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/SSHSettingsPage.swift`.
// Contract: `spec/ui/v1/pages/ssh-settings.json`; behaviour: docs/native-ssh.md.
//
// The page is projection only. The host owns the profiles, the Android Keystore
// credentials and the host-key inspection; this layer never sees a stored
// password or private key (the editor in SSHConnectionEditor.kt only sends a
// freshly typed one), and the Worker never sees any of them.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsBodyRow
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSubPageFrame

/** One saved connection as the page shows it; no credential is part of it. */
@Immutable
public data class SSHConnectionFact(
    public val id: String,
    public val alias: String,
    public val host: String,
    public val port: Int,
    public val username: String,
    public val usePrivateKey: Boolean,
    /** The pinned OpenSSH public-key line; a public value, never a secret. */
    public val trustedHostKey: String,
    /** `SHA256:…` of [trustedHostKey], computed by the host. */
    public val fingerprint: String,
)

/** The answer to one 读取并核对指纹 request, matched by [requestId]. */
@Immutable
public data class SSHInspectionFact(
    public val requestId: String,
    public val host: String,
    public val port: Int,
    /** The observed key line, or empty when [error] is set. */
    public val key: String = "",
    public val fingerprint: String = "",
    public val error: String = "",
)

/** The answer to one 保存 / 删除 request, matched by [requestId]. */
@Immutable
public data class SSHSaveResultFact(
    public val requestId: String,
    public val ok: Boolean,
    public val message: String = "",
)

/** The page's whole input, owned by the host. */
@Immutable
public data class SSHFacts(
    /** False when the host has no SSH implementation wired (the page stays read-only). */
    public val available: Boolean = false,
    public val connections: List<SSHConnectionFact> = emptyList(),
    public val inspection: SSHInspectionFact? = null,
    public val saveResult: SSHSaveResultFact? = null,
    /** A list-level failure (for example an unreadable store). */
    public val error: String = "",
)

/**
 * What the editor sends to the host. The secret members are only what the
 * person typed in this editor session; blank means "keep the stored value" for
 * an existing connection with the same authentication mode.
 */
public class SSHConnectionDraft(
    public val id: String?,
    public val alias: String,
    public val host: String,
    public val port: Int,
    public val username: String,
    public val usePrivateKey: Boolean,
    public val trustedHostKey: String,
    public val password: String,
    public val privateKey: String,
    public val passphrase: String,
) {
    override fun toString(): String = "SSHConnectionDraft(redacted)"
}

private const val SSH_ROOT_TAG = "pdsh.ssh.root"
private const val SSH_LIST_TAG = "pdsh.ssh.list"
private const val SSH_ADD_TAG = "pdsh.ssh.add"
private const val SSH_ROW_TAG = "pdsh.ssh.row."

@Composable
public fun SSHSettingsPage(
    facts: SSHFacts,
    onBack: () -> Unit,
    onOpenEditor: (id: String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "SSH",
        onBack = onBack,
        rootTag = SSH_ROOT_TAG,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            LazyColumn(modifier = Modifier.fillMaxSize().testTag(SSH_LIST_TAG)) {
                facts.connections.forEach { connection ->
                    item(key = "connection.${connection.id}") {
                        // A data row (the contract's `connection.alias` row is an
                        // expression, not a comparable label): the settings form row.
                        SettingsFormRow(
                            title = connection.alias,
                            subtitle = "${connection.username}@${connection.host}:${connection.port}",
                            chevron = true,
                            modifier = Modifier.testTag(SSH_ROW_TAG + connection.id),
                            onClick = { onOpenEditor(connection.id) },
                        )
                    }
                }
                item(key = "add") {
                    InfoRow(
                        title = "添加连接",
                        value = null,
                        enabled = facts.available,
                        modifier = Modifier.testTag(SSH_ADD_TAG),
                        onClick = { onOpenEditor(null) },
                    )
                }
                item(key = "footer") {
                    SettingsFootnoteRow(
                        text = "聊天中使用 ssh 别名 命令，或 scp 本地文件 别名:远程路径。密码和私钥以 Android Keystore 密钥加密保存在本机。" +
                            "命令执行和文件传输由手机直接连接服务器。",
                    )
                }
                if (!facts.available) {
                    item(key = "unavailable") { SettingsBodyRow(text = "本宿主未接入 SSH，无法添加或使用连接。") }
                }
                if (facts.error.isNotEmpty()) {
                    item(key = "error") { SettingsBodyRow(text = facts.error) }
                }
            }
        }
    }
}

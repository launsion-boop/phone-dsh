// SPDX-License-Identifier: MIT
//
// 发现 › QQ 邮箱 / 网易邮箱 / Gmail（应用专用密码） and 发现 › 腾讯文档.
// Kotlin ends of `MailConnectorPage.swift` and `MCPConnectorPage.swift`. The
// pages read host-owned facts and emit actions; the host verifies codes,
// keeps secrets in the Android Keystore-backed store and runs OAuth.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.BACK_GLYPH
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// MARK: mail

/** One connected mailbox (address and `MailProvider.id`). */
@Immutable
public data class MailAccountRow(public val address: String, public val providerId: String)

@Immutable
public data class MailConnectorFacts(
    public val accounts: List<MailAccountRow> = emptyList(),
    public val verifying: Boolean = false,
    public val error: String? = null,
) {
    public fun connected(providerId: String): Boolean = accounts.any { it.providerId == providerId }
}

public sealed interface MailConnectorAction {
    /** Verify against IMAP and SMTP, then save; `toString` hides the code. */
    public class Add(public val providerId: String, public val address: String, public val secret: String) : MailConnectorAction {
        override fun toString(): String = "Add($providerId, ***)"
    }
    public data class Remove(public val address: String) : MailConnectorAction
}

public object MailConnectorPageTags {
    public const val ROOT: String = "pdsh.mail.root"
    public const val ADDRESS: String = "pdsh.mail.address"
    public const val SECRET: String = "pdsh.mail.secret"
    public const val CONNECT: String = "pdsh.mail.connect"
    public const val ERROR: String = "pdsh.mail.error"
}

/** Provider copy shared by the page and the 发现 rows. */
public object MailProviderCopy {
    public fun title(providerId: String, languageId: String?): String = when (providerId) {
        "qq" -> UiStrings.settingsNativeText(languageId, "QQ 邮箱", "QQ Mail")
        "netease" -> UiStrings.settingsNativeText(languageId, "网易邮箱", "NetEase Mail")
        else -> "Gmail"
    }

    public fun secretName(providerId: String, languageId: String?): String =
        if (providerId == "gmail") UiStrings.settingsNativeText(languageId, "应用专用密码", "App password")
        else UiStrings.settingsNativeText(languageId, "客户端授权码", "Client authorization code")

    public fun help(providerId: String, languageId: String?): String = when (providerId) {
        "qq" -> UiStrings.settingsNativeText(languageId,
            "在 QQ 邮箱网页版「设置 › 账号」里开启 IMAP/SMTP 服务，按提示生成授权码后填在这里。授权码不是 QQ 密码，只保存在本机的 Android 密钥库里。",
            "In QQ Mail on the web, open Settings › Account, turn on IMAP/SMTP and generate an authorization code. It is not your QQ password and is kept only in this phone's Android Keystore.")
        "netease" -> UiStrings.settingsNativeText(languageId,
            "支持 163、126、yeah.net。在网易邮箱网页版「设置 › POP3/SMTP/IMAP」里开启 IMAP/SMTP 服务并获取授权码。授权码只保存在本机的 Android 密钥库里。",
            "Works with 163, 126 and yeah.net. In NetEase Mail on the web, open Settings › POP3/SMTP/IMAP, turn on IMAP/SMTP and get an authorization code. It is kept only in this phone's Android Keystore.")
        else -> UiStrings.settingsNativeText(languageId,
            "需要先开启 Google 账号的两步验证，然后在 Google 账号「安全性 › 应用专用密码」里生成一个密码填在这里。它只保存在本机的 Android 密钥库里。",
            "Turn on 2-Step Verification, then create an app password under Google Account › Security › App passwords and enter it here. It is kept only in this phone's Android Keystore.")
    }
}

@Composable
public fun MailConnectorPage(
    providerId: String,
    facts: MailConnectorFacts,
    onBack: () -> Unit,
    onAction: (MailConnectorAction) -> Unit,
    modifier: Modifier = Modifier,
    languageId: String? = null,
) {
    fun t(zh: String, en: String) = UiStrings.settingsNativeText(languageId, zh, en)
    var address by rememberSaveable { mutableStateOf("") }
    var secret by rememberSaveable { mutableStateOf("") }
    var pendingRemoval by rememberSaveable { mutableStateOf<String?>(null) }
    val connected = facts.accounts.filter { it.providerId == providerId }
    // A successful add lands in the list; clear the form then.
    LaunchedEffect(connected.size) { address = ""; secret = "" }

    SettingsSubPageFrame(
        backGlyph = BACK_GLYPH,
        title = MailProviderCopy.title(providerId, languageId),
        onBack = onBack,
        rootTag = MailConnectorPageTags.ROOT,
        modifier = modifier,
    ) {
        LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.Top) {
            if (connected.isNotEmpty()) {
                item(key = "connected.header") { SettingsSectionLabel(t("已连接", "Connected")) }
                item(key = "connected.list") {
                    SettingsGroupCard {
                        connected.forEachIndexed { index, account ->
                            InfoRow(
                                title = account.address,
                                value = t("断开", "Disconnect"),
                                tone = PageTone.DEGRADED,
                                onClick = { pendingRemoval = account.address },
                            )
                            if (index != connected.lastIndex) SettingsHairline()
                        }
                    }
                }
                item(key = "connected.footer") {
                    SettingsFootnoteRow(t("对话里的 DSH 可以搜索、阅读这些邮箱的邮件；发信前会在手机上请你确认。",
                        "DSH can search and read these mailboxes in chat; it asks you on this phone before sending."))
                }
            }
            item(key = "form.header") {
                SettingsSectionLabel(if (connected.isEmpty()) t("连接邮箱", "Connect a mailbox") else t("再添加一个", "Add another"))
            }
            item(key = "form") {
                SettingsGroupCard {
                    FieldRow(address, t("邮箱地址", "Email address"), MailConnectorPageTags.ADDRESS, secret = false) { address = it }
                    SettingsHairline()
                    FieldRow(secret, MailProviderCopy.secretName(providerId, languageId), MailConnectorPageTags.SECRET, secret = true) { secret = it }
                    SettingsHairline()
                    InfoRow(
                        title = if (facts.verifying) t("正在验证…", "Verifying…") else t("连接", "Connect"),
                        value = null,
                        enabled = !facts.verifying,
                        modifier = Modifier.testTag(MailConnectorPageTags.CONNECT),
                        onClick = { onAction(MailConnectorAction.Add(providerId, address, secret)) },
                    )
                }
            }
            item(key = "form.footer") { SettingsFootnoteRow(MailProviderCopy.help(providerId, languageId)) }
            facts.error?.let { error ->
                item(key = "error") { SecondaryLine(error, Modifier.testTag(MailConnectorPageTags.ERROR)) }
            }
        }
    }

    pendingRemoval?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text(t("断开这个邮箱？", "Disconnect this mailbox?")) },
            text = { Text(t("将删除本机保存的授权码，DSH 不再能读取或发送这个邮箱的邮件。",
                "The saved code is deleted from this phone; DSH can no longer read or send from this mailbox.")) },
            confirmButton = {
                TextButton(onClick = { pendingRemoval = null; onAction(MailConnectorAction.Remove(target)) }) { Text(t("断开", "Disconnect")) }
            },
            dismissButton = { TextButton(onClick = { pendingRemoval = null }) { Text(t("取消", "Cancel")) } },
        )
    }
}

// MARK: hosted MCP connector

public enum class McpConnectorPhase { DISCONNECTED, CONNECTING, CONNECTED, REAUTH }

@Immutable
public data class McpConnectorFacts(
    public val phase: McpConnectorPhase = McpConnectorPhase.DISCONNECTED,
    public val error: String? = null,
)

public sealed interface McpConnectorAction {
    public data object Connect : McpConnectorAction
    public data object Disconnect : McpConnectorAction
}

public object McpConnectorPageTags {
    public const val ROOT: String = "pdsh.mcpConnector.root"
    public const val CONNECT: String = "pdsh.mcpConnector.connect"
    public const val DISCONNECT: String = "pdsh.mcpConnector.disconnect"
}

@Composable
public fun McpConnectorPage(
    title: String,
    facts: McpConnectorFacts,
    onBack: () -> Unit,
    onAction: (McpConnectorAction) -> Unit,
    modifier: Modifier = Modifier,
    languageId: String? = null,
) {
    fun t(zh: String, en: String) = UiStrings.settingsNativeText(languageId, zh, en)
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    SettingsSubPageFrame(
        backGlyph = BACK_GLYPH,
        title = title,
        onBack = onBack,
        rootTag = McpConnectorPageTags.ROOT,
        modifier = modifier,
    ) {
        LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.Top) {
            item(key = "header") { SettingsSectionLabel(t("${title}账号", "$title account")) }
            item(key = "account") {
                SettingsGroupCard {
                    when (facts.phase) {
                        McpConnectorPhase.DISCONNECTED -> InfoRow(
                            title = t("连接$title", "Connect $title"), value = null,
                            modifier = Modifier.testTag(McpConnectorPageTags.CONNECT),
                            onClick = { onAction(McpConnectorAction.Connect) },
                        )
                        McpConnectorPhase.CONNECTING -> InfoRow(title = t("正在等待${title}授权…", "Waiting for $title authorization…"), value = null)
                        McpConnectorPhase.REAUTH -> {
                            InfoRow(title = t("授权已失效，重新连接", "Authorization expired — reconnect"), value = null,
                                tone = PageTone.DEGRADED, modifier = Modifier.testTag(McpConnectorPageTags.CONNECT),
                                onClick = { onAction(McpConnectorAction.Connect) })
                            SettingsHairline()
                            InfoRow(title = t("断开连接", "Disconnect"), value = null, tone = PageTone.DEGRADED,
                                modifier = Modifier.testTag(McpConnectorPageTags.DISCONNECT), onClick = { confirmDisconnect = true })
                        }
                        McpConnectorPhase.CONNECTED -> {
                            InfoRow(title = t("已连接", "Connected"), value = null)
                            SettingsHairline()
                            InfoRow(title = t("断开连接", "Disconnect"), value = null, tone = PageTone.DEGRADED,
                                modifier = Modifier.testTag(McpConnectorPageTags.DISCONNECT), onClick = { confirmDisconnect = true })
                        }
                    }
                }
            }
            item(key = "footer") {
                SettingsFootnoteRow(t("授权在${title}的页面完成。访问令牌只保存在本机的 Android 密钥库里，由本机代为调用，不会进入对话引擎。",
                    "You authorize on $title's own page. The access token stays in this phone's Android Keystore and the app makes the calls; it never enters the chat engine."))
            }
            facts.error?.let { error -> item(key = "error") { SecondaryLine(error) } }
        }
    }
    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(t("断开$title？", "Disconnect $title?")) },
            text = { Text(t("将删除本机保存的授权，对话里不再能使用${title}的工具。",
                "The saved authorization is deleted from this phone and $title tools leave the chat.")) },
            confirmButton = { TextButton(onClick = { confirmDisconnect = false; onAction(McpConnectorAction.Disconnect) }) { Text(t("断开连接", "Disconnect")) } },
            dismissButton = { TextButton(onClick = { confirmDisconnect = false }) { Text(t("取消", "Cancel")) } },
        )
    }
}

// MARK: shared rows

@Composable
private fun FieldRow(value: String, placeholder: String, tag: String, secret: Boolean, onValueChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = if (secret) KeyboardType.Password else KeyboardType.Email,
        ),
        textStyle = settingsValueStyle().copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        decorationBox = { inner ->
            if (value.isEmpty()) BasicText(text = placeholder, style = settingsValueStyle().copy(color = tokens.colors.tertiary))
            inner()
        },
    )
}

@Composable
private fun SecondaryLine(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = LocalUiType.current.body.copy(color = tokens.colors.secondary),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
    )
}

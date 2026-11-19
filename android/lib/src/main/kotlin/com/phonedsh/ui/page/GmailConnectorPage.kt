// Gmail: connect a Google account, search mail and read a message.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/GmailConnectorPage.swift` and
// `GmailHTMLPreview.swift`. Contract: `spec/ui/v1/pages/gmail-connector.json`;
// behaviour: PC-20261111-ios-gmail and PC-20261119-android-connectors.
//
// The host (`:app` over `com.phonedsh.connectors.gmail`) owns the Google grant,
// every Gmail request and the selected message. This page renders the host's
// facts, keeps the search draft and reports taps; it never sees a token.
//
// Structure mirrored from the baseline (`body`, `:209-237`):
//   Section Google 账号 { unconfigured | 连接 Google 账号 | progress | address + 断开连接 }
//   Section { notice }                                         (when there is one)
//   Section 邮件 { query + 搜索, message rows, progress | 没有找到邮件。, 加载更多 }
//   .sheet(selected) { GmailMessagePage }   .alert(断开 Gmail？)
package com.phonedsh.ui.page

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.SettingsNavAction
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import java.io.ByteArrayInputStream

/** The account state (`GmailMailbox.Account`, `:12-19`). */
public enum class GmailAccountPhase { UNCONFIGURED, DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING, RECONNECT }

/** One search result; the host never sends a body here. */
@Immutable
public data class GmailMessageRow(public val id: String, public val sender: String, public val subject: String)

/** The selected message's body, as the host decoded it. */
public sealed interface GmailBodyFacts {
    public data class Plain(public val text: String) : GmailBodyFacts
    public data class Html(public val html: String) : GmailBodyFacts
    public data object Unavailable : GmailBodyFacts
}

/** The message sheet (`GmailMessagePage`); [body] and [error] are both null while loading. */
@Immutable
public data class GmailOpenMessageFacts(
    public val id: String,
    public val sender: String,
    public val subject: String,
    /** The formatted date, or null when Gmail gave none. */
    public val date: String?,
    public val body: GmailBodyFacts? = null,
    public val error: String? = null,
)

/** What the host says about the Gmail connection; never a token. */
@Immutable
public data class GmailConnectorFacts(
    public val phase: GmailAccountPhase = GmailAccountPhase.UNCONFIGURED,
    /** The connected address, present only in [GmailAccountPhase.CONNECTED]. */
    public val email: String? = null,
    public val messages: List<GmailMessageRow> = emptyList(),
    public val hasNextPage: Boolean = false,
    public val loading: Boolean = false,
    public val notice: String? = null,
    /** The search the results belong to; the field starts from it. */
    public val query: String = "",
    public val openMessage: GmailOpenMessageFacts? = null,
)

/** The page's taps, reported to the host. */
public sealed interface GmailConnectorAction {
    /** `.task { await mailbox.restore() }`. */
    public data object Appeared : GmailConnectorAction
    public data object Connect : GmailConnectorAction
    public data object Disconnect : GmailConnectorAction
    /** 搜索 / keyboard search with the drafted query; `toString` hides it. */
    public class Search(public val query: String) : GmailConnectorAction {
        override fun toString(): String = "Search(***)"
    }
    public data object LoadMore : GmailConnectorAction
    public data class Open(public val id: String) : GmailConnectorAction
    /** 重试 inside the message sheet. */
    public data object RetryOpen : GmailConnectorAction
    /** 完成 / dismissing the message sheet. */
    public data object CloseMessage : GmailConnectorAction
}

/** Test tags of the Gmail page (the baseline's accessibility identifiers). */
public object GmailConnectorPageTags {
    public const val ROOT: String = "pdsh.gmail.root"
    public const val LIST: String = "pdsh.gmail.list"
    public const val CONNECT: String = "gmail.connect"
    public const val DISCONNECT: String = "gmail.disconnect"
    public const val DISCONNECT_CONFIRM: String = "gmail.disconnect.confirm"
    public const val QUERY: String = "gmail.query"
    public const val SEARCH: String = "gmail.search"
    public const val MESSAGE_ROW: String = "gmail.message.row"
    public const val LOAD_MORE: String = "gmail.loadMore"
    public const val MESSAGE: String = "gmail.message"
    public const val MESSAGE_BODY: String = "gmail.message.body"
}

@Composable
public fun GmailConnectorPage(
    facts: GmailConnectorFacts,
    onBack: () -> Unit,
    onAction: (GmailConnectorAction) -> Unit,
    modifier: Modifier = Modifier,
    languageId: String? = null,
) {
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    var draft by rememberSaveable { mutableStateOf(facts.query) }
    LaunchedEffect(Unit) { onAction(GmailConnectorAction.Appeared) }
    // A disconnect clears the query on the host (`:121`); the field follows.
    LaunchedEffect(facts.phase) { if (facts.phase != GmailAccountPhase.CONNECTED) draft = facts.query }

    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "Gmail",
        onBack = onBack,
        rootTag = GmailConnectorPageTags.ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(GmailConnectorPageTags.LIST),
            verticalArrangement = Arrangement.Top,
        ) {
            item(key = "account.header") { SettingsSectionLabel(native("Google 账号", "Google account")) }
            when (facts.phase) {
                GmailAccountPhase.UNCONFIGURED -> item(key = "account.unconfigured") {
                    GmailSecondaryText(native("当前版本未配置 Gmail 登录", "Gmail sign-in is not configured in this build"))
                }
                GmailAccountPhase.DISCONNECTED, GmailAccountPhase.RECONNECT -> item(key = "account.connect") {
                    InfoRow(
                        title = native("连接 Google 账号", "Connect Google account"),
                        value = null,
                        modifier = Modifier.testTag(GmailConnectorPageTags.CONNECT),
                        onClick = { onAction(GmailConnectorAction.Connect) },
                    )
                }
                GmailAccountPhase.CONNECTING -> item(key = "account.connecting") {
                    GmailProgressRow(native("正在连接 Gmail…", "Connecting to Gmail…"))
                }
                GmailAccountPhase.DISCONNECTING -> item(key = "account.disconnecting") {
                    GmailProgressRow(native("正在断开 Gmail…", "Disconnecting Gmail…"))
                }
                GmailAccountPhase.CONNECTED -> {
                    item(key = "account.email") {
                        val email = facts.email.orEmpty()
                        val connected = native("已连接", "Connected")
                        GmailPrimaryText(email, Modifier.semantics { contentDescription = "$connected $email" })
                    }
                    item(key = "account.disconnect") {
                        InfoRow(
                            title = native("断开连接", "Disconnect"),
                            value = null,
                            tone = PageTone.DEGRADED,
                            modifier = Modifier.testTag(GmailConnectorPageTags.DISCONNECT),
                            onClick = { confirmDisconnect = true },
                        )
                    }
                }
            }
            item(key = "account.footer") {
                SettingsFootnoteRow(
                    text = native("此连接只用于在手机上搜索和阅读邮件。", "This connection lets you search and read mail on this phone."),
                )
            }

            facts.notice?.let { notice ->
                item(key = "notice") { GmailSecondaryText(notice) }
            }

            if (facts.phase == GmailAccountPhase.CONNECTED) {
                item(key = "mail.header") { SettingsSectionLabel(native("邮件", "Mail")) }
                item(key = "mail.query") {
                    GmailQueryRow(
                        value = draft,
                        placeholder = native("发件人、主题或关键词", "Sender, subject or keyword"),
                        onValueChange = { draft = it },
                        onSearch = { onAction(GmailConnectorAction.Search(draft)) },
                    )
                }
                item(key = "mail.search") {
                    InfoRow(
                        title = native("搜索", "Search"),
                        value = null,
                        modifier = Modifier.testTag(GmailConnectorPageTags.SEARCH),
                        onClick = { onAction(GmailConnectorAction.Search(draft)) },
                    )
                }
                items(facts.messages, key = { "message.${it.id}" }) { message ->
                    GmailMessageItem(
                        subject = message.subject.ifEmpty { native("无主题", "No subject") },
                        sender = message.sender,
                        onClick = { onAction(GmailConnectorAction.Open(message.id)) },
                    )
                }
                if (facts.loading) {
                    item(key = "mail.loading") { GmailProgressRow(null) }
                } else {
                    if (facts.messages.isEmpty() && facts.notice == null) {
                        item(key = "mail.empty") { GmailSecondaryText(native("没有找到邮件。", "No messages found.")) }
                    }
                    if (facts.hasNextPage) {
                        item(key = "mail.more") {
                            InfoRow(
                                title = native("加载更多", "Load more"),
                                value = null,
                                modifier = Modifier.testTag(GmailConnectorPageTags.LOAD_MORE),
                                onClick = { onAction(GmailConnectorAction.LoadMore) },
                            )
                        }
                    }
                }
            }
        }
    }

    facts.openMessage?.let { message ->
        Dialog(
            onDismissRequest = { onAction(GmailConnectorAction.CloseMessage) },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            GmailMessagePage(
                message = message,
                languageId = languageId,
                onDone = { onAction(GmailConnectorAction.CloseMessage) },
                onRetry = { onAction(GmailConnectorAction.RetryOpen) },
            )
        }
    }

    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(native("断开 Gmail？", "Disconnect Gmail?")) },
            confirmButton = {
                TextButton(
                    modifier = Modifier.testTag(GmailConnectorPageTags.DISCONNECT_CONFIRM),
                    onClick = {
                        confirmDisconnect = false
                        onAction(GmailConnectorAction.Disconnect)
                    },
                ) { Text(native("断开连接", "Disconnect")) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisconnect = false }) { Text(native("取消", "Cancel")) }
            },
        )
    }
}

/** The message sheet (`GmailMessagePage`, `:314-383`): header, divider, body. */
@Composable
private fun GmailMessagePage(
    message: GmailOpenMessageFacts,
    languageId: String?,
    onDone: () -> Unit,
    onRetry: () -> Unit,
) {
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SettingsSubPageFrame(
        title = native("邮件正文", "Message"),
        rootTag = GmailConnectorPageTags.MESSAGE,
        trailing = { SettingsNavAction(text = native("完成", "Done"), onClick = onDone) },
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            SelectionContainer {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(tokens.spacing.cardInset),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        text = message.subject.ifEmpty { native("无主题", "No subject") },
                        style = type.headline.copy(color = tokens.colors.primary),
                    )
                    BasicText(text = message.sender, style = type.subheadline.copy(color = tokens.colors.primary))
                    message.date?.let { BasicText(text = it, style = type.caption.copy(color = tokens.colors.secondary)) }
                }
            }
            SettingsHairline()
            val body = message.body
            when {
                body is GmailBodyFacts.Plain -> SelectionContainer {
                    BasicText(
                        text = body.text,
                        style = type.body.copy(color = tokens.colors.primary),
                        modifier = Modifier
                            .fillMaxSize()
                            .testTag(GmailConnectorPageTags.MESSAGE_BODY)
                            .verticalScroll(rememberScrollState())
                            .padding(tokens.spacing.cardInset),
                    )
                }
                body is GmailBodyFacts.Html -> GmailHtmlPreview(
                    html = body.html,
                    modifier = Modifier.fillMaxSize().testTag(GmailConnectorPageTags.MESSAGE_BODY),
                )
                body == GmailBodyFacts.Unavailable -> GmailSecondaryText(
                    native("这封邮件没有可预览的正文。", "This message has no previewable body."),
                )
                message.error != null -> {
                    GmailSecondaryText(message.error)
                    InfoRow(title = native("重试", "Retry"), value = null, onClick = onRetry)
                }
                else -> GmailProgressRow(null)
            }
        }
    }
}

/**
 * Renders a mail body with every remote fetch blocked (`GmailHTMLPreview.swift`).
 * Independent layers, as on iOS: a CSP in the document, `blockNetworkLoads` /
 * `blockNetworkImage`, and [WebViewClient.shouldInterceptRequest] answering every
 * subresource locally with an empty body. JavaScript, file and content access are
 * off and every navigation is refused, so a link in the mail cannot leave the page.
 */
@Composable
private fun GmailHtmlPreview(html: String, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = false
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.blockNetworkLoads = true
                settings.blockNetworkImage = true
                settings.loadsImagesAutomatically = false
                settings.setGeolocationEnabled(false)
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse =
                        WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                }
            }
        },
        onRelease = { view -> view.destroy() },
        update = { view ->
            if (view.tag != html) {
                view.tag = html
                view.loadDataWithBaseURL(null, gmailPreviewDocument(html), "text/html", "utf-8", null)
            }
        },
    )
}

/** The CSP-wrapped document; mirrors `GmailHTMLPreview.document(_:)`. */
internal fun gmailPreviewDocument(html: String): String =
    "<!doctype html><html><head><meta charset=\"utf-8\">" +
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; " +
        "style-src 'unsafe-inline'; img-src data:; font-src data:\">" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" +
        "</head><body>" + html + "</body></html>"

@Composable
private fun GmailQueryRow(value: String, placeholder: String, onValueChange: (String) -> Unit, onSearch: () -> Unit) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            imeAction = ImeAction.Search,
        ),
        keyboardActions = KeyboardActions(onSearch = { onSearch() }),
        textStyle = settingsValueStyle().copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(GmailConnectorPageTags.QUERY)
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

/** One result: subject (two lines) over the sender (`:283-295`). */
@Composable
private fun GmailMessageItem(subject: String, sender: String, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(GmailConnectorPageTags.MESSAGE_ROW)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {}
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(text = subject, style = type.body.copy(color = tokens.colors.primary), maxLines = 2)
        BasicText(text = sender, style = type.caption.copy(color = tokens.colors.secondary), maxLines = 1)
    }
}

@Composable
private fun GmailPrimaryText(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = LocalUiType.current.body.copy(color = tokens.colors.primary),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
    )
}

@Composable
private fun GmailSecondaryText(text: String) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        style = LocalUiType.current.body.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
    )
}

@Composable
private fun GmailProgressRow(label: String?) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = if (label == null) Arrangement.Center else Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        CircularProgressIndicator(
            color = tokens.colors.secondary,
            strokeWidth = tokens.stroke.hairline,
            modifier = Modifier.heightIn(max = tokens.spacing.cardInset),
        )
        if (label != null) {
            BasicText(text = label, style = LocalUiType.current.body.copy(color = tokens.colors.primary))
        }
    }
}

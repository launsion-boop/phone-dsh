// GitHub: connect a GitHub account and browse the repositories it authorizes.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/GitHubConnectorPage.swift`.
// Contract: `spec/ui/v1/pages/git-hub-connector.json`; behaviour:
// `spec/v1/github-oauth.md` and PC-20261119-android-connectors.
//
// The host (`:app` ConnectorsHost over `com.phonedsh.connectors.github`) owns the
// OAuth attempt, the Keystore-wrapped token and every request. This page only
// renders the host's facts and reports taps; it never receives a token.
//
// Structure mirrored from the baseline (`body`, `:466-484`):
//   disconnected → Section GitHub 账号 { 此版本暂未启用… (unconfigured), 连接 GitHub }
//   connecting   → Section GitHub 账号 { progress + 正在等待 GitHub 授权… }
//   connected    → Section GitHub 账号 { login, 断开连接 } · Section 仓库授权 {
//                  在 GitHub 选择仓库, 刷新仓库 } · notice { 重试 } · Section 仓库 { rows,
//                  加载更多 }
//   any          → notice section { text, 重试, 重试删除令牌, 打开 GitHub 应用设置 }
package com.phonedsh.ui.page

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
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The connection phase (`GitHubConnectorModel.State`, `:12-21`). */
public enum class GitHubConnectorPhase { DISCONNECTED, CONNECTING, CONNECTED }

/** One authorized repository; [htmlUrl] was checked by the host to be a github.com repository page. */
@Immutable
public data class GitHubRepositoryRow(
    public val id: Long,
    public val name: String,
    public val fullName: String,
    public val htmlUrl: String,
)

/** What the host says about the GitHub connection; never a token. */
@Immutable
public data class GitHubConnectorFacts(
    /** False when this host has no connector wired; the page then shows the unconfigured copy. */
    public val configured: Boolean = false,
    public val phase: GitHubConnectorPhase = GitHubConnectorPhase.DISCONNECTED,
    /** The signed-in login, present only in [GitHubConnectorPhase.CONNECTED]. */
    public val login: String? = null,
    public val repositories: List<GitHubRepositoryRow> = emptyList(),
    public val hasNextPage: Boolean = false,
    /** A failed repository read while connected (`Connected.notice`). */
    public val repositoryNotice: String? = null,
    /** The page-level notice (`connectionNotice`). */
    public val connectionNotice: String? = null,
    /** [connectionNotice] can be retried by restoring the saved token again. */
    public val canRetryRestore: Boolean = false,
    public val loading: Boolean = false,
    public val needsDeleteRetry: Boolean = false,
    /** GitHub's installation page for the configured app. */
    public val installationUrl: String? = null,
    /** Set only after a failed server-side revoke. */
    public val revocationSettingsUrl: String? = null,
)

/** The page's taps, reported to the host. */
public enum class GitHubConnectorAction {
    /** `.task { await model.restore() }`. */
    APPEARED,
    /** `.onDisappear { model.cancelAuthorization() }`. */
    DISAPPEARED,
    CONNECT,
    DISCONNECT,
    REFRESH,
    LOAD_MORE,
    RETRY_REPOSITORIES,
    RETRY_RESTORE,
    RETRY_DELETE,
}

/** Test tags of the GitHub page (the baseline's accessibility identifiers). */
public object GitHubConnectorPageTags {
    public const val ROOT: String = "pdsh.github.root"
    public const val LIST: String = "pdsh.github.list"
    public const val UNCONFIGURED: String = "github.unconfigured"
    public const val CONNECT: String = "github.connect"
    public const val DISCONNECT: String = "github.disconnect"
    public const val INSTALL: String = "github.install"
    public const val REFRESH: String = "github.refresh"
    public const val REPO_ROW: String = "github.repo.row"
    public const val LOAD_MORE: String = "github.loadMore"
    public const val APP_SETTINGS: String = "github.appSettings"
    public const val DISCONNECT_CONFIRM: String = "github.disconnect.confirm"
}

/**
 * The GitHub connector page.
 *
 * @param onOpenUrl opens a GitHub page in the browser (installation, a repository,
 *   the authorized-app settings); the URLs come from the host, never from input.
 */
@Composable
public fun GitHubConnectorPage(
    facts: GitHubConnectorFacts,
    onBack: () -> Unit,
    onAction: (GitHubConnectorAction) -> Unit,
    onOpenUrl: (String) -> Unit,
    modifier: Modifier = Modifier,
    languageId: String? = null,
) {
    fun native(chinese: String, english: String): String = UiStrings.settingsNativeText(languageId, chinese, english)
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { onAction(GitHubConnectorAction.APPEARED) }
    // `.onDisappear { cancelAuthorization() }`: only a real leave while the app is
    // in front. The browser hop stops the activity, and a recreation (rotation,
    // theme, process trim) disposes this composition without the user leaving;
    // cancelling then would drop the callback that is about to arrive.
    val lifecycle = androidx.compose.ui.platform.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        onDispose {
            if (lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) {
                onAction(GitHubConnectorAction.DISAPPEARED)
            }
        }
    }

    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "GitHub",
        onBack = onBack,
        rootTag = GitHubConnectorPageTags.ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(GitHubConnectorPageTags.LIST),
            verticalArrangement = Arrangement.Top,
        ) {
            when (facts.phase) {
                GitHubConnectorPhase.DISCONNECTED -> {
                    item(key = "account.header") {
                        SettingsSectionLabel(native("GitHub 账号", "GitHub account"))
                    }
                    if (!facts.configured) {
                        item(key = "account.unconfigured") {
                            GitHubNoticeText(
                                native("此版本暂未启用 GitHub 连接。", "GitHub connection is unavailable in this build."),
                                Modifier.testTag(GitHubConnectorPageTags.UNCONFIGURED),
                            )
                        }
                    }
                    item(key = "account.connect") {
                        InfoRow(
                            title = native("连接 GitHub", "Connect GitHub"),
                            value = null,
                            enabled = facts.configured && !facts.needsDeleteRetry,
                            modifier = Modifier.testTag(GitHubConnectorPageTags.CONNECT),
                            onClick = { onAction(GitHubConnectorAction.CONNECT) },
                        )
                    }
                    item(key = "account.footer") {
                        SettingsFootnoteRow(
                            text = if (facts.configured) {
                                native(
                                    "连接后，在 GitHub 选择允许 Phone DSH 读取的仓库。",
                                    "Connect to GitHub, then choose the repositories Phone DSH can read.",
                                )
                            } else {
                                native(
                                    "请在此构建中配置 GitHub OAuth 后再连接。",
                                    "Set up GitHub OAuth in this build before connecting.",
                                )
                            },
                        )
                    }
                }
                GitHubConnectorPhase.CONNECTING -> {
                    item(key = "connecting.header") {
                        SettingsSectionLabel(native("GitHub 账号", "GitHub account"))
                    }
                    item(key = "connecting.progress") {
                        GitHubProgressRow(native("正在等待 GitHub 授权…", "Waiting for GitHub authorization…"))
                    }
                    item(key = "connecting.footer") {
                        SettingsFootnoteRow(
                            text = native(
                                "授权完成后会读取账号和你选择的仓库。",
                                "The account and your selected repositories are read after authorization.",
                            ),
                        )
                    }
                }
                GitHubConnectorPhase.CONNECTED -> {
                    val login = facts.login.orEmpty()
                    item(key = "connected.header") {
                        SettingsSectionLabel(native("GitHub 账号", "GitHub account"))
                    }
                    item(key = "connected.login") {
                        val connected = native("已连接", "Connected")
                        BasicText(
                            text = login,
                            style = LocalUiType.current.body.copy(color = LocalUiTokens.current.colors.primary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics { contentDescription = "$connected $login" }
                                .heightIn(min = LocalUiTokens.current.geometry.pageRowMinHeight)
                                .padding(
                                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                                    vertical = LocalUiTokens.current.spacing.iconText,
                                ),
                        )
                    }
                    item(key = "connected.disconnect") {
                        InfoRow(
                            title = native("断开连接", "Disconnect"),
                            value = null,
                            tone = PageTone.DEGRADED,
                            modifier = Modifier.testTag(GitHubConnectorPageTags.DISCONNECT),
                            onClick = { confirmDisconnect = true },
                        )
                    }
                    item(key = "connected.footer") {
                        SettingsFootnoteRow(
                            text = native(
                                "只读取登录名和你选择的仓库元数据。",
                                "Reads the login name and metadata of the repositories you selected.",
                            ),
                        )
                    }

                    item(key = "access.header") {
                        SettingsSectionLabel(native("仓库授权", "Repository access"))
                    }
                    facts.installationUrl?.let { url ->
                        item(key = "access.install") {
                            GitHubLinkRow(
                                title = native("在 GitHub 选择仓库", "Choose repositories on GitHub"),
                                tag = GitHubConnectorPageTags.INSTALL,
                                onClick = { onOpenUrl(url) },
                            )
                        }
                    }
                    item(key = "access.refresh") {
                        InfoRow(
                            title = native("刷新仓库", "Refresh repositories"),
                            value = null,
                            enabled = !facts.loading,
                            modifier = Modifier.testTag(GitHubConnectorPageTags.REFRESH),
                            onClick = { onAction(GitHubConnectorAction.REFRESH) },
                        )
                    }
                    item(key = "access.footer") {
                        SettingsFootnoteRow(
                            text = native(
                                "在 GitHub 上安装或配置 GitHub App 并选择仓库，然后刷新这里。",
                                "Install or configure the GitHub App on GitHub, choose repositories, then refresh here.",
                            ),
                        )
                    }

                    facts.repositoryNotice?.let { notice ->
                        gitHubNoticeItems(
                            key = "repos.notice",
                            notice = notice,
                            facts = facts,
                            languageId = languageId,
                            onRetry = { onAction(GitHubConnectorAction.RETRY_REPOSITORIES) },
                            onAction = onAction,
                            onOpenUrl = onOpenUrl,
                        )
                    }

                    item(key = "repos.header") {
                        SettingsSectionLabel(native("仓库", "Repositories"))
                    }
                    if (facts.repositories.isEmpty()) {
                        if (facts.loading) {
                            item(key = "repos.loading") { GitHubProgressRow(null) }
                        } else if (facts.repositoryNotice == null) {
                            item(key = "repos.empty") {
                                GitHubNoticeText(native("没有可读取的仓库。", "No repositories available."))
                            }
                        }
                    } else {
                        items(facts.repositories, key = { "repo.${it.id}" }) { repo ->
                            GitHubRepositoryItem(repo, onClick = { onOpenUrl(repo.htmlUrl) })
                        }
                        if (facts.loading) {
                            item(key = "repos.loadingMore") { GitHubProgressRow(null) }
                        }
                    }
                    if (facts.hasNextPage && facts.repositoryNotice == null && !facts.loading) {
                        item(key = "repos.more") {
                            InfoRow(
                                title = native("加载更多", "Load more"),
                                value = null,
                                modifier = Modifier.testTag(GitHubConnectorPageTags.LOAD_MORE),
                                onClick = { onAction(GitHubConnectorAction.LOAD_MORE) },
                            )
                        }
                    }
                    item(key = "repos.footer") {
                        SettingsFootnoteRow(
                            text = native("按最近更新排序，每页 30 个。", "Sorted by recently updated, 30 per page."),
                        )
                    }
                }
            }
            facts.connectionNotice?.let { notice ->
                gitHubNoticeItems(
                    key = "connection.notice",
                    notice = notice,
                    facts = facts,
                    languageId = languageId,
                    onRetry = if (facts.canRetryRestore) {
                        { onAction(GitHubConnectorAction.RETRY_RESTORE) }
                    } else {
                        null
                    },
                    onAction = onAction,
                    onOpenUrl = onOpenUrl,
                )
            }
        }
    }

    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(native("断开 GitHub？", "Disconnect GitHub?")) },
            text = {
                Text(
                    native(
                        "Phone DSH 会清除本机连接，并请求 GitHub 撤销本次访问。",
                        "Phone DSH clears this connection and asks GitHub to revoke this session.",
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    modifier = Modifier.testTag(GitHubConnectorPageTags.DISCONNECT_CONFIRM),
                    onClick = {
                        confirmDisconnect = false
                        onAction(GitHubConnectorAction.DISCONNECT)
                    },
                ) { Text(native("断开连接", "Disconnect")) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisconnect = false }) { Text(native("取消", "Cancel")) }
            },
        )
    }
}

/**
 * The untitled notice section (`noticeSection(_:retry:)`, `:647-670`): the notice,
 * an optional 重试, 重试删除令牌 while the token delete failed, and the GitHub
 * settings link after a failed revoke.
 */
private fun androidx.compose.foundation.lazy.LazyListScope.gitHubNoticeItems(
    key: String,
    notice: String,
    facts: GitHubConnectorFacts,
    languageId: String?,
    onRetry: (() -> Unit)?,
    onAction: (GitHubConnectorAction) -> Unit,
    onOpenUrl: (String) -> Unit,
) {
    item(key = "$key.text") { GitHubNoticeText(notice) }
    if (onRetry != null) {
        item(key = "$key.retry") {
            InfoRow(
                title = UiStrings.settingsNativeText(languageId, "重试", "Retry"),
                value = null,
                enabled = !facts.loading,
                onClick = onRetry,
            )
        }
    }
    if (facts.needsDeleteRetry) {
        item(key = "$key.delete") {
            InfoRow(
                title = UiStrings.settingsNativeText(languageId, "重试删除令牌", "Retry deleting token"),
                value = null,
                onClick = { onAction(GitHubConnectorAction.RETRY_DELETE) },
            )
        }
    }
    facts.revocationSettingsUrl?.let { url ->
        item(key = "$key.settings") {
            GitHubLinkRow(
                title = UiStrings.settingsNativeText(languageId, "打开 GitHub 应用设置", "Open GitHub app settings"),
                tag = GitHubConnectorPageTags.APP_SETTINGS,
                onClick = { onOpenUrl(url) },
            )
        }
    }
}

/** Secondary multi-line copy inside a section. */
@Composable
private fun GitHubNoticeText(text: String, modifier: Modifier = Modifier) {
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

/** A `ProgressView`, with its label when the baseline has one. */
@Composable
private fun GitHubProgressRow(label: String?) {
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

/** A `Link` row: opens a GitHub page in the browser. */
@Composable
private fun GitHubLinkRow(title: String, tag: String, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = title,
        style = LocalUiType.current.body.copy(color = tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick)
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
    )
}

/** One repository: name, full name, opens on GitHub (`:612-631`). */
@Composable
private fun GitHubRepositoryItem(repo: GitHubRepositoryRow, onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(GitHubConnectorPageTags.REPO_ROW)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {}
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
    ) {
        BasicText(text = repo.name, style = type.body.copy(color = tokens.colors.primary), maxLines = 1)
        BasicText(text = repo.fullName, style = type.caption.copy(color = tokens.colors.secondary), maxLines = 1)
    }
}

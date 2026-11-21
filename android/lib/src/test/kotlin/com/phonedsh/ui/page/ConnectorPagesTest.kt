// The 发现 › Gmail / GitHub pages render the host's facts and report taps.
// SPDX-License-Identifier: MIT
//
// Baselines: `GitHubConnectorPage.swift`, `GmailConnectorPage.swift`
// (PC-20261119-android-connectors). The host state machines are tested in
// `:net` (`com.phonedsh.connectors.*`); these tests pin the page projection.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ConnectorPagesTest {
    @get:Rule val compose = createComposeRule()

    private fun showGitHub(facts: GitHubConnectorFacts, actions: MutableList<GitHubConnectorAction>, urls: MutableList<String> = mutableListOf()) {
        compose.setContent {
            PdshTheme {
                GitHubConnectorPage(
                    facts = facts,
                    onBack = {},
                    onAction = { actions += it },
                    onOpenUrl = { urls += it },
                    languageId = "zh",
                )
            }
        }
    }

    @Test
    fun `an unconfigured github build says so and cannot connect`() {
        val actions = mutableListOf<GitHubConnectorAction>()
        showGitHub(GitHubConnectorFacts(configured = false), actions)
        compose.onNodeWithTag(GitHubConnectorPageTags.UNCONFIGURED).assertIsDisplayed()
        compose.onNodeWithText("此版本暂未启用 GitHub 连接。").assertIsDisplayed()
        compose.onNodeWithTag(GitHubConnectorPageTags.CONNECT).assertIsNotEnabled()
        compose.runOnIdle { assertEquals(listOf(GitHubConnectorAction.APPEARED), actions) }
    }

    @Test
    fun `github connect is reported once configured`() {
        val actions = mutableListOf<GitHubConnectorAction>()
        showGitHub(GitHubConnectorFacts(configured = true), actions)
        compose.onNodeWithText("连接后，在 GitHub 选择允许 Phone DSH 读取的仓库。").assertIsDisplayed()
        compose.onNodeWithTag(GitHubConnectorPageTags.CONNECT).performClick()
        compose.runOnIdle { assertEquals(GitHubConnectorAction.CONNECT, actions.last()) }
    }

    @Test
    fun `a connected github account lists repositories and opens them on github`() {
        val actions = mutableListOf<GitHubConnectorAction>()
        val urls = mutableListOf<String>()
        showGitHub(
            GitHubConnectorFacts(
                configured = true,
                phase = GitHubConnectorPhase.CONNECTED,
                login = "octocat",
                repositories = listOf(GitHubRepositoryRow(1, "hello", "octocat/hello", "https://github.com/octocat/hello")),
                hasNextPage = true,
                installationUrl = "https://github.com/apps/phone-dsh/installations/new",
            ),
            actions,
            urls,
        )
        compose.onNodeWithText("octocat").assertIsDisplayed()
        compose.onNodeWithText("仓库授权").assertIsDisplayed()
        compose.onNodeWithTag(GitHubConnectorPageTags.REPO_ROW).performClick()
        compose.onNodeWithTag(GitHubConnectorPageTags.LOAD_MORE).performClick()
        compose.onNodeWithTag(GitHubConnectorPageTags.INSTALL).performClick()
        compose.runOnIdle {
            assertEquals(
                listOf("https://github.com/octocat/hello", "https://github.com/apps/phone-dsh/installations/new"),
                urls,
            )
            assertEquals(GitHubConnectorAction.LOAD_MORE, actions.last())
        }
    }

    @Test
    fun `github disconnect asks first`() {
        val actions = mutableListOf<GitHubConnectorAction>()
        showGitHub(
            GitHubConnectorFacts(configured = true, phase = GitHubConnectorPhase.CONNECTED, login = "octocat"),
            actions,
        )
        compose.onNodeWithTag(GitHubConnectorPageTags.DISCONNECT).performClick()
        compose.runOnIdle { assertTrue(GitHubConnectorAction.DISCONNECT !in actions) }
        compose.onNodeWithText("断开 GitHub？").assertIsDisplayed()
        compose.onNodeWithTag(GitHubConnectorPageTags.DISCONNECT_CONFIRM).performClick()
        compose.runOnIdle { assertEquals(GitHubConnectorAction.DISCONNECT, actions.last()) }
    }

    @Test
    fun `a failed revoke offers the github settings link and a failed delete offers a retry`() {
        val actions = mutableListOf<GitHubConnectorAction>()
        val urls = mutableListOf<String>()
        showGitHub(
            GitHubConnectorFacts(
                configured = true,
                connectionNotice = "本机已断开 GitHub",
                needsDeleteRetry = true,
                revocationSettingsUrl = "https://github.com/settings/apps/authorizations",
            ),
            actions,
            urls,
        )
        compose.onNodeWithText("重试删除令牌").performClick()
        compose.onNodeWithTag(GitHubConnectorPageTags.APP_SETTINGS).performClick()
        compose.onNodeWithTag(GitHubConnectorPageTags.CONNECT).assertIsNotEnabled()
        compose.runOnIdle {
            assertEquals(GitHubConnectorAction.RETRY_DELETE, actions.last())
            assertEquals(listOf("https://github.com/settings/apps/authorizations"), urls)
        }
    }

    private fun showGmail(facts: GmailConnectorFacts, actions: MutableList<GmailConnectorAction>) {
        compose.setContent {
            PdshTheme {
                GmailConnectorPage(facts = facts, onBack = {}, onAction = { actions += it }, languageId = "zh")
            }
        }
    }

    @Test
    fun `an unconfigured gmail build has no connect action`() {
        val actions = mutableListOf<GmailConnectorAction>()
        showGmail(GmailConnectorFacts(phase = GmailAccountPhase.UNCONFIGURED), actions)
        compose.onNodeWithText("当前版本未配置 Gmail 登录").assertIsDisplayed()
        compose.onNodeWithTag(GmailConnectorPageTags.CONNECT).assertDoesNotExist()
        compose.runOnIdle { assertEquals(listOf<GmailConnectorAction>(GmailConnectorAction.Appeared), actions) }
    }

    @Test
    fun `a gmail reconnect state offers connect with its notice`() {
        val actions = mutableListOf<GmailConnectorAction>()
        showGmail(GmailConnectorFacts(phase = GmailAccountPhase.RECONNECT, notice = "Gmail 授权已失效，请重新连接。"), actions)
        compose.onNodeWithText("Gmail 授权已失效，请重新连接。").assertIsDisplayed()
        compose.onNodeWithTag(GmailConnectorPageTags.CONNECT).performClick()
        compose.runOnIdle { assertEquals(GmailConnectorAction.Connect, actions.last()) }
    }

    @Test
    fun `connected gmail searches the draft and opens a message`() {
        val actions = mutableListOf<GmailConnectorAction>()
        showGmail(
            GmailConnectorFacts(
                phase = GmailAccountPhase.CONNECTED,
                email = "me@example.com",
                messages = listOf(GmailMessageRow("m1", "Ann <ann@example.com>", "")),
                hasNextPage = true,
            ),
            actions,
        )
        compose.onNodeWithText("me@example.com").assertIsDisplayed()
        compose.onNodeWithText("无主题").assertIsDisplayed()
        compose.onNodeWithTag(GmailConnectorPageTags.QUERY).performTextReplacement("from:ann")
        compose.onNodeWithTag(GmailConnectorPageTags.SEARCH).performClick()
        compose.runOnIdle {
            val search = actions.last() as GmailConnectorAction.Search
            assertEquals("from:ann", search.query)
            assertEquals("Search(***)", search.toString())
        }
        compose.onNodeWithTag(GmailConnectorPageTags.MESSAGE_ROW).performClick()
        compose.onNodeWithTag(GmailConnectorPageTags.LOAD_MORE).performClick()
        compose.runOnIdle {
            assertEquals(
                listOf(GmailConnectorAction.Open("m1"), GmailConnectorAction.LoadMore),
                actions.takeLast(2),
            )
        }
    }

    @Test
    fun `an empty gmail search says so`() {
        showGmail(GmailConnectorFacts(phase = GmailAccountPhase.CONNECTED, email = "me@example.com"), mutableListOf())
        compose.onNodeWithText("没有找到邮件。").assertIsDisplayed()
    }

    @Test
    fun `the gmail message sheet shows a plain body and closes on done`() {
        val actions = mutableListOf<GmailConnectorAction>()
        showGmail(
            GmailConnectorFacts(
                phase = GmailAccountPhase.CONNECTED,
                email = "me@example.com",
                openMessage = GmailOpenMessageFacts(
                    id = "m1",
                    sender = "Ann",
                    subject = "Hello",
                    date = null,
                    body = GmailBodyFacts.Plain("Body text"),
                ),
            ),
            actions,
        )
        compose.onNodeWithText("邮件正文").assertIsDisplayed()
        compose.onNodeWithText("Body text").assertIsDisplayed()
        compose.onNodeWithText("完成").performClick()
        compose.runOnIdle { assertEquals(GmailConnectorAction.CloseMessage, actions.last()) }
    }

    @Test
    fun `a failed gmail read offers retry`() {
        val actions = mutableListOf<GmailConnectorAction>()
        showGmail(
            GmailConnectorFacts(
                phase = GmailAccountPhase.CONNECTED,
                email = "me@example.com",
                openMessage = GmailOpenMessageFacts("m1", "Ann", "Hello", null, error = "暂时无法读取 Gmail，请稍后重试。"),
            ),
            actions,
        )
        compose.onNodeWithText("暂时无法读取 Gmail，请稍后重试。").assertIsDisplayed()
        compose.onNodeWithText("重试").performClick()
        compose.runOnIdle { assertEquals(GmailConnectorAction.RetryOpen, actions.last()) }
    }

    @Test
    fun `the html preview document blocks every remote load`() {
        val document = gmailPreviewDocument("<img src=\"https://tracker.example/x.png\">")
        assertTrue(document.contains("default-src 'none'"))
        assertTrue(document.contains("img-src data:"))
    }
}

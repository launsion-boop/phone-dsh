// AndroidADBSettingsPage: drafts reach the host, discovery rows and verbs, busy/disabled guards.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.hasTestTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PdshSettingsRows
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class AndroidADBSettingsPageTest {
    @get:Rule val compose = createComposeRule()

    private val saved = mutableListOf<AndroidAdbDraft>()
    private val checked = mutableListOf<AndroidAdbDraft>()
    private val connected = mutableListOf<AndroidAdbCandidate>()
    private var cancelled = 0
    private var scanned = 0
    private var cancelledConnections = 0

    private val livingRoom = AndroidAdbCandidate(
        id = "192.0.2.9:5555",
        host = "192.0.2.9",
        port = 5555,
        displayName = "客厅电视",
        kind = AndroidAdbCandidateKind.ANDROID_TV,
        controllable = true,
    )
    private val castBox = AndroidAdbCandidate(
        id = "192.0.2.5:5555",
        host = "192.0.2.5",
        port = 5555,
        displayName = "TV · 192.0.2.5",
        kind = AndroidAdbCandidateKind.CAST,
        controllable = false,
    )

    private fun show(facts: AndroidAdbFacts) {
        compose.setContent {
            PdshTheme {
                AndroidADBSettingsPage(
                    facts = facts,
                    onBack = {},
                    onSave = { saved += it },
                    onCheck = { checked += it },
                    onCancel = { cancelled += 1 },
                    onScan = { scanned += 1 },
                    onConnect = { connected += it },
                    onCancelConnection = { cancelledConnections += 1 },
                )
            }
        }
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_LIST).performScrollToNode(hasTestTag(tag))
    }

    @Test
    fun draftsAreSentToTheHost() {
        show(AndroidAdbFacts(available = true, enabled = false, host = "192.0.2.7", port = 5555, revision = 1))
        scrollTo(UiPageTags.ANDROID_ADB_CHECK)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_TOGGLE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_TOGGLE).performClick()
        scrollTo(UiPageTags.ANDROID_ADB_HOST)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_HOST).performTextReplacement("192.0.2.7")
        scrollTo(UiPageTags.ANDROID_ADB_PORT)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_PORT).performTextReplacement("5556")
        scrollTo(UiPageTags.ANDROID_ADB_SAVE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).performClick()
        scrollTo(UiPageTags.ANDROID_ADB_CHECK)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsEnabled().performClick()
        scrollTo(UiPageTags.ANDROID_ADB_CANCEL)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).performClick()
        assertEquals(listOf(AndroidAdbDraft(true, "192.0.2.7", "5556")), saved)
        assertEquals(listOf(AndroidAdbDraft(true, "192.0.2.7", "5556")), checked)
        assertEquals(1, cancelled)
    }

    @Test
    fun busyDisablesSaveAndCheckAndTheStatusSectionAppears() {
        show(AndroidAdbFacts(available = true, enabled = true, host = "192.0.2.7", busy = true, status = "请查看 Android 上的调试授权提示。"))
        scrollTo(UiPageTags.ANDROID_ADB_SAVE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CHECK)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CANCEL)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).assertIsEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_STATUS)
        compose.onNodeWithText("连接状态").assertExists()
        compose.onNodeWithText("请查看 Android 上的调试授权提示。").assertExists()
    }

    @Test
    fun aHostWithoutAdbLeavesEveryControlDisabled() {
        show(AndroidAdbFacts(available = false))
        scrollTo(UiPageTags.ANDROID_ADB_SCAN)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCAN).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_SAVE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CHECK)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CANCEL)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_STATUS).assertDoesNotExist()
    }

    @Test
    fun anEmptyDiscoveryRendersItsSectionAndSendsTheScanGesture() {
        show(AndroidAdbFacts(available = true))
        compose.waitForIdle()
        assertEquals("opening the page starts one scan", 1, scanned)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_DISCOVERED_SECTION).assertExists()
        compose.onNodeWithText("发现的电视").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCAN_EMPTY).assertExists()
        compose.onNodeWithText(
            "尚未发现电视。确认电视和这台手机连接同一 Wi-Fi，并在电视上开启网络调试；也可以手动添加地址。",
        ).assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCAN).assertIsEnabled().performClick()
        assertEquals("the button refreshes on demand", 2, scanned)
    }

    @Test
    fun openingThePageStartsTheScanWithoutATap() {
        show(AndroidAdbFacts(available = true))
        compose.waitForIdle()
        assertEquals(1, scanned)
    }

    @Test
    fun aFreshTargetStartsWithControlEnabled() {
        show(AndroidAdbFacts(available = true))
        scrollTo(UiPageTags.ANDROID_ADB_TOGGLE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_TOGGLE).assertIsOn()
    }

    @Test
    fun aSavedDisabledTargetStaysOff() {
        show(AndroidAdbFacts(available = true, enabled = false, host = "192.0.2.7", port = 5555, revision = 1))
        scrollTo(UiPageTags.ANDROID_ADB_TOGGLE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_TOGGLE).assertIsOff()
    }

    @Test
    fun scanningRendersProgressAndDisablesBothDiscoveryVerbs() {
        show(
            AndroidAdbFacts(
                available = true,
                scanning = true,
                candidates = listOf(livingRoom),
            ),
        )
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCANNING).assertExists()
        compose.onNodeWithText("正在查找局域网里的电视…").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCAN).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id).assertIsNotEnabled()
    }

    @Test
    fun candidatesRenderTheirEvidenceAndConnectSendsTheCandidate() {
        show(AndroidAdbFacts(available = true, candidates = listOf(livingRoom, castBox)))
        scrollTo(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id)
        compose.onNodeWithText("客厅电视").assertExists()
        compose.onNodeWithText("192.0.2.9:5555 · Android TV · 可尝试连接").assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + castBox.id)
        compose.onNodeWithText("192.0.2.5:5555 · Google Cast · 可能不是电视").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + castBox.id).performClick()
        assertEquals(listOf(castBox), connected)
    }

    @Test
    fun awaitingAuthorizationShowsTheElapsedPromptAndCancelSendsTheGesture() {
        show(
            AndroidAdbFacts(
                available = true,
                candidates = listOf(livingRoom),
                connectionPhases = mapOf(
                    livingRoom.id to AndroidAdbConnectPhase.AwaitingAuthorization(elapsedSeconds = 3),
                ),
            ),
        )
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SCAN).assertIsNotEnabled()
        scrollTo(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id).assertIsNotEnabled()
        compose.onNodeWithText("请在电视上点“允许”…（已等待 3 秒）").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL_CONNECT_PREFIX + livingRoom.id).assertIsEnabled().performClick()
        assertEquals(1, cancelledConnections)
        assertEquals(0, connected.size)
    }

    @Test
    fun terminalPhasesRenderTheirOwnLineAndFreeTheConnectVerb() {
        show(
            AndroidAdbFacts(
                available = true,
                candidates = listOf(livingRoom),
                connectionPhases = mapOf(livingRoom.id to AndroidAdbConnectPhase.Connected("MiTV")),
            ),
        )
        scrollTo(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id)
        compose.onNodeWithText("已连接：MiTV").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CONNECT_PREFIX + livingRoom.id).assertIsEnabled()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL_CONNECT_PREFIX + livingRoom.id).assertDoesNotExist()
    }

    @Test
    fun aFailedPhaseRendersTheHostsReason() {
        show(
            AndroidAdbFacts(
                available = true,
                candidates = listOf(livingRoom),
                connectionPhases = mapOf(
                    livingRoom.id to AndroidAdbConnectPhase.Failed("等待调试授权超时（已等待 90 秒）。"),
                ),
            ),
        )
        scrollTo(UiPageTags.ANDROID_ADB_PHASE_PREFIX + livingRoom.id)
        compose.onNodeWithText("等待调试授权超时（已等待 90 秒）。").assertExists()
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL_CONNECT_PREFIX + livingRoom.id).assertDoesNotExist()
    }

    @Test
    fun theManualSectionKeepsTheWholeForm() {
        show(AndroidAdbFacts(available = true, enabled = true, host = "192.0.2.7", port = 5555))
        scrollTo(UiPageTags.ANDROID_ADB_MANUAL_SECTION)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_MANUAL_SECTION).assertExists()
        compose.onNodeWithText("手动添加（高级）").assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_TOGGLE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_TOGGLE).assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_HOST)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_HOST).assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_PORT)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_PORT).assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_SAVE)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_SAVE).assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_CHECK)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CHECK).assertExists()
        scrollTo(UiPageTags.ANDROID_ADB_CANCEL)
        compose.onNodeWithTag(UiPageTags.ANDROID_ADB_CANCEL).assertExists()
    }

    @Test
    fun theSettingsRowRoutesToThePage() {
        assertEquals(PdshRoute.AndroidAdb, PdshSettingsRows.targetOf(SettingsDestination.ANDROID_ADB))
    }
}

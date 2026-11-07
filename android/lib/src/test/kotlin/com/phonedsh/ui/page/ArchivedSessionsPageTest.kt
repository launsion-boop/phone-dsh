// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.time.ZoneId

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ArchivedSessionsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val zone = ZoneId.of("Asia/Shanghai")
    private val now = 1_700_000_000_000L

    @Test
    fun `archive snapshot distinguishes unknown empty and failed`() {
        val unknown = state(sessions = null)
        assertEquals(ArchivedSessionsPageStatus.UNKNOWN, unknown.status)
        var retried = 0
        val update = show(unknown, onRetry = { retried += 1 })
        compose.onNodeWithTag(ARCHIVED_PAGE_UNKNOWN_TAG).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_EMPTY).assertDoesNotExist()

        val empty = state(sessions = emptyList())
        assertEquals(ArchivedSessionsPageStatus.EMPTY, empty.status)
        update(empty)
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_EMPTY).assertIsDisplayed()

        val failed = state(sessions = null, failure = "归档列表读取失败")
        assertEquals(ArchivedSessionsPageStatus.FAILED, failed.status)
        update(failed)
        compose.onNodeWithTag(ARCHIVED_PAGE_FAILURE_TAG).assertIsDisplayed()
        compose.onNodeWithText("归档列表读取失败").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `restore is a host command and success appears only after the host receipt`() {
        val archive = state(sessions = listOf(SessionListing("a1", "旧会话", updatedAtMs = now - 120_000)))
        assertEquals(ArchivedSessionsPageStatus.READY, archive.status)
        assertEquals("旧会话", archive.rows.single().title)
        assertEquals(UiStrings.MINUTES_AGO.format(2), archive.rows.single().timeLabel)

        var restored: String? = null
        val update = show(archive, onRestore = { restored = it.id })
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_ROW).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_RESTORE).performClick()
        assertEquals("a1", restored)
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertDoesNotExist()

        val confirmed = archive.copy(
            mutationReceipt = PageMutationReceipt(
                operation = PageMutationOperation.SESSION_RESTORE,
                outcome = PageMutationOutcome.SUCCEEDED,
                subject = "旧会话",
            ),
        )
        update(confirmed)
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertIsDisplayed()
        compose.onNodeWithText("旧会话已恢复").assertIsDisplayed()
    }

    @Test
    fun `unknown archive data does not report a made-up empty result`() {
        val unknown = state(sessions = null)
        show(unknown)
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT).assertIsDisplayed()
    }

    @Test
    fun `restore is disabled without a host command`() {
        show(state(sessions = listOf(SessionListing("a1", "旧会话"))))
        compose.onNodeWithTag(UiPageTags.SETTINGS_ARCHIVED_RESTORE).assertIsNotEnabled()
    }

    @Test
    fun `failed restore receipt keeps the host reason visible`() {
        val failed = state(
            sessions = listOf(SessionListing("a1", "旧会话")),
            receipt = PageMutationReceipt(
                operation = PageMutationOperation.SESSION_RESTORE,
                outcome = PageMutationOutcome.FAILED,
                subject = "旧会话",
                failureReason = "会话仍在归档中，请重试",
            ),
        )
        show(failed, onRestore = {})
        compose.onNodeWithTag(PAGE_MUTATION_RECEIPT_TAG).assertIsDisplayed()
        compose.onNodeWithText("会话仍在归档中，请重试").assertIsDisplayed()
        assertNull(failed.failure)
    }

    private fun state(
        sessions: List<SessionListing>?,
        failure: String? = null,
        receipt: PageMutationReceipt? = null,
    ): ArchivedSessionsPageState = ArchivedSessionsPageState.from(
        sessions = sessions,
        nowMs = now,
        zone = zone,
        failure = failure,
        mutationReceipt = receipt,
    )

    private fun show(
        state: ArchivedSessionsPageState,
        onRestore: ((ArchivedRowView) -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
    ): (ArchivedSessionsPageState) -> Unit {
        val current = mutableStateOf(state)
        compose.setContent {
            PdshTheme {
                ArchivedSessionsPage(
                    state = current.value,
                    onBack = {},
                    onRestore = onRestore,
                    onRetry = onRetry,
                )
            }
        }
        return { next -> compose.runOnIdle { current.value = next } }
    }
}

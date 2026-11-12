// 连接电脑's state machine and contract labels (P09/P28, GAP-35).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PCPairingPageTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private fun show(
        state: PCPairingUiState,
        onScan: () -> Unit = {},
        onToggleOtherWays: () -> Unit = {},
        onLinkChange: (String) -> Unit = {},
        onPairWithLink: () -> Unit = {},
        onCodeChange: (String) -> Unit = {},
        onPairManually: () -> Unit = {},
        onCancelPairing: () -> Unit = {},
        onRetry: () -> Unit = {},
        onDone: () -> Unit = {},
        onClose: () -> Unit = {},
        onCancelScanner: () -> Unit = {},
        scannerContent: (@androidx.compose.runtime.Composable () -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                PCPairingPage(
                    state = state,
                    onScan = onScan,
                    onToggleOtherWays = onToggleOtherWays,
                    onPairingLinkChange = onLinkChange,
                    onPairWithLink = onPairWithLink,
                    onPairingCodeChange = onCodeChange,
                    onPairManually = onPairManually,
                    onCancelPairing = onCancelPairing,
                    onRetry = onRetry,
                    onDone = onDone,
                    onClose = onClose,
                    onCancelScanner = onCancelScanner,
                    installCommand = "curl example",
                    scannerContent = scannerContent,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `idle renders the install scan other and permission sections`() {
        show(PCPairingUiState.idle())
        compose.onNodeWithText(UiStrings.PC_PAIRING_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_INSTALL_LEAD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_SCAN).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.SCAN_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_OTHER).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.FULL_OWNER_WARNING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DISMISS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_LINK).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.PC_PAIRING_DONE).assertDoesNotExist()
    }

    @Test
    fun `other ways expands to the link and manual code fields`() {
        show(PCPairingUiState.otherWays())
        compose.onNodeWithText(UiStrings.PC_PAIRING_OTHER_COLLAPSE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_LINK).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_USE_LINK).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_CODE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.MANUAL_CODE_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_MANUAL).assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.LINK_ACTION).assertIsNotEnabled()
        compose.onNodeWithTag(PCPairingPageTags.MANUAL_ACTION).assertIsNotEnabled()
    }

    @Test
    fun `link input reports the draft`() {
        var link = ""
        show(
            PCPairingUiState.otherWays(),
            onLinkChange = { link = it },
        )
        compose.onNodeWithTag(PCPairingPageTags.LINK_FIELD)
            .performTextInput("pclink://pair?x=1")
        compose.waitForIdle()
        assertEquals("pclink://pair?x=1", link)
    }

    @Test
    fun `a non-blank link enables 用链接配对`() {
        var submitted = false
        show(
            PCPairingUiState.otherWays().withPairingLink("pclink://pair?x=1"),
            onPairWithLink = { submitted = true },
        )
        compose.onNodeWithTag(PCPairingPageTags.LINK_ACTION).performClick()
        assertTrue(submitted)
    }

    @Test
    fun `manual code formats every four characters and reports the formatted draft`() {
        var code = ""
        show(
            PCPairingUiState.otherWays(),
            onCodeChange = { code = pcManualCodeInput(it) },
        )
        compose.onNodeWithTag(PCPairingPageTags.CODE_FIELD)
            .performTextInput("abcd1234efgh5678")
        compose.waitForIdle()
        assertEquals("ABCD-1234-EFGH-5678", code)
    }

    @Test
    fun `manual submitted state renders joining and cancels`() {
        var cancelled = false
        show(
            PCPairingUiState.manual("abcd1234efgh5678"),
            onCancelPairing = { cancelled = true },
        )
        compose.onNodeWithText(UiStrings.PC_PAIRING_JOINING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_CANCEL).assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.CANCEL_PAIRING).performClick()
        assertTrue(cancelled)
    }

    @Test
    fun `connecting renders the named line the old-PC hint and the cancel action`() {
        var cancelled = false
        show(
            PCPairingUiState.idle().connecting("Studio").oldPcHintVisible(),
            onCancelPairing = { cancelled = true },
        )
        compose.onNodeWithText(PcLinkText.pairingConnecting("Studio")).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.PAIRING_OLD_PC_CONFIRM).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_CANCEL).assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.CANCEL_PAIRING).performClick()
        assertTrue(cancelled)
    }

    @Test
    fun `interrupted connecting shows the exact interruption sentence`() {
        show(
            PCPairingUiState.idle().connecting("Studio").interruptedDuringHandoff(),
        )
        compose.onNodeWithText(PcLinkText.PAIRING_INTERRUPTED).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.pairingConnecting("Studio")).assertIsDisplayed()
    }

    @Test
    fun `connected renders the verified name and 完成 dismisses`() {
        var done = false
        show(
            PCPairingUiState.idle().connected("Studio"),
            onDone = { done = true },
        )
        compose.onNodeWithText("已连接 Studio").assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.DONE).performClick()
        assertTrue(done)
    }

    @Test
    fun `failed renders the message retry and a separate interruption line`() {
        var retries = 0
        show(
            PCPairingUiState.idle().failed("relay unreachable", interrupted = true),
            onRetry = { retries++ },
        )
        compose.onNodeWithText("relay unreachable").assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.PAIRING_INTERRUPTED).assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.RETRY).performClick()
        assertEquals(1, retries)
    }

    @Test
    fun `camera unavailable renders the permission sentence and the other-ways entry`() {
        show(PCPairingUiState.idle().cameraUnavailable())
        compose.onNodeWithText(PcLinkText.CAMERA_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_OTHER).assertIsDisplayed()
        // The fields stay folded: only the entry is shown until 其他方式 is tapped.
        compose.onNodeWithText(UiStrings.PC_PAIRING_LINK).assertDoesNotExist()
    }

    @Test
    fun `scanner sheet owns 取消 and the host content`() {
        var cancelled = false
        show(
            PCPairingUiState.idle().scannerOpened(),
            onCancelScanner = { cancelled = true },
            scannerContent = { androidx.compose.material3.Text("camera preview") },
        )
        compose.onNodeWithText("camera preview").assertIsDisplayed()
        compose.onNodeWithTag(PCPairingPageTags.SCANNER_CANCEL)
            .performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick)
        assertTrue(cancelled)
    }

    @Test
    fun `close reports the toolbar action`() {
        var closed = false
        show(PCPairingUiState.idle(), onClose = { closed = true })
        compose.onNodeWithTag(PCPairingPageTags.CLOSE).performClick()
        assertTrue(closed)
    }

    @Test
    fun `state machine formats the manual code and refuses incomplete submissions`() {
        val empty = PCPairingUiState.idle().withPairingCode("")
        assertFalse(empty.manualCodeReady)
        assertEquals(empty, empty.manualPairing())

        val partial = PCPairingUiState.idle().withPairingCode("abcd")
        assertFalse(partial.manualCodeReady)
        assertEquals(partial, partial.manualPairing())

        val full = PCPairingUiState.idle().withPairingCode("abcd1234efgh5678")
        assertTrue(full.manualCodeReady)
        assertEquals(PCPairingStage.MANUAL, full.manualPairing().stage)

        val odd = pcManualCodeInput("  ab-cd 12!34 ")
        assertEquals("ABCD-1234", odd)
        assertEquals("ABCD-1234-EFGH-5678", pcManualCodeInput("abcd1234efgh5678extra"))
    }

    @Test
    fun `state machine keeps link and scanner transitions honest`() {
        val blankLink = PCPairingUiState.idle().withPairingLink("   ")
        assertFalse(blankLink.linkReady)
        assertEquals(blankLink, blankLink.pairingWithLink())

        val link = PCPairingUiState.idle().withPairingLink("pclink://pair?x=1")
        assertTrue(link.linkReady)
        assertEquals(PCPairingStage.CONNECTING, link.pairingWithLink().stage)

        val scanning = PCPairingUiState.idle().scannerOpened()
        assertEquals(PCPairingStage.SCANNING, scanning.stage)
        assertEquals(PCPairingStage.IDLE, scanning.scannerDismissed().stage)

        assertEquals(PCPairingStage.OTHER_WAYS, PCPairingUiState.idle().toggleOtherWays().stage)
        assertEquals(PCPairingStage.IDLE, PCPairingUiState.otherWays().toggleOtherWays().stage)
    }

    @Test
    fun `retry clears the failure and re-opens the scanner`() {
        val failed = PCPairingUiState.idle().failed("nope", interrupted = true).retry()
        assertEquals(PCPairingStage.SCANNING, failed.stage)
        assertEquals(null, failed.failureMessage)
        assertFalse(failed.interrupted)
    }
}

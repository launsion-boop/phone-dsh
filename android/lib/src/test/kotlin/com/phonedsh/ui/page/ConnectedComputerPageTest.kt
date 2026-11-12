// 已连接的电脑: empty/filled rows, the three alerts and the unpair path.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ConnectedComputerPageTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private fun show(
        state: ConnectedComputerUiState,
        onBack: () -> Unit = {},
        onOpenPairing: () -> Unit = {},
        onUnpair: () -> Unit = {},
        onDismissUnpairFailure: () -> Unit = {},
        onConnectionScreenOpened: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme {
                ConnectedComputerPage(
                    state = state,
                    onBack = onBack,
                    onOpenPairing = onOpenPairing,
                    onUnpair = onUnpair,
                    onDismissUnpairFailure = onDismissUnpairFailure,
                    onConnectionScreenOpened = onConnectionScreenOpened,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun record(
        online: Boolean = true,
        version: String? = "0.2.4",
        warning: String? = null,
        mode: PcLinkPairingMode? = PcLinkPairingMode.QR,
        longOffline: Boolean = false,
        reason: PcLinkOfflineReason? = null,
    ) = PcLinkComputerRecord(
        peerName = "Studio",
        dshVersion = version,
        versionWarning = warning,
        ownFingerprint = "PHONE-FP",
        pairingMode = mode,
        pairedAt = "2026-11-10T03:13:00Z",
        relayOrigin = "wss://relay.example",
        online = online,
        offlineReason = reason,
        longOffline = longOffline,
    )

    @Test
    fun `empty state shows the title the instruction and 连接电脑`() {
        var opened = false
        show(ConnectedComputerUiState.empty(), onOpenPairing = { opened = true })
        compose.onNodeWithText(UiStrings.PC_CONNECTED_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.NO_COMPUTER).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.NO_COMPUTER_HINT).assertIsDisplayed()
        compose.onNodeWithTag(ConnectedComputerPageTags.CONNECT).performClick()
        assertTrue(opened)
        compose.onNodeWithText(PcLinkText.PAIR_NEW_COMPUTER).assertDoesNotExist()
    }

    @Test
    fun `filled record renders both groups and the verified DSH version`() {
        val value = record()
        show(ConnectedComputerUiState.paired(value))
        compose.onNodeWithText(UiStrings.PC_COMPUTER_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_COMPUTER_NAME).assertIsDisplayed()
        compose.onNodeWithText("Studio").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_DSH_VERSION).assertIsDisplayed()
        compose.onNodeWithText("0.2.4").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_ONLINE_STATUS).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.ONLINE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_THIS_PHONE_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_OWN_FINGERPRINT).assertIsDisplayed()
        compose.onNodeWithText("PHONE-FP").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRING_MODE).assertIsDisplayed()
        compose.onNodeWithText("扫码").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_PAIRED_AT).assertIsDisplayed()
        compose.onNodeWithText(value.pairedAtText).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PC_RELAY).assertIsDisplayed()
        compose.onNodeWithText("wss://relay.example").assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.FINGERPRINT_FOOTER).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.PAIR_NEW_COMPUTER).assertIsDisplayed()
    }

    @Test
    fun `offline copy and a version warning stay visible`() {
        show(
            ConnectedComputerUiState.paired(
                record(online = false, version = "0.1.0", warning = "这台电脑的 DSH 版本较旧。"),
            ),
        )
        compose.onNodeWithText(PcLinkText.OFFLINE).assertIsDisplayed()
        compose.onNodeWithText("0.1.0（未验证）").assertIsDisplayed()
        compose.onNodeWithText("这台电脑的 DSH 版本较旧。").assertIsDisplayed()
    }

    @Test
    fun `missing verified version says it was not obtained`() {
        show(ConnectedComputerUiState.paired(record(online = false, version = null)))
        compose.onNodeWithText(PcLinkText.DSH_VERSION_UNKNOWN).assertIsDisplayed()
    }

    @Test
    fun `long offline latch adds the exact sentence`() {
        show(ConnectedComputerUiState.paired(record(online = false, longOffline = true)))
        compose.onNodeWithText(PcLinkText.LONG_OFFLINE).assertIsDisplayed()
    }

    @Test
    fun `new pairing alert blocks and can open the unpair confirmation`() {
        var unpaired = false
        show(ConnectedComputerUiState.paired(record()), onUnpair = { unpaired = true })
        compose.onNodeWithTag(ConnectedComputerPageTags.PAIR_NEW).performClick()
        compose.waitForIdle()
        compose.onNodeWithText(PcLinkText.ALREADY_PAIRED_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.ALREADY_PAIRED_MESSAGE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.UNPAIR_CURRENT).performClick()
        compose.waitForIdle()
        compose.onNodeWithText(PcLinkText.UNPAIR_CONFIRM_TITLE).assertIsDisplayed()
        compose.onNodeWithTag(ConnectedComputerPageTags.UNPAIR_CONFIRM).performClick()
        assertTrue(unpaired)
    }

    @Test
    fun `unpair action asks before writing`() {
        var unpaired = false
        show(ConnectedComputerUiState.paired(record()), onUnpair = { unpaired = true })
        compose.onNodeWithTag(ConnectedComputerPageTags.UNPAIR).performClick()
        compose.waitForIdle()
        compose.onNodeWithText(PcLinkText.UNPAIR_CONFIRM_TITLE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.UNPAIR_CONFIRM_MESSAGE).assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.CANCEL).performClick()
        compose.waitForIdle()
        assertEquals(false, unpaired)
        compose.onNodeWithTag(ConnectedComputerPageTags.UNPAIR).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(ConnectedComputerPageTags.UNPAIR_CONFIRM).performClick()
        assertTrue(unpaired)
    }

    @Test
    fun `unpair failure opens 解除没有完成 and 知道了 dismisses it`() {
        var dismissed = false
        show(
            ConnectedComputerUiState.paired(record()).copy(unpairFailure = "storage denied"),
            onDismissUnpairFailure = { dismissed = true },
        )
        compose.onNodeWithText(PcLinkText.UNPAIR_FAILED_TITLE).assertIsDisplayed()
        compose.onNodeWithText("storage denied").assertIsDisplayed()
        compose.onNodeWithText(PcLinkText.KNOW_IT).performClick()
        assertTrue(dismissed)
    }

    @Test
    fun `opening the page reports the connection-screen hook`() {
        var opened = false
        show(ConnectedComputerUiState.empty(), onConnectionScreenOpened = { opened = true })
        assertTrue(opened)
    }

    @Test
    fun `record helpers keep the three pairing modes and the dash`() {
        assertEquals("扫码", PcLinkText.pairingMode(PcLinkPairingMode.QR))
        assertEquals("手动码", PcLinkText.pairingMode(PcLinkPairingMode.MANUAL))
        assertEquals("旧版配对（未记录方式）", PcLinkText.pairingMode(null))
        assertEquals(PcLinkText.DSH_VERSION_UNKNOWN, record(version = null).dshVersionText)
        assertEquals("0.2.4（未验证）", record(warning = "warn").dshVersionText)
        assertEquals(PcLinkText.UNKNOWN_VALUE, record().display(""))
    }
}

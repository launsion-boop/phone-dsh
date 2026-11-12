// SPDX-License-Identifier: MIT
// The App-side mapping from the PC workspace controller to the plain `:lib`
// page state (design §6 C5). The fakes are the same ports the controller test
// uses; the controller is real, so each case exercises its own transition and
// not a hand-built `PcWorkspaceState`.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkClientState
import com.phonedsh.pclink.PclinkClientStatus
import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkOfflineReason
import com.phonedsh.pclink.PclinkPairingPhase
import com.phonedsh.pclink.PclinkPresence
import com.phonedsh.pclink.PclinkRosterSession
import com.phonedsh.pclink.PclinkRosterSnapshot
import com.phonedsh.pclink.PclinkRosterWorkspace
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ConnectedComputerUiState
import com.phonedsh.ui.page.PCPairingStage
import com.phonedsh.ui.page.PCPairingUiState
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerListState
import com.phonedsh.ui.page.PcDrawerPhase
import com.phonedsh.ui.page.PcLinkPairingMode
import com.phonedsh.ui.page.PcLinkPresence
import com.phonedsh.ui.page.PcLinkText
import java.nio.file.Files
import java.time.Duration
import java.time.ZoneOffset
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PcUiMappingTest {
    private class Fixture(
        camera: PcCameraAvailability = PcCameraAvailability.AVAILABLE,
        onClose: () -> Unit = {},
        val client: FakePcLinkClient = FakePcLinkClient(),
        val storage: PcWorkspaceStorage = newStorage(),
        private val diagnosticsRoot: java.io.File = Files.createTempDirectory("pc-ui-mapping").toFile(),
        val transport: ScriptedDshCall = ScriptedDshCall(),
    ) : AutoCloseable {
        val controller = PcWorkspaceController(
            client = client,
            transport = transport,
            storage = storage,
            diagnostics = PcDiagnosticsLog(diagnosticsRoot),
            turnRunner = PcChatTurnRunner(transport),
            presence = PclinkPresence(reconnectGrace = Duration.ofMillis(25)),
            cameraAvailability = { camera },
            onClose = onClose,
        )

        override fun close() = controller.close()

        companion object {
            fun newStorage(file: MapPreferenceFile = MapPreferenceFile()): PcWorkspaceStorage =
                PcWorkspaceStorage(
                    file,
                    Files.createTempDirectory("pc-ui-mapping-roster")
                        .resolve(PcWorkspaceStorage.ROSTER_DIRECTORY),
                )
        }
    }

    private fun <T> await(flow: StateFlow<T>, predicate: (T) -> Boolean): T = runBlocking {
        withTimeout(5_000) { flow.first(predicate) }
    }

    // ---- Pairing page --------------------------------------------------

    @Test
    fun `the controller's pairing phases map to the page stages`() {
        val fixture = Fixture()
        try {
            assertEquals(
                PCPairingStage.IDLE,
                fixture.controller.state.value.toPcPairingUiState().stage,
            )

            fixture.client.setStatus(
                PclinkClientStatus(
                    state = PclinkClientState.Pairing(PclinkPairingPhase.Joining),
                    pairingPrompt = PcTestValues.prompt(),
                ),
            )
            val joining = await(fixture.controller.state) {
                it.pairing.phase == PcPairingPhase.JOINING
            }
            val connecting = joining.toPcPairingUiState()
            assertEquals(PCPairingStage.CONNECTING, connecting.stage)
            assertEquals("My PC", connecting.connectingPcName)

            val error = PclinkError.AuthFailed("the computer rejected the pairing")
            fixture.client.setStatus(
                PclinkClientStatus(
                    state = PclinkClientState.Pairing(PclinkPairingPhase.Failed(error)),
                    lastError = error,
                ),
            )
            val failed = await(fixture.controller.state) {
                it.pairing.phase == PcPairingPhase.FAILED
            }
            val failedUi = failed.toPcPairingUiState()
            assertEquals(PCPairingStage.FAILED, failedUi.stage)
            assertEquals(error.message, failedUi.failureMessage)

            fixture.client.setOnline(PcTestValues.record(name = "Studio"))
            val online = await(fixture.controller.state) { it.record != null }
            val connected = online.toPcPairingUiState()
            assertEquals(PCPairingStage.CONNECTED, connected.stage)
            assertEquals("Studio", connected.connectedName)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `a denied camera maps an open scanner to camera-unavailable`() {
        val fixture = Fixture(camera = PcCameraAvailability.DENIED)
        try {
            assertFalse(fixture.controller.checkCameraForScanning())
            val ui = fixture.controller.state.value.toPcPairingUiState(
                PCPairingUiState.idle().scannerOpened(),
            )
            assertEquals(PCPairingStage.CAMERA_UNAVAILABLE, ui.stage)
            assertFalse(ui.scanning)
            assertEquals(PcCameraAvailability.DENIED, fixture.controller.state.value.camera)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the page-local draft survives a controller snapshot with no stronger fact`() {
        val fixture = Fixture()
        try {
            val draft = PCPairingUiState.otherWays().withPairingLink("pclink://pair?x=1")
            val mapped = fixture.controller.state.value.toPcPairingUiState(draft)
            assertEquals(PCPairingStage.PAIRING_LINK, mapped.stage)
            assertEquals("pclink://pair?x=1", mapped.pairingLink)
        } finally {
            fixture.close()
        }
    }

    // ---- Settings row + connected page ---------------------------------

    @Test
    fun `the settings value is unpaired, offline and the verified name`() {
        val fixture = Fixture()
        try {
            assertEquals(
                UiStrings.PC_SETTINGS_VALUE_UNPAIRED,
                fixture.controller.state.value.toPcSettingsValue(),
            )

            fixture.client.setOnline(PcTestValues.record(name = "Studio"))
            val online = await(fixture.controller.state) { it.presence.isOnline }
            assertEquals("Studio", online.toPcSettingsValue())

            fixture.client.setOffline(PclinkOfflineReason.PeerOffline)
            val offline = await(fixture.controller.state) {
                it.presence.isOffline && it.record != null
            }
            assertEquals(UiStrings.PC_SETTINGS_VALUE_OFFLINE, offline.toPcSettingsValue())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the connected page takes its DSH version from peer hello, not the record`() {
        val fixture = Fixture()
        try {
            val record = PcTestValues.record(name = "Studio")
            fixture.client.setStatus(
                PclinkClientStatus(
                    state = PclinkClientState.Online,
                    record = record,
                    peerDshVersion = "0.9.9-verified",
                ),
            )
            val state = await(fixture.controller.state) { it.record != null }
            val ui = state.toConnectedComputerUiState()
            assertEquals("Studio", ui.record?.peerName)
            assertEquals("0.9.9-verified", ui.record?.dshVersion)
            assertEquals(PcLinkPairingMode.QR, ui.record?.pairingMode)
            assertTrue(ui.record?.online == true)
            assertNull(ui.unpairFailure)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `an unpaired connected page is the empty state`() {
        val fixture = Fixture()
        try {
            val ui = fixture.controller.state.value.toConnectedComputerUiState()
            assertTrue(ui.isEmpty)
            assertEquals(ConnectedComputerUiState.empty(), ui)
        } finally {
            fixture.close()
        }
    }

    // ---- Drawer --------------------------------------------------------

    @Test
    fun `the drawer groups the PC roster by DSH workspace title and dates the cache`() {
        val fixture = Fixture()
        try {
            val record = PcTestValues.record()
            fixture.storage.writeRoster(
                record.peerMachineId,
                PclinkRosterSnapshot(
                    sessions = listOf(
                        PclinkRosterSession(
                            id = "s1",
                            title = "Alpha session",
                            updatedAtMilliseconds = 1_000.0,
                            running = false,
                            blank = false,
                            cwd = "/work/alpha",
                        ),
                        PclinkRosterSession(
                            id = "s2",
                            title = "Loose session",
                            updatedAtMilliseconds = 2_000.0,
                            running = true,
                            blank = false,
                            cwd = "/other",
                        ),
                    ),
                    workspaces = listOf(
                        PclinkRosterWorkspace(
                            id = "w1",
                            title = "Alpha",
                            path = "/work/alpha",
                            sessionIds = listOf("s1"),
                        ),
                    ),
                    workspaceOrder = listOf("w1"),
                ),
                capturedAtMilliseconds = 5_000,
            )
            fixture.client.setOnline(record)
            await(fixture.controller.state) { it.roster.sessions.size == 2 }
            fixture.controller.selectBackend(PcBackend.PC)
            val now = 10_000_000L
            val drawer = fixture.controller.state.value.toPcDrawerUiState(
                nowMilliseconds = now,
                zone = ZoneOffset.UTC,
            )

            assertEquals(PcDrawerBackend.PC, drawer.selected)
            assertEquals(PcLinkPresence.ONLINE, drawer.presence.presence)
            assertEquals(PcDrawerPhase.READY, drawer.phase)
            assertEquals(PcDrawerListState.ROWS, drawer.resolvedListState)
            assertEquals(listOf("Alpha", PcLinkText.UNGROUPED), drawer.groups.map { it.title })
            assertEquals(listOf("s1"), drawer.groups[0].sessions.map { it.id })
            assertEquals(listOf("s2"), drawer.groups[1].sessions.map { it.id })
            assertTrue(drawer.groups[1].sessions.single().running)
            assertNull(drawer.cachedListNote)

            fixture.client.setOffline(PclinkOfflineReason.PeerOffline)
            val offline = await(fixture.controller.state) { it.presence.isOffline }
            val offlineDrawer = offline.toPcDrawerUiState(nowMilliseconds = now, zone = ZoneOffset.UTC)
            assertEquals(PcDrawerPhase.OFFLINE, offlineDrawer.phase)
            assertEquals(
                PcLinkText.cachedOffline(5_000, now, ZoneOffset.UTC),
                offlineDrawer.cachedListNote,
            )
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `selecting PC while unpaired keeps the empty card and never the phone list`() {
        val fixture = Fixture()
        try {
            fixture.controller.selectBackend(PcBackend.PC)
            val drawer = fixture.controller.state.value.toPcDrawerUiState()
            assertEquals(PcDrawerBackend.PC, drawer.selected)
            assertEquals(PcDrawerPhase.PAIR, drawer.phase)
            assertTrue(drawer.showsStateCard)
            assertTrue(drawer.sessions.isEmpty())
            assertEquals(PcDrawerListState.EMPTY, drawer.resolvedListState)
            assertEquals(UiStrings.PC_SETTINGS_VALUE_UNPAIRED, drawer.presence.settingsValue)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the drawer selection persists in P18 and is restored by the next controller`() {
        val preferenceFile = MapPreferenceFile()
        val first = Fixture(storage = Fixture.newStorage(preferenceFile))
        try {
            first.controller.selectBackend(PcBackend.PC)
            assertEquals(PcBackend.PC, first.storage.readBackend())

            // A later controller over the same P18 file reads the persisted value
            // at construction; it must not start on 手机 and then "fall back".
            val second = Fixture(storage = Fixture.newStorage(preferenceFile))
            try {
                val restored = second.controller.state.value
                assertEquals(PcBackend.PC, restored.backend)
                assertEquals(PcDrawerBackend.PC, restored.toPcDrawerUiState().selected)
            } finally {
                second.close()
            }
        } finally {
            first.close()
        }
    }

    @Test
    fun `a failed roster read keeps the rows and exposes the error text`() = runBlocking {
        val fixture = Fixture()
        try {
            val record = PcTestValues.record()
            fixture.storage.writeRoster(
                record.peerMachineId,
                PclinkRosterSnapshot(
                    sessions = listOf(
                        PclinkRosterSession(
                            id = "cached",
                            title = "cached title",
                            updatedAtMilliseconds = 1.0,
                            running = false,
                            blank = false,
                        ),
                    ),
                ),
                1,
            )
            fixture.client.setOnline(record)
            await(fixture.controller.state) { it.roster.sessions.isNotEmpty() }
            fixture.transport.handler = { _, _ -> throw PclinkError.PeerOffline() }
            fixture.controller.refreshRoster().join()

            val failed = await(fixture.controller.state) { it.rosterError != null }
            val drawer = failed.toPcDrawerUiState()
            assertEquals(PcDrawerListState.ROWS, drawer.resolvedListState)
            assertEquals("the paired PC is offline", drawer.error)
            assertEquals("cached title", drawer.sessions.single().title)
            assertNotNull(drawer.sessions.single().relativeTime)
        } finally {
            fixture.close()
        }
    }
}

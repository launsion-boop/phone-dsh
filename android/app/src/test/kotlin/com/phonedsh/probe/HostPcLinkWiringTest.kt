// SPDX-License-Identifier: MIT
// The host half of the PCLink C5 glue: the same `HostPcLinkWiring` HostShell
// mounts, driven against a real `PcWorkspaceController` and the JVM fakes. The
// pages' own label/alert behaviour is covered in `:lib`; this file proves the
// app-side callback chain reaches the controller and that select-PC-unpaired
// stays the PC empty state.
package com.phonedsh.probe

import com.phonedsh.pclink.PclinkPresence
import com.phonedsh.ui.page.PCPairingStage
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerPhase
import com.phonedsh.probe.pc.FakePcLinkClient
import com.phonedsh.probe.pc.MapPreferenceFile
import com.phonedsh.probe.pc.PcBackend
import com.phonedsh.probe.pc.PcCameraAvailability
import com.phonedsh.probe.pc.PcChatTurnRunner
import com.phonedsh.probe.pc.PcDiagnosticsLog
import com.phonedsh.probe.pc.PcPairingPhase
import com.phonedsh.probe.pc.PcTestValues
import com.phonedsh.probe.pc.PcWorkspaceController
import com.phonedsh.probe.pc.PcWorkspaceStorage
import com.phonedsh.probe.pc.ScriptedDshCall
import java.nio.file.Files
import java.time.Duration
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostPcLinkWiringTest {
    private class Fixture(
        camera: PcCameraAvailability = PcCameraAvailability.AVAILABLE,
        onClose: () -> Unit = {},
    ) : AutoCloseable {
        val client = FakePcLinkClient()
        val storage = PcWorkspaceStorage(
            MapPreferenceFile(),
            Files.createTempDirectory("pc-host-wiring")
                .resolve(PcWorkspaceStorage.ROSTER_DIRECTORY),
        )
        private val transport = ScriptedDshCall()
        private val directory = Files.createTempDirectory("pc-host-wiring-log").toFile()
        val controller = PcWorkspaceController(
            client = client,
            transport = transport,
            storage = storage,
            diagnostics = PcDiagnosticsLog(directory),
            turnRunner = PcChatTurnRunner(transport),
            presence = PclinkPresence(reconnectGrace = Duration.ofMillis(25)),
            cameraAvailability = { camera },
            onClose = onClose,
        )

        override fun close() = controller.close()
    }

    private fun <T> await(flow: StateFlow<T>, predicate: (T) -> Boolean): T = runBlocking {
        withTimeout(5_000) { flow.first(predicate) }
    }

    @Test
    fun `a denied camera becomes the page's camera-unavailable state and asks the host`() {
        val fixture = Fixture(camera = PcCameraAvailability.DENIED)
        var permissionRequests = 0
        try {
            val wiring = HostPcLinkWiring(fixture.controller) { permissionRequests++ }
            wiring.onScan()
            val ui = wiring.pairingState(fixture.controller.state.value)
            assertEquals(PCPairingStage.CAMERA_UNAVAILABLE, ui.stage)
            assertEquals(1, permissionRequests)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the link callback starts the controller's pairing flow`() {
        val fixture = Fixture()
        try {
            val wiring = HostPcLinkWiring(fixture.controller)
            wiring.onPairingLinkChange("pclink://pair?v=1")
            wiring.onPairWithLink()
            await(fixture.controller.state) {
                it.pairing.phase == PcPairingPhase.COMPLETED && it.record != null
            }
            assertEquals(1, fixture.client.beginCount)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the confirmed unpair callback calls the controller and empties the page`() {
        val fixture = Fixture()
        try {
            fixture.client.setOnline(PcTestValues.record(name = "Studio"))
            val online = await(fixture.controller.state) { it.record != null }
            val wiring = HostPcLinkWiring(fixture.controller)
            assertTrue(wiring.connectedState(online).record != null)

            wiring.onUnpairConfirmed()
            val unpaired = await(fixture.controller.state) { it.record == null }
            assertEquals(1, fixture.client.unpairCount)
            val page = wiring.connectedState(unpaired)
            assertTrue(page.isEmpty)
            assertEquals(null, page.unpairFailure)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `selecting PC while unpaired keeps the PC empty card and persists the segment`() {
        val fixture = Fixture()
        try {
            val wiring = HostPcLinkWiring(fixture.controller)
            wiring.onSelectBackend(PcDrawerBackend.PC)
            val state = fixture.controller.state.value
            val drawer = wiring.drawerState(state)
            assertEquals(PcBackend.PC, state.backend)
            assertEquals(PcDrawerBackend.PC, drawer.selected)
            assertEquals(PcDrawerPhase.PAIR, drawer.phase)
            assertTrue(drawer.showsStateCard)
            assertTrue(drawer.sessions.isEmpty())
            assertEquals(PcBackend.PC, fixture.storage.readBackend())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `controller teardown closes once and is idempotent`() {
        var closes = 0
        val fixture = Fixture(onClose = { closes++ })
        fixture.controller.close()
        assertEquals(1, closes)
        fixture.controller.close()
        assertEquals(1, closes)
        fixture.close()
        assertEquals(1, closes)
    }
}

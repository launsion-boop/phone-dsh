// SPDX-License-Identifier: MIT
// The App-side PC workspace controller: pairing intents, presence projection,
// P18 cache/selection, turn submission and teardown. Fakes implement the small
// ports the controller owns; the real `PclinkClient` is covered separately for
// the invalid-QR and teardown paths.
package com.phonedsh.probe.pc

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.pclink.PclinkClient
import com.phonedsh.pclink.PclinkClientConfiguration
import com.phonedsh.pclink.PclinkClientState
import com.phonedsh.pclink.PclinkClientStatus
import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkFilePairingStore
import com.phonedsh.pclink.PclinkIdentity
import com.phonedsh.pclink.PclinkIdentityStore
import com.phonedsh.pclink.PclinkOfflineReason
import com.phonedsh.pclink.PclinkPairingPhase
import com.phonedsh.pclink.PclinkPresence
import com.phonedsh.pclink.PclinkPresenceSnapshot
import com.phonedsh.pclink.PclinkReachability
import com.phonedsh.pclink.PclinkRelayLinkFactory
import com.phonedsh.pclink.PclinkRosterSession
import com.phonedsh.pclink.PclinkRosterSnapshot
import com.phonedsh.pclink.PclinkRosterWorkspace
import com.phonedsh.pclink.PclinkRpc
import com.phonedsh.pclink.PclinkRpcError
import com.phonedsh.pclink.PclinkUnpairedReason
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PcWorkspaceControllerTest {
    private class Fixture(
        val camera: PcCameraAvailability = PcCameraAvailability.AVAILABLE,
    ) : AutoCloseable {
        val file = MapPreferenceFile()
        val directory = Files.createTempDirectory("pc-controller")
        val storage = PcWorkspaceStorage(
            file,
            directory.resolve(PcWorkspaceStorage.ROSTER_DIRECTORY),
        )
        val diagnostics = PcDiagnosticsLog(directory.toFile())
        val client = FakePcLinkClient()
        val transport = ScriptedDshCall()
        val controller = PcWorkspaceController(
            client = client,
            transport = transport,
            storage = storage,
            diagnostics = diagnostics,
            turnRunner = PcChatTurnRunner(transport),
            cameraAvailability = { camera },
            onClose = {},
        )

        override fun close() = controller.close()
    }

    private fun <T> await(flow: StateFlow<T>, predicate: (T) -> Boolean): T = runBlocking {
        withTimeout(5_000) { flow.first(predicate) }
    }

    private fun onlineFixture(camera: PcCameraAvailability = PcCameraAvailability.AVAILABLE): Fixture {
        val fixture = Fixture(camera)
        fixture.client.setOnline()
        return fixture
    }

    /** A `session/list` answer with exactly [ids], newest first. */
    private fun sessionListResponse(vararg ids: String): JsonObject = JsonObject(
        linkedMapOf(
            "items" to JsonArray(
                ids.map { id ->
                    JsonObject(
                        linkedMapOf(
                            "sessionId" to JsonString(id),
                            "updatedAt" to JsonNumber("1700000000000"),
                            "running" to JsonBool(false),
                            "blank" to JsonBool(true),
                        ),
                    )
                },
            ),
        ),
    )

    // ---- Presence mapping ----------------------------------------------

    @Test
    fun `presence maps unpaired, offline and the peer name`() {
        val record = PcTestValues.record()
        val unpairedStatus = PclinkClientStatus(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
        )
        val unpairedSnapshot = PclinkPresenceSnapshot(
            reachability = PclinkReachability.OFFLINE,
            longOffline = false,
            lastSeenAtMilliseconds = null,
            offlineSinceMilliseconds = null,
            offlineReason = null,
            graceExpired = true,
        )
        val unpaired = PcPresence.from(unpairedStatus, unpairedSnapshot)
        assertEquals(PcPresence.UNPAIRED_LABEL, unpaired.settingsValue)
        assertTrue(unpaired.isUnpaired)

        val offlineStatus = PclinkClientStatus(
            state = PclinkClientState.Offline(PclinkOfflineReason.PeerOffline),
            record = record,
        )
        val offlineSnapshot = unpairedSnapshot.copy(
            reachability = PclinkReachability.OFFLINE,
            offlineReason = PclinkOfflineReason.PeerOffline,
        )
        val offline = PcPresence.from(offlineStatus, offlineSnapshot)
        assertEquals(PcPresence.OFFLINE_LABEL, offline.settingsValue)
        assertEquals(record.peerName, offline.computerName)
        assertTrue(offline.isOffline)

        val online = PcPresence.from(
            offlineStatus.copy(state = PclinkClientState.Online),
            offlineSnapshot.copy(reachability = PclinkReachability.ONLINE, offlineReason = null),
        )
        assertEquals(record.peerName, online.settingsValue)
        assertTrue(online.isOnline)

        // Reconnecting is not a claim that the PC is offline: the settings row
        // keeps the name and the drawer gets the separate reachability value.
        val reconnecting = PcPresence.from(
            offlineStatus,
            offlineSnapshot.copy(reachability = PclinkReachability.RECONNECTING, offlineReason = null),
        )
        assertEquals(record.peerName, reconnecting.settingsValue)
        assertEquals(PcReachability.RECONNECTING, reconnecting.reachability)
    }

    @Test
    fun `the long-offline sentence is surfaced only with the latch`() {
        val record = PcTestValues.record()
        val status = PclinkClientStatus(
            state = PclinkClientState.Offline(PclinkOfflineReason.PeerOffline),
            record = record,
        )
        val base = PclinkPresenceSnapshot(
            reachability = PclinkReachability.OFFLINE,
            longOffline = false,
            lastSeenAtMilliseconds = null,
            offlineSinceMilliseconds = 1,
            offlineReason = PclinkOfflineReason.PeerOffline,
            graceExpired = true,
        )
        assertNull(PcPresence.from(status, base).longOfflineHint)

        val latched = PcPresence.from(status, base.copy(longOffline = true))
        assertEquals(PclinkPresence.LONG_OFFLINE_HINT, latched.longOfflineHint)
        assertTrue(latched.longOffline)
    }

    // ---- Pairing -------------------------------------------------------

    @Test
    fun `a QR pairing intent walks joining to completed and stores the record`() {
        val fixture = Fixture()
        try {
            fixture.controller.startPairingQr("pclink://pair?v=1")
            assertEquals(PcPairingPhase.JOINING, fixture.controller.state.value.pairing.phase)
            val completed = await(fixture.controller.state) {
                it.pairing.phase == PcPairingPhase.COMPLETED && it.record != null
            }
            assertEquals("My PC", completed.record?.name)
            assertEquals("qr", completed.record?.pairingMode)
            assertEquals(1, fixture.client.confirmCount)
            assertEquals(1, fixture.client.beginCount)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `the client's initial Unpaired replayed after JOINING does not fail the attempt`() {
        // A hand-drained executor makes the race deterministic: the status
        // collector (launched at construction) runs after startPairing has
        // published JOINING and before the pairing job itself.
        val queue = java.util.ArrayDeque<Runnable>()
        val dispatcher = java.util.concurrent.Executor { queue.add(it) }.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val directory = Files.createTempDirectory("pc-controller-race")
        val client = FakePcLinkClient()
        val transport = ScriptedDshCall()
        val controller = PcWorkspaceController(
            client = client,
            transport = transport,
            storage = PcWorkspaceStorage(MapPreferenceFile(), directory.resolve(PcWorkspaceStorage.ROSTER_DIRECTORY)),
            diagnostics = PcDiagnosticsLog(directory.toFile()),
            turnRunner = PcChatTurnRunner(transport),
            scope = scope,
        )
        try {
            controller.startPairingQr("pclink://pair?v=1")
            assertEquals(PcPairingPhase.JOINING, controller.state.value.pairing.phase)
            // Only the first queued task: the status collector replays Unpaired(NoRecord).
            queue.removeFirst().run()
            assertEquals(PcPairingPhase.JOINING, controller.state.value.pairing.phase)
            assertNull(controller.state.value.pairing.error)
            // Draining the rest completes the pairing with no stale error left behind.
            repeat(200) { queue.pollFirst()?.run() }
            assertEquals(PcPairingPhase.COMPLETED, controller.state.value.pairing.phase)
            assertNull(controller.state.value.pairing.error)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `a manual code intent passes the origin through the same transition`() {
        val fixture = Fixture()
        try {
            fixture.controller.startManualPairing("ABCD-EFGH-JKMN-PQRS", "https://relay.example")
            val completed = await(fixture.controller.state) {
                it.pairing.phase == PcPairingPhase.COMPLETED && it.record != null
            }
            assertNotNull(completed.record)
            assertEquals(1, fixture.client.beginCount)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `cancel returns the page to idle and does not leave a failed pairing`() = runBlocking {
        val fixture = Fixture()
        fixture.client.holdPairing = true
        try {
            fixture.controller.startPairingQr("pclink://pair?v=1")
            await(fixture.controller.state) { it.pairing.phase == PcPairingPhase.WAITING_FOR_PC }
            fixture.controller.cancelPairing()?.join()
            val idle = await(fixture.controller.state) { it.pairing.phase == PcPairingPhase.IDLE }
            assertEquals(PcPairingPhase.IDLE, idle.pairing.phase)
            assertEquals(1, fixture.client.cancelCount)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `an invalid QR fails without a dial`() {
        val pairFile = Files.createTempDirectory("pc-invalid-qr").resolve("pairs.json")
        val identityStore = object : PclinkIdentityStore {
            var seed: ByteArray? = null
            override fun loadSeed(): ByteArray? = seed
            override fun saveSeed(seed: ByteArray) {
                this.seed = seed.copyOf()
            }
            override fun deleteSeed() {
                seed = null
            }
        }
        var dialed = false
        val realClient = PclinkClient(
            identityStore = identityStore,
            pairingStore = PclinkFilePairingStore(pairFile),
            relayLinkFactory = object : PclinkRelayLinkFactory {
                override suspend fun connect(url: String): com.phonedsh.pclink.PclinkRelayLink {
                    dialed = true
                    error("must not dial for an invalid QR")
                }
            },
            configuration = PclinkClientConfiguration(),
        )
        val directory = Files.createTempDirectory("pc-invalid-qr-controller")
        val transport = ScriptedDshCall()
        val controller = PcWorkspaceController(
            client = PclinkClientAdapter(realClient),
            transport = transport,
            storage = PcWorkspaceStorage(MapPreferenceFile(), directory.resolve("roster")),
            diagnostics = PcDiagnosticsLog(directory.toFile()),
            turnRunner = PcChatTurnRunner(transport),
            onClose = {},
        )
        try {
            controller.startPairingQr("not-a-pairing-uri")
            val failed = await(controller.state) { it.pairing.phase == PcPairingPhase.FAILED }
            assertEquals("bad_frame", failed.pairing.error?.code)
            assertFalse(dialed)
        } finally {
            controller.close()
        }
    }

    @Test
    fun `an already-paired phone refuses a second pairing before opening a link`() {
        val fixture = Fixture()
        fixture.client.setOnline()
        try {
            await(fixture.controller.state) { it.record != null }
            fixture.controller.startPairingQr("pclink://pair?v=1")
            val failed = await(fixture.controller.state) { it.pairing.phase == PcPairingPhase.FAILED }
            assertEquals("already_paired", failed.pairing.error?.code)
            assertEquals(0, fixture.client.beginCount)
        } finally {
            fixture.close()
        }
    }

    // ---- P18 backend + roster -----------------------------------------

    @Test
    fun `backend selection is persisted and reflected in state`() {
        val fixture = Fixture()
        try {
            fixture.controller.selectBackend(PcBackend.PC)
            assertEquals(PcBackend.PC, fixture.controller.state.value.backend)
            assertEquals(PcBackend.PC, fixture.storage.readBackend())
            fixture.controller.selectBackend("phone")
            assertEquals(PcBackend.PHONE, fixture.controller.state.value.backend)
            assertEquals(PcBackend.PHONE, fixture.storage.readBackend())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `refreshRoster caches the session list under the paired machine`() = runBlocking {
        val fixture = onlineFixture()
        try {
            fixture.client.setOnline()
            val record = PcTestValues.record()
            fixture.transport.handler = { endpoint, _ ->
                assertEquals(PcWorkspaceController.SESSION_LIST_ENDPOINT, endpoint)
                JsonObject(
                    linkedMapOf(
                        "items" to JsonArray(
                            listOf(
                                JsonObject(
                                    linkedMapOf(
                                        "sessionId" to JsonString("s1"),
                                        "updatedAt" to JsonNumber("1700000000000"),
                                        "running" to JsonBool(true),
                                        "blank" to JsonBool(false),
                                        "cwd" to JsonString("/work/phone-dsh"),
                                        "projections" to JsonObject(
                                            linkedMapOf(
                                                "values" to JsonObject(
                                                    linkedMapOf("title" to JsonString("build the app")),
                                                ),
                                            ),
                                        ),
                                    ),
                                ),
                            ),
                        ),
                    ),
                )
            }
            await(fixture.controller.state) { it.record != null }
            fixture.controller.refreshRoster().join()

            val loaded = await(fixture.controller.state) { it.roster.sessions.isNotEmpty() }
            assertEquals("build the app", loaded.roster.sessions.single().title)
            assertTrue(loaded.roster.sessions.single().running)
            assertNotNull(loaded.rosterCapturedAtMilliseconds)
            val cached = fixture.storage.readRoster(record.peerMachineId)
            assertTrue(cached is com.phonedsh.pclink.PclinkRosterCacheEntry.Stored)
        } finally {
            fixture.close()
        }
    }

    // ---- PC new session -------------------------------------------------

    @Test
    fun `pc new session uses the stored workspace and refreshes the roster`() = runBlocking {
        val fixture = Fixture()
        try {
            val record = PcTestValues.record()
            fixture.storage.writeLastWorkspace(record.peerMachineId, "workspace-1")
            fixture.client.setOnline(record)
            await(fixture.controller.state) { it.record != null }
            fixture.transport.handler = { endpoint, args ->
                when (endpoint) {
                    PcWorkspaceController.SESSION_CREATE_ENDPOINT -> {
                        val request = (args as JsonObject)["request"] as JsonObject
                        assertEquals("workspace-1", (request["workspaceId"] as JsonString).value)
                        assertNull("the workspace id is the one selector", request["cwd"])
                        JsonObject(linkedMapOf("sessionId" to JsonString("new-session")))
                    }

                    PcWorkspaceController.SESSION_LIST_ENDPOINT -> sessionListResponse("new-session")
                    else -> throw AssertionError("unexpected endpoint $endpoint")
                }
            }

            val outcome = fixture.controller.createSession()

            assertEquals(
                PcNewSessionOutcome.Created("new-session", "workspace-1"),
                outcome,
            )
            assertEquals(
                listOf("session/create", "session/list"),
                fixture.transport.calls.map { it.first },
            )
            val state = await(fixture.controller.state) { current ->
                current.roster.sessions.any { it.id == "new-session" }
            }
            assertEquals("workspace-1", state.lastWorkspaceId)
            assertEquals("new-session", state.roster.sessions.first().id)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `an explicit PC workspace is sent and remembered for the next create`() = runBlocking {
        val fixture = onlineFixture()
        try {
            val record = PcTestValues.record()
            await(fixture.controller.state) { it.record != null }
            fixture.transport.handler = { endpoint, args ->
                when (endpoint) {
                    PcWorkspaceController.SESSION_CREATE_ENDPOINT -> {
                        val request = (args as JsonObject)["request"] as JsonObject
                        assertEquals("picked-2", (request["workspaceId"] as JsonString).value)
                        JsonObject(linkedMapOf("sessionId" to JsonString("new-in-picked")))
                    }

                    PcWorkspaceController.SESSION_LIST_ENDPOINT ->
                        sessionListResponse("new-in-picked")

                    else -> throw AssertionError("unexpected endpoint $endpoint")
                }
            }

            val outcome = fixture.controller.createSession("picked-2")

            assertEquals(
                PcNewSessionOutcome.Created("new-in-picked", "picked-2"),
                outcome,
            )
            assertEquals("picked-2", fixture.controller.state.value.lastWorkspaceId)
            assertEquals("picked-2", fixture.storage.readLastWorkspace(record.peerMachineId))
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `pc new session without a stored workspace lets the PC choose and keeps the returned row`() =
        runBlocking {
            val fixture = onlineFixture()
            try {
                await(fixture.controller.state) { it.record != null }
                fixture.transport.handler = { endpoint, args ->
                    when (endpoint) {
                        PcWorkspaceController.SESSION_CREATE_ENDPOINT -> {
                            val request = (args as JsonObject)["request"] as JsonObject
                            assertTrue("no workspace selector was chosen", request.members.isEmpty())
                            JsonObject(linkedMapOf("sessionId" to JsonString("adopted")))
                        }

                        // The list can race the PC's own write; the returned id
                        // is still the authority for the row this action made.
                        PcWorkspaceController.SESSION_LIST_ENDPOINT -> sessionListResponse()
                        else -> throw AssertionError("unexpected endpoint $endpoint")
                    }
                }

                val outcome = fixture.controller.createSession()

                assertEquals(PcNewSessionOutcome.Created("adopted", null), outcome)
                val state = fixture.controller.state.value
                assertEquals("adopted", state.roster.sessions.single().id)
                assertTrue(state.roster.sessions.single().blank)
                assertNull(state.lastWorkspaceId)
            } finally {
                fixture.close()
            }
        }

    @Test
    fun `pc new session offline is an honest failure and never calls the transport`() = runBlocking {
        val fixture = onlineFixture()
        try {
            await(fixture.controller.state) { it.record != null }
            fixture.client.setOffline()
            // The presence machine keeps an 8 s reconnecting grace, so the
            // check is "not online" rather than the latched OFFLINE value.
            await(fixture.controller.state) { !it.presence.isOnline }

            val outcome = fixture.controller.createSession()

            assertTrue(outcome is PcNewSessionOutcome.Failed)
            assertEquals("peer_offline", (outcome as PcNewSessionOutcome.Failed).error.code)
            assertTrue("no phone fallback: nothing was sent", fixture.transport.calls.isEmpty())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `pc new session without a paired computer is a failure, not a phone session`() = runBlocking {
        val fixture = Fixture()
        try {
            val outcome = fixture.controller.createSession()

            assertTrue(outcome is PcNewSessionOutcome.Failed)
            assertEquals("not_paired", (outcome as PcNewSessionOutcome.Failed).error.code)
            assertTrue(fixture.transport.calls.isEmpty())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `a refused pc create is propagated and adds no roster row`() = runBlocking {
        val fixture = onlineFixture()
        try {
            await(fixture.controller.state) { it.record != null }
            fixture.transport.handler = { endpoint, _ ->
                assertEquals(PcWorkspaceController.SESSION_CREATE_ENDPOINT, endpoint)
                // A definite DSH refusal is not an unknown outcome: never
                // re-read on its behalf and never create a local fallback row.
                throw PclinkRpcError("workspace_not_found", "no such workspace")
            }

            val outcome = fixture.controller.createSession()

            assertTrue(outcome is PcNewSessionOutcome.Failed)
            assertEquals("workspace_not_found", (outcome as PcNewSessionOutcome.Failed).error.code)
            assertEquals(1, fixture.transport.calls.size)
            assertTrue(fixture.controller.state.value.roster.sessions.isEmpty())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `a lost pc create reply re-reads the list instead of resending the unsafe create`() =
        runBlocking {
            val fixture = onlineFixture()
            try {
                await(fixture.controller.state) { it.record != null }
                fixture.transport.handler = { endpoint, _ ->
                    when (endpoint) {
                        PcWorkspaceController.SESSION_CREATE_ENDPOINT ->
                            throw PclinkRpcError("unknown_outcome", "no definitive reply")

                        PcWorkspaceController.SESSION_LIST_ENDPOINT ->
                            sessionListResponse("landed-on-pc")

                        else -> throw AssertionError("unexpected endpoint $endpoint")
                    }
                }

                val outcome = fixture.controller.createSession()

                assertTrue(outcome is PcNewSessionOutcome.Failed)
                assertEquals("unknown_outcome", (outcome as PcNewSessionOutcome.Failed).error.code)
                assertEquals(
                    listOf("session/create", "session/list"),
                    fixture.transport.calls.map { it.first },
                )
                assertEquals(
                    "the unsafe create is never resent",
                    1,
                    fixture.transport.calls.count { it.first == "session/create" },
                )
                val state = await(fixture.controller.state) {
                    it.roster.sessions.any { row -> row.id == "landed-on-pc" }
                }
                assertEquals("landed-on-pc", state.roster.sessions.single().id)
            } finally {
                fixture.close()
            }
        }

    @Test
    fun `a malformed pc create answer is an invalid response and re-reads the list`() = runBlocking {
        val fixture = onlineFixture()
        try {
            await(fixture.controller.state) { it.record != null }
            fixture.transport.handler = { endpoint, _ ->
                when (endpoint) {
                    PcWorkspaceController.SESSION_CREATE_ENDPOINT -> JsonObject(emptyMap())
                    PcWorkspaceController.SESSION_LIST_ENDPOINT -> sessionListResponse("visible-after-read")
                    else -> throw AssertionError("unexpected endpoint $endpoint")
                }
            }

            val outcome = fixture.controller.createSession()

            assertTrue(outcome is PcNewSessionOutcome.Failed)
            assertEquals("invalid_response", (outcome as PcNewSessionOutcome.Failed).error.code)
            assertEquals(
                listOf("session/create", "session/list"),
                fixture.transport.calls.map { it.first },
            )
            assertEquals(
                "visible-after-read",
                fixture.controller.state.value.roster.sessions.single().id,
            )
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `session history read is bound to the paired machine and uses the session page shape`() = runBlocking {
        val fixture = onlineFixture()
        try {
            val record = PcTestValues.record()
            fixture.client.setOnline(record)
            await(fixture.controller.state) { it.record != null }
            fixture.transport.handler = { endpoint, _ ->
                assertEquals(PcWorkspaceController.SESSION_PAGE_ENDPOINT, endpoint)
                JsonObject(
                    linkedMapOf(
                        "records" to JsonArray(emptyList()),
                        "hasMore" to JsonBool(true),
                    ),
                )
            }

            val read = fixture.controller.readSessionHistoryPage(record.peerMachineId, "session-1")
            assertTrue(read.hasMore)
            val call = fixture.transport.calls.single()
            assertEquals("session/page", call.first)
            val request = (call.second as JsonObject)["request"] as JsonObject
            val address = request["address"] as JsonObject
            assertEquals("session", (address["kind"] as JsonString).value)
            assertEquals("session-1", (address["sessionId"] as JsonString).value)
            assertEquals("60", (request["maxMessages"] as JsonNumber).raw)

            val refused = runCatching {
                fixture.controller.readSessionHistoryPage("other-machine", "session-1")
            }
            assertTrue(refused.isFailure)
            assertEquals(1, fixture.transport.calls.size)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `a failed roster read keeps the cached rows and reports the error`() = runBlocking {
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
                5,
            )
            fixture.client.setOnline(record)
            await(fixture.controller.state) { it.roster.sessions.isNotEmpty() }

            fixture.transport.handler = { _, _ -> throw PclinkError.PeerOffline() }
            fixture.controller.refreshRoster().join()

            val failed = await(fixture.controller.state) { it.rosterError != null }
            assertEquals("peer_offline", failed.rosterError?.code)
            assertEquals("cached title", failed.roster.sessions.single().title)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `unpair removes only the current PC scope`() = runBlocking {
        val fixture = onlineFixture()
        try {
            val record = PcTestValues.record()
            fixture.client.setOnline(record)
            fixture.storage.writeLastWorkspace(record.peerMachineId, "workspace-1")
            fixture.storage.writeRoster(record.peerMachineId, PclinkRosterSnapshot(
                sessions = listOf(
                    PclinkRosterSession(
                        id = "s",
                        title = "t",
                        updatedAtMilliseconds = 1.0,
                        running = false,
                        blank = false,
                    ),
                ),
            ), 1)
            await(fixture.controller.state) { it.record != null }

            fixture.controller.unpair().join()

            assertNull(fixture.storage.readLastWorkspace(record.peerMachineId))
            assertTrue(
                fixture.storage.readRoster(record.peerMachineId) is
                    com.phonedsh.pclink.PclinkRosterCacheEntry.Missing,
            )
            assertNull(fixture.controller.state.value.record)
            assertEquals(1, fixture.client.unpairCount)
        } finally {
            fixture.close()
        }
    }

    // ---- Turn ----------------------------------------------------------

    @Test
    fun `sendTurn runs the transport adapter and publishes queued`() = runBlocking {
        val fixture = onlineFixture()
        try {
            fixture.transport.handler = { endpoint, args ->
                assertEquals(PcChatTurnRunner.ENDPOINT, endpoint)
                val request = (args as JsonObject)["request"] as JsonObject
                assertEquals(JsonString("session-1"), request["sessionId"])
                JsonObject(linkedMapOf("accepted" to JsonBool(true)))
            }
            await(fixture.controller.state) { it.presence.isOnline }
            fixture.controller.sendTurn("session-1", "hello PC")!!.join()
            val queued = await(fixture.controller.state) { it.turn is PcTurnState.Queued }
            assertTrue((queued.turn as PcTurnState.Queued).requestId.isNotEmpty())
            assertEquals(1, fixture.transport.calls.size)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `sendTurn while offline never calls the transport`() {
        val fixture = Fixture()
        try {
            fixture.controller.sendTurn("session-1", "hello")
            val failed = await(fixture.controller.state) { it.turn is PcTurnState.Failed }
            assertEquals("peer_offline", (failed.turn as PcTurnState.Failed).error.code)
            assertTrue(fixture.transport.calls.isEmpty())
        } finally {
            fixture.close()
        }
    }

    // ---- Camera + errors + teardown ------------------------------------

    @Test
    fun `a denied camera is reported without starting a pairing`() {
        val fixture = Fixture(camera = PcCameraAvailability.DENIED)
        try {
            assertFalse(fixture.controller.checkCameraForScanning())
            assertEquals(PcCameraAvailability.DENIED, fixture.controller.state.value.camera)
            assertEquals(PcPairingPhase.IDLE, fixture.controller.state.value.pairing.phase)
            assertEquals(0, fixture.client.beginCount)

            fixture.controller.onCameraPermissionResult(true)
            assertEquals(PcCameraAvailability.AVAILABLE, fixture.controller.state.value.camera)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `an absent camera is reported as unavailable`() {
        val fixture = Fixture(camera = PcCameraAvailability.UNAVAILABLE)
        try {
            assertFalse(fixture.controller.checkCameraForScanning())
            assertEquals(PcCameraAvailability.UNAVAILABLE, fixture.controller.state.value.camera)
            assertEquals(PcPairingPhase.IDLE, fixture.controller.state.value.pairing.phase)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `an unreadable identity is a storage error, not an unpaired race`() {
        val fixture = Fixture()
        fixture.client.startError = PclinkError.Storage(SecureStorePclinkIdentityStore.IDENTITY_UNREADABLE)
        try {
            fixture.controller.start()
            val failed = await(fixture.controller.state) { it.lastError != null }
            assertEquals("storage", failed.lastError?.code)
            assertEquals(SecureStorePclinkIdentityStore.IDENTITY_UNREADABLE, failed.lastError?.message)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `teardown closes the RPC instance`() {
        val fixture = Fixture()
        val rpc = PclinkRpc()
        val workspace = PcLinkWorkspace(
            client = fixture.client,
            transport = fixture.transport,
            storage = fixture.storage,
            diagnostics = fixture.diagnostics,
            rpc = rpc,
            closeables = emptyList(),
            closeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
        )
        val controller = workspace.controller()
        controller.close()

        val error = assertThrows(PclinkError.Cancelled::class.java) {
            runBlocking {
                withTimeout(TimeUnit.SECONDS.toMillis(2)) {
                    rpc.call("session/list", com.phonedsh.pclink.PclinkJson.Object(emptyMap()))
                }
            }
        }
        assertEquals("cancelled", error.code)
        fixture.close()
    }
}

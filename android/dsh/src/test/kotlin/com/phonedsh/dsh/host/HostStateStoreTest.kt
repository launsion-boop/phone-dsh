// phone-dsh — :dsh unit test: the `host-state.json` record (P15).
// SPDX-License-Identifier: MIT
//
// The store is the file `PERSIST_HOST_STATE` writes and the D14 boot mapping
// reads, so the properties that matter are the boring ones:
//   * the record round-trips all nine D14 states, with the Swift spellings an
//     existing workspace already contains (`handingOff`);
//   * an absent, unparsable, wrong-version or unknown-state file is `null` — the
//     "no persisted state" boot row — never a guessed state;
//   * the write is atomic through the `:platform` SPI, so a kill cannot leave
//     half a document for the next boot to parse.
//
// Allocation: pure JVM, `FakePlatform` for Durability/Clock and a temporary
// directory for the file.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerFailure
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.controller.NetworkPathStatus
import com.phonedsh.controller.ScenePhase
import com.phonedsh.platform.testing.FakePlatform
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HostStateStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val logger = RecordingHostLog()

    @Test
    fun everyStateRoundTripsWithItsPersistedSpelling() {
        // The one spelling that differs from the D14 display name: the Swift
        // reference writes `handingOff`, and a workspace written by one port has
        // to stay readable by the other.
        assertEquals("handingOff", HostStateStore.spelling(HostState.HANDING_OFF))
        assertEquals(HostState.HANDING_OFF, HostStateStore.stateOf("handingOff"))
        assertEquals("a case-insensitive read", HostState.HANDING_OFF, HostStateStore.stateOf("HandingOff"))
        for (state in HostState.entries) {
            assertEquals(state, HostStateStore.stateOf(HostStateStore.spelling(state)))
        }

        val platform = FakePlatform()
        val store = newStore(platform)
        for (state in HostState.entries) {
            val machine = machineIn(state)
            assertTrue("saving $state", store.save(machine))
            val record = store.load()
            assertNotNull("reading $state back", record)
            assertEquals(state, record!!.state)
            val raw = JSONObject(String(Files.readAllBytes(store.file), Charsets.UTF_8))
            assertEquals(HostStateStore.spelling(state), raw.getString("state"))
        }
    }

    @Test
    fun theRecordCarriesTheBootDispositionAndTheFailureReason() {
        val platform = FakePlatform()
        val store = newStore(platform)
        val machine = ControllerStateMachine.boot(persistedState = HostState.PARKED)
        machine.handle(
            ControllerSignal.FailureRaised(ControllerFailure.WAL_CORRUPT, detail = "tail"),
            atMillis = 1L,
        )
        assertTrue(store.save(machine, backoffUntilMillis = 123_456L))

        val record = store.load()!!
        assertEquals(HostState.FAILED, record.state)
        assertEquals("persisted_parked", record.bootReason)
        assertEquals("parked_resume", record.bootDisposition)
        assertEquals("WAL_CORRUPT", record.reason)
        // A deadline outside `Backoff` is not written: the field describes the
        // retry window of the state that is being persisted.
        assertNull(record.backoffUntilMillis)
    }

    @Test
    fun aBackoffRecordKeepsTheRetryDeadline() {
        val platform = FakePlatform()
        val store = newStore(platform)
        val machine = machineIn(HostState.BACKOFF)
        assertTrue(store.save(machine, backoffUntilMillis = 999L))
        assertEquals(999L, store.load()!!.backoffUntilMillis)
    }

    @Test
    fun anAbsentFileIsNoPersistedState() {
        val platform = FakePlatform()
        val store = newStore(platform)
        assertNull(store.load())
    }

    @Test
    fun anUnparsableFileIsNoPersistedStateAndSaysSo() {
        val platform = FakePlatform()
        val store = newStore(platform)
        Files.createDirectories(store.file.parent)
        Files.write(store.file, "{not json".toByteArray(Charsets.UTF_8))

        assertNull(store.load())
        assertTrue(
            "the refusal must be visible: ${logger.messages}",
            logger.messages.any { it.contains("does not parse") },
        )
    }

    @Test
    fun anUnknownVersionOrStateIsNoPersistedState() {
        val platform = FakePlatform()
        val store = newStore(platform)
        Files.createDirectories(store.file.parent)

        Files.write(store.file, """{"version":2,"state":"parked"}""".toByteArray(Charsets.UTF_8))
        assertNull("a future version is not guessed", store.load())

        Files.write(store.file, """{"version":1,"state":"sleeping"}""".toByteArray(Charsets.UTF_8))
        assertNull("a state this build does not have is not guessed", store.load())
    }

    @Test
    fun theWriteIsAtomicSoNoTemporaryFileSurvives() {
        val platform = FakePlatform()
        val store = newStore(platform)
        assertTrue(store.save(ControllerStateMachine.boot(persistedState = null)))

        val siblings = Files.list(store.file.parent).use { paths -> paths.toList() }
        assertEquals("only the record is published: $siblings", listOf(store.file), siblings)
    }

    /**
     * A machine that really is in [state], driven through the table rather than
     * written there: the store's round trip must hold for states the boot
     * mapping cannot produce directly.
     */
    private fun machineIn(state: HostState): ControllerStateMachine {
        val machine = ControllerStateMachine.boot(persistedState = null)
        var at = 1L
        fun feed(signal: ControllerSignal) {
            machine.handle(signal, at)
            at += 1
        }

        when (state) {
            HostState.RECOVERING -> Unit
            HostState.RUNNING -> feed(ControllerSignal.LeaseCheckResult(verified = true))
            HostState.DRAINING -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND))
            }

            HostState.PARKED -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.ScenePhaseChanged(ScenePhase.BACKGROUND))
                feed(ControllerSignal.DrainCompleted)
            }

            HostState.BACKOFF -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.NetworkPathChanged(NetworkPathStatus.UNSATISFIED))
            }

            HostState.HANDING_OFF -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.HandoffRequested)
            }

            HostState.REMOTE -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.HandoffRequested)
                feed(ControllerSignal.HandoffFenceInstalled)
                feed(ControllerSignal.HandoffCompleted(remoteAdmissionOpen = true))
            }

            HostState.RECLAIMING -> {
                feed(ControllerSignal.LeaseCheckResult(verified = true))
                feed(ControllerSignal.HandoffRequested)
                feed(ControllerSignal.HandoffFenceInstalled)
                feed(ControllerSignal.HandoffCompleted(remoteAdmissionOpen = true))
                feed(ControllerSignal.ReclaimRequested)
            }

            HostState.FAILED -> feed(
                ControllerSignal.FailureRaised(ControllerFailure.WAL_CORRUPT, detail = null),
            )
        }
        assertEquals("the machine reached $state", state, machine.state)
        return machine
    }

    private fun newStore(platform: FakePlatform): HostStateStore = HostStateStore(
        file = temporary.newFolder().toPath().resolve(HostStateStore.FILE_NAME),
        durability = platform,
        clock = platform,
        logger = logger,
    )
}

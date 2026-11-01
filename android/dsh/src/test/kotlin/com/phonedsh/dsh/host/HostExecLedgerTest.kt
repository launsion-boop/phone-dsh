// phone-dsh — :dsh unit test: HostExec wires the injected durable ledger.
// SPDX-License-Identifier: MIT
//
// exec.md §2's dedup table is only as durable as the ledger the bridge is
// built with. `FileRequestLedgerTest` proves the file backend; `ExecBridge`
// tests prove replay from an injected ledger. This test proves the wiring the
// App now uses: `HostExec.defaultTools(..., ledger = FileRequestLedger(...))` over
// a workspace root, and a *second* bridge built the same way over the same root
// answers the repeated `idem_key` from the ledger (`start.replayed = true`)
// instead of running the accelerator again.
//
// The accelerator is the real `phone info` with its default Android source, so
// on the JVM the platform read fails; that failure is still an honest terminal
// event and a durable record, which is exactly what the second boot replays.
// The assertion is about the ledger, not the device facts.
//
// JNI prerequisite, as for every `:dsh` wire test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.FileRequestLedger
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecFixtures
import com.phonedsh.platform.testing.FakePlatform
import java.nio.file.Files
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostExecLedgerTest {
    @Test
    fun aSecondBridgeOverTheSameWorkspaceReplaysThroughTheFileLedger() {
        FakePlatform().use { platform ->
            val root = platform.tempDir
            val idemKey = ExecFixtures.IDEM_A

            val firstBoot = HostExec.defaultTools(
                clock = platform,
                controller = openAdmission(),
                wal = null,
                logger = HostLog.None,
                ledger = FileRequestLedger(root, platform, platform),
            )
            val firstEvents = runBlocking {
                firstBoot.onRequest(
                    ExecFixtures.request(
                        execId = ExecFixtures.EXEC_ID,
                        argv = listOf(PHONE, "info"),
                        idemKey = idemKey,
                    ),
                ).toList()
            }
            val firstStart = firstEvents.first() as ExecEvent.Start
            assertEquals(ExecFixtures.EXEC_ID, firstStart.execId)
            assertFalse("the first call is a real run, not a replay", firstStart.replayed)
            assertTrue("a terminal event was recorded", firstEvents.size >= 2)
            assertTrue(
                "exec.md §2: the entry is a file under the workspace's exec/",
                Files.exists(root.resolve("exec").resolve("$idemKey.json")),
            )

            // A restart: fresh ledger, fresh bridge, same workspace root.
            val secondBoot = HostExec.defaultTools(
                clock = platform,
                controller = openAdmission(),
                wal = null,
                logger = HostLog.None,
                ledger = FileRequestLedger(root, platform, platform),
            )
            val secondEvents = runBlocking {
                secondBoot.onRequest(
                    ExecFixtures.request(
                        execId = ExecFixtures.OTHER_EXEC_ID,
                        argv = listOf(PHONE, "info"),
                        idemKey = idemKey,
                    ),
                ).toList()
            }

            val replayedStart = secondEvents.first() as ExecEvent.Start
            assertTrue("exec.md §2: a completed key replays", replayedStart.replayed)
            assertEquals("the recorded execution identity is kept", ExecFixtures.EXEC_ID, replayedStart.execId)
            assertEquals(
                "the whole recorded stream is replayed, not re-executed",
                firstEvents.map { event -> event.type },
                secondEvents.map { event -> event.type },
            )
        }
    }

    /**
     * The D14 machine in `Running`, i.e. admission open.
     *
     * The facade reaches this state through the engine and the lease probe; this
     * test drives the one transition directly because it asserts the exec
     * wiring, not the boot sequence (HostExecTest covers that path).
     */
    private fun openAdmission(): ControllerStateMachine =
        ControllerStateMachine.boot(persistedState = null).apply {
            handle(ControllerSignal.LeaseCheckResult(verified = true), atMillis = 0L)
        }

    private companion object {
        /** `HostExec.defaultTools` advertises exactly this accelerator. */
        const val PHONE: String = "phone"
    }
}

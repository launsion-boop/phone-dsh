// phone-dsh — :dsh unit test: the durable exec dedup table (exec.md §2).
// SPDX-License-Identifier: MIT
//
// The persistent ledger is what makes D10 replay survive a process restart. The
// required facts:
//
//   1. a completed entry written by one instance replays from a *new* instance
//      over the same directory — the cross-process answer;
//   2. an in-flight entry is never evicted by the `maxEntries` trim (forgetting
//      it would let the same key execute twice), even when completed entries
//      are evicted around it;
//   3. an intent recovered after a "crash" replays the terminal `interrupted`
//      error and is never executed again;
//   4. abandon removes a never-completed entry, so a cancelled call may retry;
//   5. the entry file is the exec record of exec.md §2 and stores no absolute
//      workspace path.
//
// `FakePlatform` is the real `:platform` test double; its `atomicReplace` does
// the actual temp-file + rename and records every `fsyncPath`, so the ordering
// assertions are about the production seam, not a mock of it.

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.tools.RequestLedger
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FileRequestLedgerTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val platform = FakePlatform()

    private fun root(): Path = temporary.newFolder().toPath()

    private fun record(
        idemKey: String = KEY_A,
        execId: String = ExecFixtures.EXEC_ID,
    ): ExecRecord = ExecRecord(
        idemKey = idemKey,
        execId = execId,
        argv = listOf("rg", "needle"),
        cwd = "/dsh/workspace",
        createdAtMs = 1_700_000_000_000L,
        events = listOf(
            ExecEvent.Start(execId = execId, seq = 0L),
            ExecEvent.Exit(
                execId = execId,
                seq = 1L,
                code = 0,
                signal = null,
                status = ExecEvent.ExitStatus.EXITED,
                quiescent = true,
                stdoutBytes = 0L,
                stderrBytes = 0L,
            ),
        ),
    )

    @Test
    fun aCompletedEntryReplaysFromASecondInstance() {
        val directory = root()
        val first = FileRequestLedger(directory, platform, TestClock())
        assertEquals(RequestLedger.Admission.Proceed, first.admit(KEY_A, "rg"))
        first.complete(KEY_A, ToolOutcome.Success(record().toJson()))

        val second = FileRequestLedger(directory, platform, TestClock())
        val admission = second.admit(KEY_A, "rg")

        assertTrue("the durable entry answers Replay, not Proceed", admission is RequestLedger.Admission.Replay)
        val replay = admission as RequestLedger.Admission.Replay
        assertEquals("rg", replay.tool)
        val stored = replay.outcome as ToolOutcome.Success
        assertEquals(WireCodec.canonicalJson(record().toJson()), stored.resultJson)
        assertTrue(Files.exists(directory.resolve("exec").resolve("$KEY_A.json")))
    }

    @Test
    fun anInFlightEntryIsNeverEvictedEvenWhenTheTableIsFull() {
        val directory = root()
        val clock = TestClock(wall = 1_000L)
        val ledger = FileRequestLedger(directory, platform, clock, maxEntries = 2)

        assertEquals("A stays in flight for the whole test", RequestLedger.Admission.Proceed, ledger.admit(KEY_A, "rg"))
        clock.wall += 10_000L
        assertEquals(RequestLedger.Admission.Proceed, ledger.admit(KEY_B, "rg"))
        ledger.complete(KEY_B, ToolOutcome.Success(record(idemKey = KEY_B, execId = EXEC_B).toJson()))
        clock.wall += 10_000L
        assertEquals(RequestLedger.Admission.Proceed, ledger.admit(KEY_C, "rg"))
        ledger.complete(KEY_C, ToolOutcome.Success(record(idemKey = KEY_C, execId = EXEC_C).toJson()))

        assertEquals(
            "an in-flight entry must not be forgotten by the trim",
            RequestLedger.Admission.InFlight,
            ledger.admit(KEY_A, "rg"),
        )
        assertTrue("A's intent file survives", Files.exists(entryFile(directory, KEY_A)))
        assertFalse("the oldest completed entry was evicted", Files.exists(entryFile(directory, KEY_B)))
        assertTrue("the newest completed entry is retained", Files.exists(entryFile(directory, KEY_C)))

        val reloaded = FileRequestLedger(directory, platform, clock, maxEntries = 2)
        val admission = reloaded.admit(KEY_A, "rg")
        assertTrue("the surviving intent is recovered, not re-run", admission is RequestLedger.Admission.Replay)
        assertEquals(
            "interrupted",
            ((admission as RequestLedger.Admission.Replay).outcome as ToolOutcome.Failure).code,
        )
    }

    @Test
    fun aRecoveredInFlightEntryReplaysInterruptedAndIsNeverExecutedAgain() {
        val directory = root()
        val first = FileRequestLedger(directory, platform, TestClock())
        assertEquals(RequestLedger.Admission.Proceed, first.admit(KEY_A, "rg"))

        val second = FileRequestLedger(directory, platform, TestClock())
        val recovery = second.admit(KEY_A, "rg") as RequestLedger.Admission.Replay
        val failure = recovery.outcome as ToolOutcome.Failure
        assertEquals("exec.md §2: a host death mid-execution is terminal", "interrupted", failure.code)

        val third = FileRequestLedger(directory, platform, TestClock())
        val again = third.admit(KEY_A, "rg") as RequestLedger.Admission.Replay
        assertEquals(
            "the interrupted entry stays terminal across reloads",
            failure,
            again.outcome,
        )
    }

    @Test
    fun abandonForgetsANeverCompletedEntry() {
        val directory = root()
        val ledger = FileRequestLedger(directory, platform, TestClock())
        assertEquals(RequestLedger.Admission.Proceed, ledger.admit(KEY_A, "rg"))
        assertTrue(Files.exists(entryFile(directory, KEY_A)))

        ledger.abandon(KEY_A)

        assertFalse("abandon removes the intent file", Files.exists(entryFile(directory, KEY_A)))
        assertEquals(
            "a cancelled call may run again",
            RequestLedger.Admission.Proceed,
            ledger.admit(KEY_A, "rg"),
        )
    }

    @Test
    fun aFailureOutcomeRoundTripsItsCodeAndMessage() {
        val directory = root()
        val first = FileRequestLedger(directory, platform, TestClock())
        first.admit(KEY_A, "rg")
        first.complete(KEY_A, ToolOutcome.Failure("tool_failed", "the tool threw"))

        val second = FileRequestLedger(directory, platform, TestClock())
        val replay = second.admit(KEY_A, "rg") as RequestLedger.Admission.Replay

        assertEquals(ToolOutcome.Failure("tool_failed", "the tool threw"), replay.outcome)
    }

    @Test
    fun theEntryFileIsTheExecRecordAndStoresNoAbsoluteWorkspacePath() {
        val directory = root()
        val ledger = FileRequestLedger(directory, platform, TestClock())
        ledger.admit(KEY_A, "rg")
        ledger.complete(KEY_A, ToolOutcome.Success(record().toJson()))

        val file = entryFile(directory, KEY_A)
        val text = Files.readAllBytes(file).toString(Charsets.UTF_8)
        val payload = JSONObject(text)

        assertEquals(1, payload.getInt("v"))
        assertEquals("exec", payload.getString("kind"))
        assertEquals(KEY_A, payload.getString("idem_key"))
        assertEquals(ExecFixtures.EXEC_ID, payload.getString("exec_id"))
        assertTrue(payload.getBoolean("terminal"))
        assertEquals(2, payload.getJSONArray("events").length())
        assertFalse(
            "the workspace root must never be written into an entry",
            text.contains(directory.toAbsolutePath().toString()),
        )
    }

    @Test
    fun aBridgeOverTheDurableLedgerReplaysAcrossInstancesWithoutRunningTheTool() = runBlocking {
        val directory = root()
        val firstLedger = FileRequestLedger(directory, platform, TestClock())
        val liveTool = CountingTool()
        val firstBridge = ExecFixtures.bridge(tool = liveTool, ledger = firstLedger)

        val recorded = firstBridge.onRequest(ExecFixtures.request()).toList()
        assertEquals(1, liveTool.calls.get())
        assertEquals(listOf("start", "output", "exit"), recorded.map { it.type })

        val secondLedger = FileRequestLedger(directory, platform, TestClock())
        val freshTool = CountingTool()
        val secondBridge = ExecFixtures.bridge(tool = freshTool, ledger = secondLedger)

        val replay = secondBridge.onRequest(
            ExecFixtures.request(execId = ExecFixtures.OTHER_EXEC_ID),
        ).toList()

        assertEquals("the restarted host must not execute the side effect", 0, freshTool.calls.get())
        assertEquals(recorded.drop(1), replay.drop(1))
        assertEquals(ExecFixtures.EXEC_ID, replay.first().execId)
        assertTrue((replay.first() as ExecEvent.Start).replayed)
    }

    private fun entryFile(directory: Path, key: String): Path =
        directory.resolve("exec").resolve("$key.json")

    companion object {
        private val KEY_A: String = ExecFixtures.IDEM_A
        private val KEY_B: String = ExecFixtures.IDEM_B
        private val KEY_C: String = "c".repeat(64)
        private const val EXEC_B: String = "xl1-test-b-0"
        private const val EXEC_C: String = "xl1-test-c-0"
    }
}

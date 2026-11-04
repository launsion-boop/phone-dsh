// phone-dsh — :dsh unit test: the tables of bridge.md §12, checked as tables.
// SPDX-License-Identifier: MIT
//
// The job machine is only worth what its exhaustiveness is worth: a state with no
// outgoing edge strands a job, and a missing boot row means a killed process comes
// back in a state the code cannot leave. So this file does not test one transition
// at a time; it walks the whole table and asserts the properties §12.3 claims:
//
//   * nine states, four terminal, and the two lists partition them;
//   * fourteen state-to-state edges (§12.3's table is fifteen rows, one of which
//     is the entry row), and every non-terminal state has at least one way out;
//   * `succeeded -> ingestRefused` is the only edge out of a terminal state;
//   * a boot maps every persisted state to a decision;
//   * the failure vocabulary is the four existing codes and the three existing
//     outcomes, and a job that may have run is never automatically retryable.
//
// The ingest math and the record codec are here too: both are pure, and both are
// where a wrong constant would be invisible in an end-to-end run.

package com.phonedsh.dsh.localexec

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuntuJobRulesTest {

    // ---- the state machine ------------------------------------------------

    @Test
    fun everyStateOfSection123IsPresentAndPartitioned() {
        assertEquals(9, UbuntuJobState.ALL.size)
        assertEquals(5, UbuntuJobState.IN_FLIGHT.size)
        assertEquals(4, UbuntuJobState.TERMINAL.size)
        assertEquals(
            UbuntuJobState.ALL.toSet(),
            (UbuntuJobState.IN_FLIGHT + UbuntuJobState.TERMINAL).toSet(),
        )
        assertEquals(9, UbuntuJobState.ALL.map { it.wire }.toSet().size)
        assertTrue(UbuntuJobState.IN_FLIGHT.none { it.terminal })
        assertTrue(UbuntuJobState.TERMINAL.all { it.terminal })
        // The persisted spelling round-trips, and an unknown one is not invented.
        UbuntuJobState.ALL.forEach { assertEquals(it, UbuntuJobState.ofWire(it.wire)) }
        assertNull(UbuntuJobState.ofWire("Running"))
    }

    @Test
    fun everyTransitionOfSection123IsPresentAndNoJobIsStranded() {
        // §12.3's table has fifteen rows; row 1 is the entry (`-` -> admitted).
        val edges = UbuntuJobState.EDGES.values.sumOf { it.size }
        assertEquals(14, edges)
        UbuntuJobState.ALL.forEach { state ->
            assertNotNull("§12.3 has no row for ${state.wire}", UbuntuJobState.EDGES[state])
        }
        UbuntuJobState.IN_FLIGHT.forEach { state ->
            assertTrue(
                "a non-terminal state with no way out strands a job: ${state.wire}",
                UbuntuJobState.EDGES.getValue(state).isNotEmpty(),
            )
        }
        // The one legal revision edge, and no other terminal has an outgoing edge.
        assertEquals(setOf(UbuntuJobState.INGEST_REFUSED), UbuntuJobState.EDGES.getValue(UbuntuJobState.SUCCEEDED))
        assertTrue(UbuntuJobState.EDGES.getValue(UbuntuJobState.FAILED).isEmpty())
        assertTrue(UbuntuJobState.EDGES.getValue(UbuntuJobState.CANCELLED).isEmpty())
        assertTrue(UbuntuJobState.EDGES.getValue(UbuntuJobState.INGEST_REFUSED).isEmpty())
    }

    @Test
    fun theAuthorityLegsAreTheHostsThreeLegs() {
        // §12.4: the job's legs are the host's `HandingOff`/`Remote`/`Reclaiming` in
        // order, and a job never jumps straight from work to results.
        assertTrue(UbuntuJobState.canMove(UbuntuJobState.HANDING_OFF, UbuntuJobState.REMOTE))
        assertTrue(UbuntuJobState.canMove(UbuntuJobState.REMOTE, UbuntuJobState.RECLAIMING))
        assertFalse("no edge skips the return leg", UbuntuJobState.canMove(UbuntuJobState.REMOTE, UbuntuJobState.SUCCEEDED))
        assertFalse(UbuntuJobState.canMove(UbuntuJobState.SEALING, UbuntuJobState.REMOTE))
        assertFalse(UbuntuJobState.canMove(UbuntuJobState.ADMITTED, UbuntuJobState.RECLAIMING))
        // Terminal is terminal, except the one documented revision.
        assertFalse(UbuntuJobState.canMove(UbuntuJobState.FAILED, UbuntuJobState.SUCCEEDED))
        assertFalse(UbuntuJobState.canMove(UbuntuJobState.CANCELLED, UbuntuJobState.INGEST_REFUSED))
    }

    @Test
    fun theBootMappingCoversEveryPersistedState() {
        // budget.md §3's rows, applied to a job: what cannot be resumed is failed
        // with the outcome the host can actually prove.
        listOf(UbuntuJobState.ADMITTED, UbuntuJobState.SEALING).forEach { state ->
            val disposition = UbuntuJobState.bootDisposition(state)
            assertTrue("$state", disposition is UbuntuBootDisposition.Fail)
            disposition as UbuntuBootDisposition.Fail
            assertEquals(UbuntuOutcome.NOT_STARTED, disposition.outcome)
            assertEquals(UbuntuCause.HOST_LOST, disposition.cause)
        }
        val handoff = UbuntuJobState.bootDisposition(UbuntuJobState.HANDING_OFF)
        assertTrue(handoff is UbuntuBootDisposition.Fail)
        assertEquals(UbuntuOutcome.UNKNOWN, (handoff as UbuntuBootDisposition.Fail).outcome)
        assertEquals(UbuntuCause.HANDOFF_LOST, handoff.cause)
        // The two that survive a kill.
        assertEquals(UbuntuBootDisposition.Keep, UbuntuJobState.bootDisposition(UbuntuJobState.REMOTE))
        assertEquals(UbuntuBootDisposition.Keep, UbuntuJobState.bootDisposition(UbuntuJobState.RECLAIMING))
        UbuntuJobState.TERMINAL.forEach {
            assertEquals(UbuntuBootDisposition.Keep, UbuntuJobState.bootDisposition(it))
        }
    }

    // ---- the failure vocabulary ------------------------------------------

    @Test
    fun everyFailureReusesAnExistingCodeAndOutcome() {
        val failures = listOf(
            UbuntuFailures.envUnavailable("ubuntu-24.04"),
            UbuntuFailures.memoryInsufficient(1, 2),
            UbuntuFailures.snapshotTooLarge(1, 2),
            UbuntuFailures.sealFailed("chmod_failed"),
            UbuntuFailures.admissionClosed(),
            UbuntuFailures.cancelled(UbuntuCause.HOST_DRAINING),
            UbuntuFailures.cancelledBeforeStart(UbuntuCause.PAGE_CANCEL),
            UbuntuFailures.drainDeadline(),
            UbuntuFailures.jobTimeout(),
            UbuntuFailures.adapterGone(),
            UbuntuFailures.adapterRefused("no rootfs"),
            UbuntuFailures.adapterFailed("crashed"),
            UbuntuFailures.lost(UbuntuCause.HOST_LOST),
            UbuntuFailures.lost(UbuntuCause.MEMORY_RECLAIMED, UbuntuOutcome.UNKNOWN),
            UbuntuFailures.lost(UbuntuCause.HOST_LOST, UbuntuOutcome.NOT_STARTED),
            UbuntuFailures.sealLost("verify_failed"),
        )
        failures.forEach { failure ->
            assertTrue("${failure.code} is not a spec/v1 code", failure.code in UbuntuJobFailure.CODES)
            assertTrue("${failure.outcome} is not a spec/v1 outcome", failure.outcome in UbuntuJobFailure.OUTCOMES)
            // §12.6: a job that may have run is never automatically retryable.
            if (failure.retryable) assertEquals(UbuntuOutcome.NOT_STARTED, failure.outcome)
            assertTrue(failure.message.length <= UbuntuJobFailure.MAX_MESSAGE)
            assertTrue("a message must not carry an absolute path: ${failure.message}", !failure.message.contains("/dsh/"))
        }
        // `admission_closed` is the only foreground-required row.
        assertEquals(
            listOf(UbuntuFailures.admissionClosed()),
            failures.filter { it.foregroundRequired },
        )
        // A cancel before any contact is retryable; a cancel after it is not.
        assertTrue(UbuntuFailures.cancelledBeforeStart(UbuntuCause.PAGE_CANCEL).retryable)
        assertFalse(UbuntuFailures.cancelled(UbuntuCause.PAGE_CANCEL).retryable)
    }

    // ---- the ingest limits ----------------------------------------------

    @Test
    fun theMutationPlanIsOneCompleteWriteThenSuffixesOfAtMostFifteenMiB() {
        // A zero-byte artifact still needs its complete write, or the file is absent
        // while the manifest says it landed.
        assertEquals(
            listOf(UbuntuMutation(complete = true, appendFrom = 0, length = 0)),
            UbuntuArtifactIngest.plan(0),
        )
        assertEquals(
            listOf(UbuntuMutation(complete = true, appendFrom = 0, length = 12)),
            UbuntuArtifactIngest.plan(12),
        )
        // Exactly one mutation's worth: no append.
        assertEquals(
            listOf(UbuntuMutation(complete = true, appendFrom = 0, length = FIFTEEN_MIB)),
            UbuntuArtifactIngest.plan(FIFTEEN_MIB),
        )
        // One byte over: the append carries the suffix only, never the file.
        val over = UbuntuArtifactIngest.plan(FIFTEEN_MIB + 1)
        assertEquals(2, over.size)
        assertEquals(FIFTEEN_MIB, over[1].appendFrom)
        assertEquals(1L, over[1].length)
        // 40 MiB is 15 + 15 + 10, and every append starts where the last ended.
        val big = UbuntuArtifactIngest.plan(40L * UbuntuJobLimits.MIB)
        assertEquals(listOf(15L, 15L, 10L).map { it * UbuntuJobLimits.MIB }, big.map { it.length })
        assertEquals(listOf(0L, 15L * UbuntuJobLimits.MIB, 30L * UbuntuJobLimits.MIB), big.map { it.appendFrom })
        assertTrue(big.all { it.complete == (it.appendFrom == 0L) })
        // The plan always reconstructs the file exactly.
        big.forEach { assertTrue(it.length <= FIFTEEN_MIB) }
        assertEquals(40L * UbuntuJobLimits.MIB, big.sumOf { it.length })
    }

    @Test
    fun theFetchChunkIsTheBridgeBinaryCapAndDividesAMutation() {
        assertEquals(524_288L, UbuntuJobLimits.FETCH_CHUNK_BYTES)
        assertEquals(0L, UbuntuJobLimits.MUTATION_MAX_BYTES % UbuntuJobLimits.FETCH_CHUNK_BYTES)
        assertEquals(1, UbuntuArtifactIngest.chunkCount(0))
        assertEquals(1, UbuntuArtifactIngest.chunkCount(512 * 1024L))
        assertEquals(2, UbuntuArtifactIngest.chunkCount(512 * 1024L + 1))
        assertEquals(31, UbuntuArtifactIngest.chunkCount(MockUbuntuAdapter.MID_BYTES))
        assertEquals(40, UbuntuArtifactIngest.chunkCount(MockUbuntuAdapter.HUGE_BYTES))
    }

    @Test
    fun thePrecheckWalksNamesAndAddsSizesSoTheVerdictIsDeterministic() {
        val limits = UbuntuJobLimits(
            fileLimitBytes = SIXTEEN_MIB,
            workspaceLimitBytes = 30L * UbuntuJobLimits.MIB,
            rssLimitBytes = null,
        )
        val manifest = listOf(
            UbuntuArtifactRecord("b.bin", 20L * UbuntuJobLimits.MIB, null, UbuntuArtifactState.AVAILABLE),
            UbuntuArtifactRecord("a.bin", 16L * UbuntuJobLimits.MIB, null, UbuntuArtifactState.AVAILABLE),
            UbuntuArtifactRecord("c.bin", 15L * UbuntuJobLimits.MIB, null, UbuntuArtifactState.AVAILABLE),
        )
        val verdicts = UbuntuArtifactIngest.precheck(manifest, limits, workspaceUsedBytes = 0)
        // Sorted by name: a.bin fits (16 <= 16, 16 <= 30), b.bin is over the file
        // bound, c.bin would cross the aggregate bound.
        assertEquals(listOf("a.bin", "b.bin", "c.bin"), verdicts.map { it.name })
        assertEquals(UbuntuArtifactState.AVAILABLE, verdicts[0].state)
        assertEquals(UbuntuVfsRefusal.FILE_TOO_LARGE, verdicts[1].refusal!!.reason)
        assertEquals(SIXTEEN_MIB, verdicts[1].refusal!!.limit)
        assertEquals(UbuntuVfsRefusal.QUOTA_EXCEEDED, verdicts[2].refusal!!.reason)
        assertEquals(30L * UbuntuJobLimits.MIB, verdicts[2].refusal!!.limit)

        // An already-ingested entry is kept and its bytes count as spent.
        val resumed = UbuntuArtifactIngest.precheck(
            listOf(
                UbuntuArtifactRecord("a.bin", 16L * UbuntuJobLimits.MIB, null, UbuntuArtifactState.INGESTED, "/dsh/workspace/a"),
                UbuntuArtifactRecord("b.bin", 15L * UbuntuJobLimits.MIB, null, UbuntuArtifactState.AVAILABLE),
            ),
            limits,
            workspaceUsedBytes = 0,
        )
        assertEquals(UbuntuArtifactState.INGESTED, resumed[0].state)
        assertEquals(UbuntuVfsRefusal.QUOTA_EXCEEDED, resumed[1].refusal!!.reason)
    }

    @Test
    fun aLogTailIsATailOnACodePointBoundary() {
        val many = "x".repeat(300_000)
        val tail = UbuntuArtifactIngest.tail(many)
        val bytes = tail.toByteArray(Charsets.UTF_8)
        assertTrue("the tail is over the 256 KiB bound: ${bytes.size}", bytes.size <= UbuntuJobLimits.LOG_TAIL_MAX_BYTES + 40)
        assertTrue(tail.startsWith("[truncated "))
        // A cut in the middle of a multi-byte character is moved forward, not
        // replaced with U+FFFD: the tail decodes cleanly.
        val unicode = "é".repeat(200_000)
        val unicodeTail = UbuntuArtifactIngest.tail(unicode, maxBytes = 1_000)
        assertTrue(unicodeTail.endsWith("é"))
        assertTrue(unicodeTail.toByteArray(Charsets.UTF_8).size <= 1_100)
        // A short log is untouched: a reader must be able to tell the two apart.
        assertEquals("short\n", UbuntuArtifactIngest.tail("short\n"))
    }

    @Test
    fun onlyChannelSixMutationPathsAreAccepted() {
        assertTrue(UbuntuArtifactIngest.isMutationPath("/dsh/workspace/.ubuntu/uj-1/tiny.txt"))
        assertTrue(UbuntuArtifactIngest.isMutationPath("/dsh/workspace/a"))
        assertFalse(UbuntuArtifactIngest.isMutationPath("/dsh/workspace"))
        assertFalse(UbuntuArtifactIngest.isMutationPath("/dsh/workspace/../etc/passwd"))
        assertFalse(UbuntuArtifactIngest.isMutationPath("/dsh/home/sessions/x"))
        assertFalse(UbuntuArtifactIngest.isMutationPath("/tmp/x"))
        assertFalse(UbuntuArtifactIngest.isMutationPath("/dsh/workspace/a/"))
    }

    // ---- the record codec ------------------------------------------------

    @Test
    fun aRecordSurvivesTheCodecAndAnUnknownVersionIsRefused() {
        TempDir().use { temp ->
            val record = seededRecord("uj-codec", UbuntuJobState.INGEST_REFUSED, UbuntuSealState.RESTORED).copy(
                artifacts = listOf(
                    UbuntuArtifactRecord("huge.bin", MockUbuntuAdapter.HUGE_BYTES, "ab", UbuntuArtifactState.REFUSED,
                        refusal = UbuntuVfsRefusal(UbuntuVfsRefusal.FILE_TOO_LARGE, FIFTEEN_MIB, MockUbuntuAdapter.HUGE_BYTES)),
                    UbuntuArtifactRecord("tiny.txt", 12, null, UbuntuArtifactState.INGESTED, "/dsh/workspace/x"),
                ),
                failure = null,
                exitCode = 0,
                internalAccessObserved = false,
            )
            val store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability)
            runBlocking {
                assertTrue(store.save(record))
                assertEquals(record, store.load(record.jobId))
                assertEquals(record, store.loadAll().single())
            }
            // A version this build does not write is not guessed at.
            val json = UbuntuJobStore.encode(record).replace("\"version\":1", "\"version\":2")
            assertNull(UbuntuJobStore.decode(org.json.JSONObject(json)))
            // Neither is a state spelling this build does not have.
            val badState = UbuntuJobStore.encode(record).replace("\"state\":\"ingestRefused\"", "\"state\":\"weird\"")
            assertNull(UbuntuJobStore.decode(org.json.JSONObject(badState)))
        }
    }
}

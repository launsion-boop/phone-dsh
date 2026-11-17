// SPDX-License-Identifier: MIT
// Recovery behaviour of the real external admission journal
// (spec/host/v1/external-admission.md sections 3 to 6; change record
// PC-20261116-external-admission section 4): a kill injected at each of the five
// write / hand-off boundaries followed by a reopen, the undecodable-file rule,
// and the hand-off of `dsh-session` records to the real send outbox with
// `rpcId = downstreamId`.
//
// Host JVM evidence only: a simulated kill is an exception thrown inside the
// real atomic write, not a device power loss.
package com.phonedsh.probe.admission

import com.phonedsh.probe.outbox.DurableFileStore
import com.phonedsh.probe.outbox.DurableWriteStep
import com.phonedsh.probe.outbox.KillingFileStore
import com.phonedsh.probe.outbox.SendOutbox
import com.phonedsh.probe.outbox.SendOutboxState
import com.phonedsh.probe.outbox.SimulatedKill
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class ExternalAdmissionRecoveryTest {
    private lateinit var sandbox: AdmissionSandbox
    private val clock = TestClock()
    private val downstream = AdmissionSpec.uuid(1)

    @Before
    fun setUp() {
        sandbox = AdmissionSandbox(Files.createTempDirectory("admissions-recovery").toFile())
    }

    @After
    fun tearDown() {
        sandbox.root.deleteRecursively()
    }

    /** A new journal over the same directory: what a restarted process has. */
    private fun reopened(files: DurableFileStore = DurableFileStore()) = sandbox.journal(clock, files)

    private fun outbox(files: DurableFileStore = DurableFileStore()) = SendOutbox(sandbox.root, nowMs = clock, files = files)

    private fun dispatcher(
        outbox: SendOutbox = outbox(),
        sessions: Set<String> = setOf("gb-main"),
        account: String? = null,
    ) = OutboxAdmissionDispatcher(outbox, sessionExists = { it in sessions }, isSignedInAccount = { it == account })

    private fun admitted(request: AdmissionRequest = AdmissionSpec.request()): AdmissionReceipt =
        (reopened().admit(request) as AdmissionResult.Admitted).receipt

    private inline fun kill(block: () -> Unit) {
        try {
            block()
        } catch (_: SimulatedKill) {
            return
        }
        fail("the simulated kill did not fire")
    }

    // ------------------------------------------------- boundary 1: before write

    @Test
    fun `boundary 1 - a kill before the record is committed leaves no record and no receipt`() {
        for (step in listOf(DurableWriteStep.BEFORE_TEMP, DurableWriteStep.TEMP_SYNCED)) {
            sandbox.reset()
            val files = KillingFileStore().apply { killWrite(step) }
            kill { reopened(files).admit(AdmissionSpec.request()) }

            val restarted = reopened()
            assertTrue("$step", restarted.records().isEmpty())
            assertTrue(restarted.dispatchable().isEmpty())
            // The source was never told "received", so it delivers again: one admission.
            val result = restarted.admit(AdmissionSpec.request())
            assertEquals("$step", "admitted", result.name())
            val receipt = (result as AdmissionResult.Admitted).receipt
            assertEquals(downstream, receipt.downstreamId)
            assertEquals(listOf(receipt.admissionId), reopened().records().map { it.admissionId })
            // A half-written temporary file is never read as a record and is left where it is.
            val leftovers = sandbox.directory.list()!!.filter { it.startsWith(".") }
            assertEquals("$step", if (step == DurableWriteStep.TEMP_SYNCED) 1 else 0, leftovers.size)
            assertEquals(1 + leftovers.size, reopened().directoryEntryCount())
        }
    }

    // --------------------------------- boundary 2: written, not yet handed over

    @Test
    fun `boundary 2 - a record written but not dispatched is delivered once after a restart`() {
        // The rename happened; the process dies before it could return a receipt or dispatch.
        val files = KillingFileStore().apply { killWrite(DurableWriteStep.RENAMED) }
        kill { reopened(files).admit(AdmissionSpec.request()) }

        val restarted = reopened()
        val record = restarted.records().single()
        assertEquals(AdmissionStage.ADMITTED, record.stage)
        assertEquals(0, record.attempts)
        assertEquals("现在几点了？", record.text)
        assertEquals(downstream, record.downstreamId)
        // The redelivery is answered from the record: same ids, nothing rewritten.
        val before = sandbox.snapshot()
        val again = restarted.admit(AdmissionSpec.request(downstreamId = AdmissionSpec.uuid(2))) as AdmissionResult.Duplicate
        assertEquals(AdmissionReceipt(record.admissionId, downstream, AdmissionStage.ADMITTED), again.receipt)
        assertEquals(before, sandbox.snapshot())

        val report = restarted.runDispatchPass(dispatcher())
        assertEquals(listOf(record.admissionId), report.linked)
        val entry = outbox().entries().single()
        assertEquals(downstream, entry.rpcId)
        assertEquals("gb-main", entry.sessionId)
        assertEquals("现在几点了？", entry.text)
        assertEquals(SendOutboxState.QUEUED, entry.state)
        // A second pass and a second process find nothing left to hand over.
        assertTrue(reopened().dispatchable().isEmpty())
        assertEquals(emptyList<String>(), reopened().runDispatchPass(dispatcher()).linked)
        assertEquals(1, outbox().entries().size)
    }

    // --------------------------------- boundary 3: dispatching, not confirmed

    @Test
    fun `boundary 3 - a kill between dispatching and the downstream write is redone with the same id`() {
        val receipt = admitted()
        val dying = object : AdmissionDispatcher {
            override fun precheck(record: AdmissionRecord) = AdmissionPrecheck.Proceed

            override fun deliver(record: AdmissionRecord): AdmissionDelivery = throw SimulatedKill("before the outbox write")
        }
        kill { reopened().runDispatchPass(dying) }
        assertTrue(outbox().entries().isEmpty())
        assertRedoneOnce(receipt)
    }

    @Test
    fun `boundary 3 - a kill after the downstream write but before linked is redone without a second entry`() {
        val receipt = admitted()
        // The dispatching write succeeds; the linked write is the one that is killed.
        val files = KillingFileStore()
        val journal = reopened(files)
        val killing = object : AdmissionDispatcher {
            val real = dispatcher()

            override fun precheck(record: AdmissionRecord) = real.precheck(record)

            override fun deliver(record: AdmissionRecord): AdmissionDelivery =
                real.deliver(record).also { files.killWrite(DurableWriteStep.TEMP_SYNCED) }
        }
        kill { journal.runDispatchPass(killing) }
        assertEquals(downstream, outbox().entries().single().rpcId)
        assertRedoneOnce(receipt)
    }

    @Test
    fun `boundary 3 - a kill inside the outbox write itself is redone without a second entry`() {
        val receipt = admitted()
        val files = KillingFileStore().apply { killWrite(DurableWriteStep.TEMP_SYNCED) { it.parentFile?.name == "send-outbox" } }
        kill { reopened().runDispatchPass(dispatcher(outbox(files))) }
        assertTrue(outbox().entries().isEmpty())
        assertRedoneOnce(receipt)
    }

    private fun assertRedoneOnce(receipt: AdmissionReceipt) {
        // Long after expiry: a dispatching record has no proof either way, so it is
        // neither expired nor cancelled nor re-admitted by a restart.
        clock.now = AdmissionSpec.T0 + 3 * AdmissionSpec.DAY
        val restarted = reopened()
        assertEquals(AdmissionSweepReport(), restarted.openSweep)
        val stuck = restarted.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.DISPATCHING, stuck.stage)
        assertEquals(0, stuck.attempts)
        assertEquals(downstream, stuck.downstreamId)
        assertEquals("duplicate", restarted.admit(AdmissionSpec.request(expiresAtMs = clock.now + 60_000)).name())
        try {
            restarted.cancel(receipt.admissionId, "withdrawn")
            fail("a dispatching record was cancelled")
        } catch (_: AdmissionException.IllegalTransition) {
            // There is no dispatching → cancelled edge.
        }
        assertEquals(listOf(receipt.admissionId), restarted.dispatchable().map { it.admissionId })

        // The target's existence is not re-litigated for a dispatching record: the write is repeated.
        val report = restarted.runDispatchPass(dispatcher(sessions = emptySet()))
        assertEquals(listOf(receipt.admissionId), report.linked)
        val linked = reopened().record(receipt.admissionId)!!
        assertEquals(AdmissionStage.LINKED, linked.stage)
        assertNull(linked.text)
        assertEquals(clock.now, linked.linkedAtMs)
        val entries = outbox().entries()
        assertEquals("exactly one downstream entry", listOf(downstream), entries.map { it.rpcId })
        assertEquals("现在几点了？", entries.single().text)
    }

    @Test
    fun `boundary 3 - a redo after the outbox already delivered and deleted the entry reuses the same rpcId`() {
        val receipt = admitted()
        val journal = reopened()
        journal.markDispatching(receipt.admissionId)
        val queue = outbox()
        dispatcher(queue).deliver(journal.record(receipt.admissionId)!!)
        queue.markSubmitting(downstream)
        queue.markAccepted(downstream)
        assertTrue(queue.observeAuthoritativeUserMessage(downstream))
        assertTrue(outbox().entries().isEmpty())

        // The journal never learned of the write. It repeats it under the same id,
        // which is the only key the authority de-duplicates by; no new id is minted.
        assertEquals(listOf(receipt.admissionId), reopened().runDispatchPass(dispatcher()).linked)
        assertEquals(listOf(downstream), outbox().entries().map { it.rpcId })
    }

    // ----------------------------------------- boundary 4: linked, not settled

    @Test
    fun `boundary 4 - a linked record is never handed over again and settles only on downstream evidence`() {
        val receipt = admitted()
        reopened().runDispatchPass(dispatcher())

        val restarted = reopened()
        val linked = restarted.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.LINKED, linked.stage)
        assertNull("text leaves the journal once the outbox holds it", linked.text)
        assertFalse(sandbox.file(receipt.admissionId).readText().contains("现在几点了"))
        assertTrue(restarted.dispatchable().isEmpty())
        val before = sandbox.snapshot()
        val report = restarted.runDispatchPass(dispatcher())
        assertTrue(report.linked.isEmpty() && report.unresolved.isEmpty())
        assertEquals(before, sandbox.snapshot())
        assertEquals(1, outbox().entries().size)
        // Redelivery is a duplicate whose receipt says linked, not executed.
        val again = restarted.admit(AdmissionSpec.request()) as AdmissionResult.Duplicate
        assertEquals(AdmissionStage.LINKED, again.receipt.stage)
        // Same request id with other words is a conflict, even though the text is gone.
        assertEquals("conflict", restarted.admit(AdmissionSpec.request(text = "现在几点了")).name())
        assertEquals(before, sandbox.snapshot())
        assertEquals(receipt.admissionId, restarted.recordForDownstreamId(downstream)?.admissionId)

        // The outbox delivering the message is not completion; expiry does not touch it either.
        clock.now = AdmissionSpec.T0 + 2 * AdmissionSpec.DAY
        assertEquals(AdmissionStage.LINKED, reopened().record(receipt.admissionId)?.stage)

        // A kill inside the settling write leaves it linked; the report is applied again.
        val files = KillingFileStore().apply { killWrite(DurableWriteStep.TEMP_SYNCED) }
        kill { reopened(files).complete(receipt.admissionId) }
        assertEquals(AdmissionStage.LINKED, reopened().record(receipt.admissionId)?.stage)
        val completed = reopened().complete(receipt.admissionId)
        assertEquals(AdmissionStage.COMPLETED, completed.stage)
        assertEquals(clock.now, completed.settledAtMs)
        assertEquals(linked.linkedAtMs, completed.linkedAtMs)
    }

    @Test
    fun `boundary 4 - a linked record with no terminal report becomes unknown after 14 days and is kept`() {
        val receipt = admitted()
        reopened().runDispatchPass(dispatcher())
        clock.now = AdmissionSpec.T0 + AdmissionPolicy.LINKED_TIMEOUT_MS - 1
        assertEquals(AdmissionStage.LINKED, reopened().record(receipt.admissionId)?.stage)
        clock.now += 1
        val restarted = reopened()
        assertEquals(listOf(receipt.admissionId), restarted.openSweep.unknown)
        val unknown = restarted.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.UNKNOWN, unknown.stage)
        assertEquals(clock.now, unknown.settledAtMs)
        // No edge leaves a terminal stage.
        try {
            restarted.complete(receipt.admissionId)
            fail("a terminal record moved")
        } catch (_: AdmissionException.IllegalTransition) {
            assertEquals(AdmissionStage.UNKNOWN, reopened().record(receipt.admissionId)?.stage)
        }
    }

    // -------------------------------------- boundary 5: terminal, not cleaned

    @Test
    fun `boundary 5 - a terminal record is the dedupe tombstone until sweep deletes it`() {
        val receipt = admitted()
        reopened().runDispatchPass(dispatcher())
        clock.now = AdmissionSpec.T0 + 9_800
        reopened().complete(receipt.admissionId)

        // Restart while the tombstone is due to stay: redelivery is a duplicate, never a second run.
        clock.now = AdmissionSpec.T0 + AdmissionSpec.DAY - 1
        var restarted = reopened()
        assertEquals(AdmissionSweepReport(), restarted.openSweep)
        val again = restarted.admit(AdmissionSpec.request(expiresAtMs = clock.now + 60_000)) as AdmissionResult.Duplicate
        assertEquals(AdmissionReceipt(receipt.admissionId, downstream, AdmissionStage.COMPLETED), again.receipt)
        assertTrue(restarted.dispatchable().isEmpty())
        assertEquals(1, outbox().entries().size)

        // expiresAtMs has passed but 24 h after settling has not: still kept.
        clock.now = AdmissionSpec.T0 + 9_800 + AdmissionPolicy.TOMBSTONE_MS - 1
        assertEquals(AdmissionSweepReport(), reopened().openSweep)
        assertTrue(sandbox.file(receipt.admissionId).exists())

        // A kill right after the delete: the file is gone and nothing else was touched.
        clock.now += 1
        val files = KillingFileStore().apply { killAfterDelete() }
        kill { reopened(files) }
        restarted = reopened()
        assertEquals(AdmissionSweepReport(), restarted.openSweep)
        assertNull(restarted.record(receipt.admissionId))
        assertEquals(0, restarted.directoryEntryCount())
        // With the tombstone gone the same request id is a new admission.
        assertEquals("admitted", restarted.admit(AdmissionSpec.request(expiresAtMs = clock.now + 60_000)).name())
    }

    @Test
    fun `boundary 5 - sweep expires an admitted record at open and keeps its tombstone for 24 hours`() {
        val receipt = admitted(AdmissionSpec.request(expiresAtMs = AdmissionSpec.T0 + 60_000))
        clock.now = AdmissionSpec.T0 + 60_000
        val restarted = reopened()
        assertEquals(listOf(receipt.admissionId), restarted.openSweep.expired)
        val expired = restarted.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.EXPIRED, expired.stage)
        assertNull(expired.text)
        assertTrue(restarted.runDispatchPass(dispatcher()).linked.isEmpty())
        assertTrue(outbox().entries().isEmpty())
        clock.now = AdmissionSpec.T0 + 60_000 + AdmissionPolicy.TOMBSTONE_MS - 1
        assertTrue(reopened().openSweep.deleted.isEmpty())
        clock.now += 1
        assertEquals(listOf(receipt.admissionId), reopened().openSweep.deleted)
    }

    // ------------------------------------------------------ undecodable files

    @Test
    fun `a file that is not a v1 record is counted and otherwise left exactly as it is`() {
        val newer = AdmissionSpec.recordIn(AdmissionStage.ADMITTED, requestId = "req-1")
        val newerText = AdmissionCodec.encode(newer).replaceFirst("\"v\":1", "\"v\":2")
        assertTrue(newerText.contains("\"v\":2"))
        sandbox.seedBytes("${newer.admissionId}.json", newerText)
        val future = AdmissionCodec.encode(AdmissionSpec.recordIn(AdmissionStage.ADMITTED, requestId = "future"))
            .replaceFirst("\"stage\":\"admitted\"", "\"stage\":\"paused\"")
        sandbox.seedBytes("${AdmissionPolicy.admissionId("local", AdmissionSpec.VOICE, "future")}.json", future)
        sandbox.seedBytes("${"ab".repeat(32)}.json", "{ this is not json")
        sandbox.seedBytes("${"cd".repeat(32)}.json", "")
        sandbox.seedBytes("notes.txt", "kept")
        // A valid record stored under another record's name is not that record.
        val misplaced = AdmissionSpec.recordIn(AdmissionStage.ADMITTED, requestId = "misplaced")
        sandbox.seedBytes("${"ef".repeat(32)}.json", AdmissionCodec.encode(misplaced))
        File(sandbox.directory, "${"12".repeat(32)}.json").mkdir()
        val before = sandbox.directory.listFiles()!!.filter { it.isFile }.associate { it.name to it.readText() }

        // Far in the future, so every rule that could expire or delete a record would fire.
        clock.now = AdmissionSpec.T0 + 400 * AdmissionSpec.DAY
        val journal = reopened()
        assertEquals(AdmissionSweepReport(), journal.openSweep)
        assertTrue(journal.records().isEmpty())
        assertNull(journal.record(newer.admissionId))
        assertNull(journal.recordForDownstreamId(newer.downstreamId))
        assertEquals(7, journal.directoryEntryCount())
        val delivered = ArrayList<String>()
        val report = journal.runDispatchPass(object : AdmissionDispatcher {
            override fun precheck(record: AdmissionRecord) = AdmissionPrecheck.Proceed

            override fun deliver(record: AdmissionRecord): AdmissionDelivery {
                delivered.add(record.admissionId)
                return AdmissionDelivery.Linked
            }
        })
        assertTrue(delivered.isEmpty())
        assertTrue(report.linked.isEmpty())
        try {
            journal.cancel(newer.admissionId)
            fail("moved a record this build cannot read")
        } catch (_: AdmissionException.UnknownRecord) {
            // Not a record for this build.
        }

        // A request whose admissionId is the unreadable file's name never overwrites it
        // and gets no receipt.
        val result = journal.admit(AdmissionSpec.request(requestId = "req-1", expiresAtMs = clock.now + 60_000))
        assertTrue(result.toString(), result is AdmissionResult.Storage)
        // An unrelated request is still admitted next to them.
        val other = journal.admit(AdmissionSpec.request(requestId = "req-2", expiresAtMs = clock.now + 60_000))
        assertEquals("admitted", other.name())
        assertEquals(8, journal.directoryEntryCount())

        val after = sandbox.directory.listFiles()!!.filter { it.isFile }.associate { it.name to it.readText() }
        assertEquals(before, after - "${(other as AdmissionResult.Admitted).receipt.admissionId}.json")
        assertTrue(File(sandbox.directory, "${"12".repeat(32)}.json").isDirectory)
    }

    @Test
    fun `undecodable files count toward the directory bound and are not deleted to make room`() {
        repeat(AdmissionPolicy.MAX_ENTRIES) { sandbox.seedBytes("unreadable-$it.json", "{\"v\":2}") }
        val before = sandbox.snapshot()
        val journal = reopened()
        assertEquals(AdmissionPolicy.MAX_ENTRIES, journal.directoryEntryCount())
        assertEquals("capacity", journal.admit(AdmissionSpec.request()).name())
        journal.sweep()
        assertEquals(before, sandbox.snapshot())
        File(sandbox.directory, "unreadable-0.json").delete()
        assertEquals("admitted", reopened().admit(AdmissionSpec.request()).name())
    }

    // ------------------------------------------------------------- dispatcher

    @Test
    fun `a bot record stays admitted and untouched behind the interface`() {
        val receipt = admitted(AdmissionSpec.request(target = AdmissionTarget.Bot("bot-7f3a")))
        val before = sandbox.snapshot()
        val journal = reopened()
        repeat(3) {
            val report = journal.runDispatchPass(dispatcher())
            assertEquals(listOf(receipt.admissionId), report.waiting)
            assertTrue(report.linked.isEmpty() && report.retried.isEmpty() && report.failed.isEmpty())
        }
        // Waiting for an owner is not an attempt and changes nothing in the record.
        assertEquals(before, sandbox.snapshot())
        assertEquals(0, journal.record(receipt.admissionId)?.attempts)
        assertTrue(outbox().entries().isEmpty())
        // It still expires like any admitted record.
        clock.now = AdmissionSpec.T0 + AdmissionSpec.DAY
        assertEquals(listOf(receipt.admissionId), journal.runDispatchPass(dispatcher()).sweep.expired)
    }

    @Test
    fun `the target and the account are re-checked immediately before dispatch`() {
        val gone = admitted(AdmissionSpec.request(requestId = "gone", target = AdmissionTarget.DshSession("deleted-chat")))
        val signedOut = admitted(
            AdmissionSpec.request(requestId = "task-1", principal = "account:u_18f3", source = AdmissionSpec.CLOUD, downstreamId = AdmissionSpec.uuid(2)),
        )
        val kept = admitted(
            AdmissionSpec.request(requestId = "task-2", principal = "account:u_18f3", source = AdmissionSpec.CLOUD, downstreamId = AdmissionSpec.uuid(3)),
        )
        val journal = reopened()
        clock.now += 10
        val report = journal.runDispatchPass(dispatcher(account = "someone-else"))
        assertEquals(setOf(gone.admissionId, signedOut.admissionId, kept.admissionId), report.cancelled.toSet())
        assertEquals("target_deleted", journal.record(gone.admissionId)?.reason)
        val cancelled = journal.record(signedOut.admissionId)!!
        assertEquals(AdmissionStage.CANCELLED, cancelled.stage)
        assertEquals("account_signed_out", cancelled.reason)
        assertNull(cancelled.text)
        assertTrue(outbox().entries().isEmpty())

        // Signed in as that account, the same kind of record is handed over.
        sandbox.reset()
        val task = admitted(
            AdmissionSpec.request(requestId = "task-3", principal = "account:u_18f3", source = AdmissionSpec.CLOUD, downstreamId = AdmissionSpec.uuid(4)),
        )
        assertEquals(listOf(task.admissionId), reopened().runDispatchPass(dispatcher(account = "u_18f3")).linked)
        assertEquals(listOf(AdmissionSpec.uuid(4)), outbox().entries().map { it.rpcId })
    }

    @Test
    fun `a definite outbox failure backs off with the same downstreamId and fails after twelve attempts`() {
        val receipt = admitted()
        val broken = object : DurableFileStore() {
            override fun writeAtomically(target: File, bytes: ByteArray): Unit = throw IOException("disk full")
        }
        val journal = reopened()
        val failing = dispatcher(outbox(broken))
        var delay = 3_000L
        for (attempt in 1..AdmissionPolicy.MAX_ATTEMPTS) {
            val report = journal.runDispatchPass(failing)
            assertEquals("attempt $attempt", listOf(receipt.admissionId), report.retried)
            val record = journal.record(receipt.admissionId)!!
            assertEquals(AdmissionStage.ADMITTED, record.stage)
            assertEquals(attempt, record.attempts)
            assertEquals("outbox_storage", record.lastError)
            assertEquals(clock.now + delay, record.nextAttemptAtMs)
            assertEquals(downstream, record.downstreamId)
            assertEquals("现在几点了？", record.text)
            // Before the backoff has passed the pass does not touch it.
            clock.now += delay - 1
            assertTrue(journal.dispatchable().isEmpty())
            val idle = journal.runDispatchPass(failing)
            assertTrue(idle.retried.isEmpty() && idle.failed.isEmpty())
            clock.now += 1
            delay = minOf(delay * 2, 300_000L)
        }
        val last = journal.runDispatchPass(failing)
        assertEquals(listOf(receipt.admissionId), last.failed)
        val failed = journal.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.FAILED, failed.stage)
        assertEquals("retry_exhausted", failed.reason)
        assertEquals(AdmissionPolicy.MAX_ATTEMPTS, failed.attempts)
        assertNull(failed.text)
        assertTrue(outbox().entries().isEmpty())
        // The source redelivering after the failure gets the terminal receipt, not a second run.
        val again = journal.admit(AdmissionSpec.request(expiresAtMs = clock.now + 60_000)) as AdmissionResult.Duplicate
        assertEquals(AdmissionStage.FAILED, again.receipt.stage)
    }

    @Test
    fun `a storage failure whose entry may exist leaves the record dispatching and is linked by the redo`() {
        val receipt = admitted()
        // The entry is renamed into place, then the directory fsync fails.
        val flaky = object : DurableFileStore() {
            var fail = true

            override fun syncDirectory(directory: File) {
                if (fail && directory.name == "send-outbox") throw IOException("fsync failed")
                super.syncDirectory(directory)
            }
        }
        val journal = reopened()
        val report = journal.runDispatchPass(dispatcher(outbox(flaky)))
        assertEquals(listOf(receipt.admissionId), report.unresolved)
        val stuck = journal.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.DISPATCHING, stuck.stage)
        assertEquals(0, stuck.attempts)
        assertEquals(listOf(receipt.admissionId), reopened().runDispatchPass(dispatcher()).linked)
        assertEquals(listOf(downstream), outbox().entries().map { it.rpcId })
    }

    @Test
    fun `a session id the outbox cannot hold is a definite refusal`() {
        val receipt = admitted(AdmissionSpec.request(target = AdmissionTarget.DshSession("chat/with:odd*chars")))
        val journal = reopened()
        val report = journal.runDispatchPass(dispatcher(sessions = setOf("chat/with:odd*chars")))
        assertEquals(listOf(receipt.admissionId), report.failed)
        val failed = journal.record(receipt.admissionId)!!
        assertEquals(AdmissionStage.FAILED, failed.stage)
        assertEquals("target_missing", failed.reason)
        assertTrue(outbox().entries().isEmpty())
    }

    @Test
    fun `dispatch is FIFO into the outbox and each record keeps its own target session`() {
        val journal = reopened()
        val ids = ArrayList<String>()
        for (index in 0 until 20) {
            clock.now = AdmissionSpec.T0 + index
            val result = journal.admit(
                AdmissionSpec.request(
                    requestId = "req-$index",
                    text = "message $index",
                    target = AdmissionTarget.DshSession(if (index % 2 == 0) "even" else "odd"),
                    downstreamId = AdmissionSpec.uuid(100 + index),
                ),
            ) as AdmissionResult.Admitted
            ids.add(result.receipt.admissionId)
        }
        clock.now = AdmissionSpec.T0 + 1_000
        val first = journal.runDispatchPass(dispatcher(sessions = setOf("even", "odd")))
        assertEquals(ids.take(AdmissionPolicy.PASS_LIMIT), first.linked)
        clock.now += 1
        val second = journal.runDispatchPass(dispatcher(sessions = setOf("even", "odd")))
        assertEquals(ids.drop(AdmissionPolicy.PASS_LIMIT), second.linked)
        val even = outbox().pending("even")
        assertEquals((0 until 20 step 2).map { "message $it" }, even.map { it.text })
        assertEquals((0 until 20 step 2).map { AdmissionSpec.uuid(100 + it) }, even.map { it.rpcId })
        assertEquals((1 until 20 step 2).map { "message $it" }, outbox().pending("odd").map { it.text })
    }
}

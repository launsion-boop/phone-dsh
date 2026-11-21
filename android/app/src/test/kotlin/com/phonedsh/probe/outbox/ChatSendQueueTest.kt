// SPDX-License-Identifier: MIT
// The composer's delivery of the durable send outbox
// (spec/host/v1/README.md sections 10 and 10.1): the REAL `ChatSendQueue`, the
// REAL `SendOutbox` and the REAL admission journal over a temporary directory.
// Only the engine and the Worker transport are scripted, because they are the
// external edge; a "new process" is a new queue and a new outbox over the same
// directory, with none of the previous instance's memory.
//
// Host JVM evidence only: no device, no real Worker, no process kill.
package com.phonedsh.probe.outbox

import com.phonedsh.probe.admission.AdmissionRequest
import com.phonedsh.probe.admission.AdmissionResult
import com.phonedsh.probe.admission.AdmissionSource
import com.phonedsh.probe.admission.AdmissionSourceKind
import com.phonedsh.probe.admission.AdmissionStage
import com.phonedsh.probe.admission.AdmissionTarget
import com.phonedsh.probe.admission.ExternalAdmissionJournal
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ChatSendQueueTest {
    private lateinit var root: File
    private var clock = 1_794_700_000_000L
    private val scopes = ArrayList<CoroutineScope>()

    @Before
    fun setUp() {
        root = Files.createTempDirectory("chat-send-queue").toFile()
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        root.deleteRecursively()
    }

    private val ready = ChatDeliveryFacts(
        foreground = true, keepingAlive = false, hostPresent = true, parked = false,
        transitioning = false, busy = false, transportReady = true, requiresRecovery = false,
    )

    /** The scripted engine and Worker. Everything it records is what reached the "transport". */
    private inner class FakeHost : ChatSendHost {
        lateinit var queue: ChatSendQueue
        @Volatile var facts = ready
        @Volatile var active: String? = SESSION
        @Volatile var running = false
        @Volatile var startTurnAllowed = true

        /** How a turn started for an entry behaves once started. */
        @Volatile var turn: suspend (SendOutboxEntry) -> Unit = { entry -> completeTurn(entry) }
        @Volatile var promptFailure: Exception? = null
        @Volatile var startEngineFailure: Exception? = null
        @Volatile var onStartEngine: () -> Unit = { facts = ready }

        val turnsStarted = ArrayList<String>()
        /** Every `session/prompt` that reached the transport: rpcId, in order. */
        val transport = ArrayList<String>()
        val busyPrompts = ArrayList<Pair<String, String>>()
        val readBacks = ArrayList<String>()
        val readBackAnswers = HashMap<String, SendOutboxReadBack>()
        var startEngineCalls = 0
        var resumeEngineCalls = 0
        var published: List<SendOutboxEntry> = emptyList()
        val sessions = HashSet<String>(listOf(SESSION, OTHER))

        suspend fun completeTurn(entry: SendOutboxEntry) {
            queue.transportStarting(entry.rpcId)
            transport.add(entry.rpcId)
            queue.transportAccepted(entry.rpcId)
            queue.onTurnStarted()
            queue.onAuthoritativeUserMessage(entry.rpcId)
            queue.onTurnEnded("completed")
            running = false
            queue.deliveryEnded(entry.rpcId, null)
        }

        override fun deliveryFacts() = facts

        override suspend fun startEngine() {
            startEngineCalls++
            startEngineFailure?.let { throw it }
            onStartEngine()
        }

        override suspend fun resumeEngine() {
            resumeEngineCalls++
            onStartEngine()
        }

        override fun activeSessionId() = active

        override fun turnRunning() = running

        override fun startTurn(entry: SendOutboxEntry): Boolean {
            if (!startTurnAllowed) return false
            turnsStarted.add(entry.rpcId)
            running = true
            scope().launch { turn(entry) }
            return true
        }

        override suspend fun promptRunningTurn(entry: SendOutboxEntry, mode: String) {
            transport.add(entry.rpcId)
            busyPrompts.add(entry.rpcId to mode)
            promptFailure?.let { throw it }
        }

        override suspend fun readBack(entry: SendOutboxEntry): SendOutboxReadBack {
            readBacks.add(entry.rpcId)
            return readBackAnswers[entry.rpcId] ?: SendOutboxReadBack.INCONCLUSIVE
        }

        override fun sessionExists(sessionId: String) = sessionId in sessions

        override fun signedInAccountId(): String? = null

        override fun queueChanged(entries: List<SendOutboxEntry>) {
            published = entries
        }

        override fun log(line: String) = Unit
    }

    private fun scope() = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined).also { scopes.add(it) }

    private fun outbox() = SendOutbox(root, nowMs = { clock })

    private fun journal() = ExternalAdmissionJournal(root, nowMs = { clock })

    /** A new process: a new host, queue, outbox and journal over the same directory. */
    private fun process(configure: FakeHost.() -> Unit = {}): FakeHost {
        val host = FakeHost().apply(configure)
        host.queue = ChatSendQueue(
            outbox = outbox(),
            journal = lazy { journal() },
            host = host,
            scope = scope(),
            io = Dispatchers.Unconfined,
            nowMs = { clock },
            waitPollMillis = 5,
            maxWaitPolls = 400,
        )
        return host
    }

    private fun await(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what" }
            Thread.sleep(5)
        }
    }

    private fun enqueue(host: FakeHost, text: String = "hello", session: String = SESSION, rpcId: String? = null) =
        runBlocking { host.queue.enqueue(session, text, rpcId) }

    // ---------------------------------------------------- enqueue before transport

    @Test
    fun `a send is on disk with its rpcId before any transport attempt`() {
        var onDiskAtTransport: SendOutboxEntry? = null
        val host = process()
        host.turn = { entry ->
            onDiskAtTransport = outbox().entry(entry.rpcId)
            host.completeTurn(entry)
        }
        val entry = enqueue(host)!!
        assertTrue(SendOutboxCodec.isValidRpcId(entry.rpcId))
        assertEquals(listOf(entry.rpcId), host.transport)
        assertEquals(entry.rpcId, onDiskAtTransport?.rpcId)
        assertEquals("hello", onDiskAtTransport?.text)
        assertEquals(SESSION, onDiskAtTransport?.sessionId)
        // The authoritative user message deleted it; nothing is left to send twice.
        await("the entry to be deleted") { outbox().entries().isEmpty() }
    }

    @Test
    fun `a transport that fails or never returns leaves the entry for the next process with the same rpcId`() {
        // 1. The turn dies before the transport is touched: still queued.
        var host = process { turn = { entry -> running = false; queue.deliveryEnded(entry.rpcId, "no_turn_started") } }
        val first = enqueue(host, "one")!!
        assertEquals(SendOutboxState.QUEUED, outbox().entry(first.rpcId)?.state)
        assertTrue(host.transport.isEmpty())

        // 2. The transport call never returns (the process is gone mid-submit).
        host = process { active = OTHER; turn = { entry -> queue.transportStarting(entry.rpcId); transport.add(entry.rpcId) } }
        val second = enqueue(host, "two", OTHER)!!
        assertEquals(listOf(second.rpcId), host.transport)
        assertEquals(SendOutboxState.SUBMITTING, outbox().entry(second.rpcId)?.state)

        // A new process reads both back unchanged: same ids, same text, same sessions.
        val reopened = outbox().entries()
        assertEquals(setOf(first.rpcId, second.rpcId), reopened.map { it.rpcId }.toSet())
        assertEquals("one", outbox().entry(first.rpcId)?.text)
        assertEquals(OTHER, outbox().entry(second.rpcId)?.sessionId)
    }

    @Test
    fun `the queue accepts while the engine is stopped starting or busy and shows the entry as queued`() {
        for (facts in listOf(
            ready.copy(hostPresent = false, transportReady = false, foreground = false),
            ready.copy(transitioning = true, transportReady = false),
            ready.copy(busy = true),
            ready.copy(requiresRecovery = true),
        )) {
            root.deleteRecursively()
            val host = process { this.facts = facts }
            val entry = enqueue(host)
            assertNotNull("$facts", entry)
            await("the queue to settle") { host.published.map { it.rpcId } == listOf(entry!!.rpcId) }
            assertEquals(SendOutboxState.QUEUED, outbox().entry(entry!!.rpcId)?.state)
            assertTrue(host.transport.isEmpty())
        }
    }

    // --------------------------------------------------------- five kill points

    @Test
    fun `kill point 1 - nothing written means nothing is sent by the next process`() {
        val host = process()
        host.queue.startup()
        host.queue.requestDelivery()
        assertTrue(host.transport.isEmpty())
        assertTrue(host.turnsStarted.isEmpty())
    }

    @Test
    fun `kill point 2 - written but not submitted is sent once by the next process with the same rpcId`() {
        val entry = outbox().enqueue(SESSION, "queued by the previous process")
        val host = process()
        host.queue.startup()
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals(listOf(entry.rpcId), host.transport)
        // More triggers do not send it again.
        host.queue.onForeground()
        host.queue.requestDelivery()
        assertEquals(listOf(entry.rpcId), host.transport)
    }

    @Test
    fun `kill point 3 - mid-submit is never resent on its own and is settled by the read-back`() {
        // Found in history: accepted, durable, deleted, never sent again.
        var entry = outbox().enqueue(SESSION, "maybe sent")
        outbox().markSubmitting(entry.rpcId)
        var host = process { readBackAnswers[entry.rpcId] = SendOutboxReadBack.JOURNALED }
        host.queue.startup()
        await("the journaled entry to be deleted") { outbox().entries().isEmpty() }
        assertTrue(host.transport.isEmpty())
        assertEquals(listOf(entry.rpcId), host.readBacks)

        // Held in the engine's inbox: accepted, not resent.
        entry = outbox().enqueue(SESSION, "held")
        outbox().markSubmitting(entry.rpcId)
        host = process { readBackAnswers[entry.rpcId] = SendOutboxReadBack.HELD }
        host.queue.startup()
        await("held to be accepted") { outbox().entry(entry.rpcId)?.state == SendOutboxState.ACCEPTED }
        assertTrue(host.transport.isEmpty())
        outbox().observeAuthoritativeUserMessage(entry.rpcId)

        // No proof: it stays unknown through any number of triggers and a user retry.
        entry = outbox().enqueue(SESSION, "unknown")
        outbox().markSubmitting(entry.rpcId)
        host = process()
        host.queue.startup()
        await("the unknown state") { outbox().entry(entry.rpcId)?.state == SendOutboxState.OUTCOME_UNKNOWN }
        host.queue.onForeground()
        host.queue.requestDelivery()
        assertEquals(entry.rpcId, enqueue(host, "unknown", rpcId = entry.rpcId)?.rpcId)
        clock += 3_600_000
        host.queue.requestDelivery()
        assertTrue("an unknown outcome is never resent without proof", host.transport.isEmpty())
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, outbox().entry(entry.rpcId)?.state)
        assertEquals(1, outbox().entry(entry.rpcId)?.attempts)
    }

    @Test
    fun `kill point 4 - accepted before durable is not resent and is deleted by history`() {
        val entry = outbox().enqueue(SESSION, "accepted")
        outbox().markSubmitting(entry.rpcId)
        outbox().markAccepted(entry.rpcId)
        var host = process()
        host.queue.startup()
        assertTrue(host.transport.isEmpty())
        assertEquals(SendOutboxState.ACCEPTED, outbox().entry(entry.rpcId)?.state)

        host = process { readBackAnswers[entry.rpcId] = SendOutboxReadBack.JOURNALED }
        host.queue.startup()
        await("deletion") { outbox().entries().isEmpty() }
        assertTrue(host.transport.isEmpty())
    }

    @Test
    fun `kill point 5 - durable before delete is removed by the next process and never sent`() {
        val entry = outbox().enqueue(SESSION, "durable")
        outbox().markSubmitting(entry.rpcId)
        outbox().markAccepted(entry.rpcId)
        outbox().markDurable(entry.rpcId)
        val host = process()
        host.queue.startup()
        await("deletion") { outbox().entries().isEmpty() }
        assertTrue(host.transport.isEmpty())
        assertTrue(host.readBacks.isEmpty())
    }

    @Test
    fun `startup collects orphan attachment directories and keeps referenced ones`() {
        val orphan = File(File(root, "send-outbox/attachments/9d8c7b6a-5f4e-4d3c-8b2a-190817161514"), "a")
        orphan.parentFile!!.mkdirs()
        orphan.writeText("orphan")
        val host = process { facts = ready.copy(foreground = false) }
        host.queue.startup()
        await("orphan GC") { !orphan.parentFile!!.exists() }
    }

    // ----------------------------------------------------------- unknown outcome

    @Test
    fun `read-back absent resends once with the same rpcId only after the settle delay`() {
        val host = process()
        var failOnce = true
        host.turn = { entry ->
            host.queue.transportStarting(entry.rpcId)
            host.transport.add(entry.rpcId)
            if (failOnce) {
                failOnce = false
                host.running = false
                host.queue.deliveryEnded(entry.rpcId, "transport closed after the request was written")
            } else {
                host.queue.transportAccepted(entry.rpcId)
                host.queue.onAuthoritativeUserMessage(entry.rpcId)
                host.running = false
                host.queue.deliveryEnded(entry.rpcId, null)
            }
        }
        val entry = runBlocking {
            // Proof of absence is available from the first read-back on.
            val created = outbox().enqueue(SESSION, "again")
            host.readBackAnswers[created.rpcId] = SendOutboxReadBack.ABSENT
            host.queue.requestDelivery()
            created
        }
        await("the unknown state") { outbox().entry(entry.rpcId)?.state == SendOutboxState.OUTCOME_UNKNOWN }
        // Inside the settle window absence proves nothing yet.
        clock += SendOutboxReadBack.settleDelayMs(1) - 1
        host.queue.requestDelivery()
        assertEquals(listOf(entry.rpcId), host.transport)
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, outbox().entry(entry.rpcId)?.state)
        // A user retry does not replace the proof either.
        assertEquals(entry.rpcId, enqueue(host, "again", rpcId = entry.rpcId)?.rpcId)
        assertEquals(listOf(entry.rpcId), host.transport)

        clock += 1
        host.queue.requestDelivery()
        await("the resend") { outbox().entries().isEmpty() }
        assertEquals("one resend, with the same rpcId", listOf(entry.rpcId, entry.rpcId), host.transport)
        host.queue.requestDelivery()
        assertEquals(2, host.transport.size)
    }

    @Test
    fun `a retry of an existing row never writes a second entry and must match its session and text`() {
        val host = process { facts = ready.copy(foreground = false) }
        val entry = enqueue(host, "same")!!
        assertEquals(entry, enqueue(host, "same", rpcId = entry.rpcId))
        assertNull(enqueue(host, "different", rpcId = entry.rpcId))
        assertNull(enqueue(host, "same", OTHER, rpcId = entry.rpcId))
        assertEquals(listOf(entry.rpcId), outbox().entries().map { it.rpcId })
        assertNull("an invalid session is not accepted", enqueue(host, "x", "bad session id"))
    }

    // ------------------------------------------------------------- preparation

    @Test
    fun `without eligibility nothing boots the engine and a foreground return delivers`() {
        val host = process { facts = ready.copy(foreground = false, hostPresent = false, transportReady = false) }
        val entry = enqueue(host)!!
        host.queue.requestDelivery()
        host.queue.onAdmission()
        assertEquals(0, host.startEngineCalls)
        assertTrue(host.transport.isEmpty())
        assertEquals(SendOutboxState.QUEUED, outbox().entry(entry.rpcId)?.state)

        // Foreground return: the retained work starts the engine once and is delivered.
        host.facts = host.facts.copy(foreground = true)
        host.queue.onForeground()
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals(1, host.startEngineCalls)
        assertEquals(listOf(entry.rpcId), host.transport)
    }

    @Test
    fun `a held turn window is eligibility in the background`() {
        val host = process { facts = ready.copy(foreground = false, keepingAlive = true, hostPresent = false, transportReady = false) }
        val entry = enqueue(host)!!
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals(1, host.startEngineCalls)
        assertEquals(listOf(entry.rpcId), host.transport)
    }

    @Test
    fun `an explicit stop pauses queued preparation until the engine is started again`() {
        val host = process { facts = ready.copy(hostPresent = false, transportReady = false) }
        host.queue.pause()
        assertTrue(host.queue.isPaused)
        // Entries written while paused by another path (an admission, a previous process).
        val entry = outbox().enqueue(SESSION, "kept")
        host.queue.requestDelivery()
        host.queue.onForeground()
        host.queue.onAdmission()
        assertEquals(0, host.startEngineCalls)
        assertTrue(host.transport.isEmpty())

        host.queue.unpause()
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals(1, host.startEngineCalls)
        assertEquals(listOf(entry.rpcId), host.transport)
    }

    @Test
    fun `a stop during a boot that queued work started never drains afterwards`() {
        val host = process { facts = ready.copy(hostPresent = false, transportReady = false) }
        host.onStartEngine = {
            host.queue.pause()
            host.facts = ready
        }
        val entry = outbox().enqueue(SESSION, "kept")
        host.queue.requestDelivery()
        assertEquals(1, host.startEngineCalls)
        assertTrue(host.transport.isEmpty())
        assertEquals(SendOutboxState.QUEUED, outbox().entry(entry.rpcId)?.state)
    }

    @Test
    fun `manual recovery and a failed boot keep the entries and boot at most once per request`() {
        var host = process { facts = ready.copy(requiresRecovery = true, hostPresent = false) }
        val entry = enqueue(host)!!
        assertEquals(0, host.startEngineCalls)

        host = process {
            facts = ready.copy(hostPresent = false, transportReady = false)
            startEngineFailure = IllegalStateException("boot failed")
        }
        host.queue.requestDelivery()
        assertEquals(1, host.startEngineCalls)
        assertTrue(host.transport.isEmpty())
        assertEquals(SendOutboxState.QUEUED, outbox().entry(entry.rpcId)?.state)
    }

    @Test
    fun `a parked engine is resumed and a transition is waited out by the one job`() {
        var host = process { facts = ready.copy(parked = true, transportReady = false) }
        var entry = enqueue(host)!!
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals(1, host.resumeEngineCalls)
        assertEquals(0, host.startEngineCalls)
        assertEquals(listOf(entry.rpcId), host.transport)

        host = process { facts = ready.copy(transitioning = true, transportReady = false) }
        entry = enqueue(host)!!
        // Requests made while the job waits are joined into it.
        repeat(5) { host.queue.requestDelivery() }
        assertTrue(host.transport.isEmpty())
        host.facts = ready
        await("delivery after the transition") { outbox().entries().isEmpty() }
        assertEquals(listOf(entry.rpcId), host.transport)
        assertEquals(0, host.startEngineCalls)
    }

    // ------------------------------------------------------------------- order

    @Test
    fun `a session is delivered in FIFO order and another session never blocks it`() {
        val host = process { facts = ready.copy(foreground = false) }
        clock = 1_000
        val foreign = enqueue(host, "for another conversation", OTHER)!!
        clock = 2_000
        val first = enqueue(host, "first")!!
        clock = 3_000
        val second = enqueue(host, "second")!!
        host.facts = ready
        host.queue.onForeground()
        await("both deliveries") { outbox().entries().map { it.rpcId } == listOf(foreign.rpcId) }
        assertEquals(listOf(first.rpcId, second.rpcId), host.transport)
        // The other conversation's entry waits, untouched, until it is the active one.
        assertEquals(SendOutboxState.QUEUED, outbox().entry(foreign.rpcId)?.state)
        assertEquals(0, outbox().entry(foreign.rpcId)?.attempts)
        host.active = OTHER
        host.queue.requestDelivery()
        await("the other session") { outbox().entries().isEmpty() }
        assertEquals(listOf(first.rpcId, second.rpcId, foreign.rpcId), host.transport)
    }

    @Test
    fun `sends queued behind a running turn follow into it and an unknown one holds the rest`() {
        val host = process { running = true }
        val first = enqueue(host, "into the running turn")!!
        assertEquals(listOf(first.rpcId to "queue"), host.busyPrompts)
        assertEquals(SendOutboxState.ACCEPTED, outbox().entry(first.rpcId)?.state)
        assertTrue(host.turnsStarted.isEmpty())

        host.promptFailure = IllegalStateException("connection reset")
        clock += 10
        val second = enqueue(host, "lost response")!!
        clock += 10
        val third = enqueue(host, "behind the unknown one")!!
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, outbox().entry(second.rpcId)?.state)
        assertEquals("connection reset", outbox().entry(second.rpcId)?.lastError)
        // FIFO: the entry behind an unsettled one is not sent ahead of it.
        assertEquals(SendOutboxState.QUEUED, outbox().entry(third.rpcId)?.state)
        assertEquals(listOf(first.rpcId, second.rpcId), host.transport)
    }

    @Test
    fun `a mid-turn submission is admitted durably before its transport call and never re-sent while unknown`() {
        val host = process { running = true }
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        runBlocking {
            assertEquals(ChatPromptAdmission.SEND, host.queue.admitRunningPrompt(SESSION, "steer this", rpcId, "steer"))
            val onDisk = outbox().entry(rpcId)!!
            assertEquals(SendOutboxState.SUBMITTING, onDisk.state)
            assertEquals("steer this", onDisk.text)
            // The queue's own drain does not send what the composer is sending.
            host.queue.requestDelivery()
            assertTrue(host.transport.isEmpty())

            host.queue.transportUnknown(rpcId, "response lost")
            assertEquals(SendOutboxState.OUTCOME_UNKNOWN, outbox().entry(rpcId)?.state)
            assertEquals(ChatPromptAdmission.HELD, host.queue.admitRunningPrompt(SESSION, "steer this", rpcId, "steer"))
            assertEquals(ChatPromptAdmission.REFUSED, host.queue.admitRunningPrompt(SESSION, "other text", rpcId, "steer"))
            assertTrue(host.transport.isEmpty())

            val accepted = "9d8c7b6a-5f4e-4d3c-8b2a-190817161514"
            assertEquals(ChatPromptAdmission.SEND, host.queue.admitRunningPrompt(SESSION, "ok", accepted, "queue"))
            host.queue.runningPromptAccepted(accepted)
            assertEquals(SendOutboxState.ACCEPTED, outbox().entry(accepted)?.state)
            assertEquals(ChatPromptAdmission.REFUSED, host.queue.admitRunningPrompt("bad session id", "x", "not-a-uuid", "queue"))
        }
    }

    @Test
    fun `eligibility lost during the submitting write puts the unsent entry back with its rpcId`() {
        val host = process { running = true }
        val entry = outbox().enqueue(SESSION, "defer")
        // The turn ends between the durable write and the transport call.
        var reads = 0
        val flipping = object : ChatSendHost by host {
            override fun turnRunning(): Boolean = reads++ < 1
        }
        val queue = ChatSendQueue(outbox(), lazy { null }, flipping, scope(), Dispatchers.Unconfined, { clock }, 5, 40)
        queue.requestDelivery()
        assertTrue(host.transport.isEmpty())
        val saved = outbox().entry(entry.rpcId)!!
        assertEquals(SendOutboxState.QUEUED, saved.state)
        assertEquals(1, saved.attempts)
        assertEquals(entry.rpcId, saved.rpcId)
    }

    @Test
    fun `a session-not-found retry inside one live delivery reuses the rpcId through the legal edges`() {
        val host = process()
        host.turn = { entry ->
            host.queue.transportStarting(entry.rpcId)
            // The Worker refused the stored session; the runner opens a new one and prompts again.
            host.queue.transportStarting(entry.rpcId)
            host.transport.add(entry.rpcId)
            host.queue.transportAccepted(entry.rpcId)
            host.running = false
            host.queue.deliveryEnded(entry.rpcId, null)
        }
        val entry = enqueue(host)!!
        await("acceptance") { outbox().entry(entry.rpcId)?.state == SendOutboxState.ACCEPTED }
        val saved = outbox().entry(entry.rpcId)!!
        assertEquals(2, saved.attempts)
        assertEquals(listOf(entry.rpcId), host.transport)
    }

    // --------------------------------------------------------------- admissions

    private fun request(id: String, session: String = SESSION) = AdmissionRequest(
        principal = "local",
        source = AdmissionSource(AdmissionSourceKind.CLOUD_TASK, "dev-1"),
        sourceRequestId = id,
        target = AdmissionTarget.DshSession(session),
        text = "run the tests",
        expiresAtMs = clock + 3_600_000,
    )

    @Test
    fun `an admission is dispatched into the outbox on the same trigger and settled by the turn's terminal event`() {
        val host = process()
        val receipt = (journal().admit(request("task-1")) as AdmissionResult.Admitted).receipt
        host.queue.onAdmission()
        await("delivery") { outbox().entries().isEmpty() }
        assertEquals("the outbox rpcId is the admission's downstreamId", listOf(receipt.downstreamId), host.transport)
        await("completion") { journal().record(receipt.admissionId)?.stage == AdmissionStage.COMPLETED }
        assertNull(journal().record(receipt.admissionId)?.text)

        // A turn that does not end normally settles the record as failed.
        host.turn = { entry ->
            host.queue.transportStarting(entry.rpcId)
            host.transport.add(entry.rpcId)
            host.queue.transportAccepted(entry.rpcId)
            host.queue.onTurnStarted()
            host.queue.onAuthoritativeUserMessage(entry.rpcId)
            host.queue.onTurnEnded("error")
            host.running = false
            host.queue.deliveryEnded(entry.rpcId, null)
        }
        val failed = (journal().admit(request("task-2")) as AdmissionResult.Admitted).receipt
        host.queue.onAdmission()
        await("failure") { journal().record(failed.admissionId)?.stage == AdmissionStage.FAILED }
        assertEquals("turn_not_completed", journal().record(failed.admissionId)?.reason)
    }

    @Test
    fun `an admission is linked with no engine and executed only once eligible and never reported as executed before`() {
        val host = process { facts = ready.copy(foreground = false, hostPresent = false, transportReady = false) }
        val receipt = (journal().admit(request("task-3")) as AdmissionResult.Admitted).receipt
        host.queue.startup()
        await("linking") { journal().record(receipt.admissionId)?.stage == AdmissionStage.LINKED }
        assertEquals(0, host.startEngineCalls)
        assertEquals(SendOutboxState.QUEUED, outbox().entry(receipt.downstreamId)?.state)
        // A turn ending without this admission's user message settles nothing.
        host.queue.onTurnStarted()
        host.queue.onTurnEnded("completed")
        assertEquals(AdmissionStage.LINKED, journal().record(receipt.admissionId)?.stage)

        // A new process in the foreground executes it once, under the same id.
        val next = process { facts = ready.copy(hostPresent = false, transportReady = false) }
        next.queue.startup()
        await("completion") { journal().record(receipt.admissionId)?.stage == AdmissionStage.COMPLETED }
        assertEquals(listOf(receipt.downstreamId), next.transport)
        assertFalse(next.queue.isPaused)
    }

    @Test
    fun `an admission for a conversation that no longer exists is cancelled and never reaches the outbox`() {
        val host = process()
        val receipt = (journal().admit(request("task-4", "deleted-session")) as AdmissionResult.Admitted).receipt
        host.queue.onAdmission()
        await("cancellation") { journal().record(receipt.admissionId)?.stage == AdmissionStage.CANCELLED }
        assertTrue(outbox().entries().isEmpty())
        assertTrue(host.transport.isEmpty())
    }

    private companion object {
        const val SESSION = "worker-session-1"
        const val OTHER = "worker-session-2"
    }
}

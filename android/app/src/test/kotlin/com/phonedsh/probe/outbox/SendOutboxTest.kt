// SPDX-License-Identifier: MIT
// Behaviour of the real durable send outbox (spec/host/v1/README.md section 10):
// enqueue-as-durable-fact, per-session FIFO, the attachment store and its
// lifecycle, startup GC, and the five kill points. Port of
// `examples/probe-app/PhoneDSHSimTests/SendOutboxTests.swift`, with the kills
// injected into the real atomic write instead of only reopening between calls.
//
// Host JVM evidence only: no device, no power loss.
package com.phonedsh.probe.outbox

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class SendOutboxTest {
    private lateinit var root: File
    private var clock = 1_794_400_000_000L

    @Before
    fun setUp() {
        root = Files.createTempDirectory("send-outbox").toFile()
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    /** A new instance over the same directory: what a restarted process has. */
    private fun reopened(files: DurableFileStore = DurableFileStore()) = SendOutbox(root, nowMs = { clock }, files = files)

    private val directory get() = File(root, "send-outbox")

    private fun entryFile(rpcId: String) = File(directory, "$rpcId.json")

    private fun image(id: String? = "att-1", bytes: ByteArray = "image-bytes".toByteArray()) =
        SendOutboxAttachmentInput(id, SendOutboxAttachmentKind.IMAGE, "image/png", "photo.png", bytes)

    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try {
            block()
        } catch (thrown: Throwable) {
            if (thrown is T) return thrown
            throw thrown
        }
        fail("expected ${T::class.simpleName}")
        throw IllegalStateException()
    }

    // ------------------------------------------------------------------ enqueue

    @Test
    fun `enqueue mints a lowercase UUIDv4 and the entry survives a restart unchanged`() {
        val entry = reopened().enqueue("gb-main", "hello")
        assertTrue(SendOutboxCodec.isValidRpcId(entry.rpcId))
        assertEquals(SendOutboxState.QUEUED, entry.state)
        assertEquals(0, entry.attempts)
        assertEquals(SendOutboxBackend.LOCAL, entry.backend)
        assertEquals(clock, entry.createdAtMs)
        assertTrue(entryFile(entry.rpcId).isFile)
        assertEquals(entry, reopened().entry(entry.rpcId))
        // No temporary file is left behind by a completed write.
        assertEquals(listOf("${entry.rpcId}.json"), directory.list()!!.toList())
    }

    @Test
    fun `the queue never refuses for engine state and rejects only an invalid entry`() {
        val store = reopened()
        expect<SendOutboxException.InvalidSessionId> { store.enqueue("bad id", "x") }
        expect<SendOutboxException.EmptyText> { store.enqueue("gb-main", "") }
        expect<SendOutboxException.InvalidRpcId> { store.enqueue("gb-main", "x", rpcId = "not-a-uuid") }
        expect<SendOutboxException.InvalidRpcId> {
            store.enqueue("gb-main", "x", rpcId = "3F2A1C4E-5B6D-4E8F-9A0B-1C2D3E4F5A6B")
        }
        expect<SendOutboxException.InvalidRpcId> {
            store.enqueue("gb-main", "x", rpcId = "3f2a1c4e-5b6d-3e8f-9a0b-1c2d3e4f5a6b")
        }
        expect<SendOutboxException.TextTooLong> { store.enqueue("gb-main", "x".repeat(1_000_001)) }
        assertFalse(directory.exists())
        // The bound counts characters, so a million two-unit characters still fit.
        assertEquals(2_000_000, store.enqueue("gb-main", "😀".repeat(1_000_000)).text.length)
    }

    @Test
    fun `a caller-owned rpcId is used once and never overwrites its entry`() {
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        val store = reopened()
        assertEquals(rpcId, store.enqueue("gb-main", "first", rpcId = rpcId).rpcId)
        store.markSubmitting(rpcId)
        val refused = expect<SendOutboxException.AlreadyExists> { store.enqueue("gb-main", "second", rpcId = rpcId) }
        assertEquals(rpcId, refused.rpcId)
        assertEquals("first", store.entry(rpcId)?.text)
        assertEquals(SendOutboxState.SUBMITTING, store.entry(rpcId)?.state)
    }

    @Test
    fun `each session is FIFO by createdAtMs and sessions are independent`() {
        val store = reopened()
        clock = 1_000
        val first = store.enqueue("a", "1")
        clock = 2_000
        val second = store.enqueue("a", "2")
        clock = 1_500
        val other = store.enqueue("b", "3")
        assertEquals(listOf(first.rpcId, second.rpcId), reopened().pending("a").map { it.rpcId })
        assertEquals(listOf(other.rpcId), reopened().pending("b").map { it.rpcId })
        assertEquals(listOf(first.rpcId, other.rpcId, second.rpcId), reopened().pending().map { it.rpcId })
        // A later state does not change the position in its session.
        store.markSubmitting(first.rpcId)
        store.markOutcomeUnknown(first.rpcId, "cut")
        assertEquals(listOf(first.rpcId, second.rpcId), reopened().pending("a").map { it.rpcId })
    }

    // -------------------------------------------------------------- state machine

    @Test
    fun `outcomeUnknown never resends and requeues only through the read-back edge`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "maybe")
        store.markSubmitting(entry.rpcId)
        clock += 500
        val unknown = store.markOutcomeUnknown(entry.rpcId, "transport closed after write")
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, unknown.state)
        assertEquals("transport closed after write", unknown.lastError)
        assertEquals(clock, unknown.outcomeUnknownAtMs)
        val refused = expect<SendOutboxException.IllegalTransition> { store.markSubmitting(entry.rpcId) }
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, refused.from)
        expect<SendOutboxException.DeleteRequiresDurable> { store.deleteIfDurable(entry.rpcId) }

        // Read-back found it.
        assertTrue(store.observeAuthoritativeUserMessage(entry.rpcId))
        assertNull(store.entry(entry.rpcId))

        // Read-back proved it absent: the same rpcId goes back to queued.
        val second = store.enqueue("gb-main", "again")
        store.markSubmitting(second.rpcId)
        store.markOutcomeUnknown(second.rpcId, "cut")
        val requeued = store.requeue(second.rpcId)
        assertEquals(second.rpcId, requeued.rpcId)
        assertEquals(SendOutboxState.QUEUED, requeued.state)
        assertNull(requeued.lastError)
        assertNull(requeued.outcomeUnknownAtMs)
        assertEquals(2, store.markSubmitting(second.rpcId).attempts)
    }

    @Test
    fun `a local acknowledgement deletes nothing and only durable is deleted`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "x")
        expect<SendOutboxException.IllegalTransition> { store.markDurable(entry.rpcId) }
        assertEquals(SendOutboxState.QUEUED, expect<SendOutboxException.DeleteRequiresDurable> {
            store.deleteIfDurable(entry.rpcId)
        }.state)
        // History cannot hold a message this store never submitted.
        assertFalse(store.observeAuthoritativeUserMessage(entry.rpcId))
        assertEquals(SendOutboxState.QUEUED, store.entry(entry.rpcId)?.state)

        store.markSubmitting(entry.rpcId)
        val accepted = store.markAccepted(entry.rpcId)
        assertEquals(clock, accepted.acceptedAtMs)
        // The live event and the acknowledgement may both report it.
        assertEquals(accepted, store.markAccepted(entry.rpcId))
        expect<SendOutboxException.DeleteRequiresDurable> { store.deleteIfDurable(entry.rpcId) }
        assertTrue(entryFile(entry.rpcId).exists())
        assertTrue(store.observeAuthoritativeUserMessage(entry.rpcId))
        assertFalse(entryFile(entry.rpcId).exists())
        assertFalse(store.observeAuthoritativeUserMessage(entry.rpcId))
        expect<SendOutboxException.UnknownEntry> { store.markSubmitting(entry.rpcId) }
    }

    // --------------------------------------------------------------- kill points

    @Test
    fun `kill point 1 - before the entry file is committed nothing was accepted`() {
        for (step in listOf(DurableWriteStep.BEFORE_TEMP, DurableWriteStep.TEMP_SYNCED)) {
            root.deleteRecursively()
            val files = KillingFileStore()
            files.killWrite(step) { it.name.endsWith(".json") }
            val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
            expect<SimulatedKill> { reopened(files).enqueue("gb-main", "look", listOf(image()), rpcId = rpcId) }

            val restarted = reopened()
            assertTrue("$step", restarted.entries().isEmpty())
            assertNull(restarted.entry(rpcId))
            assertFalse(entryFile(rpcId).exists())
            // The attachment bytes were written first; with no entry they are an orphan.
            assertTrue(File(restarted.attachmentDirectory(rpcId), "att-1").isFile)
            assertEquals(listOf(rpcId), restarted.collectOrphanAttachments())
            assertFalse(restarted.attachmentDirectory(rpcId).exists())
            // The user sends again: one entry, and a half-written temporary file is never read as one.
            val again = restarted.enqueue("gb-main", "look", listOf(image()))
            assertEquals(listOf(again.rpcId), reopened().entries().map { it.rpcId })
        }
    }

    @Test
    fun `kill point 1 - a kill while the attachment bytes are written leaves only an orphan`() {
        val files = KillingFileStore()
        files.killWrite(DurableWriteStep.TEMP_SYNCED) { it.name == "att-2" }
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        expect<SimulatedKill> {
            reopened(files).enqueue("gb-main", "", listOf(image("att-1"), image("att-2")), rpcId = rpcId)
        }
        val restarted = reopened()
        assertTrue(restarted.entries().isEmpty())
        assertEquals(listOf(rpcId), restarted.collectOrphanAttachments())
    }

    @Test
    fun `kill point 2 - written but not submitted is resumed as queued with the same rpcId`() {
        val files = KillingFileStore()
        // The rename happened; the kill lands before the caller could submit.
        files.killWrite(DurableWriteStep.RENAMED) { it.name.endsWith(".json") }
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        val bytes = "crash-image".toByteArray()
        expect<SimulatedKill> { reopened(files).enqueue("gb-main", "one", listOf(image(bytes = bytes)), rpcId = rpcId) }

        val restarted = reopened()
        val entry = restarted.pending().single()
        assertEquals(rpcId, entry.rpcId)
        assertEquals(SendOutboxState.QUEUED, entry.state)
        assertEquals(0, entry.attempts)
        assertArrayEquals(bytes, restarted.verifiedAttachmentData(rpcId).single().data)
        assertTrue(restarted.collectOrphanAttachments().isEmpty())
        assertEquals(1, restarted.markSubmitting(rpcId).attempts)
    }

    @Test
    fun `kill point 3 - mid-submit is never resent on its own and is settled by the read-back`() {
        for (found in listOf(true, false)) {
            root.deleteRecursively()
            val store = reopened()
            val entry = store.enqueue("gb-main", "one", listOf(image()))
            store.markSubmitting(entry.rpcId)

            val restarted = reopened()
            val replay = restarted.entry(entry.rpcId)!!
            assertEquals(SendOutboxState.SUBMITTING, replay.state)
            assertEquals(1, replay.attempts)
            // There is no submitting → submitting and no submitting → queued edge.
            expect<SendOutboxException.IllegalTransition> { restarted.markSubmitting(entry.rpcId) }
            expect<SendOutboxException.IllegalTransition> { restarted.requeue(entry.rpcId) }
            restarted.markOutcomeUnknown(entry.rpcId, "process ended during submit")
            if (found) {
                assertTrue(restarted.observeAuthoritativeUserMessage(entry.rpcId))
                assertTrue(reopened().entries().isEmpty())
                assertFalse(restarted.attachmentDirectory(entry.rpcId).exists())
            } else {
                assertEquals(entry.rpcId, restarted.requeue(entry.rpcId).rpcId)
                assertEquals(2, reopened().markSubmitting(entry.rpcId).attempts)
                assertEquals(listOf(entry.rpcId), reopened().entries().map { it.rpcId })
            }
        }
    }

    @Test
    fun `kill point 3 - a kill inside the submitting write leaves a whole entry in one of the two states`() {
        for (step in listOf(DurableWriteStep.TEMP_SYNCED, DurableWriteStep.RENAMED)) {
            root.deleteRecursively()
            val entry = reopened().enqueue("gb-main", "one")
            val files = KillingFileStore()
            files.killWrite(step)
            expect<SimulatedKill> { reopened(files).markSubmitting(entry.rpcId) }
            val replay = reopened().entry(entry.rpcId)!!
            val expected = if (step == DurableWriteStep.TEMP_SYNCED) SendOutboxState.QUEUED else SendOutboxState.SUBMITTING
            assertEquals("$step", expected, replay.state)
            assertEquals(entry.rpcId, replay.rpcId)
            assertEquals("one", replay.text)
        }
    }

    @Test
    fun `kill point 4 - accepted before durable replays the same rpcId and is deleted by history`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "one", listOf(image()))
        store.markSubmitting(entry.rpcId)
        store.markAccepted(entry.rpcId)

        val restarted = reopened()
        val replay = restarted.entry(entry.rpcId)!!
        assertEquals(SendOutboxState.ACCEPTED, replay.state)
        assertEquals(listOf(entry.rpcId), restarted.pending().map { it.rpcId })
        assertTrue(File(directory, replay.attachments!![0].storePath).isFile)
        assertTrue(restarted.collectOrphanAttachments().isEmpty())
        assertTrue(restarted.observeAuthoritativeUserMessage(entry.rpcId))
        assertNull(reopened().entry(entry.rpcId))
        assertFalse(restarted.attachmentDirectory(entry.rpcId).exists())
    }

    @Test
    fun `kill point 5 - durable before delete is removed on the next scan and never sent again`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "two", listOf(image()))
        store.markSubmitting(entry.rpcId)
        store.markAccepted(entry.rpcId)
        store.markDurable(entry.rpcId)

        val restarted = reopened()
        assertEquals(SendOutboxState.DURABLE, restarted.entry(entry.rpcId)?.state)
        assertTrue("a durable leftover is not resumable work", restarted.pending().isEmpty())
        expect<SendOutboxException.IllegalTransition> { restarted.markSubmitting(entry.rpcId) }
        assertTrue(restarted.attachmentDirectory(entry.rpcId).exists())
        assertTrue(restarted.observeAuthoritativeUserMessage(entry.rpcId))
        assertNull(restarted.entry(entry.rpcId))
        assertFalse(restarted.attachmentDirectory(entry.rpcId).exists())
    }

    @Test
    fun `kill point 5 - a kill between the entry delete and the byte unlink leaves an orphan for startup GC`() {
        val entry = reopened().enqueue("gb-main", "two", listOf(image()))
        val files = KillingFileStore()
        val store = reopened(files)
        store.markSubmitting(entry.rpcId)
        store.markAccepted(entry.rpcId)
        files.killAfterDelete()
        expect<SimulatedKill> { store.observeAuthoritativeUserMessage(entry.rpcId) }

        val restarted = reopened()
        assertTrue(restarted.entries().isEmpty())
        assertTrue(restarted.attachmentDirectory(entry.rpcId).exists())
        assertEquals(listOf(entry.rpcId), restarted.collectOrphanAttachments())
        assertFalse(restarted.attachmentDirectory(entry.rpcId).exists())
    }

    @Test
    fun `a reported storage failure writes no entry and removes what the call created`() {
        val failing = object : DurableFileStore() {
            override fun writeAtomically(target: File, bytes: ByteArray) {
                if (target.name.endsWith(".json")) throw java.io.IOException("disk full")
                super.writeAtomically(target, bytes)
            }
        }
        expect<SendOutboxException.Storage> { reopened(failing).enqueue("gb-main", "x", listOf(image())) }
        assertTrue(reopened().entries().isEmpty())
        assertTrue(File(directory, "attachments").list().isNullOrEmpty())
    }

    // -------------------------------------------------------------- attachments

    @Test
    fun `attachment bytes are stored before the entry and the entry holds references only`() {
        val bytes = "image-bytes".toByteArray()
        val store = reopened()
        val entry = store.enqueue("gb-main", "look", listOf(image(bytes = bytes)))
        val attachment = entry.attachments!!.single()
        assertEquals("att-1", attachment.id)
        assertEquals(SendOutboxAttachmentKind.IMAGE, attachment.kind)
        assertEquals(bytes.size.toLong(), attachment.byteSize)
        assertEquals(SendOutboxCodec.sha256Hex(bytes), attachment.sha256)
        assertEquals("attachments/${entry.rpcId}/att-1", attachment.storePath)
        assertArrayEquals(bytes, File(directory, attachment.storePath).readBytes())
        assertFalse(entryFile(entry.rpcId).readText().contains("aW1hZ2U"))
        assertEquals(entry.attachments, reopened().entry(entry.rpcId)?.attachments)
        assertArrayEquals(bytes, reopened().verifiedAttachmentData(entry.rpcId).single().data)
        assertTrue(reopened().verifiedAttachmentData(reopened().enqueue("gb-main", "text only").rpcId).isEmpty())
    }

    @Test
    fun `a missing or modified attachment blocks the submit and keeps the entry`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "look", listOf(image()))
        val file = File(directory, entry.attachments!![0].storePath)
        assertTrue(file.delete())
        assertEquals("att-1", expect<SendOutboxException.AttachmentMissing> { store.verifiedAttachmentData(entry.rpcId) }.id)
        store.recordAttachmentFailure(entry.rpcId, SendOutboxAttachmentFailure.MISSING)
        var kept = store.entry(entry.rpcId)!!
        assertEquals(SendOutboxState.QUEUED, kept.state)
        assertEquals(0, kept.attempts)
        assertEquals("attachment_missing", kept.lastError)

        // Same byte count, different bytes.
        file.writeBytes("image-bytez".toByteArray())
        expect<SendOutboxException.AttachmentDigestMismatch> { store.verifiedAttachmentData(entry.rpcId) }
        store.recordAttachmentFailure(entry.rpcId, SendOutboxAttachmentFailure.DIGEST_MISMATCH)
        kept = reopened().entry(entry.rpcId)!!
        assertEquals("attachment_digest_mismatch", kept.lastError)
        assertEquals(listOf(entry.rpcId), reopened().pending().map { it.rpcId })
        assertEquals(entry.attachments, kept.attachments)

        // Restoring the bytes makes the same entry dispatchable again.
        file.writeBytes("image-bytes".toByteArray())
        assertEquals(1, reopened().verifiedAttachmentData(entry.rpcId).size)
        assertNull(reopened().markSubmitting(entry.rpcId).lastError)

        // An unresolved previous submit stays outcomeUnknown while blocked.
        store.markOutcomeUnknown(entry.rpcId, "cut")
        assertTrue(file.delete())
        store.recordAttachmentFailure(entry.rpcId, SendOutboxAttachmentFailure.MISSING)
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, store.entry(entry.rpcId)?.state)
        assertEquals("attachment_missing", store.entry(entry.rpcId)?.lastError)
    }

    @Test
    fun `an entry written before attachments existed still decodes and delivers`() {
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        directory.mkdirs()
        entryFile(rpcId).writeText(
            """{"v":1,"rpcId":"$rpcId","sessionId":"gb-main","text":"old text-only entry",""" +
                """"createdAtMs":1794398651000,"state":"queued","attempts":0,"backend":"local"}""",
        )
        val store = reopened()
        assertNull(store.entry(rpcId)!!.attachments)
        store.markSubmitting(rpcId)
        store.markAccepted(rpcId)
        assertTrue(store.observeAuthoritativeUserMessage(rpcId))
        assertNull(store.entry(rpcId))
    }

    @Test
    fun `startup GC removes only attachment directories that have no entry`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "look", listOf(image()))
        val kept = File(directory, entry.attachments!![0].storePath)
        val orphanId = "9d8c7b6a-5f4e-4d3c-8b2a-190817161514"
        File(store.attachmentDirectory(orphanId), "a").apply { parentFile!!.mkdirs() }.writeText("orphan")

        assertEquals(listOf(orphanId), reopened().collectOrphanAttachments())
        assertFalse(store.attachmentDirectory(orphanId).exists())
        assertTrue("bytes referenced by an entry are never collected", kept.isFile)
        // Even when one of its files is missing, an entry's directory is not an orphan.
        assertTrue(kept.delete())
        assertTrue(reopened().collectOrphanAttachments().isEmpty())
        assertTrue(store.attachmentDirectory(entry.rpcId).isDirectory)
        assertEquals(listOf(entry.rpcId), reopened().pending().map { it.rpcId })
    }

    @Test
    fun `the delete order is entry first then bytes and only for a durable entry`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "look", listOf(image()))
        expect<SendOutboxException.DeleteRequiresDurable> { store.deleteIfDurable(entry.rpcId) }
        assertTrue(entryFile(entry.rpcId).exists())
        assertTrue(File(directory, entry.attachments!![0].storePath).exists())
        store.markSubmitting(entry.rpcId)
        store.markAccepted(entry.rpcId)
        store.markDurable(entry.rpcId)
        assertTrue(store.deleteIfDurable(entry.rpcId))
        assertFalse(entryFile(entry.rpcId).exists())
        assertFalse(store.attachmentDirectory(entry.rpcId).exists())
        assertFalse(store.deleteIfDurable(entry.rpcId))
    }

    @Test
    fun `inline bytes an unknown member and a foreign store path make the file unreadable not repaired`() {
        val store = reopened()
        val entry = store.enqueue("gb-main", "look", listOf(image()))
        val original = entryFile(entry.rpcId).readText()

        entryFile(entry.rpcId).writeText(original.replace("\"filename\":", "\"data\":\"aW1hZ2UtYnl0ZXM=\",\"filename\":"))
        assertNull(reopened().entry(entry.rpcId))
        entryFile(entry.rpcId).writeText(original.replaceFirst("{", "{\"dataBase64\":\"aW1hZ2UtYnl0ZXM=\","))
        assertNull(reopened().entry(entry.rpcId))
        val foreign = "attachments/9d8c7b6a-5f4e-4d3c-8b2a-190817161514/att-1"
        entryFile(entry.rpcId).writeText(original.replace("attachments/${entry.rpcId}/att-1", foreign))
        assertNotEquals(original, entryFile(entry.rpcId).readText())
        assertNull(reopened().entry(entry.rpcId))
        entryFile(entry.rpcId).writeText(original.replace("\"attachments\":[", "\"attachments\":null,\"x\":["))
        assertNull(reopened().entry(entry.rpcId))
        for (corrupt in listOf("{ this is not json", "", "[]", "null")) {
            entryFile(entry.rpcId).writeText(corrupt)
            assertNull(corrupt, reopened().entry(entry.rpcId))
            assertTrue(reopened().entries().isEmpty())
            assertTrue("an unreadable file is not deleted", entryFile(entry.rpcId).exists())
        }
        // The bytes of an unreadable entry are still not an orphan.
        assertTrue(reopened().collectOrphanAttachments().isEmpty())

        entryFile(entry.rpcId).writeText(original)
        assertEquals(entry, reopened().entry(entry.rpcId))
    }

    @Test
    fun `the attachment count and duplicate ids fail closed before anything is written`() {
        val store = reopened()
        val twentyOne = (0 until 21).map { image("att-$it", "$it".toByteArray()) }
        assertEquals(21, expect<SendOutboxException.TooManyAttachments> { store.enqueue("gb-main", "too many", twentyOne) }.count)
        assertEquals("same", expect<SendOutboxException.DuplicateAttachmentId> {
            store.enqueue("gb-main", "dupe", listOf(image("same"), image("same")))
        }.id)
        expect<SendOutboxException.InvalidAttachmentId> { store.enqueue("gb-main", "x", listOf(image(".."))) }
        expect<SendOutboxException.InvalidAttachmentId> { store.enqueue("gb-main", "x", listOf(image("a/b"))) }
        expect<SendOutboxException.InvalidContentType> {
            store.enqueue("gb-main", "x", listOf(SendOutboxAttachmentInput("a", SendOutboxAttachmentKind.FILE, "", "f", byteArrayOf())))
        }
        expect<SendOutboxException.InvalidFilename> {
            store.enqueue("gb-main", "x", listOf(SendOutboxAttachmentInput("a", SendOutboxAttachmentKind.FILE, "t/x", "f".repeat(256), byteArrayOf())))
        }
        assertFalse(directory.exists())

        val accepted = store.enqueue("gb-main", "", twentyOne.take(20))
        assertEquals(20, accepted.attachments?.size)
        assertEquals("", accepted.text)
        assertEquals("", reopened().entry(accepted.rpcId)?.text)
    }

    @Test
    fun `the mime mapping labels every declared kind like the Swift end`() {
        val expected = mapOf(
            "image/png" to SendOutboxAttachmentKind.IMAGE,
            "AUDIO/mpeg" to SendOutboxAttachmentKind.AUDIO,
            "video/mp4" to SendOutboxAttachmentKind.VIDEO,
            "text/plain" to SendOutboxAttachmentKind.DOCUMENT,
            "application/pdf" to SendOutboxAttachmentKind.DOCUMENT,
            "application/vnd.ms-excel" to SendOutboxAttachmentKind.DOCUMENT,
            "application/octet-stream" to SendOutboxAttachmentKind.FILE,
        )
        for ((mime, kind) in expected) assertEquals(mime, kind, SendOutboxAttachmentKind.fromMimeType(mime))
    }
}

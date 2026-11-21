// SPDX-License-Identifier: MIT
// The Kotlin consumer of the frozen send-outbox contract
// (spec/host/v1/README.md section 10): the real codec and the real store are
// driven by the shared goldens and by every case of
// spec/host/v1/tools/outbox_invalid_cases.json, each judged by the rule the
// reference checker (test_outbox_contract.py) uses for it.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class SendOutboxContractTest {
    private lateinit var root: File
    private val schema = HostSpec.obj("spec/host/v1/schema/outbox-entry.schema.json")
    private val invalidCases =
        HostSpec.obj("spec/host/v1/tools/outbox_invalid_cases.json").objects("invalid")

    @Before
    fun setUp() {
        root = Files.createTempDirectory("send-outbox-contract").toFile()
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    private fun outbox(now: Long = 1_794_400_000_000L) = SendOutbox(root, nowMs = { now })

    private fun entryFile(name: String) = File(File(root, "send-outbox"), "$name.json")

    private fun writeRaw(name: String, value: JsonValue) {
        entryFile(name).apply { parentFile!!.mkdirs() }.writeText(value.toJsonString(), Charsets.UTF_8)
    }

    // ------------------------------------------------------------------ goldens

    @Test
    fun `the six goldens decode and re-encode to the same value`() {
        for (name in GOLDENS) {
            val instance = HostSpec.goldenInstance(name)
            assertEquals(name, emptyList<String>(), SpecSchema.validate(schema, instance))
            val entry = SendOutboxCodec.decode(instance)
            val encoded = JsonValue.parse(SendOutboxCodec.encode(entry))
            assertEquals(name, instance, encoded)
            assertEquals(name, emptyList<String>(), SpecSchema.validate(schema, encoded))
        }
        val twenty = SendOutboxCodec.decode(HostSpec.goldenInstance("outbox-entry-attachments-20.json"))
        assertEquals(20, twenty.attachments?.size)
        val only = SendOutboxCodec.decode(HostSpec.goldenInstance("outbox-entry-attachment-only.json"))
        assertEquals("", only.text)
        val unknown = SendOutboxCodec.decode(HostSpec.goldenInstance("outbox-entry-outcome-unknown.json"))
        assertEquals(SendOutboxState.OUTCOME_UNKNOWN, unknown.state)
        assertEquals(SendOutboxBackend.PC, unknown.backend)
    }

    @Test
    fun `a golden stored as a file is read back by the store under its own rpcId`() {
        for (name in GOLDENS) {
            val instance = HostSpec.goldenInstance(name)
            writeRaw(instance.string("rpcId"), instance)
        }
        val entries = outbox().entries()
        assertEquals(GOLDENS.size, entries.size)
        assertEquals(entries.sortedBy { it.createdAtMs }.map { it.rpcId }, entries.map { it.rpcId })
        // A file whose name is not the entry's rpcId is not that entry.
        val queued = HostSpec.goldenInstance("outbox-entry-queued.json")
        writeRaw("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", queued)
        assertEquals(GOLDENS.size, outbox().entries().size)
    }

    @Test
    fun `every entry the store produces validates against the owning schema`() {
        var clock = 1_794_400_000_000L
        val store = SendOutbox(root, nowMs = { clock++ })
        fun check(rpcId: String) {
            val raw = JsonValue.parse(entryFile(rpcId).readText(Charsets.UTF_8))
            assertEquals(raw.toJsonString(), emptyList<String>(), SpecSchema.validate(schema, raw))
        }
        val text = store.enqueue("gb-main", "看一下这张截图里的报错")
        check(text.rpcId)
        store.markSubmitting(text.rpcId).also { check(it.rpcId) }
        store.markOutcomeUnknown(text.rpcId, "transport closed after the request was written").also { check(it.rpcId) }
        store.requeue(text.rpcId).also { check(it.rpcId) }
        store.markSubmitting(text.rpcId).also { check(it.rpcId) }
        store.markAccepted(text.rpcId).also { check(it.rpcId) }
        store.markDurable(text.rpcId).also { check(it.rpcId) }

        val attachments = (0 until 20).map {
            SendOutboxAttachmentInput(
                id = "img-%02d".format(it),
                kind = SendOutboxAttachmentKind.IMAGE,
                contentType = "image/png",
                filename = "shot $it.png",
                data = "bytes-$it".toByteArray(),
            )
        }
        val only = store.enqueue("gb-main", "", attachments)
        check(only.rpcId)
        File(File(root, "send-outbox"), only.attachments!![0].storePath).delete()
        store.recordAttachmentFailure(only.rpcId, SendOutboxAttachmentFailure.MISSING)
        check(only.rpcId)
        assertEquals("attachment_missing", store.entry(only.rpcId)?.lastError)
        val generated = store.enqueue(
            "gb-main",
            "generated id",
            listOf(SendOutboxAttachmentInput(null, SendOutboxAttachmentKind.FILE, "application/octet-stream", "a.bin", byteArrayOf(1))),
        )
        check(generated.rpcId)
        // A long transport error is cut to the schema bound, not rejected.
        val long = store.enqueue("gb-main", "x")
        store.markSubmitting(long.rpcId)
        store.markOutcomeUnknown(long.rpcId, "é".repeat(5_000))
        check(long.rpcId)
        assertEquals(1_024, store.entry(long.rpcId)?.lastError?.length)
    }

    // ------------------------------------------------------------- invalid cases

    @Test
    fun `every schema-invalid case is rejected by the real decoder and never becomes an entry`() {
        var checked = 0
        for (case in invalidCases.filter { it.bool("schema") }) {
            val id = case.string("id")
            val value = case.child("case")
            assertTrue("$id must be schema-invalid", SpecSchema.validate(schema, value).isNotEmpty())
            try {
                SendOutboxCodec.decode(value)
                fail("$id decoded")
            } catch (rejected: SendOutboxInvalidEntryException) {
                assertEquals(id, SendOutboxInvalidReason.SCHEMA, rejected.reason)
            }
            val name = (value["rpcId"] as? JsonString)?.value ?: "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
            root.deleteRecursively()
            writeRaw(name, value)
            val store = outbox()
            assertTrue(id, store.entries().isEmpty())
            assertNull(id, store.entry(name))
            assertTrue("$id: an unreadable file is not deleted", entryFile(name).exists())
            checked++
        }
        assertTrue(checked > 0)
    }

    @Test
    fun `every illegal transition case is refused by the real store and changes nothing`() {
        var checked = 0
        for (case in invalidCases.filter { !it.bool("schema") && it["law"] == null }) {
            val id = case.string("id")
            val from = SendOutboxState.fromWire(case.child("case").string("from"))!!
            val to = SendOutboxState.fromWire(case.child("case").string("to"))!!
            assertFalse(id, SendOutboxTransition.allows(from, to))
            root.deleteRecursively()
            val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
            writeRaw(rpcId, entryIn(rpcId, from))
            val before = entryFile(rpcId).readText()
            val store = outbox()
            try {
                move(store, rpcId, to)
                fail("$id was allowed")
            } catch (refused: SendOutboxException.IllegalTransition) {
                assertEquals(id, from, refused.from)
                assertEquals(id, to, refused.to)
            }
            assertEquals(id, before, entryFile(rpcId).readText())
            checked++
        }
        assertTrue(checked > 0)
    }

    @Test
    fun `the store allows exactly the six edges of section 10`() {
        val allowed = setOf(
            SendOutboxState.QUEUED to SendOutboxState.SUBMITTING,
            SendOutboxState.SUBMITTING to SendOutboxState.ACCEPTED,
            SendOutboxState.SUBMITTING to SendOutboxState.OUTCOME_UNKNOWN,
            SendOutboxState.ACCEPTED to SendOutboxState.DURABLE,
            SendOutboxState.OUTCOME_UNKNOWN to SendOutboxState.ACCEPTED,
            SendOutboxState.OUTCOME_UNKNOWN to SendOutboxState.QUEUED,
        )
        val rpcId = "3f2a1c4e-5b6d-4e8f-9a0b-1c2d3e4f5a6b"
        for (from in SendOutboxState.entries) {
            for (to in SendOutboxState.entries) {
                assertEquals("$from → $to", (from to to) in allowed, SendOutboxTransition.allows(from, to))
                if (from == to && to != SendOutboxState.SUBMITTING) continue // a repeated report is a no-op
                root.deleteRecursively()
                writeRaw(rpcId, entryIn(rpcId, from))
                val moved = try {
                    move(outbox(), rpcId, to).state == to
                } catch (_: SendOutboxException.IllegalTransition) {
                    false
                }
                assertEquals("$from → $to through the store", (from to to) in allowed, moved)
                assertEquals(if (moved) to else from, outbox().entry(rpcId)?.state)
            }
        }
    }

    @Test
    fun `every attachment law case is rejected by its own rule`() {
        var checked = 0
        for (case in invalidCases.filter { (it["law"] as? JsonString)?.value == "attachment" }) {
            val id = case.string("id")
            val body = case.child("case")
            val rpcId = body.string("rpcId")
            val references = body.objects("attachments")
            root.deleteRecursively()
            when (val reason = case.string("reason")) {
                "duplicate_attachment_id", "attachment_store_path_mismatch" -> {
                    val full = entryIn(rpcId, SendOutboxState.QUEUED).with(
                        "attachments" to JsonArray(references.map(::fullAttachment)),
                    )
                    try {
                        SendOutboxCodec.decode(full)
                        fail("$id decoded")
                    } catch (rejected: SendOutboxInvalidEntryException) {
                        assertEquals(id, reason.uppercase(), rejected.reason.name)
                    }
                    writeRaw(rpcId, full)
                    assertNull(id, outbox().entry(rpcId))
                    if (reason == "duplicate_attachment_id") {
                        val inputs = references.map { input(it.string("id")) }
                        try {
                            outbox().enqueue("gb-main", "x", inputs)
                            fail("$id enqueued")
                        } catch (refused: SendOutboxException.DuplicateAttachmentId) {
                            assertEquals(references[0].string("id"), refused.id)
                        }
                    }
                }
                "attachment_store_missing", "attachment_digest_mismatch" -> {
                    val store = outbox()
                    val entry = store.enqueue("gb-main", "x", references.map { input(it.string("id")) }, rpcId = rpcId)
                    assertEquals(id, references.map { it.string("storePath") }, entry.attachments!!.map { it.storePath })
                    val file = File(store.directory, entry.attachments!![0].storePath)
                    val expected: SendOutboxAttachmentFailure
                    if (reason == "attachment_store_missing") {
                        assertTrue(body.bool("storeMissing"))
                        assertTrue(file.delete())
                        expected = SendOutboxAttachmentFailure.MISSING
                    } else {
                        assertFalse(body.bool("digestMatches"))
                        file.writeBytes(ByteArray(file.length().toInt()) { 0x7f })
                        expected = SendOutboxAttachmentFailure.DIGEST_MISMATCH
                    }
                    try {
                        store.verifiedAttachmentData(rpcId)
                        fail("$id verified")
                    } catch (blocked: SendOutboxException) {
                        val actual = when (blocked) {
                            is SendOutboxException.AttachmentMissing -> SendOutboxAttachmentFailure.MISSING
                            is SendOutboxException.AttachmentDigestMismatch -> SendOutboxAttachmentFailure.DIGEST_MISMATCH
                            else -> throw blocked
                        }
                        assertEquals(id, expected, actual)
                    }
                    // The entry stays where it is: same state, same references, no attempt.
                    store.recordAttachmentFailure(rpcId, expected)
                    val kept = outbox().entry(rpcId)
                    assertNotNull(id, kept)
                    assertEquals(SendOutboxState.QUEUED, kept!!.state)
                    assertEquals(0, kept.attempts)
                    assertEquals(expected.wire, kept.lastError)
                    assertEquals(entry.attachments, kept.attachments)
                }
                else -> fail("unknown attachment law reason $reason in $id")
            }
            checked++
        }
        assertTrue(checked > 0)
    }

    @Test
    fun `the fixture carries all three kinds of invalid case`() {
        assertTrue(invalidCases.any { it.bool("schema") })
        assertTrue(invalidCases.any { !it.bool("schema") && it["law"] == null })
        assertTrue(invalidCases.any { (it["law"] as? JsonString)?.value == "attachment" })
    }

    // ------------------------------------------------------------------ helpers

    private fun entryIn(rpcId: String, state: SendOutboxState): JsonObject = JsonObject(
        linkedMapOf(
            "v" to JsonNumber("1"),
            "rpcId" to JsonString(rpcId),
            "sessionId" to JsonString("gb-main"),
            "text" to JsonString("x"),
            "createdAtMs" to JsonNumber("1"),
            "state" to JsonString(state.wire),
            "attempts" to JsonNumber(if (state == SendOutboxState.QUEUED) "0" else "1"),
        ),
    )

    private fun fullAttachment(reference: JsonObject): JsonObject = JsonObject(
        linkedMapOf(
            "id" to reference["id"]!!,
            "kind" to JsonString("file"),
            "byteSize" to JsonNumber("3"),
            "sha256" to JsonString(SendOutboxCodec.sha256Hex("abc".toByteArray())),
            "contentType" to JsonString("application/octet-stream"),
            "filename" to JsonString("a.bin"),
            "storePath" to reference["storePath"]!!,
        ),
    )

    private fun input(id: String) = SendOutboxAttachmentInput(
        id = id,
        kind = SendOutboxAttachmentKind.FILE,
        contentType = "application/octet-stream",
        filename = "a.bin",
        data = "abc".toByteArray(),
    )

    private fun move(store: SendOutbox, rpcId: String, to: SendOutboxState): SendOutboxEntry = when (to) {
        SendOutboxState.QUEUED -> store.requeue(rpcId)
        SendOutboxState.SUBMITTING -> store.markSubmitting(rpcId)
        SendOutboxState.ACCEPTED -> store.markAccepted(rpcId)
        SendOutboxState.DURABLE -> store.markDurable(rpcId)
        SendOutboxState.OUTCOME_UNKNOWN -> store.markOutcomeUnknown(rpcId, "cut")
    }

    private companion object {
        val GOLDENS = listOf(
            "outbox-entry-queued.json",
            "outbox-entry-outcome-unknown.json",
            "outbox-entry-attachment.json",
            "outbox-entry-attachments-multiple.json",
            "outbox-entry-attachment-only.json",
            "outbox-entry-attachments-20.json",
        )
    }
}

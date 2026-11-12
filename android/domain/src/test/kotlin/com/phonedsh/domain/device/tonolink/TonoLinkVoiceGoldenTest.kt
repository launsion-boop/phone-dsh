// SPDX-License-Identifier: MIT
// phone-dsh — :domain tests: spec/device/v1/golden/tonolink-voice.json on Android.
//
// Every row of the three golden sections (events, listen_commands, packets) is
// executed against the real parser/builder, including the rejecting rows. The
// file is read from disk; no case is copied into this test.

package com.phonedsh.domain.device.tonolink

import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TonoLinkVoiceGoldenTest {
    private val fixture: Map<String, Any?> by lazy {
        val path = Path.of(
            System.getProperty("pdsh.repo.root")
                ?: error("pdsh.repo.root is not set; the :domain test task supplies it"),
        ).resolve("spec/device/v1/golden/tonolink-voice.json")
        assertTrue("shared golden must exist at $path", Files.isRegularFile(path))
        MiniJson.parseObject(path.toFile().readText())
    }

    @Suppress("UNCHECKED_CAST")
    private fun rows(section: String): List<Map<String, Any?>> =
        requireNotNull(fixture[section] as? List<Map<String, Any?>>) { "$section is missing" }

    private fun hex(text: String): ByteArray {
        require(text.length % 2 == 0) { "odd hex length: $text" }
        return ByteArray(text.length / 2) { index ->
            text.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    @Test
    fun constantsMatchTheContract() {
        @Suppress("UNCHECKED_CAST")
        val constants = requireNotNull(fixture["constants"] as? Map<String, Any?>) { "constants is missing" }
        assertEquals(TonoLinkVoicePacket.HEADER_BYTES.toLong(), constants["header_bytes"])
        assertEquals(TonoLinkVoicePacket.OPUS_MAX_BYTES.toLong(), constants["opus_max_bytes"])
        assertEquals(TonoLinkVoicePacket.FRAME_MS.toLong(), constants["frame_ms"])
        assertEquals(TonoLinkVoicePacket.FLAG_FIRST.toLong(), constants["flag_first"])
        assertEquals(TonoLinkVoicePacket.FLAG_LAST.toLong(), constants["flag_last"])
    }

    @Test
    fun everyEventRow() {
        val events = rows("events")
        assertEquals("the golden's events section", 16, events.size)
        for (row in events) {
            val line = row["line"] as String
            val parsed = TonoLinkVoiceEvent.parse(line)
            @Suppress("UNCHECKED_CAST")
            val expect = row["expect"] as? Map<String, Any?>
            if (expect == null) {
                assertNull("$line must not be an event", parsed)
                continue
            }
            val event = requireNotNull(parsed) { "$line must parse as an event" }
            when (expect["kind"]) {
                "wake" -> assertEquals(
                    line,
                    TonoLinkVoiceEvent.Wake(
                        n = (expect["n"] as Long).toUInt(),
                        upMs = (expect["up_ms"] as Long).toUInt(),
                    ),
                    event,
                )

                "listen_end" -> assertEquals(
                    line,
                    TonoLinkVoiceEvent.ListenEnd(
                        n = (expect["n"] as Long).toUInt(),
                        frames = (expect["frames"] as Long).toUInt(),
                        reason = requireNotNull(TonoLinkVoiceEvent.Reason.entries
                            .firstOrNull { it.wire == expect["reason"] }) { "unknown reason in $line" },
                    ),
                    event,
                )

                else -> error("unknown kind in $line")
            }
        }
    }

    @Test
    fun everyListenCommandRow() {
        val commands = rows("listen_commands")
        assertEquals("the golden's listen_commands section", 2, commands.size)
        for (row in commands) {
            val bytes = TonoLinkVoiceCommand.listen(
                seq = (row["seq"] as Long).toInt(),
                id = (row["id"] as Long).toUInt(),
            )
            assertEquals(row["line"] as String, String(bytes, Charsets.US_ASCII))
        }
        // §4.1 numbers the turn from the phone: id 0 is refused, never sent.
        try {
            TonoLinkVoiceCommand.listen(seq = 1, id = 0u)
            error("listen id 0 must be refused")
        } catch (_: IllegalArgumentException) {
            // Expected: the board would otherwise number the turn itself.
        }
    }

    @Test
    fun everyPacketRow() {
        val packets = rows("packets")
        assertEquals("the golden's packets section", 8, packets.size)
        for (row in packets) {
            val turn = (row["turn_id"] as Long).toUInt()
            val data = when (val repeat = row["hex_repeat"]) {
                is Map<*, *> -> {
                    val prefix = hex(repeat["prefix"] as String)
                    prefix + ByteArray((repeat["count"] as Long).toInt()) { hex(repeat["byte"] as String)[0] }
                }

                else -> hex(row["hex"] as String)
            }
            val parsed = TonoLinkVoicePacket.parse(data, turnId = turn)
            @Suppress("UNCHECKED_CAST")
            val expect = row["expect"] as? Map<String, Any?>
            if (expect == null) {
                assertNull("$row must be dropped", parsed)
                continue
            }
            val packet = requireNotNull(parsed) { "$row must parse" }
            assertEquals((expect["seq"] as Long).toInt(), packet.seq)
            assertEquals(expect["first"] as Boolean, packet.first)
            assertEquals(expect["last"] as Boolean, packet.last)
            assertEquals(hex(expect["opus_hex"] as String).toList(), packet.opus.toList())
        }
    }

    @Test
    fun tallyCountsGapsAndDropsWithoutFillingThem() {
        val tally = TonoLinkVoiceTally()
        for (seq in listOf(0, 1, 3)) {
            tally.record(TonoLinkVoicePacket(seq = seq, first = seq == 0, last = false, opus = byteArrayOf(1)))
        }
        tally.record(null)
        assertEquals(3, tally.packets)
        assertEquals(1, tally.gaps)
        assertEquals(1, tally.dropped)

        // A u16 seq wraps from 65535 to 0; that is not a gap.
        val wrap = TonoLinkVoiceTally()
        wrap.record(TonoLinkVoicePacket(seq = 0xFFFF, first = false, last = false, opus = byteArrayOf(2)))
        wrap.record(TonoLinkVoicePacket(seq = 0, first = false, last = false, opus = byteArrayOf(3)))
        assertEquals(2, wrap.packets)
        assertEquals(0, wrap.gaps)

        // Out-of-order and duplicate seqs are still gaps, and are never reordered.
        val late = TonoLinkVoiceTally()
        late.record(TonoLinkVoicePacket(seq = 5, first = false, last = false, opus = byteArrayOf(4)))
        late.record(TonoLinkVoicePacket(seq = 5, first = false, last = false, opus = byteArrayOf(5)))
        assertEquals(1, late.gaps)
        assertEquals(2, late.packets)
    }
}

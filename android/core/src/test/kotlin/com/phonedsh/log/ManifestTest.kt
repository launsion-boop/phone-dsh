// manifest.json schema versus corruption (wal.md §7, revised §7.2).
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.wire.WalException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ManifestTest {
    private val validJson = """
        {
          "format": 1,
          "boot_id": "00112233445566778899aabbccddeeff",
          "materialized_upto_mseq": 12,
          "last_mseq": 12,
          "last_durable_epoch": 1,
          "segments": [
            {"file": "wal/00000001.000000.xlwal", "epoch": 1, "first_mseq": 1, "last_mseq": 12}
          ]
        }
    """.trimIndent()

    @Test
    fun unknownMembersAreIgnored() {
        // README §2: a decoder MUST accept any legal JSON object and MAY ignore
        // unknown members. An unknown member is never "schema-invalid".
        val withUnknown = """
            {
              "format": 1,
              "boot_id": "00112233445566778899aabbccddeeff",
              "materialized_upto_mseq": 12,
              "last_mseq": 12,
              "last_durable_epoch": 1,
              "future_member": {"anything": [1, 2, 3]},
              "segments": [
                {
                  "file": "wal/00000001.000000.xlwal",
                  "epoch": 1,
                  "first_mseq": 1,
                  "last_mseq": 12,
                  "future_segment_member": "ignored"
                }
              ]
            }
        """.trimIndent()
        val manifest = Manifest.fromJson(withUnknown)
        assertEquals(12L, manifest.lastMseq)
        assertEquals(12L, manifest.materializedUptoMseq)
        assertEquals(1, manifest.lastDurableEpoch)
        assertEquals("00112233445566778899aabbccddeeff", manifest.bootId.hex)
        assertEquals(1, manifest.segments.size)
        assertEquals(WalSegmentName(1, 0), manifest.segments.single().name)
        // An unknown member does not survive a rewrite: the encoder emits only
        // the §7 members.
        assertEquals(false, Manifest.fromJson(manifest.toJson()).toJson().contains("future_member"))
    }

    @Test
    fun missingRequiredMemberIsSchemaInvalid() {
        val parsed = JsonValue.parse(validJson) as JsonObject
        for (member in listOf(
            "format",
            "boot_id",
            "materialized_upto_mseq",
            "last_mseq",
            "last_durable_epoch",
            "segments",
        )) {
            val withoutMember = JsonObject(parsed.members.filterKeys { it != member }).toJsonString()
            val error = assertThrows(
                "$member removed",
                WalException::class.java,
            ) { Manifest.fromJson(withoutMember) }
            assertEquals("$member removed: ${error.detail}", "WAL_MANIFEST_INVALID", error.code)
        }
    }

    @Test
    fun outOfRangeKnownMemberIsSchemaInvalid() {
        // §7.2 as revised: "a required member is missing or a known member is
        // out of range" is the schema-invalid class, not WAL_CORRUPT.
        fun codeOf(json: String): String =
            assertThrows(WalException::class.java) { Manifest.fromJson(json) }.code

        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("\"format\": 1", "\"format\": 2")),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("00112233445566778899aabbccddeeff", "00112233445566778899AABBCCDDEEFF")),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("\"last_durable_epoch\": 1", "\"last_durable_epoch\": 100000000")),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("\"last_mseq\": 12", "\"last_mseq\": -1")),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(
                validJson.replace(
                    "\"epoch\": 1, \"first_mseq\": 1",
                    "\"epoch\": 0, \"first_mseq\": 1",
                ),
            ),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("\"first_mseq\": 1,", "\"first_mseq\": 0,")),
        )
        assertEquals(
            "WAL_MANIFEST_INVALID",
            codeOf(validJson.replace("wal/00000001.000000.xlwal", "wal/1.0.xlwal")),
        )
    }

    @Test
    fun impossibleCheckpointIsCorruptNotSchemaInvalid() {
        // A schema-valid file with a watermark above last_mseq cannot be a real
        // checkpoint; it is WAL_CORRUPT and must fail loud instead of being
        // rebuilt as if the checkpoint were absent.
        val impossible = validJson.replace(
            "\"materialized_upto_mseq\": 12",
            "\"materialized_upto_mseq\": 13",
        )
        val error = assertThrows(WalException::class.java) { Manifest.fromJson(impossible) }
        assertEquals("WAL_CORRUPT", error.code)

        // The same for a segment file whose epoch member disagrees with its name.
        val mismatched = validJson.replace(
            "\"file\": \"wal/00000001.000000.xlwal\", \"epoch\": 1",
            "\"file\": \"wal/00000002.000000.xlwal\", \"epoch\": 1",
        )
        assertEquals(
            "WAL_CORRUPT",
            assertThrows(WalException::class.java) { Manifest.fromJson(mismatched) }.code,
        )
    }

    @Test
    fun encodeAndParseRoundTrip() {
        val manifest = Manifest(
            lastMseq = 46,
            segments = listOf(
                ManifestSegment.of(WalSegmentName(1, 0), firstMseq = 42, lastMseq = 46),
            ),
            lastDurableEpoch = 1,
            bootId = TEST_BOOT_ID,
            materializedUptoMseq = 46,
        )
        val bytes = manifest.encode()
        val parsed = Manifest.parse(bytes)
        assertEquals(manifest, parsed)
        // The Rust writer is canonical: emitting the parsed object reproduces
        // the same bytes, so a manifest write is byte-stable.
        assertEquals(String(bytes), String(parsed.encode()))
        assertTrue(String(bytes).contains("\"boot_id\":\"00112233445566778899aabbccddeeff\""))
    }

    @Test
    fun newWorkspaceIsEmptyAtZero() {
        val manifest = Manifest.forNewWorkspace(TEST_BOOT_ID)
        assertEquals(0L, manifest.lastMseq)
        assertEquals(0L, manifest.materializedUptoMseq)
        assertEquals(0, manifest.lastDurableEpoch)
        assertEquals(emptyList<ManifestSegment>(), manifest.segments)
        assertEquals(manifest, Manifest.parse(manifest.encode()))
    }
}

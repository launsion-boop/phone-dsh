// The two WAL golden vectors, decoded through JNI on the Kotlin side.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * One JUnit case per WAL golden vector (`spec/v1/golden/wal/`), proving the full
 * Kotlin → JNI → Rust path:
 *
 * 1. `classifyTail(file_hex)` says `clean`;
 * 2. `scanSegment(file_hex)` matches the vector's header and record summary;
 * 3. `records(file_hex)` decodes exactly the vector's `records[]` sequence —
 *    `kind`, the §3 `len` field, `crc_ok` and every body member of the golden
 *    `fields` object — and `decodeRecord(record_hex)` agrees record by record.
 */
@RunWith(Parameterized::class)
class NativeWalGoldenTest(private val vector: WalGoldenVector) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{index}: {0}")
        fun vectors(): List<WalGoldenVector> = WalGoldenCorpus.load()
    }

    @Test
    fun classifyTailReportsClean() {
        assertEquals(
            "${vector.name}: classifyTail",
            "{\"verdict\":\"clean\"}",
            NativeWal.classifyTail(hexToBytes(vector.fileHex)),
        )
    }

    @Test
    fun scanSegmentMatchesTheGoldenHeaderAndRecordSummary() {
        val scan = WalJsonParser
            .parse(NativeWal.scanSegment(hexToBytes(vector.fileHex)))
            .objectMembers()

        assertEquals("${vector.name}: header_ok", true, scan.getValue("header_ok").booleanValue())
        assertEquals("${vector.name}: corrupt", false, scan.getValue("corrupt").booleanValue())
        assertEquals(
            "${vector.name}: first_mseq",
            vector.firstMseq,
            scan.getValue("first_mseq").numberValue(),
        )
        assertTrue("${vector.name}: torn_tail", scan.getValue("torn_tail") is WalJson.Null)
        assertTrue("${vector.name}: chain_error", scan.getValue("chain_error") is WalJson.Null)
        assertTrue("${vector.name}: header_error", scan.getValue("header_error") is WalJson.Null)
        assertEquals(
            "${vector.name}: valid_len",
            vector.fileHex.length / 2L,
            scan.getValue("valid_len").numberValue(),
        )

        val mutations = vector.records.filter { it.member("kind").stringValue() == "mutation" }
        val closes = vector.records.filter { it.member("kind").stringValue() == "epoch_close" }
        val firstMutation = mutations
            .firstOrNull()
            ?.member("fields")
            ?.member("mseq")
            ?.numberValue()
        assertEquals(
            "${vector.name}: first_mutation_mseq",
            firstMutation,
            optionalNumber(scan.getValue("first_mutation_mseq")),
        )
        assertEquals(
            "${vector.name}: last_mutation_mseq",
            mutations
                .map { it.member("fields").member("mseq").numberValue() }
                .maxOrNull() ?: 0L,
            scan.getValue("last_mutation_mseq").numberValue(),
        )
        assertEquals(
            "${vector.name}: epoch_close",
            closes.lastOrNull()?.member("fields")?.member("durable_upto")?.numberValue(),
            optionalNumber(scan.getValue("epoch_close")),
        )
    }

    @Test
    fun recordsDecodeTheGoldenSequence() {
        val decoded = WalJsonParser
            .parse(NativeWal.records(hexToBytes(vector.fileHex)))
            .arrayItems()
        assertEquals("${vector.name}: record count", vector.records.size, decoded.size)

        vector.records.forEachIndexed { index, golden ->
            val label = "${vector.name} record $index"
            val kind = golden.member("kind").stringValue()
            val recordHex = golden.member("record_hex").stringValue()
            val frame = hexToBytes(recordHex)
            val actual = decoded[index].objectMembers()

            assertEquals("$label: kind", kind, actual.getValue("kind").stringValue())
            assertEquals("$label: crc_ok", true, actual.getValue("crc_ok").booleanValue())
            assertEquals(
                "$label: len (wal.md §3)",
                recordHex.substring(0, 8).toLong(16),
                actual.getValue("len").numberValue(),
            )

            // Every member of the golden `fields` object (mseq, op, mode,
            // mflags, append_from, path, data_len, data_hex, or wall_ms and
            // durable_upto) must have the same value in the decoded record.
            for ((name, value) in golden.member("fields").objectMembers()) {
                assertEquals("$label: $name", value, actual[name])
            }

            assertEquals(
                "$label: verifyRecord",
                "{\"ok\":true}",
                NativeWal.verifyRecord(frame),
            )
            assertEquals(
                "$label: decodeRecord",
                decoded[index],
                WalJsonParser.parse(NativeWal.decodeRecord(frame)),
            )
        }
    }

    private fun optionalNumber(value: WalJson): Long? =
        if (value is WalJson.Null) null else value.numberValue()
}

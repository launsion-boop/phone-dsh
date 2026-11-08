// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import com.phonedsh.domain.connector.lan.DnsPackets.Companion.SERVICE
import com.phonedsh.domain.connector.lan.DnsPackets.Companion.instance
import com.phonedsh.domain.connector.lan.DnsPackets.Companion.labels
import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DnsMessageParserTest {
    private fun ok(bytes: ByteArray): DnsMessage = when (val result = DnsMessageParser.parse(bytes)) {
        is DnsParseResult.Ok -> result.message
        is DnsParseResult.Rejected -> throw AssertionError("rejected: ${result.reason}")
    }

    private fun rejected(bytes: ByteArray): DnsReject = when (val result = DnsMessageParser.parse(bytes)) {
        is DnsParseResult.Ok -> throw AssertionError("accepted a malformed datagram")
        is DnsParseResult.Rejected -> result.reason
    }

    @Test
    fun parsesAnAdvertisementAndKeepsTxtBytesExactly() {
        val txt = byteArrayOf(1, 0xff.toByte()) + DnsPackets.txt("PrOfIlE=pdsh-mcp-1", "profile=x")
        val message = ok(DnsPackets.advertisement(txt = txt))
        assertTrue(message.isResponse)
        assertEquals(4, message.records.size)
        val ptr = message.records[0].data as DnsRecordData.Ptr
        assertEquals(4, ptr.target.labelCount)
        val srv = message.records[1]
        assertTrue("cache-flush bit is split from the class", srv.cacheFlush)
        assertEquals(DnsMessageParser.CLASS_IN, srv.dnsClass)
        assertEquals(8443, (srv.data as DnsRecordData.Srv).port)
        assertEquals("lamp.local.", (srv.data as DnsRecordData.Srv).target.toHostnameText())
        assertArrayEquals(txt, (message.records[2].data as DnsRecordData.Txt).raw)
        assertEquals(DnsRecordData.Other(1), message.records[3].data)
    }

    @Test
    fun followsBackwardCompressionPointers() {
        val packets = DnsPackets()
        val serviceAt = packets.position
        packets.ptr(SERVICE, instance("Lamp"))
        // Owner "Lamp" + pointer to the service name written in the PTR owner.
        packets.raw(4, 'L'.code, 'a'.code, 'm'.code, 'p'.code, 0xc0, serviceAt)
        packets.u16(33); packets.u16(1); packets.u32(120)
        packets.u16(6 + 1 + 4 + 2) // priority, weight, port, "lamp" + pointer
        packets.u16(0); packets.u16(0); packets.u16(443)
        packets.raw(4, 'l'.code, 'a'.code, 'm'.code, 'p'.code, 0xc0, serviceAt + 1 + 9 + 1 + 4)
        val message = ok(packets.build(answerCount = 2))
        val srv = message.records[1]
        assertTrue(srv.name.equalsIgnoreAsciiCase(DnsName(instance("lamp"))))
        assertEquals("lamp.local.", (srv.data as DnsRecordData.Srv).target.toHostnameText())
    }

    @Test
    fun refusesCompressionLoopsAndForwardOrHeaderPointers() {
        // A pointer to itself.
        val self = DnsPackets()
        val at = self.position
        self.raw(0xc0, at)
        self.u16(12); self.u16(1); self.u32(1); self.u16(1); self.raw(0)
        assertEquals(DnsReject.BAD_POINTER, rejected(self.build(answerCount = 1)))

        // Two names pointing at each other: the first pointer is forward.
        val pair = DnsPackets()
        val first = pair.position
        pair.raw(0xc0, first + 2, 0xc0, first)
        assertEquals(DnsReject.BAD_POINTER, rejected(pair.build(answerCount = 1)))

        // A pointer into the 12-byte header.
        val header = DnsPackets()
        header.raw(0xc0, 4)
        header.u16(12); header.u16(1); header.u32(1); header.u16(1); header.raw(0)
        assertEquals(DnsReject.BAD_POINTER, rejected(header.build(answerCount = 1)))
    }

    @Test
    fun boundsThePointerChain() {
        fun chain(length: Int): ByteArray {
            val packets = DnsPackets()
            // A question "a." followed by `length` questions each pointing at the previous one.
            var previous = packets.position
            packets.name(labels("a")); packets.u16(1); packets.u16(1)
            repeat(length) {
                val here = packets.position
                packets.raw(0xc0 or (previous shr 8), previous and 0xff)
                packets.u16(1); packets.u16(1)
                previous = here
            }
            // One answer whose owner points at the last link: it follows `length` + 1 pointers.
            packets.raw(0xc0 or (previous shr 8), previous and 0xff)
            packets.u16(1); packets.u16(1); packets.u32(1); packets.u16(4); packets.raw(1, 2, 3, 4)
            return packets.build(answerCount = 1, questionCount = length + 1)
        }
        // MAX_QUESTIONS caps the chain we can build here at 15 links + the answer.
        ok(chain(DnsMessageParser.MAX_POINTERS - 1))
        // Hop limit: a chain built through RDATA names is longer than the question cap allows.
        val packets = DnsPackets()
        var previous = packets.position
        packets.name(labels("a")); packets.u16(1); packets.u16(1)
        for (i in 0 until DnsMessageParser.MAX_POINTERS + 1) {
            val owner = packets.position
            packets.raw(0xc0 or (previous shr 8), previous and 0xff)
            packets.u16(12); packets.u16(1); packets.u32(1); packets.u16(2)
            val here = packets.position
            packets.raw(0xc0 or (owner shr 8), owner and 0xff)
            previous = here
        }
        assertEquals(
            DnsReject.TOO_MANY_POINTERS,
            rejected(packets.build(answerCount = DnsMessageParser.MAX_POINTERS + 1, questionCount = 1)),
        )
    }

    @Test
    fun everyTruncationIsRefusedNotMisread() {
        val full = DnsPackets.advertisement()
        ok(full)
        for (length in 0 until full.size) {
            val result = DnsMessageParser.parse(full, length)
            assertTrue("prefix $length must be rejected", result is DnsParseResult.Rejected)
        }
    }

    @Test
    fun refusesRdataThatOverrunsOrUnderrunsItsLength() {
        val overrun = DnsPackets().rawRecordHeader(16, 50, instance("Lamp")).raw(5).build()
        assertEquals(DnsReject.TRUNCATED, rejected(overrun))
        // PTR whose name ends before RDLENGTH: leftover RDATA.
        val packets = DnsPackets().rawRecordHeader(12, 4 + 1 + 1, SERVICE)
        packets.name(labels("abc")); packets.raw(0)
        assertEquals(DnsReject.BAD_RDATA, rejected(packets.build()))
        // PTR name that runs past RDLENGTH.
        val long = DnsPackets().rawRecordHeader(12, 2, SERVICE)
        long.name(labels("abc"))
        assertEquals(DnsReject.TRUNCATED, rejected(long.build()))
        // SRV shorter than its fixed fields.
        val shortSrv = DnsPackets().rawRecordHeader(33, 6, instance("Lamp")).raw(0, 0, 0, 0, 1, 0xbb)
        assertEquals(DnsReject.BAD_RDATA, rejected(shortSrv.build()))
    }

    @Test
    fun boundsTxtSizeMessageSizeAndCounts() {
        val limit = ByteArray(DnsMessageParser.MAX_TXT_BYTES) { 0 }
        ok(DnsPackets().txt(instance("Lamp"), limit).build())
        val over = ByteArray(DnsMessageParser.MAX_TXT_BYTES + 1) { 0 }
        assertEquals(DnsReject.TXT_TOO_LARGE, rejected(DnsPackets().txt(instance("Lamp"), over).build()))

        val big = DnsPackets()
        repeat(8) { big.record(labels("x$it"), 99, 1) { raw(*IntArray(1200)) } }
        assertEquals(DnsReject.TOO_LARGE, rejected(big.build()))

        val header = DnsPackets().build(answerCount = DnsMessageParser.MAX_RECORDS + 1)
        assertEquals(DnsReject.TOO_MANY_RECORDS, rejected(header))
        val questions = DnsPackets().build(questionCount = DnsMessageParser.MAX_QUESTIONS + 1)
        assertEquals(DnsReject.TOO_MANY_QUESTIONS, rejected(questions))
        assertEquals(DnsReject.TOO_SHORT, rejected(ByteArray(11)))
    }

    @Test
    fun refusesQueriesOpcodesRcodesLabelTypesLongNamesAndTrailingBytes() {
        assertEquals(DnsReject.NOT_RESPONSE, rejected(DnsPackets(flags = 0).build()))
        assertEquals(DnsReject.BAD_OPCODE, rejected(DnsPackets(flags = 0x8000 or (2 shl 11)).build()))
        assertEquals(DnsReject.BAD_RCODE, rejected(DnsPackets(flags = 0x8003).build()))
        // TC is ignored on mDNS responses (RFC 6762 §18.5).
        ok(DnsPackets(flags = 0x8600).build())

        val extended = DnsPackets().raw(0x41, 0)
        extended.u16(1); extended.u16(1)
        assertEquals(DnsReject.BAD_LABEL_TYPE, rejected(extended.build(questionCount = 1)))

        val longName = DnsPackets().question(List(4) { ByteArray(63) { 'a'.code.toByte() } }, 1)
        assertEquals(DnsReject.NAME_TOO_LONG, rejected(longName.build()))
        val longest = listOf(ByteArray(63), ByteArray(63), ByteArray(63), ByteArray(61)).map { label ->
            label.also { it.fill('a'.code.toByte()) }
        }
        ok(DnsPackets().question(longest, 1).build())

        assertEquals(DnsReject.TRAILING_BYTES, rejected(DnsPackets.advertisement() + byteArrayOf(0)))
    }

    @Test
    fun randomMutationsNeverEscapeAsExceptions() {
        val seed = DnsPackets.advertisement(txt = DnsPackets.txt("profile=pdsh-mcp-1", "a=b"))
        val random = Random(0x6d646e73)
        repeat(20_000) {
            val bytes = seed.copyOf()
            repeat(1 + random.nextInt(4)) { bytes[random.nextInt(bytes.size)] = random.nextInt(256).toByte() }
            val length = if (random.nextInt(4) == 0) random.nextInt(bytes.size + 1) else bytes.size
            try {
                DnsMessageParser.parse(bytes, length)
            } catch (error: Throwable) {
                fail("mutation escaped as ${error::class.simpleName}: ${error.message}")
            }
        }
    }

    @Test
    fun hostnameTextRefusesALabelContainingADot() {
        assertEquals("a.b.", DnsName(labels("a", "b")).toHostnameText())
        assertEquals(null, DnsName(labels("a.b")).toHostnameText())
        // Bytes are not re-encoded: non-ASCII stays non-ASCII for the validator.
        assertEquals("lÃ¡mp.", DnsName(labels("lámp")).toHostnameText())
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

/**
 * A DNS name as its wire labels. Label bytes are kept exactly: a DNS-SD service
 * instance label is arbitrary UTF-8 and may contain `.`, so joining labels into
 * text before the caller decides what it needs would be lossy.
 */
public class DnsName internal constructor(labels: List<ByteArray>) {
    private val parts: List<ByteArray> = labels.map { it.copyOf() }

    /** The labels, root excluded; each returned array is a copy. */
    public val labels: List<ByteArray> get() = parts.map { it.copyOf() }

    public val labelCount: Int get() = parts.size

    internal fun label(index: Int): ByteArray = parts[index]

    /** DNS comparison: ASCII letters fold, every other byte is compared exactly. */
    public fun equalsIgnoreAsciiCase(other: DnsName): Boolean =
        parts.size == other.parts.size && parts.indices.all { asciiFoldEquals(parts[it], other.parts[it]) }

    /** DNS name equality (ASCII case-insensitive), so identical duplicate records compare equal. */
    override fun equals(other: Any?): Boolean = other is DnsName && equalsIgnoreAsciiCase(other)

    override fun hashCode(): Int = key.hashCode()

    /** A map key with DNS case folding that cannot confuse a `.` inside a label with a separator. */
    public val key: String by lazy {
        buildString {
            for (label in parts) {
                append(label.size).append(':')
                for (byte in label) append(Integer.toHexString(foldAscii(byte.toInt() and 0xff) or 0x100).substring(1))
                append('/')
            }
        }
    }

    /**
     * The dotted text form for a hostname, with a final root dot, or `null` when a
     * label contains a `.` byte: such a name has no faithful dotted spelling.
     * Bytes map 1:1 to chars (ISO-8859-1), so non-ASCII stays visible to the
     * hostname validator, which rejects it, instead of being re-encoded.
     */
    public fun toHostnameText(): String? {
        if (parts.any { label -> label.any { it == '.'.code.toByte() } }) return null
        return parts.joinToString(separator = ".", postfix = ".") { String(it, Charsets.ISO_8859_1) }
    }

    /** The wire encoding without compression (labels plus the root byte). */
    internal fun encode(out: java.io.ByteArrayOutputStream) {
        for (label in parts) {
            out.write(label.size)
            out.write(label)
        }
        out.write(0)
    }

    public companion object {
        /** Builds a name from ASCII labels; used for the fixed service type. */
        public fun of(vararg labels: String): DnsName {
            val bytes = labels.map { it.toByteArray(Charsets.US_ASCII) }
            require(bytes.all { it.size in 1..63 }) { "label length" }
            require(bytes.sumOf { it.size + 1 } + 1 <= DnsMessageParser.MAX_NAME_WIRE_BYTES) { "name length" }
            return DnsName(bytes)
        }

        private fun foldAscii(value: Int): Int = if (value in 'A'.code..'Z'.code) value + 32 else value

        private fun asciiFoldEquals(a: ByteArray, b: ByteArray): Boolean =
            a.size == b.size && a.indices.all { foldAscii(a[it].toInt() and 0xff) == foldAscii(b[it].toInt() and 0xff) }
    }
}

/** Record data this client interprets; every other type is retained only as its type number. */
public sealed interface DnsRecordData {
    public data class Ptr(val target: DnsName) : DnsRecordData

    public data class Srv(val priority: Int, val weight: Int, val port: Int, val target: DnsName) : DnsRecordData

    /** The exact TXT RDATA: DNS-SD length-prefixed strings, never converted to a map here. */
    public class Txt(raw: ByteArray) : DnsRecordData {
        private val bytes = raw.copyOf()
        public val raw: ByteArray get() = bytes.copyOf()
        override fun equals(other: Any?): Boolean = other is Txt && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    public data class Other(val type: Int) : DnsRecordData
}

public data class DnsQuestion(val name: DnsName, val type: Int, val unicastResponse: Boolean)

/**
 * @param ttlSeconds the unsigned 32-bit TTL; 0 is an mDNS goodbye.
 * @param cacheFlush the mDNS cache-flush bit (top bit of the class field).
 */
public data class DnsRecord(
    val name: DnsName,
    val type: Int,
    val dnsClass: Int,
    val cacheFlush: Boolean,
    val ttlSeconds: Long,
    val data: DnsRecordData,
)

public class DnsMessage internal constructor(
    public val id: Int,
    public val isResponse: Boolean,
    public val questions: List<DnsQuestion>,
    /** Answer, authority and additional records, in wire order. */
    public val records: List<DnsRecord>,
)

/** Why a datagram was refused. Every refusal drops the whole datagram. */
public enum class DnsReject {
    TOO_SHORT,
    TOO_LARGE,
    NOT_RESPONSE,
    BAD_OPCODE,
    BAD_RCODE,
    TOO_MANY_QUESTIONS,
    TOO_MANY_RECORDS,
    TRUNCATED,
    BAD_LABEL_TYPE,
    NAME_TOO_LONG,
    BAD_POINTER,
    TOO_MANY_POINTERS,
    BAD_RDATA,
    TXT_TOO_LARGE,
    TRAILING_BYTES,
}

public sealed interface DnsParseResult {
    public class Ok(public val message: DnsMessage) : DnsParseResult

    public data class Rejected(val reason: DnsReject) : DnsParseResult
}

/**
 * A strict, bounded parser for one mDNS response datagram (RFC 1035 §4, RFC 6762).
 *
 * Every limit is a hard refusal of the whole datagram; nothing is repaired or
 * partially accepted:
 *  * the datagram is 12..[MAX_MESSAGE_BYTES] bytes (RFC 6762 §17's 9000-byte bound);
 *  * it is a standard-query response (QR=1, opcode 0, rcode 0). The TC bit is
 *    ignored, as RFC 6762 §18.5 requires for multicast responses;
 *  * at most [MAX_QUESTIONS] questions and [MAX_RECORDS] records in total;
 *  * names: labels of 1..63 bytes, at most [MAX_NAME_WIRE_BYTES] wire bytes after
 *    expansion, label types 0x40/0x80 refused, every compression pointer must
 *    point strictly backwards, past the header, and at most [MAX_POINTERS] are
 *    followed per name — so loops and forward references cannot run;
 *  * RDATA of PTR and SRV must consist of exactly the name (plus SRV's 6 fixed
 *    bytes); a TXT RDATA is kept byte-for-byte and is at most [MAX_TXT_BYTES];
 *  * every byte is accounted for: data after the declared records is refused.
 */
public object DnsMessageParser {
    public const val MAX_MESSAGE_BYTES: Int = 9000
    public const val MAX_QUESTIONS: Int = 16
    public const val MAX_RECORDS: Int = 128
    public const val MAX_NAME_WIRE_BYTES: Int = 255
    public const val MAX_POINTERS: Int = 16

    /** RFC 6763 §6.2: 1300 bytes is the most a TXT record should hold to fit one Ethernet packet. */
    public const val MAX_TXT_BYTES: Int = 1300

    public const val TYPE_PTR: Int = 12
    public const val TYPE_TXT: Int = 16
    public const val TYPE_SRV: Int = 33
    public const val CLASS_IN: Int = 1

    private const val HEADER_BYTES = 12

    private class Reject(val reason: DnsReject) : Exception(null, null, false, false)

    public fun parse(datagram: ByteArray, length: Int = datagram.size): DnsParseResult {
        require(length in 0..datagram.size)
        if (length < HEADER_BYTES) return DnsParseResult.Rejected(DnsReject.TOO_SHORT)
        if (length > MAX_MESSAGE_BYTES) return DnsParseResult.Rejected(DnsReject.TOO_LARGE)
        return try {
            DnsParseResult.Ok(Reader(datagram, length).message())
        } catch (reject: Reject) {
            DnsParseResult.Rejected(reject.reason)
        }
    }

    private class Reader(private val bytes: ByteArray, private val length: Int) {
        private var offset = 0

        fun message(): DnsMessage {
            val id = u16()
            val flags = u16()
            if (flags and 0x8000 == 0) throw Reject(DnsReject.NOT_RESPONSE)
            if ((flags shr 11) and 0xf != 0) throw Reject(DnsReject.BAD_OPCODE)
            if (flags and 0xf != 0) throw Reject(DnsReject.BAD_RCODE)
            val qd = u16()
            val an = u16()
            val ns = u16()
            val ar = u16()
            if (qd > MAX_QUESTIONS) throw Reject(DnsReject.TOO_MANY_QUESTIONS)
            if (an + ns + ar > MAX_RECORDS) throw Reject(DnsReject.TOO_MANY_RECORDS)
            val questions = ArrayList<DnsQuestion>(qd)
            repeat(qd) {
                val name = name()
                val type = u16()
                val qclass = u16()
                questions += DnsQuestion(name, type, qclass and 0x8000 != 0)
            }
            val records = ArrayList<DnsRecord>(an + ns + ar)
            repeat(an + ns + ar) { records += record() }
            if (offset != length) throw Reject(DnsReject.TRAILING_BYTES)
            return DnsMessage(id, isResponse = true, questions, records)
        }

        private fun record(): DnsRecord {
            val name = name()
            val type = u16()
            val rawClass = u16()
            val ttl = u32()
            val rdLength = u16()
            if (rdLength > length - offset) throw Reject(DnsReject.TRUNCATED)
            val start = offset
            val end = start + rdLength
            val data = when (type) {
                TYPE_PTR -> DnsRecordData.Ptr(name(limit = end))
                TYPE_SRV -> {
                    if (rdLength < 7) throw Reject(DnsReject.BAD_RDATA)
                    val priority = u16()
                    val weight = u16()
                    val port = u16()
                    DnsRecordData.Srv(priority, weight, port, name(limit = end))
                }
                TYPE_TXT -> {
                    if (rdLength > MAX_TXT_BYTES) throw Reject(DnsReject.TXT_TOO_LARGE)
                    offset = end
                    DnsRecordData.Txt(bytes.copyOfRange(start, end))
                }
                else -> {
                    offset = end
                    DnsRecordData.Other(type)
                }
            }
            if (offset != end) throw Reject(DnsReject.BAD_RDATA)
            return DnsRecord(name, type, rawClass and 0x7fff, rawClass and 0x8000 != 0, ttl, data)
        }

        /**
         * Reads one possibly compressed name. [limit] bounds the bytes the name may
         * occupy at the read position (the RDATA end for PTR/SRV); pointer targets are
         * earlier message bytes and are bounded by the backwards rule instead.
         */
        private fun name(limit: Int = length): DnsName {
            val labels = ArrayList<ByteArray>()
            var wire = 1 // the root byte
            var cursor = offset
            var cursorLimit = limit
            var jumped = false
            var pointers = 0
            while (true) {
                if (cursor >= cursorLimit) throw Reject(DnsReject.TRUNCATED)
                val head = bytes[cursor].toInt() and 0xff
                when (head and 0xc0) {
                    0x00 -> {
                        if (head == 0) {
                            if (!jumped) offset = cursor + 1
                            return DnsName(labels)
                        }
                        if (head > cursorLimit - cursor - 1) throw Reject(DnsReject.TRUNCATED)
                        wire += head + 1
                        if (wire > MAX_NAME_WIRE_BYTES) throw Reject(DnsReject.NAME_TOO_LONG)
                        labels += bytes.copyOfRange(cursor + 1, cursor + 1 + head)
                        cursor += head + 1
                    }
                    0xc0 -> {
                        if (cursor + 1 >= cursorLimit) throw Reject(DnsReject.TRUNCATED)
                        val target = ((head and 0x3f) shl 8) or (bytes[cursor + 1].toInt() and 0xff)
                        // Strictly backwards and outside the header: a loop or a
                        // forward reference cannot be followed.
                        if (target < HEADER_BYTES || target >= cursor) throw Reject(DnsReject.BAD_POINTER)
                        if (++pointers > MAX_POINTERS) throw Reject(DnsReject.TOO_MANY_POINTERS)
                        if (!jumped) offset = cursor + 2
                        jumped = true
                        // Earlier bytes may end anywhere before the pointer itself.
                        cursorLimit = cursor
                        cursor = target
                    }
                    else -> throw Reject(DnsReject.BAD_LABEL_TYPE)
                }
            }
        }

        private fun u16(): Int {
            if (length - offset < 2) throw Reject(DnsReject.TRUNCATED)
            val value = ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)
            offset += 2
            return value
        }

        private fun u32(): Long {
            val high = u16().toLong()
            return (high shl 16) or u16().toLong()
        }
    }
}

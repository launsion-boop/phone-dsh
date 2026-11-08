// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * The socket-free half of LAN MCP discovery (`spec/device/v1/lan-mcp.md`): it builds
 * the DNS-SD queries for `_pdsh-mcp._tcp.local.` and folds parsed responses into
 * candidates through [LanDiscoveryDecoder].
 *
 * What reaches the decoder is exactly what the profile asks for: the instance label
 * (strict UTF-8), the SRV target as DNS labels (never a resolved address) and the
 * TXT RDATA bytes unchanged. Nothing here connects, authorizes, or stores.
 *
 * Bounds and failure rules:
 *  * at most [maxInstances] instances are tracked; further names are ignored;
 *  * a record is kept for its TTL (capped at [MAX_TTL_SECONDS]); a TTL of 0 is a
 *    goodbye and removes it at once;
 *  * one datagram carrying two different SRV, or two different TXT, records for
 *    the same instance is ambiguous: the instance's stored value of that type is
 *    dropped rather than picking one (fail closed). A later unambiguous answer
 *    may restore it;
 *  * only class IN records whose owner is exactly `<one label>._pdsh-mcp._tcp.local.`
 *    are considered; everything else in the datagram is ignored;
 *  * an instance is created only by a PTR answer for the service type. SRV/TXT for
 *    a name nobody browsed to are ignored, so unsolicited records cannot occupy
 *    the instance budget. PTRs are applied before SRV/TXT of the same datagram,
 *    so record order inside a response does not matter.
 *
 * Not thread-safe: one scan owns one browser.
 */
public class LanMdnsBrowser(private val maxInstances: Int = 100) {
    init {
        require(maxInstances > 0)
    }

    private class Instance(var label: ByteArray, val name: DnsName) {
        var ptrExpiry: Long? = null
        var srv: Pair<DnsRecordData.Srv, Long>? = null
        var txt: Pair<ByteArray, Long>? = null
    }

    private val instances = LinkedHashMap<String, Instance>()

    /** Every instance the browser currently tracks, including incomplete ones. */
    public val trackedCount: Int get() = instances.size

    /**
     * Folds one parsed response in. Returns true when the stored state changed.
     * [nowMs] is a monotonic clock reading supplied by the caller.
     */
    public fun accept(message: DnsMessage, nowMs: Long): Boolean {
        var changed = false
        val srvSeen = HashMap<String, MutableSet<DnsRecordData.Srv>>()
        val txtSeen = HashMap<String, MutableSet<DnsRecordData.Txt>>()
        val txtTtl = HashMap<String, Long>()
        val srvTtl = HashMap<String, Long>()
        for (record in message.records) {
            if (record.dnsClass != DnsMessageParser.CLASS_IN) continue
            when (val data = record.data) {
                is DnsRecordData.Ptr -> {
                    if (!record.name.equalsIgnoreAsciiCase(SERVICE_TYPE)) continue
                    val label = instanceLabel(data.target) ?: continue
                    val key = data.target.key
                    if (record.ttlSeconds == 0L) {
                        if (instances.remove(key) != null) changed = true
                        continue
                    }
                    val instance = instances[key] ?: newInstance(label, data.target, key) ?: continue
                    instance.label = label
                    instance.ptrExpiry = expiry(nowMs, record.ttlSeconds)
                    changed = true
                }
                is DnsRecordData.Srv -> {
                    if (instanceLabel(record.name) == null) continue
                    srvSeen.getOrPut(record.name.key) { LinkedHashSet() } += data
                    srvTtl[record.name.key] = record.ttlSeconds
                }
                is DnsRecordData.Txt -> {
                    if (instanceLabel(record.name) == null) continue
                    txtSeen.getOrPut(record.name.key) { LinkedHashSet() } += data
                    txtTtl[record.name.key] = record.ttlSeconds
                }
                is DnsRecordData.Other -> Unit
            }
        }
        for ((key, values) in srvSeen) {
            val instance = instances[key] ?: continue
            val ttl = srvTtl.getValue(key)
            instance.srv = if (values.size != 1 || ttl == 0L) null else values.single() to expiry(nowMs, ttl)
            changed = true
        }
        for ((key, values) in txtSeen) {
            val instance = instances[key] ?: continue
            val ttl = txtTtl.getValue(key)
            instance.txt = if (values.size != 1 || ttl == 0L) null else values.single().raw to expiry(nowMs, ttl)
            changed = true
        }
        return changed
    }

    /** Validated candidates, sorted by name; expired records do not contribute. */
    public fun candidates(nowMs: Long): List<LanDeviceCandidate> {
        purge(nowMs)
        val out = ArrayList<LanDeviceCandidate>()
        for (instance in instances.values) {
            if (instance.ptrExpiry == null) continue
            val srv = instance.srv?.first ?: continue
            val txt = instance.txt?.first ?: continue
            val service = strictUtf8(instance.label) ?: continue
            val host = srv.target.toHostnameText() ?: continue
            LanDiscoveryDecoder.decode(service, host, srv.port, txt)?.let { out += it }
        }
        return out.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }

    /** Browsed instances still missing an SRV or TXT answer, for a follow-up query. */
    public fun unresolved(nowMs: Long): List<DnsName> {
        purge(nowMs)
        return instances.values.filter { it.ptrExpiry != null && (it.srv == null || it.txt == null) }.map { it.name }
    }

    private fun purge(nowMs: Long) {
        val iterator = instances.values.iterator()
        while (iterator.hasNext()) {
            val instance = iterator.next()
            if (instance.srv?.second?.let { it <= nowMs } == true) instance.srv = null
            if (instance.txt?.second?.let { it <= nowMs } == true) instance.txt = null
            if (instance.ptrExpiry?.let { it <= nowMs } == true) instance.ptrExpiry = null
            if (instance.ptrExpiry == null && instance.srv == null && instance.txt == null) iterator.remove()
        }
    }

    private fun newInstance(label: ByteArray, name: DnsName, key: String): Instance? {
        if (instances.size >= maxInstances) return null
        return Instance(label, name).also { instances[key] = it }
    }

    public companion object {
        /** `_pdsh-mcp._tcp.local.`, the fixed service type of the profile. */
        public val SERVICE_TYPE: DnsName = DnsName.of("_pdsh-mcp", "_tcp", "local")

        public const val MAX_TTL_SECONDS: Long = 4500
        public const val MDNS_PORT: Int = 5353

        /** 224.0.0.251, the IPv4 mDNS group. */
        public val MDNS_IPV4_GROUP: ByteArray = byteArrayOf(224.toByte(), 0, 0, 251.toByte())

        /** A PTR browse query for the service type (RFC 6763 §4.1). */
        public fun browseQuery(id: Int = 0): ByteArray = query(id, listOf(SERVICE_TYPE to DnsMessageParser.TYPE_PTR))

        /** SRV and TXT questions for one instance (RFC 6763 §5). */
        public fun resolveQuery(instance: DnsName, id: Int = 0): ByteArray =
            query(id, listOf(instance to DnsMessageParser.TYPE_SRV, instance to DnsMessageParser.TYPE_TXT))

        private fun query(id: Int, questions: List<Pair<DnsName, Int>>): ByteArray {
            val out = ByteArrayOutputStream()
            fun u16(value: Int) { out.write(value shr 8 and 0xff); out.write(value and 0xff) }
            u16(id and 0xffff)
            u16(0) // standard query, QR=0
            u16(questions.size)
            u16(0); u16(0); u16(0)
            for ((name, type) in questions) {
                name.encode(out)
                u16(type)
                u16(DnsMessageParser.CLASS_IN) // QM: answers go to the group
            }
            return out.toByteArray()
        }

        /**
         * RFC 6762 §11 / §6: a response is considered only when it came from UDP
         * port 5353 and from an IPv4 address on one of the receiving interface's
         * subnets (given as address + prefix length). Anything else is not on-link.
         */
        public fun acceptsSource(address: ByteArray, port: Int, subnets: List<Pair<ByteArray, Int>>): Boolean {
            if (port != MDNS_PORT || address.size != 4) return false
            return subnets.any { (network, prefix) ->
                network.size == 4 && prefix in 1..32 && samePrefix(address, network, prefix)
            }
        }

        private fun samePrefix(a: ByteArray, b: ByteArray, prefix: Int): Boolean {
            val mask = if (prefix == 32) -1 else (-1 shl (32 - prefix))
            return (ByteBuffer.wrap(a).int and mask) == (ByteBuffer.wrap(b).int and mask)
        }

        /** The instance label when [name] is exactly `<label>._pdsh-mcp._tcp.local.`. */
        internal fun instanceLabel(name: DnsName): ByteArray? {
            if (name.labelCount != 4) return null
            val parent = DnsName(listOf(name.label(1), name.label(2), name.label(3)))
            if (!parent.equalsIgnoreAsciiCase(SERVICE_TYPE)) return null
            return name.label(0)
        }

        private fun expiry(nowMs: Long, ttlSeconds: Long): Long = nowMs + ttlSeconds.coerceIn(1, MAX_TTL_SECONDS) * 1000

        private fun strictUtf8(bytes: ByteArray): String? = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}

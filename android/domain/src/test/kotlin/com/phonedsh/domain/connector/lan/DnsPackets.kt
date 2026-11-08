// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import java.io.ByteArrayOutputStream

/**
 * A deliberately literal DNS response writer for tests. It writes exactly what it
 * is told (including malformed lengths), so a test states its wire bytes rather
 * than trusting the parser's own idea of a valid message.
 */
internal class DnsPackets(
    private val flags: Int = 0x8400,
    private val id: Int = 0,
) {
    private val body = ByteArrayOutputStream()
    private var qd = 0
    private var an = 0

    /** Byte offset (in the final message) where the next write lands. */
    val position: Int get() = 12 + body.size()

    fun question(name: List<ByteArray>, type: Int) = apply {
        name(name); u16(type); u16(1); qd++
    }

    fun ptr(owner: List<ByteArray>, target: List<ByteArray>, ttl: Long = 120) = record(owner, 12, ttl) { name(target) }

    fun srv(owner: List<ByteArray>, target: List<ByteArray>, port: Int, ttl: Long = 120, cls: Int = 0x8001) =
        record(owner, 33, ttl, cls) { u16(0); u16(0); u16(port); name(target) }

    fun txt(owner: List<ByteArray>, raw: ByteArray, ttl: Long = 4500, cls: Int = 0x8001) =
        record(owner, 16, ttl, cls) { body.write(raw) }

    fun a(owner: List<ByteArray>, address: ByteArray = byteArrayOf(192.toByte(), 168.toByte(), 1, 2)) =
        record(owner, 1, 120) { body.write(address) }

    /** A record whose RDATA is written by [rdata]; RDLENGTH is computed from what it wrote. */
    fun record(owner: List<ByteArray>, type: Int, ttl: Long, cls: Int = 1, rdata: DnsPackets.() -> Unit) = apply {
        name(owner)
        u16(type); u16(cls); u32(ttl)
        // Write RDATA into a scratch buffer so its length is known (no compression
        // inside RDATA from this helper; compressed cases are written with raw()).
        val inner = DnsPackets()
        inner.rdata()
        val bytes = inner.body.toByteArray()
        u16(bytes.size)
        body.write(bytes)
        an++
    }

    /** Appends raw bytes as they are (for compression pointers and malformed tails). */
    fun raw(vararg bytes: Int) = apply { bytes.forEach { body.write(it and 0xff) } }

    fun rawRecordHeader(type: Int, rdLength: Int, owner: List<ByteArray>) = apply {
        name(owner); u16(type); u16(1); u32(120); u16(rdLength); an++
    }

    fun name(labels: List<ByteArray>) {
        for (label in labels) {
            require(label.size in 1..63) { "unrepresentable label" }
            body.write(label.size)
            body.write(label)
        }
        body.write(0)
    }

    fun u16(value: Int) {
        body.write(value shr 8 and 0xff); body.write(value and 0xff)
    }

    fun u32(value: Long) {
        u16((value shr 16).toInt() and 0xffff); u16(value.toInt() and 0xffff)
    }

    fun build(answerCount: Int = an, questionCount: Int = qd): ByteArray {
        val out = ByteArrayOutputStream()
        fun w(v: Int) { out.write(v shr 8 and 0xff); out.write(v and 0xff) }
        w(id); w(flags); w(questionCount); w(answerCount); w(0); w(0)
        out.write(body.toByteArray())
        return out.toByteArray()
    }

    companion object {
        fun labels(vararg text: String): List<ByteArray> = text.map { it.toByteArray(Charsets.UTF_8) }

        val SERVICE: List<ByteArray> = labels("_pdsh-mcp", "_tcp", "local")

        fun instance(name: String): List<ByteArray> = listOf(name.toByteArray(Charsets.UTF_8)) + SERVICE

        fun host(text: String): List<ByteArray> =
            text.removeSuffix(".").split('.').map { it.toByteArray(Charsets.UTF_8) }

        fun txt(vararg entries: String): ByteArray {
            val out = ByteArrayOutputStream()
            for (entry in entries) {
                val bytes = entry.toByteArray(Charsets.UTF_8)
                out.write(bytes.size); out.write(bytes)
            }
            return out.toByteArray()
        }

        /** A typical complete advertisement: PTR answer, SRV/TXT/A additionals. */
        fun advertisement(
            service: String = "Lamp",
            host: String = "lamp.local.",
            port: Int = 8443,
            txt: ByteArray = txt("profile=pdsh-mcp-1"),
            ttl: Long = 120,
        ): ByteArray = DnsPackets()
            .ptr(SERVICE, instance(service), ttl)
            .srv(instance(service), host(host), port, ttl)
            .txt(instance(service), txt, ttl)
            .a(host(host))
            .build()
    }
}

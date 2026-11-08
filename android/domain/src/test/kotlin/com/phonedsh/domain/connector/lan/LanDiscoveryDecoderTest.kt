// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import com.phonedsh.domain.testing.MiniJson
import java.io.ByteArrayOutputStream
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanDiscoveryDecoderTest {
    private val root = Path.of(System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set"))
    private val profile = txt("profile=pdsh-mcp-1")

    @Test
    fun sharedTextVectorsDriveTheRealDecoder() {
        forEachVector("lan-discovery.jsonl") { row ->
            val raw = ByteArrayOutputStream()
            for (entry in row.getValue("txt_records") as List<*>) {
                val bytes = (entry as String).toByteArray(Charsets.UTF_8)
                require(bytes.size <= 255)
                raw.write(bytes.size)
                raw.write(bytes)
            }
            assertVector(row, raw.toByteArray())
        }
    }

    @Test
    fun sharedRawVectorsDriveTheRealDecoder() {
        // Retain named security and compatibility cases: a truncated fixture or
        // one stripped of invalid inputs must not turn this test green.
        val required = mapOf(
            "valid" to true,
            "case_and_binary_unknown" to true,
            "numeric_label_named_domain" to true,
            "hex_label_named_domain" to true,
            "truncated" to false,
            "duplicate_case" to false,
            "unicode_kelvin_casefold" to false,
            "ipv4_dotted" to false,
            "ipv4_short" to false,
            "ipv4_integer" to false,
            "ipv4_hex" to false,
            "ipv4_mixed_hex" to false,
            "numeric_leading_zero" to false,
            "numeric_out_of_range" to false,
            "numeric_hostname" to false,
            "hex_prefix_only" to false,
            "hex_prefix_short" to false,
            "ipv4_hex_empty_final" to false,
            "named_numeric_final" to false,
            "named_hex_prefix_final" to false,
            "named_hex_final" to false,
        )
        val seen = mutableSetOf<String>()
        var positives = 0
        var negatives = 0
        forEachVector("lan-discovery-raw.jsonl") { row ->
            val name = row.getValue("name") as String
            assertTrue("duplicate raw vector name: $name", seen.add(name))
            assertVector(row, decodeHex(row.getValue("txt_hex") as String))
            val hasURL = row.containsKey("url")
            if (hasURL) positives++ else negatives++
            required[name]?.let { expected -> assertEquals("$name: changed outcome", expected, hasURL) }
        }
        assertTrue("raw fixtures need a positive case", positives > 0)
        assertTrue("raw fixtures need a negative case", negatives > 0)
        assertTrue("missing required raw vectors: ${required.keys - seen}", seen.containsAll(required.keys))
    }

    @Test
    fun strictTxtFramingAndProfileSemantics() {
        fun candidate(raw: ByteArray) = LanDiscoveryDecoder.decode("Device", "light.example.", 443, raw)
        assertNotNull(candidate(byteArrayOf(0) + profile))
        assertNotNull(candidate(byteArrayOf(1, 0xff.toByte()) + txt("PrOfIlE=pdsh-mcp-1")))
        assertNull(candidate(profile + txt("PROFILE=pdsh-mcp-1")))
        assertNull(candidate(txt("profile")))
        assertNull(candidate(txt("profile=")))
        assertNull(candidate(txt("profile=pdsh-mcp-1=extra")))
        assertNull(candidate(txt("profile=PDSH-MCP-1")))
        assertNull(candidate(byteArrayOf(0xff.toByte(), 1)))
        assertNull(candidate(profile + byteArrayOf(2, 0x61)))
        assertNull(candidate(byteArrayOf(9) + "profile=".toByteArray() + byteArrayOf(0xff.toByte())))
    }

    @Test
    fun hostnameServiceAndPortBoundaries() {
        fun candidate(service: String = "A", host: String = "a.example.", port: Int = 443) =
            LanDiscoveryDecoder.decode(service, host, port, profile)
        assertEquals("https://a.example/mcp", candidate(host = "A.Example.")?.url)
        assertEquals("https://a.example:1/mcp", candidate(port = 1)?.url)
        assertEquals("https://a.example:65535/mcp", candidate(port = 65535)?.url)
        assertNull(candidate(port = 0))
        assertNull(candidate(port = 65536))
        assertNotNull(candidate(host = "a".repeat(63) + ".example."))
        assertNull(candidate(host = "a".repeat(64) + ".example."))
        assertNull(candidate(host = "a..example"))
        assertNull(candidate(host = "-a.example"))
        assertNull(candidate(host = "a-.example"))
        assertNull(candidate(host = "a.example.."))
        assertNull(candidate(host = "a.example/path"))
        assertNull(candidate(host = "lämp.example"))
        assertNull(candidate(host = "a.example:443"))
        assertNull(candidate(host = "K.example"))
        assertNull(candidate(host = "192.168.1.2"))
        assertNull(candidate(host = "127.1"))
        assertNull(candidate(host = "2130706433"))
        assertNull(candidate(host = "0x7f000001"))
        assertNull(candidate(host = "0X"))
        assertNull(candidate(host = "device.123"))
        assertNull(candidate(host = "999.999.999.999"))
        assertNotNull(candidate(host = "123.example"))
        assertNotNull(candidate(host = "0x.example"))
        assertNotNull(candidate(host = "example.0x-not-hex"))
        val longestHost = listOf("a".repeat(63), "b".repeat(63), "c".repeat(63), "d".repeat(61)).joinToString(".")
        assertEquals(253, longestHost.length)
        assertNotNull(candidate(host = "$longestHost."))
        assertNull(candidate(host = longestHost + "x"))
        assertNotNull(candidate(service = "界".repeat(21)))
        assertNull(candidate(service = "界".repeat(22)))
        assertNull(candidate(service = ""))
        assertNull(candidate(service = "\uD800"))
    }

    private fun forEachVector(name: String, block: (Map<String, Any?>) -> Unit) {
        val path = root.resolve("spec/device/v1/golden/$name")
        val lines = path.toFile().readLines().filter { it.isNotBlank() }
        require(lines.isNotEmpty()) { "no vectors: $path" }
        lines.forEach { block(MiniJson.parseObject(it)) }
    }

    private fun assertVector(row: Map<String, Any?>, raw: ByteArray) {
        val name = row.getValue("name") as String
        val candidate = LanDiscoveryDecoder.decode(
            service = row.getValue("service") as String,
            host = row.getValue("host") as String,
            port = (row.getValue("port") as Number).toInt(),
            txt = raw,
        )
        val hasURL = row.containsKey("url")
        val hasError = row.containsKey("error")
        assertTrue("$name: fixture must specify exactly one outcome", hasURL xor hasError)
        if (hasError) {
            assertEquals(name, "invalid_advertisement", row["error"])
            assertNull(name, candidate)
        } else {
            assertEquals(name, row.getValue("url") as String, candidate?.url)
            assertEquals(name, row.getValue("service"), candidate?.name)
        }
    }

    private fun txt(entry: String): ByteArray {
        val bytes = entry.toByteArray(Charsets.UTF_8)
        require(bytes.size <= 255)
        return byteArrayOf(bytes.size.toByte()) + bytes
    }

    private fun decodeHex(hex: String): ByteArray {
        require(hex.length % 2 == 0)
        return ByteArray(hex.length / 2) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }
}

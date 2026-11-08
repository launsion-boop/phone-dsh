// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import com.phonedsh.domain.connector.lan.DnsPackets.Companion.SERVICE
import com.phonedsh.domain.connector.lan.DnsPackets.Companion.host
import com.phonedsh.domain.connector.lan.DnsPackets.Companion.instance
import com.phonedsh.domain.connector.lan.DnsPackets.Companion.txt
import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Path
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LanMdnsBrowserTest {
    private val root = Path.of(System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set"))

    private fun parse(bytes: ByteArray): DnsMessage =
        (DnsMessageParser.parse(bytes) as? DnsParseResult.Ok)?.message ?: throw AssertionError("rejected")

    private fun browse(vararg datagrams: ByteArray, now: Long = 0): LanMdnsBrowser =
        LanMdnsBrowser().also { browser -> datagrams.forEach { browser.accept(parse(it), now) } }

    /**
     * The shared P07 vectors, carried through real DNS wire bytes: the instance
     * label, SRV target labels, port and TXT RDATA go into a response, the real
     * parser reads it, and the real browser hands the result to the decoder.
     * A vector whose fields cannot be expressed on the wire at all (an empty or
     * >63-byte label, a port above 65535) can never arrive this way; those must
     * be expected errors, which the test asserts instead of skipping silently.
     */
    @Test
    fun sharedVectorsDriveParserBrowserAndDecoderTogether() {
        var carried = 0
        var unrepresentable = 0
        for (file in listOf("lan-discovery.jsonl", "lan-discovery-raw.jsonl")) {
            for (row in vectors(file)) {
                val name = "$file:${row["name"]}"
                val service = row.getValue("service") as String
                val hostText = row.getValue("host") as String
                val port = (row.getValue("port") as Number).toInt()
                val raw = row["txt_hex"]?.let { hex(it as String) }
                    ?: txt(*(row.getValue("txt_records") as List<*>).map { it as String }.toTypedArray())
                val serviceBytes = service.toByteArray(Charsets.UTF_8)
                val hostLabels = host(hostText)
                val representable = serviceBytes.size in 1..63 && port in 0..65535 &&
                    hostLabels.all { it.size in 1..63 } && hostLabels.sumOf { it.size + 1 } + 1 <= 255
                if (!representable) {
                    assertTrue("$name: unrepresentable on the wire but expects success", row.containsKey("error"))
                    unrepresentable++
                    continue
                }
                val candidates = browse(DnsPackets.advertisement(service, hostText, port, raw)).candidates(0)
                if (row.containsKey("url")) {
                    assertEquals(name, listOf(row["url"]), candidates.map { it.url })
                    assertEquals(name, service, candidates.single().name)
                } else {
                    assertEquals(name, emptyList<LanDeviceCandidate>(), candidates)
                }
                carried++
            }
        }
        assertTrue("most vectors must travel through DNS bytes", carried >= 30)
        assertTrue(unrepresentable in 1..6)
    }

    @Test
    fun recordOrderInsideOneResponseDoesNotMatter() {
        val packets = DnsPackets()
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .ptr(SERVICE, instance("Lamp"))
            .build()
        assertEquals(listOf("https://lamp.local/mcp"), browse(packets).candidates(0).map { it.url })
    }

    @Test
    fun twoDifferentTxtOrSrvRecordsForOneInstanceFailClosed() {
        val twoTxt = DnsPackets()
            .ptr(SERVICE, instance("Lamp"))
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .txt(instance("Lamp"), txt("PROFILE=pdsh-mcp-1"))
            .build()
        val browser = browse(twoTxt)
        assertEquals(emptyList<LanDeviceCandidate>(), browser.candidates(0))
        // An unambiguous later answer restores it.
        browser.accept(parse(DnsPackets.advertisement(port = 443)), 0)
        assertEquals(1, browser.candidates(0).size)

        val twoSrv = DnsPackets()
            .ptr(SERVICE, instance("Lamp"))
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .srv(instance("Lamp"), host("evil.local"), 443)
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .build()
        browser.accept(parse(twoSrv), 0)
        assertEquals(emptyList<LanDeviceCandidate>(), browser.candidates(0))

        // The same record twice (a duplicate RR) is not ambiguous.
        val repeated = DnsPackets()
            .ptr(SERVICE, instance("Lamp"))
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .build()
        browser.accept(parse(repeated), 0)
        assertEquals(1, browser.candidates(0).size)
    }

    @Test
    fun goodbyeAndTtlExpiryRemoveCandidates() {
        val browser = browse(DnsPackets.advertisement(ttl = 10))
        assertEquals(1, browser.candidates(9_999).size)
        assertEquals(0, browser.candidates(10_000).size)
        assertEquals(0, browser.trackedCount)

        browser.accept(parse(DnsPackets.advertisement(ttl = 120)), 0)
        assertEquals(1, browser.candidates(0).size)
        browser.accept(parse(DnsPackets().ptr(SERVICE, instance("lamp"), ttl = 0).build()), 1)
        assertEquals("goodbye matches the instance case-insensitively", 0, browser.candidates(1).size)
    }

    @Test
    fun unsolicitedRecordsAndOtherNamesAreIgnored() {
        val noPtr = DnsPackets()
            .srv(instance("Lamp"), host("lamp.local"), 443)
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .build()
        val browser = browse(noPtr)
        assertEquals(0, browser.trackedCount)

        val otherType = DnsPackets()
            .ptr(DnsPackets.labels("_http", "_tcp", "local"), DnsPackets.labels("Lamp", "_http", "_tcp", "local"))
            .build()
        browser.accept(parse(otherType), 0)
        assertEquals(0, browser.trackedCount)

        // A PTR whose target is not an instance of the service type.
        val strayTarget = DnsPackets().ptr(SERVICE, DnsPackets.labels("Lamp", "_other", "_tcp", "local")).build()
        browser.accept(parse(strayTarget), 0)
        assertEquals(0, browser.trackedCount)

        // A non-IN class is ignored.
        val chaos = DnsPackets()
            .record(SERVICE, 12, 120, cls = 3) { name(instance("Lamp")) }
            .build()
        browser.accept(parse(chaos), 0)
        assertEquals(0, browser.trackedCount)
    }

    @Test
    fun hostileNamesNeverBecomeCandidates() {
        // Instance label that is not UTF-8.
        val badLabel = DnsPackets()
            .ptr(SERVICE, listOf(byteArrayOf(0xff.toByte())) + SERVICE)
            .srv(listOf(byteArrayOf(0xff.toByte())) + SERVICE, host("lamp.local"), 443)
            .txt(listOf(byteArrayOf(0xff.toByte())) + SERVICE, txt("profile=pdsh-mcp-1"))
            .build()
        assertEquals(emptyList<LanDeviceCandidate>(), browse(badLabel).candidates(0))
        // SRV target whose single label contains a dot: "lamp.local" as ONE label.
        val dotted = DnsPackets()
            .ptr(SERVICE, instance("Lamp"))
            .srv(instance("Lamp"), listOf("lamp.local".toByteArray()), 443)
            .txt(instance("Lamp"), txt("profile=pdsh-mcp-1"))
            .build()
        assertEquals(emptyList<LanDeviceCandidate>(), browse(dotted).candidates(0))
        // The SRV target is used, never an A record's address.
        val ipTarget = DnsPackets.advertisement(host = "192.168.1.2")
        assertEquals(emptyList<LanDeviceCandidate>(), browse(ipTarget).candidates(0))
    }

    @Test
    fun instanceBudgetIsHard() {
        val browser = LanMdnsBrowser(maxInstances = 3)
        for (index in 0 until 10) browser.accept(parse(DnsPackets.advertisement(service = "D$index")), 0)
        assertEquals(3, browser.trackedCount)
        assertEquals(listOf("D0", "D1", "D2"), browser.candidates(0).map { it.name })
    }

    @Test
    fun unresolvedListsBrowsedInstancesMissingSrvOrTxt() {
        val browser = browse(DnsPackets().ptr(SERVICE, instance("Lamp")).build())
        assertEquals(1, browser.unresolved(0).size)
        assertTrue(browser.unresolved(0).single().equalsIgnoreAsciiCase(DnsName(instance("Lamp"))))
        browser.accept(parse(DnsPackets.advertisement()), 0)
        assertEquals(0, browser.unresolved(0).size)
    }

    @Test
    fun queriesAreExactWireBytes() {
        val expected = hex(
            "1234" + "0000" + "0001" + "0000" + "0000" + "0000" +
                "095f706473682d6d6370045f746370056c6f63616c00" + "000c" + "0001",
        )
        assertArrayEquals(expected, LanMdnsBrowser.browseQuery(0x1234))
        val resolve = LanMdnsBrowser.resolveQuery(DnsName(instance("Lamp")))
        assertEquals(2, ((resolve[4].toInt() and 0xff) shl 8) or (resolve[5].toInt() and 0xff))
        // The query itself is not a response: the parser would refuse to read it as one.
        assertTrue(DnsMessageParser.parse(resolve) is DnsParseResult.Rejected)
    }

    @Test
    fun sourceMustBePort5353AndOnLink() {
        val subnet = listOf(byteArrayOf(192.toByte(), 168.toByte(), 6, 0) to 24)
        val onLink = byteArrayOf(192.toByte(), 168.toByte(), 6, 106)
        assertTrue(LanMdnsBrowser.acceptsSource(onLink, 5353, subnet))
        assertTrue(!LanMdnsBrowser.acceptsSource(onLink, 5354, subnet))
        assertTrue(!LanMdnsBrowser.acceptsSource(byteArrayOf(192.toByte(), 168.toByte(), 7, 1), 5353, subnet))
        assertTrue(!LanMdnsBrowser.acceptsSource(ByteArray(16), 5353, subnet))
        assertTrue(!LanMdnsBrowser.acceptsSource(onLink, 5353, emptyList()))
        assertTrue(LanMdnsBrowser.acceptsSource(onLink, 5353, listOf(onLink to 32)))
    }

    private fun vectors(name: String): List<Map<String, Any?>> =
        root.resolve("spec/device/v1/golden/$name").toFile().readLines().filter { it.isNotBlank() }
            .map { MiniJson.parseObject(it) }
            .also { require(it.isNotEmpty()) }

    private fun hex(text: String): ByteArray =
        ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

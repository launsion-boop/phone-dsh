// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.gateway.GatewayTransport
import com.phonedsh.gateway.GatewayTransportRequest
import com.phonedsh.gateway.GatewayTransportResponse
import com.phonedsh.loopback.LoopbackHttpRequest
import com.phonedsh.ui.page.EgressAllowListScreenState
import com.phonedsh.ui.page.EgressStatus
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NetworkAccessSettingsTest {
    @get:Rule val directory = TemporaryFolder()
    private val file get() = File(directory.root, "settings.json")
    private val fixture get() = JSONObject(File(System.getProperty("pdsh.repo.root"),
        "spec/ui/v1/fixtures/mobile-egress-settings.json").readText())

    private fun values(key: String): List<String> {
        val items = fixture.getJSONArray(key)
        return List(items.length()) { items.getString(it) }
    }
    private fun hosts(settings: NetworkAccessSettings) = settings.facts.value.rules?.map { it.host }
    private fun request(host: String, method: String = "GET", body: ByteArray = byteArrayOf(),
                        extra: Map<String, String> = emptyMap()): LoopbackHttpRequest {
        val url = "https://$host/read"
        return LoopbackHttpRequest("POST", url, method, mapOf("x-pdsh-target-url" to url) + extra, body)
    }

    @Test fun confirmedEditsStashRestoreAndInvalidInputs() {
        val settings = NetworkAccessSettings(file)
        assertEquals(values("defaults"), hosts(settings))
        for (host in values("invalid")) settings.add(host)
        assertEquals(values("defaults"), hosts(settings))
        for (host in values("valid")) settings.add(host)
        settings.add(" EXAMPLE.ORG ")
        assertEquals(values("defaults") + values("valid"), hosts(NetworkAccessSettings(file)))
        settings.toggle(true)
        val reopened = NetworkAccessSettings(file)
        assertTrue(EgressAllowListScreenState.from(reopened.facts.value).allowAll)
        reopened.remove("example.org")
        reopened.toggle(false)
        assertEquals(values("defaults") + "*.example.org", hosts(reopened))
        hosts(reopened)!!.forEach(reopened::remove)
        assertEquals(EgressStatus.DENY_ALL, EgressAllowListScreenState.from(NetworkAccessSettings(file).facts.value).status)
        reopened.restore()
        assertEquals(values("defaults"), hosts(NetworkAccessSettings(file)))
    }

    @Test fun internationalDomainsAndAbsoluteDnsNamesRoundTripWithoutAliases() {
        val store = NetworkAccessSettings(file)
        val cases = fixture.getJSONObject("normalized")
        for (input in cases.keys()) {
            val expected = cases.getString(input)
            store.add(input)
            store.add(expected)
            assertEquals(1, hosts(NetworkAccessSettings(file))!!.count { it == expected })
        }
    }

    @Test fun gatewayUsesTheStoredListForInitialRequestsAndRedirectsWithoutCredentials() {
        val settings = NetworkAccessSettings(file)
        val calls = mutableListOf<GatewayTransportRequest>()
        val transport = object : GatewayTransport {
            override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                calls += request
                return if (request.url.contains("redirect.example.org")) {
                    settings.remove("destination.example.org")
                    GatewayTransportResponse(302, mapOf("location" to "https://destination.example.org/read"))
                } else GatewayTransportResponse(200)
            }
        }
        val gateway = GatewayHttpEgress(settings.readGateway(transport))
        val target = "new.example.org"
        assertEquals(403, gateway.handle(request(target)).status)
        settings.add(target)
        for (method in listOf("POST", "PUT", "DELETE")) assertEquals(403, gateway.handle(request(target, method)).status)
        assertEquals(403, gateway.handle(request(target, body = byteArrayOf(1))).status)
        assertEquals(403, gateway.handle(request(target, extra = mapOf("X-HTTP-Method-Override" to "DELETE"))).status)
        assertTrue(calls.isEmpty())
        assertEquals(200, gateway.handle(request(target, extra = mapOf("authorization" to "synthetic"))).status)
        assertTrue(calls.single().headers.keys.none { it.equals("authorization", true) })
        settings.remove(target)
        assertEquals(403, gateway.handle(request(target)).status)
        settings.toggle(true)
        assertEquals(200, gateway.handle(request(target, "HEAD")).status)
        settings.toggle(false)
        assertEquals(403, gateway.handle(request(target)).status)
        settings.add("redirect.example.org")
        settings.add("destination.example.org")
        val res = gateway.handle(request("redirect.example.org"))
        assertEquals(302, res.status)
        assertTrue(calls.none { it.url.contains("destination.example.org") })
    }

    @Test fun approvedWriteContactsOnlyTheApprovedHostAndMethod() {
        val settings = NetworkAccessSettings(file)
        settings.add("first.example.org")
        settings.add("second.example.org")
        val approvals = mutableListOf<String>()
        val calls = mutableListOf<GatewayTransportRequest>()
        val transport = object : GatewayTransport {
            override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                calls += request
                return GatewayTransportResponse(307, mapOf("Location" to "https://second.example.org/path"))
            }
        }
        val gateway = GatewayHttpEgress(settings.readGateway(transport) { method, url ->
            approvals += "$method ${url.host}"
            null
        })
        assertEquals(403, gateway.handle(request("third.example.org", "PUT")).status)
        assertEquals(403, gateway.handle(request("first.example.org", "GET", byteArrayOf(1))).status)
        assertEquals(403, gateway.handle(request("first.example.org", "POST", extra = mapOf("X-HTTP-Method-Override" to "DELETE"))).status)
        assertEquals(307, gateway.handle(request("first.example.org", "PATCH", byteArrayOf(1))).status)
        assertEquals(listOf("PATCH first.example.org"), approvals)
        assertEquals("PATCH", calls.single().method)
        assertArrayEquals(byteArrayOf(1), calls.single().body)
    }

    @Test fun failedEditDoesNotPublishAnUnconfirmedPermissionAndRetryReadsOldFile() {
        val parent = directory.newFolder("product")
        val store = NetworkAccessSettings(File(parent, "rules.json"))
        store.add("before.example.org")
        val preserved = File(directory.root, "preserved")
        assertTrue(parent.renameTo(preserved))
        parent.writeText("not a directory")
        store.toggle(true)
        assertEquals(EgressStatus.FAILED, EgressAllowListScreenState.from(store.facts.value).status)
        assertEquals(403, GatewayHttpEgress(store.readGateway()).handle(request("example.com")).status)
        assertTrue(parent.delete())
        assertTrue(preserved.renameTo(parent))
        store.refresh()
        assertFalse(EgressAllowListScreenState.from(store.facts.value).allowAll)
        assertTrue("before.example.org" in hosts(store).orEmpty())
    }

    @Test fun concurrentEditsUseTheLastCommittedList() {
        val store = NetworkAccessSettings(file)
        val names = List(6) { "added$it.example.org" }
        val gate = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(3)
        try {
            val jobs = names.map { host ->
                pool.submit { gate.await(); store.add(host) }
            }
            gate.countDown()
            jobs.forEach { it.get(10, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }
        assertEquals((values("defaults") + names).toSet(), hosts(NetworkAccessSettings(file))!!.toSet())
    }

    @Test fun malformedOrUnknownDiskDataCannotBecomeAnAllowAllOrTheDefaultList() {
        val settings = NetworkAccessSettings(file)
        for (bytes in listOf("broken", """{"version":2,"hosts":[],"allowAll":true}""",
                """{"version":1,"hosts":["*"],"allowAll":false}""")) {
            file.writeText(bytes)
            settings.refresh()
            assertEquals(EgressStatus.FAILED, EgressAllowListScreenState.from(settings.facts.value).status)
            assertEquals(403, GatewayHttpEgress(settings.readGateway()).handle(request("example.com")).status)
            settings.add("example.org")
            assertEquals(bytes, file.readText())
        }
    }
}

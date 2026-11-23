// SPDX-License-Identifier: MIT
package com.phonedsh.gateway

import com.phonedsh.loopback.LoopbackServer
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DisconnectedWriteTest {
    @get:Rule val root = TemporaryFolder()

    @Test fun disconnectWhileWaitingPreventsLateApprovedTransport() {
        val contacts = AtomicInteger()
        val pending = CountDownLatch(1)
        val allow = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val peer = AtomicReference<() -> Boolean>()
        val gateway = GatewaySession(
            object : GatewayTransport {
                override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                    contacts.incrementAndGet()
                    return GatewayTransportResponse(200)
                }
            }, { GatewayCredential.None },
            AllowListEgressPolicy(listOf(checkNotNull(GatewayHostRule.parse("qa.example")))),
            anonymousReadsOnly = true,
            approveWrite = { _, _, connected ->
                peer.set(checkNotNull(connected))
                pending.countDown()
                check(allow.await(5, TimeUnit.SECONDS))
                null
            },
        )
        val egress = GatewayHttpEgress(gateway)
        LoopbackServer(httpEgress = { request -> try { egress.handle(request) } finally { finished.countDown() } }).use { server ->
            val endpoint = server.start(root.root.toPath())
            try {
                Socket("127.0.0.1", endpoint.port).use { socket ->
                    socket.setSoLinger(true, 0)
                    val request = "POST /v1/http HTTP/1.1\r\nHost: 127.0.0.1:${endpoint.port}\r\n" +
                        "Authorization: Bearer ${endpoint.token}\r\nX-PDSH-Target-URL: https://qa.example/path\r\nContent-Length: 0\r\n\r\n"
                    socket.getOutputStream().write(request.toByteArray())
                    assertTrue(pending.await(5, TimeUnit.SECONDS))
                    assertTrue(peer.get().invoke())
                }
                val limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
                while (peer.get().invoke() && System.nanoTime() < limit) Thread.sleep(10)
                assertFalse("downstream reset must reach the live request", peer.get().invoke())
            } finally { allow.countDown() }
            assertTrue(finished.await(4, TimeUnit.SECONDS))
            assertEquals(0, contacts.get())
        }
    }
}

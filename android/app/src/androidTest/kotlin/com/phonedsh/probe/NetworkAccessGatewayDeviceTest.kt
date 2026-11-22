// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.loopback.LoopbackServer
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URL
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** Exercise both real sockets on the emulator; no remote service or device credentials are needed. */
@RunWith(AndroidJUnit4::class)
class NetworkAccessGatewayDeviceTest {
    @Test fun authenticatedLoopbackAppliesCommittedEditsWithoutRestartingItsListener() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = Files.createTempDirectory(context.cacheDir.toPath(), "network-settings-test")
        val executor = Executors.newSingleThreadExecutor()
        try {
            val settings = NetworkAccessSettings(root.resolve("settings.json").toFile())
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { target ->
                val upstream = executor.submit<String> {
                    target.accept().use { socket ->
                        val reader = socket.getInputStream().bufferedReader()
                        val line = reader.readLine()
                        while (!reader.readLine().isNullOrEmpty()) { /* consume headers */ }
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                        line
                    }
                }
                LoopbackServer(httpEgress = GatewayHttpEgress(settings.readGateway())).use { server ->
                    val endpoint = server.start(root)
                    fun read(): Int {
                        val connection = URL(endpoint.urlFor("/v1/http")).openConnection() as HttpURLConnection
                        return try {
                            connection.connectTimeout = 5000
                            connection.readTimeout = 5000
                            connection.setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                            connection.setRequestProperty("X-PDSH-Target-URL", "http://127.0.0.1:${target.localPort}/health")
                            connection.responseCode
                        } finally { connection.disconnect() }
                    }
                    assertEquals(403, read())
                    settings.add("127.0.0.1")
                    assertEquals(200, read())
                    assertEquals("GET /health HTTP/1.1", upstream.get(5, TimeUnit.SECONDS))
                    settings.remove("127.0.0.1")
                    assertEquals(403, read())
                }
            }
        } finally {
            executor.shutdownNow()
            root.toFile().deleteRecursively()
        }
    }
}

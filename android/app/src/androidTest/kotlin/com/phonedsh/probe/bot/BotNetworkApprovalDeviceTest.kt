// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.app.Application
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.gateway.GatewayHttpEgress
import kotlinx.coroutines.async
import com.phonedsh.probe.MainActivity
import com.phonedsh.probe.NetworkAccessSettings
import com.phonedsh.probe.ProbeEngineViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class BotNetworkApprovalDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private suspend fun tap(label: String) {
        val deadline = android.os.SystemClock.elapsedRealtime() + 25000
        var visible = emptyList<String>()
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            instrumentation.uiAutomation.rootInActiveWindow?.let(queue::add)
            val labels = mutableListOf<String>()
            while (queue.isNotEmpty()) {
                val item = queue.removeFirst()
                for (index in 0 until item.childCount) item.getChild(index)?.let(queue::add)
                for (text in listOfNotNull(item.text?.toString(), item.contentDescription?.toString())) {
                    labels += text
                    if (text != label) continue
                    var node: AccessibilityNodeInfo? = item
                    while (node != null && !node.isClickable) node = node.parent
                    if (node != null) {
                        if (InstrumentationRegistry.getArguments().getString("recordDemo") == "true") delay(1400)
                        if (node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return
                    }
                }
            }
            visible = labels
            delay(180)
        }
        fail("Cannot tap $label. Visible controls: ${visible.joinToString()}")
    }

    @Test fun timelyApprovalContinuesOnlyTheOriginalRequest() = runBlocking {
        val app = instrumentation.targetContext.applicationContext as Application
        ActivityScenario.launch(MainActivity::class.java).use {
            val engine = ProbeEngineViewModel.sharedHost(app)
            withTimeout(60000) { engine.botPlatformConfig.filterNotNull().first() }
            val botName = "审批验证-" + UUID.randomUUID().toString().take(6)
            engine.handleBotDrawer(com.phonedsh.ui.bot.state.BotDrawerIntent.Create(botName,
                com.phonedsh.bot.profile.BotFishColor.TEAL, com.phonedsh.bot.profile.BotFishHairstyle.BOB))
            val config = withTimeout(30000) { engine.botPlatformConfig.filterNotNull().first { it.context.botName == botName } }
            engine.start()
            withTimeout(60000) { engine.workerReady.first { it } }
            (config.driver as AppBotChatDriver).startMainSession()

            val file = File.createTempFile("approval-test", ".json", app.cacheDir).apply { delete() }
            try {
                val policy = NetworkAccessSettings(file)
                policy.add("127.0.0.1")
                val actor = checkNotNull(engine.appBotRuntime?.egress)
                val gateway = GatewayHttpEgress(policy.readGateway { method, url, connected ->
                    actor.check(method, url, false, connected)
                })
                java.net.ServerSocket(0, 2, java.net.InetAddress.getByName("127.0.0.1")).use { upstream ->
                    upstream.soTimeout = 24000
                    val target = "http://127.0.0.1:${upstream.localPort}/receipt"
                    com.phonedsh.loopback.LoopbackServer(httpEgress = gateway).use { server ->
                        val endpoint = server.start(app.cacheDir.toPath())
                        fun post(body: String) = async(kotlinx.coroutines.Dispatchers.IO) {
                            val connection = java.net.URL(endpoint.urlFor("/v1/http")).openConnection() as java.net.HttpURLConnection
                            try {
                                connection.requestMethod = "POST"
                                connection.readTimeout = 25000
                                connection.setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                                connection.setRequestProperty(GatewayHttpEgress.TARGET_URL, target)
                                connection.setFixedLengthStreamingMode(body.length)
                                connection.doOutput = true
                                connection.outputStream.use { it.write(body.toByteArray()) }
                                val status = connection.responseCode
                                val reply = if (status == 200) connection.inputStream.bufferedReader().use { it.readText() } else ""
                                status to reply
                            } finally { connection.disconnect() }
                        }
                        val received = async(kotlinx.coroutines.Dispatchers.IO) {
                            upstream.accept().use { socket ->
                                val reader = socket.getInputStream().bufferedReader()
                                assertEquals("POST /receipt HTTP/1.1", reader.readLine())
                                var length = 0
                                while (true) {
                                    val header = reader.readLine() ?: error("incomplete request")
                                    if (header.isEmpty()) break
                                    if (header.startsWith("Content-Length:", ignoreCase = true)) length = header.substringAfter(':').trim().toInt()
                                }
                                val body = buildString { repeat(length) { append(reader.read().toChar()) } }
                                val reply = "receipt:$body"
                                socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Length: ${reply.length}\r\nConnection: close\r\n\r\n" + reply).toByteArray())
                                body
                            }
                        }
                        android.util.Log.i("BotApprovalDeviceTest", "Starting the live HTTP comparison")
                        val refused = post("denied-simulator-body")
                        tap("拒绝")
                        assertEquals(403, refused.await().first)
                        assertFalse(received.isCompleted)
                        delay(1000)
                        val original = post("approved-simulator-body")
                        tap("允许一次")
                        assertEquals(200 to "receipt:approved-simulator-body", original.await())
                        assertEquals("approved-simulator-body", received.await())
                        delay(900)
                        val again = post("consumed-grant")
                        tap("拒绝")
                        assertEquals(403, again.await().first)
                        upstream.soTimeout = 500
                        assertThrows(java.net.SocketTimeoutException::class.java) { upstream.accept().close() }
                    }
                }
            } finally { file.delete() }
        }
        Unit
    }
}

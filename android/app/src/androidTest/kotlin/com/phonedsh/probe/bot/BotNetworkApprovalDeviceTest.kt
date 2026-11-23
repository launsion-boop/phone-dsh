// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.app.Application
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.gateway.GatewayTransport
import com.phonedsh.gateway.GatewayTransportRequest
import com.phonedsh.gateway.GatewayTransportResponse
import com.phonedsh.loopback.LoopbackHttpRequest
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
                    if (node?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return
                }
            }
            visible = labels
            delay(180)
        }
        fail("Cannot tap $label. Visible controls: ${visible.joinToString()}")
    }

    @Test fun durableApprovalCardAuthorizesOneRetry() = runBlocking {
        val app = instrumentation.targetContext.applicationContext as Application
        ActivityScenario.launch(MainActivity::class.java).use {
            val engine = ProbeEngineViewModel.sharedHost(app)
            val config = withTimeout(60000) { engine.botPlatformConfig.filterNotNull().first() }
            engine.start()
            withTimeout(60000) { engine.workerReady.first { it } }
            (config.driver as AppBotChatDriver).startMainSession()

            val file = File.createTempFile("approval-test", ".json", app.cacheDir).apply { delete() }
            try {
                val host = "qa-${UUID.randomUUID()}.example.org"
                val policy = NetworkAccessSettings(file)
                policy.add(host)
                var contacts = 0
                val actor = checkNotNull(engine.appBotRuntime?.egress)
                val gateway = GatewayHttpEgress(policy.readGateway(object : GatewayTransport {
                    override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                        contacts++
                        return GatewayTransportResponse(200)
                    }
                }) { method, url -> actor.check(method, url, false) })
                val target = "https://$host/check"
                val request = LoopbackHttpRequest("POST", target, "POST",
                    mapOf(GatewayHttpEgress.TARGET_URL to target), byteArrayOf(1))
                assertEquals(403, gateway.handle(request).status)
                assertEquals(0, contacts)
                tap("拒绝")
                delay(500)
                assertEquals(403, gateway.handle(request).status)
                assertEquals(0, contacts)
                tap("允许一次")
                withTimeout(10000) {
                    while (gateway.handle(request).status != 200) delay(160)
                }
                assertEquals(1, contacts)
                assertEquals(403, gateway.handle(request).status)
                assertEquals(1, contacts)
                tap("拒绝")
            } finally { file.delete() }
        }
        Unit
    }
}

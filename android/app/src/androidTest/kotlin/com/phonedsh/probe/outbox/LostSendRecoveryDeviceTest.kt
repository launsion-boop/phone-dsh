// SPDX-License-Identifier: MIT
package com.phonedsh.probe.outbox

import android.app.Application
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.probe.MainActivity
import com.phonedsh.probe.ProbeEngineViewModel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class LostSendRecoveryDeviceTest {
    @Test fun missingWorkerSessionIsExposedWithoutSubmittingTheMessage() = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val disk = SendOutbox(app.filesDir)
        val entry = disk.enqueue("session-${UUID.randomUUID()}", "恢复测试")
        ActivityScenario.launch(MainActivity::class.java).use {
            val engine = ProbeEngineViewModel.sharedHost(app)
            val lost = withTimeout(60000) { engine.lostSends.first { rows -> rows.any { row -> row.rpcId == entry.rpcId } } }
            assertEquals(0, lost.single { row -> row.rpcId == entry.rpcId }.attempts)
            assertEquals(SendOutboxState.TARGET_LOST, disk.entry(entry.rpcId)?.state)
            engine.recoverLostSend(entry.rpcId, null)
            assertNull(disk.entry(entry.rpcId))
        }
        Unit
    }
}

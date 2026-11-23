// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.app.Application
import android.content.ContentValues
import android.provider.MediaStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.probe.MainActivity
import com.phonedsh.probe.ProbeEngineViewModel
import com.phonedsh.ui.bot.driver.BotDraftAttachment
import com.phonedsh.ui.bot.driver.BotDraftImporter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class BotComposerImportDeviceTest {
    @Test fun selectedDocumentCommitsThroughTheRunningBotSession() = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val bytes = "Bot composer import smoke".toByteArray()
        val name = "composer-test.txt"
        val uri = checkNotNull(app.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME, name); put(MediaStore.Downloads.MIME_TYPE, "text/plain") }))
        try {
            app.contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
            ActivityScenario.launch(MainActivity::class.java).use {
                val engine = ProbeEngineViewModel.sharedHost(app)
                withTimeout(60000) { engine.workerReady.first { ready -> ready } }
                val config = withTimeout(30000) { engine.botPlatformConfig.first { it != null } }!!
                val importer = config.driver as BotDraftImporter
                val id = UUID.randomUUID().toString()
                val draft = BotDraftAttachment(id, BotAttachment(name, "", bytes.size.toLong(), "text/plain", "file"), uri.toString())
                val result = importer.importDraft(id, listOf(draft))
                assertEquals(emptyList<String>(), result.errors)
                val attachment = result.files.single()
                assertEquals("${BotWorkspaceLayout.botRoot(config.context.botID)}/imports/attachments-$id/$name", attachment.path)
                assertEquals(bytes.size.toLong(), attachment.size)
                val workspace = com.phonedsh.log.WalPaths(app.filesDir.toPath().resolve("xl")).materializedWorkspace
                val committedFile = workspace.resolve(attachment.path.removePrefix("/dsh/workspace/"))
                assertArrayEquals(bytes, java.nio.file.Files.readAllBytes(committedFile))
            }
        } finally {
            app.contentResolver.delete(uri, null, null)
        }
        Unit
    }
}

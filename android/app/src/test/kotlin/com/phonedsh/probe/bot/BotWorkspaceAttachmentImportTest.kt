// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.*
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.bot.session.BotFollowConnection
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.ui.bot.driver.BotDraftAttachment
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BotWorkspaceAttachmentImportTest {
    @get:Rule val temp = TemporaryFolder()
    private fun file(name: String, uri: String) = BotDraftAttachment(uri, BotAttachment(name, "", 3, "text/plain", "file"), uri)

    private class Remote(val badAck: Boolean) : BotSessionTransport {
        val calls = mutableListOf<String>()
        val paths = mutableListOf<String>()
        override fun openFollow(): BotFollowConnection = error("not used")
        override fun call(endpoint: String, args: JsonObject): JsonObject {
            calls += endpoint
            val req = args["request"] as JsonObject
            assertEquals(JsonString("session"), req["sessionId"])
            return when (endpoint) {
                "phone/importBegin" -> JsonObject(mapOf("importId" to JsonString("import")))
                "phone/importWrite" -> {
                    paths += (req["path"] as JsonString).value
                    assertEquals(JsonString("YWJj"), req["dataBase64"])
                    JsonObject(mapOf("received" to JsonNumber(if (badAck) "2" else "3")))
                }
                "phone/importCommit" -> JsonObject(mapOf(
                    "absolutePath" to JsonString("${BotWorkspaceLayout.botRoot("main")}/imports/attachments-msg"),
                    "workspacePath" to JsonString("imports/attachments-msg"),
                    "fileCount" to JsonNumber(paths.size.toString()), "totalBytes" to JsonNumber((paths.size * 3).toString()),
                ))
                "phone/importAbort" -> JsonObject(emptyMap())
                else -> error(endpoint)
            }
        }
    }

    @Test fun readableSubsetUsesConfirmedBotPathsAndCollidingNamesStayDistinct() = runBlocking {
        val remote = Remote(false)
        val importer = BotWorkspaceAttachmentImport(temp.root, { if (it == "missing") null else "abc".byteInputStream() },
            remote, { "session" }, "main")
        val result = importer.run("msg", listOf(file("../a.txt", "one"), file("a.txt", "two"), file("lost", "missing")))
        assertEquals(listOf("a.txt","a-1.txt"), remote.paths)
        assertEquals(remote.paths, result.files.map { it.name })
        assertTrue(result.files.all { it.path.startsWith("${BotWorkspaceLayout.botRoot("main")}/imports/attachments-msg/") })
        assertEquals(1, result.errors.size)
        assertTrue(temp.root.listFiles()!!.isEmpty())
    }

    @Test fun wrongWriteAcknowledgementAbortsAndPublishesNoAttachment() = runBlocking {
        val remote = Remote(true)
        val importer = BotWorkspaceAttachmentImport(temp.root, { "abc".byteInputStream() }, remote, { "session" }, "main")
        val result = importer.run("msg", listOf(file("a", "one")))
        assertEquals(listOf("phone/importBegin","phone/importWrite","phone/importAbort"), remote.calls)
        assertTrue(result.files.isEmpty()); assertEquals(1, result.errors.size)
        assertTrue(temp.root.listFiles()!!.isEmpty())
    }
}

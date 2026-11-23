// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.ui.bot.driver.BotDraftAttachment
import com.phonedsh.ui.bot.driver.BotDraftImportResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.io.InputStream
import java.util.Base64

/** Uses the same session-scoped begin/write/commit service as the iOS Bot. */
internal class BotWorkspaceAttachmentImport(
    private val cache: File,
    private val open: (String) -> InputStream?,
    private val transport: BotSessionTransport,
    private val session: () -> String,
    private val botID: String,
) {
    private data class Prepared(val file: File, val meta: BotAttachment)

    suspend fun run(messageID: String, items: List<BotDraftAttachment>): BotDraftImportResult {
        val staged = mutableListOf<Prepared>()
        val errors = mutableListOf<String>()
        val committed = mutableListOf<BotAttachment>()
        val root = BotWorkspaceLayout.botRoot(botID)
        var sessionId: String? = null
        var importId: String? = null
        var stage = "打开 Bot 会话"
        fun call(method: String, vararg args: Pair<String, JsonValue>): JsonObject {
            stage = method
            val fields = mapOf("v" to JsonNumber("1"), "sessionId" to JsonString(checkNotNull(sessionId))) + args
            return transport.call(method, JsonObject(mapOf("request" to JsonObject(fields))))
        }
        try {
            for ((index, item) in items.withIndex()) {
                currentCoroutineContext().ensureActive()
                if (index >= BotAttachmentPolicy.MAX_COUNT) {
                    errors += "每条消息最多 10 个附件。"
                    break
                }
                val uri = item.sourceUri
                if (uri == null) {
                    committed += item.attachment
                    continue
                }
                var temporary: File? = null
                try {
                    val name = uniqueName(item.attachment.name, staged)
                    val file = File.createTempFile("bot-import-", ".part", cache)
                    temporary = file
                    val size = open(uri)?.use { input ->
                        file.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var bytes = 0L
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val read = input.read(buffer)
                                if (read < 0) break
                                bytes += read
                                require(bytes <= BotAttachmentPolicy.MAX_BYTES) { "超过 25 MiB" }
                                output.write(buffer, 0, read)
                            }
                            bytes
                        }
                    } ?: error("无法读取")
                    require(size > 0 && size == item.attachment.size) { "所选文件已改变或为空" }
                    staged += Prepared(file, item.attachment.copy(name = name, size = size))
                    temporary = null
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    errors += "附件「${item.attachment.name}」未附加：所选文件无法读取、已改变或超限。"
                } finally {
                    temporary?.delete()
                }
            }
            if (staged.isEmpty()) return BotDraftImportResult(committed, errors)
            (transport as? DshBotSessionTransport)?.awaitImportChannel()
            sessionId = session()
            val total = staged.sumOf { it.meta.size }
            val manifest = staged.map { JsonObject(mapOf("path" to JsonString(it.meta.name), "size" to JsonNumber(it.meta.size.toString()))) }
            val begin = call("phone/importBegin", "targetDirectory" to JsonString(root),
                "entryName" to JsonString("attachments-$messageID"), "directories" to JsonArray(emptyList()),
                "files" to JsonArray(manifest), "totalBytes" to JsonNumber(total.toString()))
            val id = (begin["importId"] as? JsonString)?.value?.takeIf { it.isNotEmpty() } ?: error("导入未开始")
            importId = id
            val buffer = ByteArray(256 * 1024)
            for (part in staged) {
                var offset = 0L
                part.file.inputStream().use { input ->
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        val response = call("phone/importWrite", "importId" to JsonString(id),
                            "path" to JsonString(part.meta.name), "offset" to JsonNumber(offset.toString()),
                            "dataBase64" to JsonString(Base64.getEncoder().encodeToString(buffer.copyOf(count))))
                        offset += count
                        check((response["received"] as? JsonNumber)?.asLongOrNull() == offset)
                    }
                }
            }
            currentCoroutineContext().ensureActive()
            val result = call("phone/importCommit", "importId" to JsonString(id))
            val dir = (result["absolutePath"] as? JsonString)?.value ?: error("导入回执缺少路径")
            check(dir.substringBeforeLast('/') == "$root/imports" && dir.substringAfterLast('/') !in setOf("", ".", ".."))
            check((result["workspacePath"] as? JsonString)?.value == dir.removePrefix("$root/"))
            check((result["fileCount"] as? JsonNumber)?.asLongOrNull() == staged.size.toLong())
            check((result["totalBytes"] as? JsonNumber)?.asLongOrNull() == total)
            importId = null
            committed += staged.map { it.meta.copy(path = "$dir/${it.meta.name}") }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            val code = when (error) {
                is com.phonedsh.bot.session.BotSessionRemoteException -> error.code
                is com.phonedsh.dsh.host.HostApiException -> error.code
                else -> error.javaClass.simpleName
            }
            errors += staged.map { "附件「${it.meta.name}」未附加：$stage 失败（$code）。" }
        } finally {
            importId?.let { id -> runCatching { call("phone/importAbort", "importId" to JsonString(id)) } }
            staged.forEach { it.file.delete() }
        }
        return BotDraftImportResult(committed, errors)
    }

    private fun uniqueName(original: String, staged: List<Prepared>): String {
        val safe = BotAttachmentPolicy.safeName(original)
        var name = safe
        var attempt = 1
        while (staged.any { it.meta.name == name }) {
            val extension = safe.substringAfterLast('.', "")
            val suffix = "-${attempt++}" + if (extension.isEmpty()) "" else ".${extension.take(80)}"
            name = safe.substringBeforeLast('.', safe).take(120 - suffix.length) + suffix
        }
        return name
    }
}

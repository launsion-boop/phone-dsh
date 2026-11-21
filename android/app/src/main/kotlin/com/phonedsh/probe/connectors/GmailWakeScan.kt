// SPDX-License-Identifier: MIT
package com.phonedsh.probe.connectors

import android.content.Context
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.bot.store.sha256
import com.phonedsh.bot.wake.ConnectorUpdateOutbox
import com.phonedsh.bot.wake.HeldConnectorUpdate
import com.phonedsh.connectors.gmail.GmailApi
import com.phonedsh.connectors.gmail.GmailAuthorizationException
import com.phonedsh.connectors.gmail.GmailAuthorizationFailure
import com.phonedsh.connectors.gmail.GmailError
import com.phonedsh.connectors.gmail.GmailException
import com.phonedsh.connectors.gmail.GmailSummary
import com.phonedsh.probe.BuildConfig
import com.phonedsh.probe.HostWakeScheduler
import com.phonedsh.probe.WakeDemand
import com.phonedsh.probe.WakeDemandKey
import com.phonedsh.probe.WakeDemandKind
import com.phonedsh.probe.WakeDemandSource
import com.phonedsh.probe.outbox.DurableFileStore
import java.io.File
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Metadata scanning uses the existing Google grant, without opening a consent UI. */
internal class GmailWakeScan(
    context: Context,
    private val outbox: ConnectorUpdateOutbox,
) {
    private val authorizer = GoogleGmailAuthorizer(context, BuildConfig.PDSH_GMAIL_ENABLED) { null }
    private val api = GmailApi()
    private val store = DurableFileStore()
    private val root = File(context.filesDir, "host-wake/connectors")
    private val scheduler = HostWakeScheduler.get(context)
    private val key = WakeDemandKey(WakeDemandSource.connectorScan, "gmail")

    suspend fun run() = withContext(Dispatchers.IO) {
        if (!scheduler.isUnlocked) return@withContext
        try {
            val now = System.currentTimeMillis()
            if (scheduler.read().any { it.identity == key && it.dueAtMs > now }) return@withContext
            val token = authorizer.accessToken()
            val mailbox = api.wakeMailbox(token)
            val file = File(root, "gmail-${sha256(mailbox.email.lowercase().toByteArray(Charsets.UTF_8))}.json")
            val prior = load(file)
            var head = mailbox.historyId
            var reset = if (prior == null && file.isFile) "cursor-invalid" else null
            if (prior != null) {
                if (head.toBigInteger() < prior.toBigInteger()) {
                    reset = "cursor-regressed"
                } else {
                    try {
                        val delta = api.wakeHistory(prior, token)
                        head = delta.historyId
                        coroutineContext.ensureActive()
                        if (head != prior && delta.messages.isNotEmpty()) {
                            outbox.enqueue(HeldConnectorUpdate(
                                "gmail", prior, head, delta.messages.map(::metadata),
                            ), now)
                        }
                    } catch (failure: GmailException) {
                        if (failure.error != GmailError.NOT_FOUND) throw failure
                        reset = "cursor-invalid"
                    }
                }
            }
            coroutineContext.ensureActive()
            val finishedAt = System.currentTimeMillis()
            val cursor = JsonObject(buildMap {
                put("version", JsonNumber("1"))
                put("connector", JsonString("gmail"))
                put("cursor", JsonString(head))
                put("updatedAt", JsonNumber(finishedAt.toString()))
                put("status", JsonString(if (reset == null) "established" else "reset"))
                reset?.let { put("lastError", JsonString(it)) }
            })
            store.writeAtomically(file, cursor.toJsonString().toByteArray(Charsets.UTF_8))
            scheduler.set(WakeDemand(key, finishedAt + SCAN_INTERVAL_MS, WakeDemandKind.recurring, false))
        } catch (failure: GmailAuthorizationException) {
            if (failure.failure !in setOf(
                    GmailAuthorizationFailure.NOT_AUTHORIZED,
                    GmailAuthorizationFailure.INVALID_GRANT,
                    GmailAuthorizationFailure.READ_PERMISSION_REQUIRED,
                )
            ) throw failure
            scheduler.remove(key)
        } catch (failure: GmailException) {
            if (failure.error != GmailError.UNAUTHORIZED && failure.error != GmailError.FORBIDDEN) throw failure
            scheduler.remove(key)
        }
        Unit
    }

    private fun load(file: File): String? {
        val bytes = try {
            Files.readAllBytes(file.toPath())
        } catch (_: NoSuchFileException) {
            return null
        }
        return decodeGmailWakeCursor(bytes.toString(Charsets.UTF_8))
    }

    private fun metadata(message: GmailSummary): JsonObject = JsonObject(buildMap {
        put("id", JsonString(message.id))
        put("at", JsonNumber((message.dateMillis ?: 0).coerceAtLeast(0).toString()))
        message.sender.take(512).takeIf { it.isNotBlank() }?.let { put("from", JsonString(it)) }
        message.subject.take(512).takeIf { it.isNotBlank() }?.let { put("subject", JsonString(it)) }
    })

    private companion object { const val SCAN_INTERVAL_MS = 1_800_000L }
}

internal fun decodeGmailWakeCursor(raw: String): String? {
    val row = runCatching { JsonValue.parse(raw) }.getOrNull() as? JsonObject ?: return null
    val required = setOf("version", "connector", "updatedAt", "cursor", "status")
    if (!row.members.keys.containsAll(required) || (row.members.keys - required - "lastError").isNotEmpty()) return null
    if ((row["version"] as? JsonNumber)?.asLongOrNull() != 1L ||
        (row["connector"] as? JsonString)?.value != "gmail" ||
        ((row["updatedAt"] as? JsonNumber)?.asLongOrNull() ?: -1) < 0 ||
        (row["status"] as? JsonString)?.value !in setOf("established", "reset")
    ) return null
    val error = row["lastError"]
    if (error != null && (error as? JsonString)?.value !in
        setOf("cursor-invalid", "cursor-regressed", "scan-failed")
    ) return null
    return (row["cursor"] as? JsonString)?.value?.takeIf { it.matches(Regex("[0-9]{1,20}")) }
}

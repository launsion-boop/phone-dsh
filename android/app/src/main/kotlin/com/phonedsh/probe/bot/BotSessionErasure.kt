// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.bot.memory.BotMemoryScope
import com.phonedsh.bot.memory.BotMemorySessionErasureReport
import com.phonedsh.bot.memory.BotMemorySessionErasureRequest
import com.phonedsh.bot.memory.BotMemoryUncoveredRecord
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.log.ClosedSessionRewrite
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.util.UUID

internal class BotSessionErasure(
    private val sessionsRoot: Path,
    private val store: BotDomainStore,
    private val roster: AppBotRosterController,
    private val park: () -> AutoCloseable,
    private val writer: ClosedSessionRewrite,
    private val workerReplaced: () -> Unit,
) {
    private data class Line(val raw: String, val row: JsonObject?) {
        val seq get() = (row?.get("seq") as? JsonNumber)?.asLongOrNull()
        val kind get() = (row?.get("type") as? JsonString)?.value
        val data get() = row?.get("data") as? JsonObject
    }
    private data class Plan(val session: String, val changes: List<ClosedSessionRewrite.FileChange>,
                            val erased: Set<Long>, val continuation: String?)

    fun <T> perform(operation: (com.phonedsh.bot.memory.BotMemorySessionEraser) -> T): T {
        var lease: AutoCloseable? = null
        try {
            return operation(com.phonedsh.bot.memory.BotMemorySessionEraser { request ->
                erase(request) { lease = park() }
            })
        } finally {
            lease?.let {
                try {
                    workerReplaced()
                    roster.forgetWorkerAfterErasure()
                } finally { it.close() }
            }
        }
    }

    private fun erase(request: BotMemorySessionErasureRequest, acquire: () -> Unit): BotMemorySessionErasureReport {
        val (owners, _) = ownership(request)
        val erasureID = "session-erasure-" + UUID.randomUUID()
        val before = plans(request, owners.keys, erasureID, previewOnly = true)
        val epochs = mutableListOf<JsonObject>()
        val switched = mutableSetOf<String>()
        val continuations = mutableMapOf<String, AppBotChatDriver>()
        val affected = before.filter { it.erased.isNotEmpty() }.mapNotNull { owners[it.session] }.toSet()
        for (bot in if (affected.isEmpty()) emptySet() else affected + request.botId) {
            val driver = roster.driverFor(bot)
            val active = driver?.startSessionForErasure()
            if (driver != null && active != null && (bot == request.botId || before.any { it.session == active && it.erased.isNotEmpty() })) {
                owners[active] = bot
                val records = before.flatMap { plan -> plan.erased.map { ref(plan.session, it) } }.distinct()
                val next = driver.switchForErasure(erasureID, records)
                switched += next.old
                continuations[next.old] = driver
                epochs += JsonObject(mapOf("fromSessionId" to JsonString(next.old), "toSessionId" to JsonString(next.new),
                    "at_ms" to JsonNumber(request.atMs.toString())))
            }
        }
        val covered = mutableSetOf<String>()
        val receipts = mutableListOf<JsonObject>()
        val uncovered = request.records.toMutableSet()
        if (owners.isNotEmpty() && Files.isDirectory(sessionsRoot, NOFOLLOW_LINKS)) {
            acquire()
            kotlinx.coroutines.runBlocking {
                val (settledOwners, exited) = ownership(request)
                val known = owners.keys + settledOwners.keys
                val witnesses = plans(request, known, erasureID, previewOnly = true)
                    .groupBy { it.session }.mapValues { (_, copies) -> copies.flatMap { it.erased }.toSet() }
                val final = plans(request, known, erasureID, switched, witnesses = witnesses)
                val closed = final.filter { it.session in switched || it.session in exited }
                for (plan in final - closed.toSet()) plan.erased.forEach { uncovered += ref(plan.session, it) }
                if (closed.isNotEmpty()) writer.apply(closed.flatMap { it.changes }, closed.map { it.session }.toSet())
                for (plan in closed) continuations[plan.session]?.continueAfterErasure(plan.continuation)
                for (plan in closed) for (seq in plan.erased) {
                    val record = ref(plan.session, seq)
                    if (covered.add(record)) receipts += JsonObject(mapOf("record" to JsonString(record),
                        "sessionId" to JsonString(plan.session), "seq" to JsonNumber(seq.toString())))
                }
            }
        }
        return BotMemorySessionErasureReport(receipts, epochs, (uncovered - covered).sorted().map {
            BotMemoryUncoveredRecord(it, "session-log-session-not-closed")
        })
    }

    private fun ownership(request: BotMemorySessionErasureRequest): Pair<MutableMap<String, String>, Set<String>> {
        val owners = mutableMapOf<String, String>()
        val exited = mutableSetOf<String>()
        var cursor = 0
        while (true) {
            val events = store.events(cursor, 256)
            for (event in events) {
                val bot = event.principal.botId ?: continue
                if (request.scope != BotMemoryScope.USER && bot != request.botId) continue
                for (id in listOfNotNull(event.principal.sessionId, (event.origin as? BotEventOrigin.Dsh)?.sessionId)) {
                    check(owners.put(id, bot) in setOf(null, bot)) { "会话归属不明确，记忆已保留" }
                }
                event.principal.sessionId?.let { session ->
                    when (event.type) {
                        "runtime.exited" -> exited.add(session)
                        "runtime.started" -> exited.remove(session)
                        else -> Unit
                    }
                }
            }
            if (events.size < 256) break
            cursor = checkNotNull(events.last().commitSeq).toInt()
        }
        return owners to exited
    }

    private fun plans(request: BotMemorySessionErasureRequest, owned: Set<String>, id: String, continuity: Set<String> = emptySet(), previewOnly: Boolean = false,
                      witnesses: Map<String, Set<Long>> = emptyMap()): List<Plan> {
        if (Files.notExists(sessionsRoot, NOFOLLOW_LINKS)) return emptyList()
        val groups = mutableMapOf<Path, MutableList<Path>>()
        Files.walk(sessionsRoot).use { files ->
            files.filter { it.parent?.fileName?.toString() in owned && generation.matches(it.fileName.toString()) }.forEach {
                check(Files.isRegularFile(it, NOFOLLOW_LINKS))
                groups.getOrPut(it.parent) { mutableListOf() }.add(it)
            }
        }
        return groups.mapNotNull { (dir, paths) ->
            val files = paths.sortedByDescending { generation.matchEntire(it.fileName.toString())!!.groupValues[1].toLong() }
            val newest = files.first()
            check(!newest.fileName.toString().endsWith(".zstd")) { "最新会话日志已压缩，无法验证抹除" }
            val session = dir.fileName.toString()
            val original = Files.readAllBytes(newest)
            val lines = decodeLines(original)
            fun matches(line: Line): Boolean {
                val seq = line.seq ?: return false
                val text = strings(line.data).joinToString("\n")
                return ref(session, seq) in request.records || seq in witnesses[session].orEmpty() ||
                    (line.kind != TOMBSTONE && request.needles.any(text::contains))
            }
            val selected = lines.filter(::matches).mapNotNull { it.seq }.toMutableSet()
            if (previewOnly) {
                // A previous generation may be the only remaining copy of a record.
                for (old in files.drop(1).filterNot { it.fileName.toString().endsWith(".zstd") }) {
                    decodeLines(Files.readAllBytes(old)).filter(::matches).mapNotNullTo(selected) { it.seq }
                }
            }
            if (selected.isEmpty() && session !in continuity && session !in witnesses) return@mapNotNull null
            var added: Boolean
            do {
                val fingerprints = lines.filter { it.seq in selected }.flatMap(::fingerprints).toSet()
                added = false
                for (line in lines.filter { it.kind == "agent/inbox/spliced" }) {
                    if (fingerprints(line).any(fingerprints::contains)) line.seq?.let { if (selected.add(it)) added = true }
                }
            } while (added)
            if (previewOnly) return@mapNotNull Plan(session, emptyList(), selected, null)
            val edits = mutableListOf<ClosedSessionRewrite.FileChange>()
            if (selected.isNotEmpty()) {
                val bytes = lines.joinToString("\n") { line ->
                    if (line.seq !in selected || line.kind == TOMBSTONE) line.raw else JsonObject(mapOf(
                        "type" to JsonString(TOMBSTONE), "seq" to checkNotNull(line.row?.get("seq")),
                        "time" to (line.row["time"] ?: JsonNumber("0")), "ignorable" to com.phonedsh.agentcore.JsonBool(true),
                        "data" to JsonObject(mapOf("erased" to com.phonedsh.agentcore.JsonBool(true),
                            "erasureId" to JsonString(id), "record" to JsonString(ref(session, checkNotNull(line.seq))))),
                    )).toJsonString()
                }.toByteArray()
                edits += ClosedSessionRewrite.FileChange(newest, java.security.MessageDigest.getInstance("SHA-256").digest(original), bytes)
            }
            if (selected.isNotEmpty() || session in witnesses) {
                for (old in files.drop(1)) edits += ClosedSessionRewrite.FileChange(old, ClosedSessionRewrite.digest(old), null)
            }
            val tail = lines.filter { it.seq !in selected && it.kind in setOf("user/message", "assistant/message") }
                .mapNotNull { line -> messageText(line.data)?.let { (if (line.kind == "user/message") "User: " else "Assistant: ") +
                    it.replace("<", "&lt;").replace(">", "&gt;") } }.joinToString("\n").takeLast(12000)
            Plan(session, edits, selected + witnesses[session].orEmpty(), tail.takeIf { it.isNotEmpty() }?.let {
                "<session_continuation>\nThe previous conversation continues below. Lines the user erased are omitted.\n$it\n</session_continuation>"
            })
        }
    }

    private fun decodeLines(original: ByteArray): List<Line> =
        Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(original)).toString().split('\n').map { raw ->
            Line(raw, if (raw.isBlank()) null else JsonValue.parse(raw) as JsonObject)
        }

    private fun fingerprints(line: Line): List<String> {
        val data = line.data ?: return emptyList()
        val messages = when (line.kind) {
            "user/message", "assistant/message" -> listOf(data["message"] as? JsonObject ?: data)
            "agent/inbox/spliced" -> (data["inserted"] as? JsonArray)?.values.orEmpty().filterIsInstance<JsonObject>()
            else -> emptyList()
        }
        return messages.flatMap { m ->
            val source = m["source"] as? JsonObject
            listOfNotNull((m["id"] as? JsonString)?.value?.takeIf(String::isNotEmpty)?.let { "id:$it" },
                (source?.get("rpcId") as? JsonString)?.value?.takeIf(String::isNotEmpty)?.let { "rpc:$it" },
                messageText(m)?.trim()?.takeIf { it.codePointCount(0, it.length) >= 8 }?.let {
                    "text:${(source?.get("kind") as? JsonString)?.value ?: "unknown"}:$it"
                })
        }
    }

    private fun messageText(data: JsonObject?): String? {
        val m = data?.get("message") as? JsonObject ?: data ?: return null
        val content = m["content"]
        if (content is JsonString) return content.value
        return (content as? JsonArray)?.values?.filterIsInstance<JsonObject>()?.mapNotNull {
            (it["text"] as? JsonString)?.value?.takeIf { _ -> (it["type"] as? JsonString)?.value == "text" }
        }?.joinToString("\n")?.takeIf { it.isNotBlank() }
    }

    private fun strings(data: JsonValue?): Sequence<String> = sequence {
        when (data) {
            is JsonString -> yield(data.value)
            is JsonArray -> for (v in data.values) yieldAll(strings(v))
            is JsonObject -> for (v in data.members.values) yieldAll(strings(v))
            else -> Unit
        }
    }

    private fun ref(session: String, seq: Long) = "record://session/$session#$seq"

    companion object {
        private const val TOMBSTONE = "phone-dsh/session-erasure"
        private val generation = Regex("""session\.v([0-9]+)\.jsonl(?:\.zstd)?""")
    }
}

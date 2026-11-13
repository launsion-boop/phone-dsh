// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import java.text.Normalizer
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * One-time, replayable migration from legacy fact events to the document tree
 * (v2 §1.6). It only adds missing documents and missing fact lines, so later
 * edits are never overwritten and a second run writes no event.
 */
public object BotMemoryMigrator {
    public fun migrate(
        facts: List<BotMemoryLegacyFact>,
        store: BotMemoryDocumentStore,
        botId: String,
        now: Long,
    ) {
        val ordered = facts.sortedWith(
            compareBy<BotMemoryLegacyFact> { it.learnedAtMs }.thenBy { it.factId },
        )
        val grouped = LinkedHashMap<String, MutableList<BotMemoryLegacyFact>>()
        for (fact in ordered) grouped.getOrPut(targetPath(fact)) { ArrayList() } += fact
        for (path in grouped.keys.sorted()) {
            merge(grouped[path].orEmpty(), path, store, botId, now)
        }

        val documents = store.documents(scope = null)
        for (scope in BotMemoryScope.roots) {
            val indexPath = "${scope.wire}/INDEX.md"
            if (store.document(indexPath) != null) continue
            writeWithRetry(
                path = indexPath,
                content = indexContent(scope, documents),
                evidence = emptyList(),
                expectedVersion = 0,
                store = store,
                botId = botId,
                now = now,
            )
        }
    }

    public fun targetPath(fact: BotMemoryLegacyFact): String {
        val root = fact.scope.wire
        return when (fact.tier) {
            BotMemoryTier.PROFILE -> "$root/profile.md"
            BotMemoryTier.NOTE -> "$root/notes/${slug(fact.key)}.md"
            BotMemoryTier.LOG -> "$root/log/${month(fact.learnedAtMs)}.md"
        }
    }

    public fun slug(key: String?): String {
        val normalized = Normalizer.normalize(
            (key ?: "").let(BotMemoryText::trimWhitespace).lowercase(Locale.ROOT),
            Normalizer.Form.NFKC,
        )
        val output = StringBuilder()
        var lastDash = false
        var index = 0
        while (index < normalized.length) {
            val cp = normalized.codePointAt(index)
            index += Character.charCount(cp)
            val allowed = cp in 'a'.code..'z'.code || cp in '0'.code..'9'.code || cp == '.'.code ||
                cp == '_'.code || cp == '-'.code
            if (allowed) {
                output.appendCodePoint(cp)
                lastDash = cp == '-'.code
            } else if (!lastDash) {
                output.append('-')
                lastDash = true
            }
        }
        val trimmed = output.toString().trim('-', '.', '_')
        return if (trimmed.isEmpty()) "note" else BotMemoryText.prefixScalars(trimmed, 64)
    }

    public fun month(timestampMs: Long): String =
        DateTimeFormatter.ofPattern("yyyy-MM", Locale.ROOT)
            .withZone(ZoneOffset.UTC)
            .format(Instant.ofEpochMilli(maxOf(0, timestampMs)))

    private fun merge(
        facts: List<BotMemoryLegacyFact>,
        path: String,
        store: BotMemoryDocumentStore,
        botId: String,
        now: Long,
    ) {
        if (facts.isEmpty()) return
        repeat(3) {
            val existing = store.document(path)
            val header = header(facts[0])
            val existingContent = existing?.content ?: header
            val content = StringBuilder(existingContent)
            for (fact in facts) {
                if (content.contains(fact.text)) continue
                if (content.toString() == header) {
                    content.append("\n\n- ").append(fact.text)
                } else {
                    content.append("\n- ").append(fact.text)
                }
            }
            val evidence = unionEvidence(existing?.evidence ?: emptyList(), facts)
            if (existing != null && existing.content == content.toString() &&
                existing.evidence == evidence
            ) {
                return
            }
            val outcome = writeWithRetry(
                path = path,
                content = content.toString(),
                evidence = evidence,
                expectedVersion = existing?.version ?: 0,
                store = store,
                botId = botId,
                now = now,
            )
            when (outcome) {
                is BotMemoryStoreWriteOutcome.Written,
                is BotMemoryStoreWriteOutcome.Deleted,
                -> return
                is BotMemoryStoreWriteOutcome.Conflict -> Unit
                else -> return
            }
        }
    }

    private fun writeWithRetry(
        path: String,
        content: String,
        evidence: List<String>,
        expectedVersion: Int,
        store: BotMemoryDocumentStore,
        botId: String,
        now: Long,
    ): BotMemoryStoreWriteOutcome = store.write(
        BotMemoryStoreWriteRequest(
            action = BotMemoryAction.WRITE,
            path = path,
            content = content,
            expectedVersion = expectedVersion,
            author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.MIGRATION),
            evidence = evidence,
            trust = null,
            source = null,
            atMs = now,
        ),
    )

    private fun header(fact: BotMemoryLegacyFact): String = when (fact.tier) {
        BotMemoryTier.PROFILE -> "# Profile"
        BotMemoryTier.NOTE -> "# ${fact.key ?: "note"}"
        BotMemoryTier.LOG -> "# ${month(fact.learnedAtMs)}"
    }

    private fun unionEvidence(
        existing: List<String>,
        facts: List<BotMemoryLegacyFact>,
    ): List<String> {
        val values = sortedSetOf<String>()
        values += existing
        for (fact in facts) values += fact.evidence
        return values.take(8)
    }

    public fun indexContent(
        scope: BotMemoryScope,
        documents: List<BotMemoryDocument>,
    ): String {
        val paths = documents
            .filter { it.scope == scope && !BotMemoryPath.isIndex(it.path) }
            .map { it.path }
            .sorted()
        if (paths.isEmpty()) return "# Index"
        val lines = arrayListOf("# Index", "")
        for (path in paths) {
            val candidate = lines + listOf("- $path")
            if (BotMemoryText.scalarCount(candidate.joinToString("\n")) > BotMemoryLimits.INDEX) {
                val note = "- …（更多文档用 ReadMemory 列举）"
                val withNote = lines + listOf(note)
                if (BotMemoryText.scalarCount(withNote.joinToString("\n")) <= BotMemoryLimits.INDEX) {
                    lines += note
                }
                break
            }
            lines += "- $path"
        }
        return lines.joinToString("\n")
    }
}

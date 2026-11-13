// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

/**
 * Host-only physical erasure planning (v2 §1.8). The planner mirrors the
 * shared reference implementation `spec/bot/v2/tools/validate_vectors.py`
 * (`erasure_plan`) so `golden/memory-erasure.json` drives the real code.
 */
public data class BotMemoryErasureVersion(
    public val version: Int,
    public val content: String,
    public val deleted: Boolean = false,
)

public data class BotMemoryErasureStateDocument(
    public val path: String,
    public val scope: BotMemoryScope,
    public val botId: String,
    public val live: Boolean,
    public val versions: List<BotMemoryErasureVersion>,
    public val evidence: List<String> = emptyList(),
)

public data class BotMemoryErasureStateEvent(
    public val seq: Long,
    public val type: String,
    public val botId: String? = null,
    public val path: String? = null,
    public val text: String? = null,
    public val refs: List<String> = emptyList(),
    public val factId: String? = null,
    public val factScope: String? = null,
    public val erasedPayload: Boolean = false,
)

public data class BotMemoryErasureTarget(
    public val scope: BotMemoryScope?,
    public val path: String? = null,
)

public data class BotMemoryErasureMemoryVersions(
    public val path: String,
    public val scope: BotMemoryScope,
    public val versions: List<Int>,
)

public data class BotMemoryErasurePlan(
    public val scope: BotMemoryScope,
    public val paths: List<String>,
    public val removedDocuments: Int,
    public val removedVersions: Int,
    public val erasedEvents: List<Long>,
    public val survivingPaths: List<String>,
    public val uncoveredRecords: List<String>,
    public val legacyFactIds: List<String>,
    public val needles: List<String>,
    public val memoryVersions: List<BotMemoryErasureMemoryVersions>,
)

public data class BotMemoryErasurePlanResult(
    public val plan: BotMemoryErasurePlan?,
    public val error: String?,
)

public object BotMemoryErasurePlanner {
    public fun plan(
        target: BotMemoryErasureTarget,
        botId: String,
        documents: List<BotMemoryErasureStateDocument>,
        events: List<BotMemoryErasureStateEvent>,
    ): BotMemoryErasurePlanResult {
        val scope = target.scope ?: return BotMemoryErasurePlanResult(null, "memory-path-invalid")
        val path = target.path
        if (path != null) {
            if (BotMemoryPath.parse(path) == null || BotMemoryPath.scopeOf(path) != scope) {
                return BotMemoryErasurePlanResult(null, "memory-path-invalid")
            }
        }
        val normalizedBot = normalizeBotId(botId)
        val selected = documents.filter { document ->
            if (document.scope != scope) return@filter false
            if (scope == BotMemoryScope.AGENT && normalizeBotId(document.botId) != normalizedBot) {
                return@filter false
            }
            if (path != null && document.path != path) return@filter false
            true
        }
        val paths = selected.map { it.path }.toSortedSet().toList()
        val needles = sortedSetOf<String>()
        for (document in selected) {
            for (version in document.versions) {
                if (!version.deleted) needles += needles(version.content)
            }
        }
        val needleList = needles.toList()
        val erased = sortedSetOf<Long>()
        val legacyFactIds = sortedSetOf<String>()
        for (event in events) {
            if (event.erasedPayload) continue
            if (event.type == "erasure") continue
            if (!eventBelongs(event, normalizedBot, scope)) continue
            if (event.path != null && event.path in paths && event.type.startsWith("memory.")) {
                erased += event.seq
            }
            val text = event.text
            if (text != null && needleList.any { text.contains(it) }) {
                erased += event.seq
            }
            when (event.type) {
                "memory.written" -> {
                    val factId = event.factId ?: continue
                    val factScope = event.factScope
                    val belongs = if (path != null) {
                        text != null && needleList.any { text.contains(it) }
                    } else if (scope == BotMemoryScope.USER) {
                        factScope == BotMemoryScope.USER.wire
                    } else {
                        factScope == BotMemoryScope.AGENT.wire
                    }
                    if (belongs) {
                        erased += event.seq
                        legacyFactIds += factId
                    }
                }
                "memory.forgotten" -> {
                    val factId = event.factId ?: continue
                    val belongs = if (path != null) {
                        factId in legacyFactIds
                    } else {
                        event.factScope == scope.wire
                    }
                    if (belongs) {
                        erased += event.seq
                        legacyFactIds += factId
                    }
                }
                else -> Unit
            }
        }
        val erasedRefs = erased.map { "record://event/$it" }.toSet()
        if (erasedRefs.isNotEmpty()) {
            for (event in events) {
                if (event.seq in erased) continue
                if (event.type.startsWith("memory.")) continue
                if (event.type == "erasure") continue
                if (!eventBelongs(event, normalizedBot, scope)) continue
                if (event.refs.any { reference -> erasedRefs.any { reference.contains(it) } }) {
                    erased += event.seq
                }
            }
        }

        val pathBots = HashMap<Pair<String, BotMemoryScope>, MutableSet<String>>()
        for (document in documents) {
            pathBots.getOrPut(document.path to document.scope) { LinkedHashSet() }
                .add(normalizeBotId(document.botId))
        }
        val selectedKeys = selected.map { Triple(it.path, it.scope, normalizeBotId(it.botId)) }.toSet()
        val surviving = ArrayList<String>()
        for (document in documents) {
            val key = Triple(document.path, document.scope, normalizeBotId(document.botId))
            if (key in selectedKeys) continue
            var marker = document.path
            if (document.scope == BotMemoryScope.AGENT &&
                (pathBots[document.path to BotMemoryScope.AGENT]?.size ?: 0) > 1
            ) {
                marker += "#${document.botId}"
            }
            surviving += marker
        }
        surviving.sort()

        val uncovered = sortedSetOf<String>()
        for (document in selected) {
            for (raw in document.evidence) {
                if (raw.startsWith("record://session/")) uncovered += raw
            }
        }
        val memoryVersions = selected.map { document ->
            BotMemoryErasureMemoryVersions(
                path = document.path,
                scope = document.scope,
                versions = document.versions.map { it.version }.sorted(),
            )
        }.sortedBy { it.path }
        return BotMemoryErasurePlanResult(
            plan = BotMemoryErasurePlan(
                scope = scope,
                paths = paths,
                removedDocuments = selected.count { it.live },
                removedVersions = selected.sumOf { it.versions.size },
                erasedEvents = erased.toList(),
                survivingPaths = surviving,
                uncoveredRecords = uncovered.toList(),
                legacyFactIds = legacyFactIds.toList(),
                needles = needleList,
                memoryVersions = memoryVersions,
            ),
            error = null,
        )
    }

    /** Exact version text, each non-empty line, and distinctive marker tokens. */
    internal fun needles(content: String): Set<String> {
        val result = sortedSetOf<String>()
        val stripped = BotMemoryText.trimWhitespace(content)
        if (BotMemoryText.scalarCount(stripped) >= 8) result += stripped
        for (line in content.split("\n")) {
            val value = BotMemoryText.trimWhitespace(line)
            if (BotMemoryText.scalarCount(value) >= 8) result += value
        }
        val separators = ",;:!?()[]{}<>\"'".toSet()
        val token = StringBuilder()
        var index = 0
        fun flush() {
            if (token.isEmpty()) return
            val value = token.toString()
            token.setLength(0)
            if (BotMemoryText.scalarCount(value) < 8) return
            val hasDigit = value.codePoints().anyMatch { Character.isDigit(it) }
            if (value.contains("_") || hasDigit) result += value
        }
        while (index < content.length) {
            val cp = content.codePointAt(index)
            index += Character.charCount(cp)
            if (BotMemoryText.isWhitespace(cp) || (cp <= 0xFFFF && cp.toChar() in separators)) {
                flush()
            } else {
                token.appendCodePoint(cp)
            }
        }
        flush()
        return result
    }

    private fun eventBelongs(
        event: BotMemoryErasureStateEvent,
        botId: String,
        scope: BotMemoryScope,
    ): Boolean {
        if (scope == BotMemoryScope.USER) return true
        val eventBot = event.botId
        return eventBot == null || normalizeBotId(eventBot) == botId
    }

    private fun normalizeBotId(value: String?): String =
        if (value.isNullOrEmpty()) "main" else value
}

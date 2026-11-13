// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

/**
 * Memory facade: preparation (one-time legacy migration + root indexes), the
 * three primitives write/read/recall, injection and physical erasure. The
 * durable event log behind [BotMemoryDocumentStore] remains the authority.
 */
public class BotMemory(
    public val store: BotMemoryDocumentStore,
    private val botId: String,
    private val language: BotMemoryPromptLanguage = BotMemoryPromptLanguage.ZH,
    private val now: () -> Long = { System.currentTimeMillis() },
    /**
     * Production hosts materialize both root indexes before the first turn.
     * Golden write/read vectors seed exact document states instead, so tests
     * may turn the automatic creation off.
     */
    private val prepareIndexes: Boolean = true,
) {
    private var prepared = false
    private val recallIndex = BotMemoryDocumentRecallIndex()

    @Synchronized
    public fun documents(scope: BotMemoryScope? = null): List<BotMemoryDocument> {
        prepare()
        return store.documents(scope)
    }

    @Synchronized
    public fun versions(path: String): List<BotMemoryDocumentVersion> {
        prepare()
        return store.versions(path)
    }

    public fun replayDiagnostics(): BotMemoryReplayDiagnostics = store.replayDiagnostics()

    public fun write(
        request: BotMemoryWriteRequest,
        context: BotMemoryWriteContext,
    ): BotMemoryWriteResult {
        prepare()
        if (BotMemoryPath.parse(request.path) == null) {
            return failure(request, "memory-path-invalid", "记忆路径必须位于 user/ 或 agent/ 下，且不能包含空段、'.'、'..' 或反斜杠。")
        }
        if (request.action == BotMemoryAction.MOVE) {
            val to = request.to
            if (to == null || BotMemoryPath.parse(to) == null) {
                return failure(request, "memory-path-invalid", "移动目标必须是一个有效的记忆路径。")
            }
        }
        val author = BotMemoryAuthor(
            botId = context.botId,
            sessionId = context.sessionId,
            kind = context.authorKind,
        )
        BotMemoryPath.scopeDenial(author, request.path)?.let {
            return failure(request, it, "任务和例行任务会话只能写自己的 agent/inbox/<会话>/ 目录。")
        }
        if (request.action == BotMemoryAction.MOVE) {
            val to = request.to!!
            BotMemoryPath.scopeDenial(author, to)?.let {
                return failure(request, it, "移动目标不在当前会话的收件目录里。")
            }
        }
        BotMemoryPath.maintenanceScopeDenial(author, request.path, context.isMainBot)?.let {
            return failure(request, it, "只有主 Bot 的后台整理可以写共享 user/ 记忆。")
        }
        if (request.action == BotMemoryAction.MOVE) {
            val to = request.to!!
            BotMemoryPath.maintenanceScopeDenial(author, to, context.isMainBot)?.let {
                return failure(request, it, "只有主 Bot 的后台整理可以写共享 user/ 记忆。")
            }
        }
        BotMemoryPath.userBoundaryError(
            sourceKind = context.source.kind,
            trust = context.trust,
            path = request.path,
            authorKind = context.authorKind,
            hostRollback = context.isHostRollback,
        )?.let { return boundaryFailure(request, it) }
        if (request.action == BotMemoryAction.MOVE) {
            val to = request.to!!
            BotMemoryPath.userBoundaryError(
                sourceKind = context.source.kind,
                trust = context.trust,
                path = to,
                authorKind = context.authorKind,
                hostRollback = context.isHostRollback,
            )?.let { return boundaryFailure(request, it) }
        }

        val evidence = try {
            BotMemoryEvidence.resolveForWrite(
                references = request.evidence,
                sourceKind = context.source.kind,
                currentUserTurnReference = context.currentUserTurnReference,
            )
        } catch (error: BotMemoryEvidenceException) {
            return failure(request, error.code, error.message ?: "证据引用无效。")
        }

        val outcome = store.write(
            BotMemoryStoreWriteRequest(
                action = request.action,
                path = request.path,
                content = request.content,
                find = request.find,
                replace = request.replace,
                to = request.to,
                expectedVersion = request.expectedVersion,
                restoreVersion = request.restoreVersion,
                author = author,
                evidence = evidence,
                trust = context.trust,
                source = context.source,
                atMs = now(),
                correlationId = context.batchId?.let { "memory-maintenance:$it" },
            ),
        )
        val result = when (outcome) {
            is BotMemoryStoreWriteOutcome.Written -> BotMemoryWriteResult.Success(
                action = request.action,
                path = outcome.document.path,
                scope = outcome.document.scope,
                version = outcome.document.version,
                previousVersion = request.expectedVersion,
                replaced = outcome.replaced,
            )
            is BotMemoryStoreWriteOutcome.Deleted -> BotMemoryWriteResult.Success(
                action = request.action,
                path = outcome.version.path,
                scope = outcome.version.scope,
                version = outcome.version.version,
                previousVersion = request.expectedVersion,
            )
            is BotMemoryStoreWriteOutcome.Conflict -> BotMemoryWriteResult.Failure(
                code = "memory-version-conflict",
                error = "文档当前是第 ${outcome.currentVersion} 版；请重新读取后用这个版本号重试。",
                action = request.action,
                path = request.path,
                scope = BotMemoryPath.scopeOf(request.path),
                currentVersion = outcome.currentVersion,
            )
            is BotMemoryStoreWriteOutcome.NotFound -> BotMemoryWriteResult.Failure(
                code = "memory-not-found",
                error = "${outcome.path} 下没有这份文档。",
                action = request.action,
                path = outcome.path,
                scope = BotMemoryPath.scopeOf(outcome.path),
            )
            is BotMemoryStoreWriteOutcome.PathExists -> BotMemoryWriteResult.Failure(
                code = "memory-path-exists",
                error = "目标位置已经有文档了：${outcome.path}。",
                action = request.action,
                path = outcome.path,
                scope = BotMemoryPath.scopeOf(outcome.path),
            )
            BotMemoryStoreWriteOutcome.ReplaceNotFound -> BotMemoryWriteResult.Failure(
                code = "memory-replace-not-found",
                error = "文档里没有找到这段原文。",
                action = request.action,
                path = request.path,
                scope = BotMemoryPath.scopeOf(request.path),
            )
            is BotMemoryStoreWriteOutcome.VersionNotFound -> BotMemoryWriteResult.Failure(
                code = "memory-version-not-found",
                error = "这份文档没有第 ${outcome.version} 版可恢复的历史版本。",
                action = request.action,
                path = request.path,
                scope = BotMemoryPath.scopeOf(request.path),
            )
            is BotMemoryStoreWriteOutcome.IndexTooLong -> BotMemoryWriteResult.Failure(
                code = "memory-index-too-long",
                error = "${outcome.path} has ${outcome.actual} characters; INDEX.md is limited to ${outcome.limit}.",
                action = request.action,
                path = outcome.path,
                scope = BotMemoryPath.scopeOf(outcome.path),
                limit = outcome.limit,
                actual = outcome.actual,
            )
        }
        if (request.markedContradiction && result is BotMemoryWriteResult.Success) {
            // Swift treats the follow-up review marker as best effort: the
            // document write is already durable and must not be reported as
            // failed because the marker could not be appended.
            runCatching {
                (store as? BotMemoryReviewWriter)?.recordReviewRequested(
                    botId = context.botId,
                    action = author,
                    path = result.path,
                    scope = result.scope,
                    version = result.version,
                    evidence = evidence,
                    atMs = now(),
                    correlationId = context.batchId?.let { "memory-maintenance:$it" },
                )
            }
        }
        return result
    }

    /** Direct host path for the memory page; no model evidence required. */
    public fun forget(path: String, expectedVersion: Int): BotMemoryForgetResult {
        prepare()
        if (BotMemoryPath.parse(path) == null) {
            return BotMemoryForgetResult(
                ok = false,
                error = "memory-path-invalid",
                removed = 0,
                path = path,
                count = 0,
                scope = BotMemoryPath.scopeOf(path) ?: BotMemoryScope.AGENT,
            )
        }
        val author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.UI)
        val outcome = store.write(
            BotMemoryStoreWriteRequest(
                action = BotMemoryAction.DELETE,
                path = path,
                expectedVersion = expectedVersion,
                author = author,
                evidence = emptyList(),
                trust = null,
                source = null,
                atMs = now(),
            ),
        )
        return when (outcome) {
            is BotMemoryStoreWriteOutcome.Deleted -> BotMemoryForgetResult(
                ok = true,
                removed = 1,
                path = path,
                version = outcome.version.version,
                count = store.documents(outcome.version.scope).size,
                scope = outcome.version.scope,
            )
            is BotMemoryStoreWriteOutcome.Conflict -> BotMemoryForgetResult(
                ok = false,
                error = "文档当前是第 ${outcome.currentVersion} 版；请刷新后重试。",
                removed = 0,
                path = path,
                count = 0,
                scope = BotMemoryPath.scopeOf(path) ?: BotMemoryScope.AGENT,
            )
            is BotMemoryStoreWriteOutcome.NotFound -> BotMemoryForgetResult(
                ok = true,
                removed = 0,
                path = path,
                count = 0,
                scope = BotMemoryPath.scopeOf(path) ?: BotMemoryScope.AGENT,
            )
            else -> BotMemoryForgetResult(
                ok = false,
                error = "这份文档暂时没能删除。",
                removed = 0,
                path = path,
                count = 0,
                scope = BotMemoryPath.scopeOf(path) ?: BotMemoryScope.AGENT,
            )
        }
    }

    public fun eraseAll(scope: BotMemoryScope): BotMemoryEraseScopeResult {
        prepare()
        val removed = store.eraseAll(
            scope = scope,
            author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.UI),
            atMs = now(),
        )
        return BotMemoryEraseScopeResult(
            ok = true,
            scope = scope,
            botId = botId,
            removed = removed,
            count = store.documents(scope).size,
        )
    }

    public fun erase(path: String): BotMemoryPhysicalEraseOutcome = erase(path, null)

    @Synchronized
    public fun erase(
        path: String,
        sessionEraser: BotMemorySessionEraser?,
    ): BotMemoryPhysicalEraseOutcome {
        prepare()
        val outcome = store.erase(
            path = path,
            author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.UI),
            atMs = now(),
            sessionEraser = sessionEraser,
        )
        if (outcome.ok) recallIndex.sync(emptyList())
        return outcome
    }

    public fun erase(scope: BotMemoryScope): BotMemoryPhysicalEraseOutcome = erase(scope, null)

    @Synchronized
    public fun erase(
        scope: BotMemoryScope,
        sessionEraser: BotMemorySessionEraser?,
    ): BotMemoryPhysicalEraseOutcome {
        prepare()
        val outcome = store.erase(
            scope = scope,
            author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.UI),
            atMs = now(),
            sessionEraser = sessionEraser,
        )
        if (outcome.ok) recallIndex.sync(emptyList())
        return outcome
    }

    @Synchronized
    public fun read(path: String, version: Int? = null): BotMemoryReadResult {
        prepare()
        if (BotMemoryPath.parse(path, allowRoot = true) == null) {
            return BotMemoryReadResult.Failure("memory-path-invalid", "记忆路径无效。", path)
        }
        val scope = BotMemoryPath.scopeOf(path)
            ?: return BotMemoryReadResult.Failure("memory-path-invalid", "记忆路径无效。", path)
        if (version != null) {
            val found = store.versions(path).firstOrNull { it.version == version }
                ?: return BotMemoryReadResult.Failure(
                    "memory-version-not-found", "$path 没有第 $version 版。", path,
                )
            return BotMemoryReadResult.Document(found)
        }
        val document = store.document(path)
        if (document != null) {
            return BotMemoryReadResult.Document(
                BotMemoryDocumentVersion(
                    path = document.path,
                    scope = document.scope,
                    version = document.version,
                    content = document.content,
                    updatedAtMs = document.updatedAtMs,
                    author = document.author,
                    evidence = document.evidence,
                    trust = document.trust,
                ),
            )
        }
        val entries = directoryEntries(store.documents(scope), path)
        if (entries.isNotEmpty() || path == scope.wire) {
            return BotMemoryReadResult.Directory(path, scope, entries)
        }
        return BotMemoryReadResult.Failure("memory-not-found", "$path 下没有文档或目录。", path)
    }

    public fun recall(
        query: String = "",
        limit: Int = 40,
        scope: BotMemoryScope? = null,
    ): List<BotMemoryRecallHit> = recallPage(query, limit, scope).hits

    @Synchronized
    public fun recallPage(
        query: String = "",
        limit: Int = 40,
        scope: BotMemoryScope? = null,
    ): BotMemoryRecallPage {
        prepare()
        val documents = store.documents(scope).filter { !BotMemoryPath.isIndex(it.path) }
        recallIndex.sync(documents)
        return recallIndex.searchPage(query, limit = limit, now = now(), includeScope = scope)
    }

    @Synchronized
    public fun injection(): BotMemoryInjection {
        prepare()
        ensureIndexes()
        return BotMemoryInjector.render(
            userIndex = store.document("user/INDEX.md"),
            agentIndex = store.document("agent/INDEX.md"),
            language = language,
        )
    }

    public fun promptBlock(): String = injection().text

    @Synchronized
    private fun prepare() {
        if (prepared) return
        val facts = store.legacyFacts(scope = null)
        if (facts.isNotEmpty()) {
            BotMemoryMigrator.migrate(facts, store, botId, now())
        }
        prepared = true
        try {
            if (prepareIndexes) ensureIndexes()
        } catch (error: Throwable) {
            prepared = false
            throw error
        }
    }

    private fun ensureIndexes() {
        for (scope in BotMemoryScope.roots) {
            val path = "${scope.wire}/INDEX.md"
            if (store.document(path) != null) continue
            store.write(
                BotMemoryStoreWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = path,
                    content = "# Index",
                    expectedVersion = 0,
                    author = BotMemoryAuthor(botId = botId, kind = BotMemoryAuthorKind.SYSTEM),
                    evidence = emptyList(),
                    trust = null,
                    source = null,
                    atMs = now(),
                ),
            )
        }
    }

    private fun failure(
        request: BotMemoryWriteRequest,
        code: String,
        error: String,
    ): BotMemoryWriteResult = BotMemoryWriteResult.Failure(
        code = code,
        error = error,
        action = request.action,
        path = request.path,
        scope = BotMemoryPath.scopeOf(request.path),
    )

    private fun boundaryFailure(
        request: BotMemoryWriteRequest,
        code: String,
    ): BotMemoryWriteResult {
        val message = if (code == "memory-source-boundary") {
            "只有真实用户回合才能写共享 user/ 记忆。"
        } else {
            "写共享 user/ 记忆至少需要一条指向用户消息的依据。"
        }
        return failure(request, code, message)
    }

    private fun directoryEntries(
        documents: List<BotMemoryDocument>,
        path: String,
    ): List<BotMemoryDirectoryEntry> {
        val prefix = if (path.endsWith("/")) path else "$path/"
        val entries = LinkedHashMap<String, BotMemoryDirectoryEntry>()
        for (document in documents) {
            if (!document.path.startsWith(prefix)) continue
            val remainder = document.path.substring(prefix.length)
            val head = remainder.substringBefore("/", remainder)
            val child = prefix + head
            entries[child] = if (remainder.contains("/")) {
                BotMemoryDirectoryEntry(child, head, BotMemoryDirectoryEntry.Kind.DIRECTORY)
            } else {
                BotMemoryDirectoryEntry(
                    child, head, BotMemoryDirectoryEntry.Kind.DOCUMENT,
                    document.version, document.updatedAtMs,
                )
            }
        }
        return entries.values.sortedBy { it.path }
    }
}

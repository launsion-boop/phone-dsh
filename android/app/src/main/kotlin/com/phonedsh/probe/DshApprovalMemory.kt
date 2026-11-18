// SPDX-License-Identifier: MIT
//
// The app-local "always allow" for DSH permission requests, ported from iOS
// `DSHApprovalMemory.swift` (`DSHApprovalPolicy` + `DSHApprovalMemory`) and the
// `ChatModel.respond(to:decision:)` / `autoApprove` wiring.
//
// DSH itself only has `allowed-once` on the wire. The app remembers a standing
// answer locally, per DSH session and per *scope* (never per bare tool), and only
// for operations that are safe to repeat. Every grant expires after 24 hours. The
// wire answer for an "always" decision is still `allowed-once`.
package com.phonedsh.probe

import android.content.Context
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.ui.page.DshApprovalGrantRow

/** Which permission requests may get a standing grant, and under which scope. */
internal object DshApprovalPolicy {
    /** Keep the local decision for one day (iOS `DSHApprovalPolicy.ttl`). */
    const val TTL_MS: Long = 24L * 60 * 60 * 1000

    private val safeTools = setOf(
        "read", "glob", "grep", "web_search", "web_fetch",
        "job_list", "job_output", "job_status", "todo_write",
    )

    private val destructiveTools = setOf(
        "write", "edit", "delete", "move", "rename", "rm", "mkdir",
        "chmod", "chown", "truncate", "shred", "dd", "mkfs",
    )

    private val destructiveBash = listOf(
        """(?:^|[;&|]\s*)rm\s+""",
        """(?:^|[;&|]\s*)sudo\s+rm\s+""",
        """(?:^|[;&|]\s*)git\s+reset\s+[^\n]*--hard""",
        """(?:^|[;&|]\s*)find\s+[^\n]*(?:\s|^)-delete(?:\s|$)""",
        """(?:^|[;&|]\s*)(?:dd|mkfs|shred|truncate)\b""",
        """(?:^|[;&|]\s*)chmod\s+-R\b""",
        """(?:^|[;&|]\s*)chown\s+-R\b""",
    ).map { Regex(it, RegexOption.IGNORE_CASE) }

    private val readOnlyCommands = setOf(
        "ls", "pwd", "cat", "head", "tail", "grep", "rg", "wc",
        "stat", "du", "df", "echo", "which", "date", "whoami", "true",
    )

    /** Markers of a sandbox escalation (iOS `PermissionCardView.isSandboxEscalation`). */
    private val escalationMarkers = listOf(
        "danger-full-access", "danger full access", "full-access",
        "sandbox upgrade", "escalat", "完全权限", "沙箱升级",
    )

    /** The scope to persist, or `null` when this request must stay one-shot. */
    fun grantKey(tool: String, arguments: Map<String, String>): String? {
        val name = tool.lowercase()
        if (name == "bash") {
            val command = arguments["command"]?.trim().orEmpty()
            if (command.isEmpty()) return null
            if (isDestructiveBash(command) || !isReadOnlyBash(command)) return null
            return "bash:read-only"
        }
        if (name in destructiveTools) return null
        if (name !in safeTools) return null
        return "tool:$name"
    }

    /**
     * The scope the card may offer: [grantKey], withheld for a sandbox escalation,
     * the one approval that widens what the agent may touch (iOS hides 总是允许 then).
     */
    fun offeredScope(tool: String, reason: String, arguments: Map<String, String>): String? {
        val lowered = reason.lowercase()
        if (escalationMarkers.any { lowered.contains(it) }) return null
        return grantKey(tool, arguments)
    }

    fun isDestructiveBash(command: String): Boolean = destructiveBash.any { it.containsMatchIn(command) }

    /**
     * Only a single, clearly read-only command may get a standing grant. Shell
     * separators and pipes are rejected: `ls; rm ...` and `cat x | …` are not
     * read-only as a whole. This intentionally errs toward asking.
     */
    fun isReadOnlyBash(command: String): Boolean {
        val text = command.trim()
        if (text.isEmpty()) return false
        if (listOf(";", "|", "&", "<", ">", "`", "$(", "\n", "\r").any { text.contains(it) }) return false
        val tokens = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        val first = tokens.firstOrNull() ?: return false
        if (first == "git") {
            if (tokens.size <= 1) return false
            return tokens[1] in setOf("status", "diff", "log", "show", "rev-parse", "ls-files")
        }
        if (first == "find") {
            return tokens.drop(1).none { it in setOf("-delete", "-exec", "-execdir", "-ok") }
        }
        return first in readOnlyCommands
    }

    /** iOS `ChatModel.flattenedArguments`: strings verbatim, other values as their JSON text. */
    fun flattenArguments(value: JsonValue?): Map<String, String> {
        val members = (value as? JsonObject)?.members ?: return emptyMap()
        return members.mapValues { (_, item) ->
            when (item) {
                is com.phonedsh.agentcore.JsonString -> item.value
                is JsonNumber -> item.raw
                else -> item.toJsonString()
            }
        }
    }
}

/** Where [DshApprovalMemory] keeps its one JSON document. */
internal interface DshApprovalFile {
    fun read(): String?
    fun write(value: String)
    fun clear()
}

internal class SharedPreferencesDshApprovalFile(context: Context) : DshApprovalFile {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    override fun read(): String? = runCatching { prefs.getString(KEY, null) }.getOrNull()
    override fun write(value: String) { prefs.edit().putString(KEY, value).apply() }
    override fun clear() { prefs.edit().remove(KEY).apply() }

    private companion object {
        const val FILE = "phone-dsh-dsh-approvals"
        const val KEY = "dsh-permission-always.v2"
    }
}

/**
 * Session+scope grants with a decision time (iOS `DSHApprovalMemory`). A grant is
 * valid for [DshApprovalPolicy.TTL_MS]; allow-once or deny removes the matching
 * grant so the next request asks again.
 */
internal class DshApprovalMemory(
    private val file: DshApprovalFile,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Synchronized
    fun isAllowed(sessionID: String, scope: String): Boolean {
        if (sessionID.isEmpty() || scope.isEmpty()) return false
        val decidedAt = load()[sessionID]?.get(scope) ?: return false
        return fresh(decidedAt, clock())
    }

    @Synchronized
    fun remember(sessionID: String, scope: String) {
        if (sessionID.isEmpty() || scope.isEmpty()) return
        val now = clock()
        val all = pruned(load(), now).mapValues { it.value.toMutableMap() }.toMutableMap()
        all.getOrPut(sessionID) { mutableMapOf() }[scope] = now
        save(all)
    }

    @Synchronized
    fun forget(sessionID: String, scope: String) {
        if (sessionID.isEmpty() || scope.isEmpty()) return
        val all = load().mapValues { it.value.toMutableMap() }.toMutableMap()
        all[sessionID]?.remove(scope)
        if (all[sessionID]?.isEmpty() == true) all.remove(sessionID)
        save(all)
    }

    /** Live grants, newest first. */
    @Synchronized
    fun activeGrants(): List<DshApprovalGrantRow> =
        pruned(load(), clock()).flatMap { (session, scopes) ->
            scopes.map { (scope, at) -> DshApprovalGrantRow(session, scope, at) }
        }.sortedByDescending { it.decidedAtMs }

    @Synchronized
    fun clearAll() {
        file.clear()
    }

    private fun fresh(decidedAt: Long, now: Long): Boolean = now >= decidedAt && now - decidedAt < DshApprovalPolicy.TTL_MS

    private fun pruned(entries: Map<String, Map<String, Long>>, now: Long): Map<String, Map<String, Long>> =
        entries.mapValues { (_, scopes) -> scopes.filterValues { fresh(it, now) } }.filterValues { it.isNotEmpty() }

    private fun load(): Map<String, Map<String, Long>> {
        val text = file.read() ?: return emptyMap()
        val root = runCatching { JsonValue.parse(text) as? JsonObject }.getOrNull() ?: return emptyMap()
        return root.members.mapNotNull { (session, value) ->
            val scopes = (value as? JsonObject)?.members?.mapNotNull { (scope, at) ->
                (at as? JsonNumber)?.asLongOrNull()?.let { scope to it }
            }?.toMap() ?: return@mapNotNull null
            session to scopes
        }.toMap()
    }

    private fun save(entries: Map<String, Map<String, Long>>) {
        val json = JsonObject(entries.mapValues { (_, scopes) ->
            JsonObject(scopes.mapValues { (_, at) -> JsonNumber(at.toString()) })
        })
        file.write(json.toJsonString())
    }
}

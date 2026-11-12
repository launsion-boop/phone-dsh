// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.session.BotSessionKind
import java.nio.file.Path

/**
 * The capability subset a child Task runs with (`BotMCPRuntime.swift` §2.5).
 * A task session without the `task.workspace:` marker has no authority at all,
 * so a missing subset is `task_scope:missing_authorization`, never unlimited.
 */
public data class BotTaskAuthorization(
    public val workspaceRoot: String,
    public val allowedWriteDirectories: List<String>,
    public val canWriteOutsideWorkspace: Boolean,
    public val canNetworkWrite: Boolean,
    public val canDelegateTasks: Boolean,
) {
    public fun allowsWrite(path: String): Boolean {
        val candidate = normalize(path, workspaceRoot)
        if (candidate.isEmpty()) return false
        return allowedWriteDirectories.any { directory ->
            candidate == directory || candidate.startsWith("$directory/")
        }
    }

    public companion object {
        public const val WORKSPACE_CAPABILITY_PREFIX: String = "task.workspace:"
        public const val WRITE_DIRECTORY_PREFIX: String = "task.write-dir:"
        public const val OUTSIDE_WORKSPACE_CAPABILITY: String = "task.write-outside-workspace"
        public const val NETWORK_WRITE_CAPABILITY: String = "task.network-write"
        public const val DELEGATE_CAPABILITY: String = "task.delegate"

        public fun fromCapabilities(capabilities: List<String>): BotTaskAuthorization? {
            val workspace = capabilities.firstNotNullOfOrNull { capability ->
                capability
                    .takeIf { it.startsWith(WORKSPACE_CAPABILITY_PREFIX) }
                    ?.removePrefix(WORKSPACE_CAPABILITY_PREFIX)
                    ?.takeIf { it.isNotBlank() }
            } ?: return null
            val directories = capabilities.mapNotNull { capability ->
                capability
                    .takeIf { it.startsWith(WRITE_DIRECTORY_PREFIX) }
                    ?.removePrefix(WRITE_DIRECTORY_PREFIX)
                    ?.takeIf { it.isNotBlank() }
            }
            return BotTaskAuthorization(
                workspaceRoot = workspace,
                allowedWriteDirectories = if (directories.isEmpty()) listOf(workspace) else directories,
                canWriteOutsideWorkspace = capabilities.contains(OUTSIDE_WORKSPACE_CAPABILITY),
                canNetworkWrite = capabilities.contains(NETWORK_WRITE_CAPABILITY),
                canDelegateTasks = capabilities.contains(DELEGATE_CAPABILITY),
            )
        }

        internal fun normalize(value: String, root: String): String {
            var text = value.trim()
            if (text == "~") text = System.getProperty("user.home")
            if (text.startsWith("~/")) text = System.getProperty("user.home") + text.drop(1)
            val path = if (Path.of(text).isAbsolute) Path.of(text) else Path.of(root).resolve(text)
            return path.normalize().toString()
        }
    }
}

/** Conservative bash write-target extraction, matching `ShellWriteTargets`. */
public object BotShellWriteTargets {
    private val redirect = Regex("(?:^|[^0-9&])[0-9]*>>?[ \\t]*([^\\s;&|<>)`]+)")
    private val lastOperandCommands = setOf("cp", "mv", "install", "ln")
    private val allOperandCommands = setOf(
        "tee", "mkdir", "touch", "rm", "rmdir", "truncate", "chmod", "chown",
    )

    public fun targets(command: String): List<String> {
        val result = ArrayList<String>()
        for (match in redirect.findAll(command)) {
            val target = match.groupValues[1]
            if (target.isNotEmpty() && target != "/dev/null" && !target.startsWith("&")) {
                result += target
            }
        }
        val tokens = command.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        for ((index, token) in tokens.withIndex()) {
            if (token !in allOperandCommands && token !in lastOperandCommands) continue
            val operands = tokens.drop(index + 1).filter { !it.startsWith("-") }
            if (token in allOperandCommands) {
                val values = if (token == "chmod" || token == "chown") operands.drop(1) else operands
                result += values
            } else {
                operands.lastOrNull()?.let { result += it }
            }
        }
        for (token in tokens) {
            if (token.startsWith("of=")) result += token.removePrefix("of=")
        }
        return result.filter { it.isNotEmpty() }
    }
}

/** The built-in Task authorization slot used by the approval coordinator. */
public object BotTaskAuthorizationGate : BotTaskAuthorizationPort {
    override fun denial(
        call: BotResolvedToolCall,
        bareName: String,
        arguments: JsonValue,
        command: String,
    ): String? {
        if (call.principal.kind != BotSessionKind.TASK) return null
        if (bareName != "write" && bareName != "edit" && bareName != "bash") return null
        val authorization = BotTaskAuthorization.fromCapabilities(call.principal.capabilities)
            ?: return "task_scope:missing_authorization"
        if (bareName == "write" || bareName == "edit") {
            val args = (arguments as? JsonObject)?.members
            val path = args?.let {
                BotJson.string(it["file_path"])?.takeIf { text -> text.isNotBlank() }
                    ?: BotJson.string(it["path"])?.takeIf { text -> text.isNotBlank() }
            } ?: return null
            return if (authorization.allowsWrite(path)) null else "task_scope:path_denied"
        }
        if (command.isEmpty()) return null
        for (target in BotShellWriteTargets.targets(command)) {
            if (!authorization.allowsWrite(target)) return "task_scope:path_denied"
        }
        return null
    }
}

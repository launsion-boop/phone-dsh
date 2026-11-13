// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.nio.file.Path

/**
 * File-write and host-egress effects (`BotEgressEffects.swift`).
 *
 * A `write`/`edit` inside the Bot workspace root is auto: the DSH file sandbox
 * is the boundary. Outside it the resource is the standardized parent
 * directory, so an "always" grant is reusable for the next file in the same
 * directory and is never keyed by content or argument digest.
 */
public object BotEgressEffects {
    public const val TOOL_NAME: String = "egress"

    public fun fileEffects(
        tool: String,
        arguments: JsonValue,
        workspaceRoot: String,
        language: BotToolLanguage = BotToolLanguage.ZH,
    ): List<BotToolEffect> {
        if (tool != "write" && tool != "edit") return emptyList()
        val args = (arguments as? JsonObject)?.members
        val rawPath = args?.let { BotJson.string(it["file_path"]) }
        if (rawPath == null || rawPath.trim().isEmpty()) {
            return listOf(
                BotToolEffect(
                    tool = tool,
                    operation = "tool.unclassified",
                    resource = "unclassified=$tool&args=invalid",
                    target = tool,
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.ASK,
                    label = if (language == BotToolLanguage.ZH) {
                        "执行未分类文件工具 $tool"
                    } else {
                        "Run unclassified file tool $tool"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "file_path 缺失或为空；默认需要用户审批。"
                    } else {
                        "file_path is missing or empty; it needs approval by default."
                    },
                    known = false,
                ),
            )
        }
        val target = resolve(rawPath, workspaceRoot)
        if (isInsideWorkspace(target, workspaceRoot)) return emptyList()
        val directory = directoryResource(target)
        val operation = if (tool == "write") "file.write" else "file.edit"
        val label: String
        val detail: String
        if (language == BotToolLanguage.ZH) {
            label = if (tool == "write") "写入工作区外的文件" else "编辑工作区外的文件"
            detail = "目标 $target 不在这个 Bot 的工作区 $workspaceRoot 内；授权按目录 $directory 记住。"
        } else {
            label = if (tool == "write") {
                "Write a file outside the Bot workspace"
            } else {
                "Edit a file outside the Bot workspace"
            }
            detail = "The target $target is outside this Bot's workspace $workspaceRoot; " +
                "the approval is remembered per directory $directory."
        }
        return listOf(
            BotToolEffect(
                tool = tool,
                operation = operation,
                resource = directory,
                target = target,
                mutability = BotToolMutability.WRITE,
                policy = BotToolPolicy.ASK,
                label = label,
                detail = detail,
                known = true,
            ),
        )
    }

    public fun resolve(path: String, workspaceRoot: String): String {
        val trimmed = path.trim()
        val absolute = if (Path.of(trimmed).isAbsolute) {
            Path.of(trimmed)
        } else {
            Path.of(workspaceRoot).resolve(trimmed)
        }
        return absolute.normalize().toString()
    }

    public fun isInsideWorkspace(path: String, workspaceRoot: String): Boolean {
        val root = Path.of(workspaceRoot).normalize().toString().trimEnd('/').ifEmpty { "/" }
        if (root == "/") return true
        val candidate = Path.of(path).normalize().toString()
        return candidate == root || candidate.startsWith("$root/")
    }

    public fun directoryResource(path: String): String {
        val parent = Path.of(path).normalize().parent ?: Path.of("/")
        return "dir=${parent.normalize()}"
    }

    public fun egressOperation(method: String): String = "egress.${method.lowercase()}"

    public fun egressResource(host: String): String = "host=${host.lowercase().trim()}"

    public fun egressEffect(
        method: String,
        host: String,
        target: String,
        language: BotToolLanguage = BotToolLanguage.ZH,
    ): BotToolEffect {
        val upper = method.uppercase()
        val resource = egressResource(host)
        val label = if (language == BotToolLanguage.ZH) {
            "向 $host 发送网络 $upper 请求"
        } else {
            "Send a network $upper request to $host"
        }
        val detail = if (language == BotToolLanguage.ZH) {
            "这是 Bot 会话在宿主出口发出的网络写入；授权按主机与方法记住。"
        } else {
            "This is a Bot-session network write at the host exit; the approval is remembered per host and method."
        }
        return BotToolEffect(
            tool = TOOL_NAME,
            operation = egressOperation(upper),
            resource = resource,
            target = target,
            mutability = BotToolMutability.EXTERNAL_SEND,
            policy = BotToolPolicy.ASK,
            label = label,
            detail = detail,
            known = true,
        )
    }
}

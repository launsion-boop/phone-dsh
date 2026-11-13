// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.nio.file.Path

/** One advisory destructive-command match (`BotApprovalPatternMatch`). */
public data class BotApprovalPatternMatch(
    public val kind: String,
    public val label: String,
    public val detail: String,
    public val target: String,
    public val resource: String,
    public val askAction: String = "run-command",
    public val grantKeys: List<String>,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "kind" to JsonString(kind),
        "label" to JsonString(label),
        "detail" to JsonString(detail),
        "target" to JsonString(target),
        "resource" to JsonString(resource),
        "askAction" to JsonString(askAction),
        "grantKeys" to JsonArray(grantKeys.map(::JsonString)),
    )
}

/**
 * The frozen destructive-command analyzer (`BotApprovalPatternAnalyzer.swift`).
 *
 * Network command spelling is deliberately not an effect on phone: the host
 * `/v1/http` exit owns host+method approval, and command text is
 * model-controlled. `rm`, `git reset --hard` and `find -delete` stay as
 * advisory card hints.
 */
public object BotApprovalPatternAnalyzer {
    private val rmPattern = Regex("(?:^|[;&|]\\s*)rm\\s+(?:[^\\s;&|]+\\s+)*-", RegexOption.IGNORE_CASE)
    private val gitResetPattern = Regex("(?:^|[;&|]\\s*)git\\s+reset\\s+[^\\n]*--hard", RegexOption.IGNORE_CASE)
    private val findDeletePattern = Regex("(?:^|[;&|]\\s*)find\\s+[^\\n]*(?:\\s|^)-delete(?:\\s|$)", RegexOption.IGNORE_CASE)

    public fun analyze(
        tool: String,
        arguments: JsonValue,
        workspace: String,
        language: BotToolLanguage = BotToolLanguage.EN,
    ): List<BotApprovalPatternMatch> {
        if (tool != "bash") return emptyList()
        val args = (arguments as? JsonObject)?.members ?: return emptyList()
        val command = BotJson.string(args["command"]) ?: return emptyList()
        if (command.isEmpty()) return emptyList()
        if (rmPattern.containsMatchIn(command) || command.startsWith("rm ")) {
            return listOf(
                match(
                    kind = "rm-destructive",
                    zhLabel = "删除文件或目录（rm）",
                    enLabel = "Delete files or directories (rm)",
                    zhDetail = "这个命令会删除文件或目录：$command",
                    enDetail = "This command deletes files or directories: $command",
                    command = command,
                    resource = rmResource(command, workspace),
                    language = language,
                ),
            )
        }
        if (gitResetPattern.containsMatchIn(command)) {
            return listOf(
                match(
                    kind = "git-destructive",
                    zhLabel = "丢弃 Git 工作区变更",
                    enLabel = "Discard Git working-tree changes",
                    zhDetail = "这个命令会丢弃未提交的变更：$command",
                    enDetail = "This command discards uncommitted changes: $command",
                    command = command,
                    resource = command,
                    language = language,
                ),
            )
        }
        if (findDeletePattern.containsMatchIn(command)) {
            return listOf(
                match(
                    kind = "find-delete",
                    zhLabel = "使用 find -delete 删除文件",
                    enLabel = "Delete files with find -delete",
                    zhDetail = "find -delete 会移除符合条件的文件：$command",
                    enDetail = "find -delete removes the matching files: $command",
                    command = command,
                    resource = command,
                    language = language,
                ),
            )
        }
        return emptyList()
    }

    public fun effects(
        tool: String,
        arguments: JsonValue,
        workspace: String,
        language: BotToolLanguage = BotToolLanguage.EN,
    ): List<BotToolEffect> = analyze(tool, arguments, workspace, language).map {
        BotToolEffect(
            tool = tool,
            operation = it.kind,
            resource = it.resource,
            target = it.target,
            mutability = BotToolMutability.DESTRUCTIVE,
            policy = BotToolPolicy.ASK,
            label = it.label,
            detail = it.detail,
        )
    }

    private fun match(
        kind: String,
        zhLabel: String,
        enLabel: String,
        zhDetail: String,
        enDetail: String,
        command: String,
        resource: String,
        language: BotToolLanguage,
    ): BotApprovalPatternMatch = BotApprovalPatternMatch(
        kind = kind,
        label = if (language == BotToolLanguage.ZH) zhLabel else enLabel,
        detail = if (language == BotToolLanguage.ZH) zhDetail else enDetail,
        target = command,
        resource = resource,
        grantKeys = listOf(command),
    )

    private fun rmResource(command: String, workspace: String): String {
        val tokens = command.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val rmIndex = tokens.indexOf("rm")
        if (rmIndex < 0) return command
        val operand = tokens.drop(rmIndex + 1).firstOrNull {
            !it.startsWith("-") && it != "--"
        } ?: return command
        val path = if (Path.of(operand).isAbsolute) {
            Path.of(operand)
        } else {
            Path.of(workspace).resolve(operand)
        }
        return path.normalize().toString()
    }
}

/** File-level facade matching the lane's `BotApprovalPatterns` name. */
public object BotApprovalPatterns {
    public fun analyze(
        tool: String,
        arguments: JsonValue,
        workspace: String,
        language: BotToolLanguage = BotToolLanguage.EN,
    ): List<BotApprovalPatternMatch> =
        BotApprovalPatternAnalyzer.analyze(tool, arguments, workspace, language)

    public fun effects(
        tool: String,
        arguments: JsonValue,
        workspace: String,
        language: BotToolLanguage = BotToolLanguage.EN,
    ): List<BotToolEffect> =
        BotApprovalPatternAnalyzer.effects(tool, arguments, workspace, language)
}

// Display formatting shared by the Bot info page and its sub-pages.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotUIFormat.swift`. Dates are
// fixed to Simplified Chinese with a 24-hour clock and the device time zone, so
// an English system locale never leaks an English date into the Chinese UI. Raw
// host values (routine delivery, creator references, grant scopes, operation
// ids, paths) are mapped here; every mapper falls back to 其他 and the raw value
// stays in the detail disclosure.
package com.phonedsh.ui.bot.page.info

import com.phonedsh.ui.bot.state.BotMemoryScope
import com.phonedsh.ui.bot.state.BotMaintenanceChange
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

/** Pure display formatting for the Bot info surfaces. */
public object BotInfoFormat {
    /** Display fallback for an enum-like value this build does not know. */
    public const val UNKNOWN: String = "其他"

    /** `今天 22:12`, `10月9日 22:12` (this year), or `2025年10月9日 22:12`. */
    public fun dateTime(
        milliseconds: Long,
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val value = ZonedDateTime.ofInstant(Instant.ofEpochMilli(milliseconds), zone)
        val current = ZonedDateTime.ofInstant(Instant.ofEpochMilli(now), zone)
        val day = when {
            value.toLocalDate() == current.toLocalDate() -> "今天"
            value.year == current.year -> "${value.monthValue}月${value.dayOfMonth}日"
            else -> "${value.year}年${value.monthValue}月${value.dayOfMonth}日"
        }
        return "$day ${time(milliseconds, zone)}"
    }

    /** `HH:mm`. */
    public fun time(milliseconds: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val value = ZonedDateTime.ofInstant(Instant.ofEpochMilli(milliseconds), zone)
        return "%02d:%02d".format(value.hour, value.minute)
    }

    /** The last path component, as the memory rows display it. */
    public fun fileName(path: String): String =
        path.split('/').lastOrNull { it.isNotEmpty() } ?: path

    /** `M月d日`. */
    public fun monthDay(milliseconds: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val value = ZonedDateTime.ofInstant(Instant.ofEpochMilli(milliseconds), zone)
        return "${value.monthValue}月${value.dayOfMonth}日"
    }

    /** `25%`; a non-positive total renders `—` instead of dividing by zero. */
    public fun percent(used: Long, total: Long): String {
        if (total <= 0L) return "—"
        val ratio = (used.toDouble() / total.toDouble() * 100.0).coerceIn(0.0, 100.0)
        return "${ratio.toInt()}%"
    }

    /** `held` → `下次聊天时送达`, `interrupt` → `立即提醒`. */
    public fun routineDelivery(rawValue: String): String = when (key(rawValue)) {
        "held", "存入待处理", "queued", "下次聊天时送达" -> "下次聊天时送达"
        "interrupt", "立即打断", "立即提醒" -> "立即提醒"
        else -> UNKNOWN
    }

    /** Maps the flattened creator string without printing its ids. */
    public fun routineCreator(rawValue: String?): String? {
        val value = rawValue?.let(::key).orEmpty()
        if (value.isEmpty()) return null
        if (value.contains("经用户确认") || value.contains("user-confirmed")) {
            return "你确认后创建"
        }
        if (value.contains("用户回合") || value.contains("user-turn") || value.contains("对话中")) {
            return "由你在对话中创建"
        }
        if (value.contains("其他 bot") || value.contains("bot") || value.contains("agent")) {
            return "由其他 Bot 创建"
        }
        if (value.contains("例行任务") || value.contains("routine")) {
            return "由例行任务创建"
        }
        if (value.contains("子任务") || value.contains("task")) {
            return "由子任务创建"
        }
        if (value.contains("后台") || value.contains("held")) {
            return "由后台回合创建"
        }
        return "其他来源"
    }

    /** `until` → `长期有效`, `session` → `本次会话`, `once` → `仅本次`. */
    public fun grantScope(rawValue: String): String = when (key(rawValue)) {
        "until" -> "长期有效"
        "session" -> "本次会话"
        "once" -> "仅本次"
        else -> UNKNOWN
    }

    /** `approval-card` → `来自审批卡`, `approval-standing` → `来自常设审批`. */
    public fun grantSource(rawValue: String): String = when (key(rawValue)) {
        "approval-card" -> "来自审批卡"
        "approval-standing" -> "来自常设审批"
        "approval" -> "来自审批"
        else -> UNKNOWN
    }

    /** Human title for one grant/approval operation id. */
    public fun grantOperationTitle(rawValue: String): String {
        val value = key(rawValue)
        if (value.startsWith("egress.")) return "访问网络"
        if (value.startsWith("ui.")) return "显示卡片"
        return when (value) {
            "write.file", "file.write" -> "写入文件"
            "file.edit" -> "编辑文件"
            "network-egress" -> "访问网络"
            "rm-destructive", "find-delete" -> "删除文件"
            "git-destructive" -> "丢弃改动"
            "dshbot.task" -> "启动子任务"
            "dshbot.awaittask" -> "等待子任务"
            "dshbot.stopsubagent" -> "停止子任务"
            "dshbot.sendtouser" -> "发送消息"
            "dshbot.sendtoagent" -> "给其他 Bot 发消息"
            "dshbot.createteammate" -> "创建协作 Bot"
            "dshbot.updateroutine" -> "修改例行任务"
            "dshbot.listroutines" -> "查看例行任务"
            "memory.read" -> "读取记忆"
            "memory.recall" -> "回想记忆"
            "memory.sort" -> "整理记忆"
            "memory.write" -> "写入记忆"
            "memory.forget" -> "删除记忆"
            "ble.devices" -> "发现蓝牙设备"
            "ble.read" -> "读取设备数据"
            "ble.link_tools" -> "查看设备工具"
            "ble.link_result" -> "读取设备结果"
            "ble.alert" -> "提醒设备"
            "ble.link_call" -> "调用设备工具"
            else -> UNKNOWN
        }
    }

    /** Network resources keep only the host; every other value is path-aware. */
    public fun grantResourceSummary(resource: String, operation: String): String {
        val value = resource.trim()
        if (value.isEmpty()) return UNKNOWN
        val normalizedOperation = key(operation)
        if (normalizedOperation == "network-egress" || normalizedOperation.startsWith("egress.")) {
            urlHost(value)?.let { return it }
            if (key(value).startsWith("host=")) return pathSummary(value)
            return "网络资源"
        }
        return pathSummary(value)
    }

    /** `allow` + scope → the human decision; `deny` → `拒绝`. */
    public fun approvalDecision(
        decision: String,
        scope: String? = null,
        status: String? = null,
    ): String {
        when (key(status.orEmpty())) {
            "expired" -> return "已过期（视为拒绝）"
            "timed-out", "timed_out", "timedout", "timeout" -> return "已超时（视为拒绝）"
            "cancelled", "canceled" -> return "已取消"
            else -> Unit
        }
        val normalizedScope = key(scope.orEmpty())
        return when (key(decision)) {
            "allowonce", "allow-once", "allow" -> when (normalizedScope) {
                "session" -> "本次会话允许"
                "until" -> "总是允许"
                else -> "允许一次"
            }
            "always", "allowed" -> when (normalizedScope) {
                "session" -> "本次会话允许"
                "once" -> "允许一次"
                else -> "总是允许"
            }
            "deny", "denied" -> "拒绝"
            else -> UNKNOWN
        }
    }

    /** `Asia/Shanghai` → `上海时间（UTC+8）`; the raw IANA id stays in 详情. */
    public fun routineTimeZone(
        rawValue: String,
        milliseconds: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val identifier = rawValue.trim()
        if (identifier.isEmpty()) return UNKNOWN
        val resolved = runCatching { ZoneId.of(identifier) }.getOrNull() ?: return UNKNOWN
        val cityName = when (key(identifier)) {
            "asia/shanghai", "prc", "asia/chongqing", "asia/harbin" -> "上海时间"
            "asia/tokyo", "japan" -> "东京时间"
            "asia/seoul", "rok" -> "首尔时间"
            "asia/singapore" -> "新加坡时间"
            "asia/hong_kong", "hongkong" -> "香港时间"
            "asia/taipei" -> "台北时间"
            "asia/macau" -> "澳门时间"
            "asia/bangkok" -> "曼谷时间"
            "asia/jakarta" -> "雅加达时间"
            "asia/kolkata", "asia/calcutta" -> "印度时间"
            "asia/dubai" -> "迪拜时间"
            "europe/london", "gb" -> "伦敦时间"
            "europe/paris" -> "巴黎时间"
            "europe/berlin" -> "柏林时间"
            "america/new_york" -> "纽约时间"
            "america/los_angeles" -> "洛杉矶时间"
            "australia/sydney" -> "悉尼时间"
            "utc", "gmt", "etc/utc", "etc/gmt" -> "协调世界时"
            else -> if (identifier == zone.id) "当前时区" else ""
        }
        val offset = utcOffset(
            resolved.rules.getOffset(Instant.ofEpochMilli(milliseconds)).totalSeconds,
        )
        return if (cityName.isEmpty()) "$offset 时区" else "$cityName（$offset）"
    }

    /** Free text that carries internal tokens is never paraphrased on the main row. */
    public fun routineFreeTextNeedsDetail(rawValue: String): Boolean {
        val value = rawValue.trim()
        if (value.isEmpty()) return false
        if (value.contains("`") || value.contains("://")) return true
        if (BRACKETED.containsMatchIn(value)) return true
        if (CAMEL_TOOL.containsMatchIn(value)) return true
        val lowered = value.lowercase()
        return KNOWN_TOKENS.any { lowered.contains(it) }
    }

    /** The reason sentence shown under the one reconciliation block. */
    public fun routineReconciliationReason(rawValue: String?): String? {
        var reason = rawValue?.trim().orEmpty()
        if (reason.isEmpty()) return null
        for (prefix in REASON_PREFIXES) {
            if (reason.startsWith(prefix)) {
                reason = reason.removePrefix(prefix).trim()
                break
            }
        }
        if (reason.isEmpty()) return null
        val asciiOnly = reason.all { it.code < 128 } && reason.any { it.isLetter() }
        if (asciiOnly || routineFreeTextNeedsDetail(reason)) {
            return "这次运行在确认结果前中断。"
        }
        return if (reason.last() in "。！？.!?") reason else "$reason。"
    }

    /** Human label for one maintenance batch status (`BotInfoPage.swift:1008-1018`). */
    public fun maintenanceStatusLabel(status: String, rolledBack: Boolean): String {
        if (rolledBack) return BotInfoCopy.MAINTENANCE_STATUS_ROLLED_BACK_FLAG
        return when (key(status)) {
            "committed" -> BotInfoCopy.MAINTENANCE_STATUS_COMMITTED
            "cancelled" -> BotInfoCopy.MAINTENANCE_STATUS_CANCELLED
            "failed" -> BotInfoCopy.MAINTENANCE_STATUS_FAILED
            "rolled_back" -> BotInfoCopy.MAINTENANCE_STATUS_ROLLED_BACK
            "rollback_failed" -> BotInfoCopy.MAINTENANCE_STATUS_ROLLBACK_FAILED
            else -> BotInfoCopy.MAINTENANCE_STATUS_UNKNOWN
        }
    }

    /** Main-row change label; full paths stay in 查看详情 (`:1020-1049`). */
    public fun maintenanceChangeLabel(change: BotMaintenanceChange): String {
        val name = maintenanceDocumentName(change.path, change.scope)
        return if (change.deleted) {
            BotInfoCopy.format(BotInfoCopy.MAINTENANCE_CHANGE_DELETED, "name" to name)
        } else {
            BotInfoCopy.format(
                BotInfoCopy.MAINTENANCE_CHANGE_VERSIONS,
                "name" to name,
                "before" to change.beforeVersion,
                "after" to change.afterVersion,
            )
        }
    }

    /** The same change with its full `user/`/`agent/` path, for 查看详情. */
    public fun maintenanceChangeDetail(change: BotMaintenanceChange): String =
        if (change.deleted) {
            "${change.path}：已删除"
        } else {
            "${change.path}：第 ${change.beforeVersion} 版 → 第 ${change.afterVersion} 版"
        }

    /**
     * Main-view name for one maintenance change. `INDEX.md` and `profile.md` get
     * a purpose label instead of a bare file name (`BotInfoPage.swift:1036-1049`).
     */
    public fun maintenanceDocumentName(
        path: String,
        scope: BotMemoryScope,
    ): String = maintenanceDocumentName(path, scope.wire)

    public fun maintenanceDocumentName(path: String, scope: String): String {
        var relative = path
        if (relative.startsWith("user/")) relative = relative.removePrefix("user/")
        else if (relative.startsWith("agent/")) relative = relative.removePrefix("agent/")
        val fileName = relative.split('/').lastOrNull() ?: relative
        val shared = scope == "user" || path.startsWith("user/")
        return when (fileName) {
            "INDEX.md" -> if (shared) {
                BotInfoCopy.MAINTENANCE_SHARED_INDEX
            } else {
                BotInfoCopy.MAINTENANCE_BOT_INDEX
            }
            "profile.md" -> if (shared) {
                BotInfoCopy.MAINTENANCE_SHARED_PROFILE
            } else {
                BotInfoCopy.MAINTENANCE_BOT_PROFILE
            }
            else -> if (shared) {
                BotInfoCopy.format(BotInfoCopy.MAINTENANCE_SHARED_DOC, "path" to relative)
            } else {
                BotInfoCopy.format(BotInfoCopy.MAINTENANCE_BOT_DOC, "path" to relative)
            }
        }
    }

    /** `对话来源 2 条 · 记录来源 1 条`; `无来源` for an empty list. */
    public fun evidenceSummary(evidence: List<String>): String {
        if (evidence.isEmpty()) return BotInfoCopy.DOCUMENT_NO_EVIDENCE
        val counts = linkedMapOf(
            BotInfoCopy.EVIDENCE_SESSION to 0,
            BotInfoCopy.EVIDENCE_EVENT to 0,
            BotInfoCopy.EVIDENCE_OTHER to 0,
        )
        evidence.forEach { reference ->
            val kind = evidenceKind(reference)
            counts[kind] = (counts[kind] ?: 0) + 1
        }
        val parts = counts.mapNotNull { (name, count) ->
            if (count == 0) null else "$name $count 条"
        }
        return if (parts.isEmpty()) {
            BotInfoCopy.DOCUMENT_NO_EVIDENCE
        } else {
            parts.joinToString(" · ")
        }
    }

    public fun evidenceKind(reference: String): String = when {
        reference.startsWith("record://session/") -> BotInfoCopy.EVIDENCE_SESSION
        reference.startsWith("record://event/") -> BotInfoCopy.EVIDENCE_EVENT
        else -> BotInfoCopy.EVIDENCE_OTHER
    }

    /** A trailing glob becomes `reports 文件夹`; `…/agent/profile.md` becomes `profile.md`. */
    public fun pathSummary(path: String, isDirectory: Boolean = false): String {
        var value = path.trim()
        var directory = isDirectory
        if (value.lowercase().startsWith("dir=")) {
            value = value.drop(4)
            directory = true
        }
        var relative = workspaceRelativePath(value)
        while (relative.startsWith("./")) relative = relative.drop(2)
        relative = relative.trim('/')
        if (relative.isEmpty() || relative == ".") return "Bot 工作区"
        if (relative.endsWith("/**")) {
            relative = relative.dropLast(3)
            directory = true
        }
        if (relative.endsWith("/")) {
            relative = relative.dropLast(1)
            directory = true
        }
        val parts = relative.split('/').filter { it.isNotEmpty() }
        val last = parts.lastOrNull() ?: return "Bot 工作区"
        return if (directory) "${parts.joinToString("/")} 文件夹" else last
    }

    private fun workspaceRelativePath(path: String): String {
        var value = path.trim()
        if (value.lowercase().startsWith("dir=")) value = value.drop(4)
        val agentMarker = "/.dshbot/agents/"
        val agentIndex = value.indexOf(agentMarker)
        if (agentIndex >= 0) {
            val remainder = value.substring(agentIndex + agentMarker.length)
            val slash = remainder.indexOf('/')
            return if (slash < 0) "" else remainder.substring(slash + 1)
        }
        val workspaceMarker = "/dsh/workspace/"
        val workspaceIndex = value.indexOf(workspaceMarker)
        if (workspaceIndex >= 0) return value.substring(workspaceIndex + workspaceMarker.length)
        return value
    }

    private fun urlHost(value: String): String? =
        URL_HOST.find(value)?.value

    private fun utcOffset(seconds: Int): String {
        val sign = if (seconds < 0) "-" else "+"
        val magnitude = kotlin.math.abs(seconds)
        val hours = magnitude / 3_600
        val minutes = (magnitude % 3_600) / 60
        return if (minutes == 0) "UTC$sign$hours" else "UTC$sign$hours:${minutes.toString().padStart(2, '0')}"
    }

    private fun key(value: String): String = value.trim().lowercase()

    private val URL_HOST = Regex("""https?://[^\s/]+""", RegexOption.IGNORE_CASE)
    private val BRACKETED = Regex("""\[[^\]\n]{1,40}\]""")
    private val CAMEL_TOOL = Regex("""\b[A-Z][a-z]+(?:[A-Z][a-z0-9]+)+\b""")
    private val KNOWN_TOKENS = listOf(
        "sendtouser", "sendtoagent", "updateroutine", "listroutines",
        "createteammate", "readmemory", "writememory", "recallmemory",
        "forgetmemory", "awaittask", "stopsubagent", "record://",
    )
    private val REASON_PREFIXES = listOf(
        "投递结果未知：", "投递结果未知:", "執行結果未知，需要確認：",
        "执行结果未知，需要确认：", "执行结果未知：", "结果未知：", "未知原因：",
    )
}

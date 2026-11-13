// Geometry, copy and stable ids for the Bot information page and its sub-pages.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift` and
// `spec/ui/v1/pages/bot-info.md`. Section/row chrome reuses the app's
// `PageFrame` + `SessionSectionLabel`; the page-specific sizes below are the
// Swift view's measured points. Normative error/status copy comes from
// `BotUiStrings`; labels `strings.json` does not freeze are in [BotInfoCopy].
package com.phonedsh.ui.bot.page.info

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Measured geometry of the info page (`BotInfoPage.swift:571-1867`). */
public object BotInfoMetrics {
    /** The header avatar (`BotInfoPage.swift:576`). */
    public val HEADER_FISH: Dp = 80.dp

    /** Header name/description type (`BotInfoPage.swift:579,583`). */
    public val HEADER_NAME_SIZE: TextUnit = 22.sp
    public val HEADER_DESCRIPTION_SIZE: TextUnit = 14.sp

    /** Header vertical padding (`BotInfoPage.swift:588`). */
    public val HEADER_PADDING_V: Dp = 8.dp
    public val HEADER_GAP: Dp = 12.dp

    /** Appearance section row padding (`BotInfoPage.swift:612`). */
    public val APPEARANCE_PADDING_V: Dp = 12.dp

    /** The data entry icon slot (`BotInfoPage.swift:781-785`). */
    public val ENTRY_ICON: Dp = 24.dp
    public val ENTRY_ICON_SIZE: Dp = 17.dp
    public val ENTRY_MIN_HEIGHT: Dp = 32.dp
    public val ENTRY_GAP: Dp = 12.dp

    /** Status indicator a data entry uses (`BotInfoPage.swift:789-800`). */
    public val ENTRY_STATUS_SIZE: TextUnit = 15.sp

    /** A header action's 44 pt hit area (`BotInfoPage.swift:696-703`). */
    public val ACTION: Dp = 44.dp

    /** Confirmation dialog width cap (`HomeDrawer.swift:722`). */
    public val CONFIRM_MAX_WIDTH: Dp = 360.dp

    /** The small in-row progress indicator (`BotInfoPage.swift:794`). */
    public val ENTRY_PROGRESS: Dp = 16.dp
    public val ENTRY_PROGRESS_STROKE: Dp = 1.5.dp

    /** Memory document row icon (`BotInfoPage.swift:1093`). */
    public val DOCUMENT_ICON: Dp = 16.dp

    /** Field label column in the routine grid (`BotInfoPage.swift:1531`). */
    public val ROUTINE_LABEL_WIDTH: Dp = 64.dp

    /** Warning wash of the one reconciliation block (`BotInfoPage.swift:1452`). */
    public const val RECONCILIATION_FILL_ALPHA: Float = 0.08f

    /** Status-pill fill opacity (`BotUIComponents.swift`, `BotStatusPill`). */
    public const val PILL_FILL_ALPHA: Float = 0.12f

    /** Label/value or disclosure gap (`BotInfoPage.swift:1535,1612`). */
    public val LABEL_GAP: Dp = 6.dp

    /** Routine row vertical padding (`BotInfoPage.swift:1425`). */
    public val ROUTINE_PADDING_V: Dp = 4.dp

    /** Reconciliation block inset/radius (`BotInfoPage.swift:1450-1453`). */
    public val RECONCILIATION_PADDING: Dp = 10.dp
    public val RECONCILIATION_RADIUS: Dp = 10.dp

    /** Routine detail disclosure surface (`BotInfoPage.swift:1640-1643`). */
    public val DETAIL_PADDING: Dp = 10.dp
    public val DETAIL_RADIUS: Dp = 10.dp

    /** Routine status pill insets (`BotInfoPage.swift:1350`). */
    public val PILL_PADDING_H: Dp = 8.dp
    public val PILL_PADDING_V: Dp = 3.dp

    /** Grant detail divider (`BotInfoPage.swift:1708-1710`). */
    public val HAIRLINE: Dp = 0.5.dp

    /** Maintenance/footnote type (`BotInfoPage.swift:965-970`). */
    public val CAPTION_SIZE: TextUnit = 12.sp
    public val CAPTION_13: TextUnit = 13.sp

    /** Long-value routine field line box (`BotInfoPage.swift:1553`). */
    public val ROUTINE_VALUE_LINE: TextUnit = 22.sp
    public val ROUTINE_VALUE_SIZE: TextUnit = 15.sp

    /** Danger section vertical inset (`BotInfoPage.swift:1717`). */
    public val GRANT_PADDING_V: Dp = 4.dp
}

/**
 * Copy `spec/ui/v1/bot/strings.json` does not freeze: section titles, field
 * labels and confirmation bodies from `BotInfoPage.swift`. Every error/status
 * string that *is* frozen comes from `BotUiStrings` at the call site.
 */
public object BotInfoCopy {
    public const val TITLE: String = "Bot 信息"
    public const val DONE: String = "完成"
    public const val REFRESH: String = "刷新"
    public const val NAME_SECTION: String = "Bot 名称"
    public const val NAME_PLACEHOLDER: String = "给 Bot 起个名字"
    public const val SAVE_NAME: String = "保存名称"
    public const val APPEARANCE_SECTION: String = "外观"
    public const val PRESENCE_SECTION: String = "在场"
    public const val DISRUPTION_SECTION: String = "打扰"
    public const val DATA_SECTION: String = "数据"
    public const val DANGER_SECTION: String = "危险操作"
    public const val DEFAULT_DESCRIPTION: String = "你的私人 Bot，替你跟进任务和提醒"

    public const val DATA_MEMORY: String = "记忆"
    public const val DATA_ROUTINES: String = "例行任务"
    public const val DATA_APPROVALS: String = "审批记录"
    public const val DATA_GRANTS: String = "常设授权"
    public const val DELETE_BOT: String = "删除这个 Bot"
    public const val DELETE_TITLE: String = "删除这个 Bot？"
    public const val DELETE_CONFIRM: String = "删除"
    public const val DELETING: String = "正在删除…"

    // Presence (`BotInfoPage.swift:1739-1769`).
    public const val PRESENCE_LEVEL: String = "当前级别"
    public const val PRESENCE_LEVEL_FOREGROUND: String = "前台"
    public const val PRESENCE_LEVEL_BACKGROUND: String = "后台保活"
    public const val PRESENCE_LEVEL_SCHEDULED: String = "预定通知"
    public const val PRESENCE_NOTIFICATIONS: String = "已登记提醒"
    public const val PRESENCE_NONE_DEFERRED: String = "没有因安静时段延后的例行任务。"
    public const val PRESENCE_DEFERRED_FROM: String = "原定 {from}，延后到 {until}"

    // Disturbance (`BotInfoPage.swift:1772-1795`).
    public const val DND: String = "勿扰"
    public const val QUIET_START: String = "安静时段开始"
    public const val QUIET_END: String = "安静时段结束"
    public const val TIME_CONFIRM: String = "确定"

    // Memory (`BotInfoPage.swift:805-1239`).
    public const val MEMORY_TITLE: String = "记忆"
    public const val MAINTENANCE_TITLE: String = "后台整理"
    public const val MAINTENANCE_SWITCH: String = "后台记忆整理"
    public const val MEMORY_EMPTY: String = "还没有已保存的记忆。"
    public const val MEMORY_ROOT_EMPTY: String = "还没有文档。"
    public const val MAINTENANCE_BATCH: String = "上次整理"
    public const val MAINTENANCE_DETAIL: String = "查看详情"
    public const val MAINTENANCE_COLLAPSE: String = "收起详情"
    public const val MAINTENANCE_CHANGED: String = "{count} 份文档 · 检查{result}"
    public const val MAINTENANCE_CHECKED: String = "通过"
    public const val MAINTENANCE_UNCHECKED: String = "未通过"
    public const val MAINTENANCE_TOKENS: String = "本次用量：{tokens} token"
    public const val MAINTENANCE_FAILURE: String = "失败原因：{code}"
    public const val MAINTENANCE_BUDGET: String = "今日整理额度已用 {ratio}。"
    public const val MAINTENANCE_BUDGET_EXHAUSTED: String = "今日整理额度已用完。"
    public const val MAINTENANCE_STATUS_COMMITTED: String = "已完成"
    public const val MAINTENANCE_STATUS_CANCELLED: String = "已取消（已写入的保留）"
    public const val MAINTENANCE_STATUS_FAILED: String = "未完成"
    public const val MAINTENANCE_STATUS_ROLLED_BACK: String = "已整批回滚"
    public const val MAINTENANCE_STATUS_ROLLBACK_FAILED: String = "回滚有冲突"
    public const val MAINTENANCE_STATUS_ROLLED_BACK_FLAG: String = "已回滚"
    public const val MAINTENANCE_STATUS_UNKNOWN: String = "状态未知"
    public const val MAINTENANCE_CHANGE_DELETED: String = "{name}：已删除"
    public const val MAINTENANCE_CHANGE_VERSIONS: String = "{name}：第 {before} 版 → 第 {after} 版"
    public const val MAINTENANCE_SHARED_INDEX: String = "共享索引 INDEX.md"
    public const val MAINTENANCE_BOT_INDEX: String = "本 Bot 索引 INDEX.md"
    public const val MAINTENANCE_SHARED_PROFILE: String = "共享资料 profile.md"
    public const val MAINTENANCE_BOT_PROFILE: String = "本 Bot 资料 profile.md"
    public const val MAINTENANCE_SHARED_DOC: String = "共享记忆 {path}"
    public const val MAINTENANCE_BOT_DOC: String = "本 Bot 记忆 {path}"
    public const val MAINTENANCE_ROLLBACK_CONFIRM_TITLE: String = "回滚这次整理？"
    public const val MAINTENANCE_ROLLBACK_CONFIRM: String = "整批回滚"
    public const val MAINTENANCE_ROLLBACK_BODY: String =
        "本批改动过的每份文档都会恢复到整理前的版本；之后又被改过的文档会保留并报告冲突。"
    public const val DOCUMENT_COUNT: String = "{count} 条来源"
    public const val DOCUMENT_NO_EVIDENCE: String = "无来源"
    public const val DOCUMENT_VERSION: String = "第 {version} 版 · {time} · {evidence}"
    public const val DOCUMENT_TITLE: String = "正文"
    public const val DOCUMENT_PATH: String = "路径：{path}"
    public const val DOCUMENT_SOURCES: String = "来源"
    public const val DOCUMENT_NO_SOURCES: String = "没有来源引用。"
    public const val DOCUMENT_AUTHOR: String = "作者"
    public const val DOCUMENT_UPDATED: String = "更新时间"
    public const val DOCUMENT_VERSIONS: String = "版本"
    public const val DOCUMENT_VERSION_ROW: String = "第 {version} 版"
    public const val DOCUMENT_CURRENT: String = "当前"
    public const val DOCUMENT_VERSION_DELETED: String = "这一版已被删除。"
    public const val DOCUMENT_EMPTY: String = "（空文档）"
    public const val DOCUMENT_UNKNOWN: String = "未知"
    public const val FORGET_TITLE: String = "忘记这份文档？"
    public const val FORGET_BODY: String = "忘记只移除当前版本，历史版本仍保留。"
    public const val FORGET_ACTION: String = "忘记这份文档"
    public const val ERASE_DOCUMENT: String = "抹除这份文档和全部历史版本"
    public const val ERASE_DOCUMENT_TITLE: String = "抹除这份文档？"
    public const val ERASE_DOCUMENT_CONFIRM: String = "抹除文档和全部版本"
    public const val ERASE_DOCUMENT_BODY: String =
        "会永久删除这份文档和全部历史版本，相关内容也会从旧对话里移除，共享记忆的其他文档不受影响，无法撤销。"
    public const val ERASE_BOT_TITLE: String = "抹除这个 Bot 的记忆？"
    public const val ERASE_BOT_CONFIRM: String = "抹除这个 Bot 的记忆"
    public const val ERASE_BOT_BODY: String =
        "会永久删除这个 Bot 的记忆和全部历史版本，相关内容也会从旧对话里移除，共享记忆不受影响，无法撤销。"
    public const val ERASE_SHARED_TITLE: String = "抹除所有 Bot 共享的记忆？"
    public const val ERASE_SHARED_CONFIRM: String = "继续"
    public const val ERASE_SHARED_BODY: String =
        "所有 Bot 共享的记忆和全部历史版本会被永久删除，相关内容也会从旧对话里移除，无法撤销。"
    public const val ERASE_SHARED_AGAIN_TITLE: String = "最后确认：抹除全部共享记忆？"
    public const val ERASE_SHARED_AGAIN_CONFIRM: String = "抹除共享记忆"
    public const val ERASE_SHARED_AGAIN_BODY: String =
        "所有 Bot 会立即失去这些共享记忆，全部历史版本也会被永久删除，无法撤销。"
    public const val EVIDENCE_SESSION: String = "对话来源"
    public const val EVIDENCE_EVENT: String = "记录来源"
    public const val EVIDENCE_OTHER: String = "其他来源"

    // Routines (`BotInfoPage.swift:1282-1647`).
    public const val ROUTINES_TITLE: String = "例行任务"
    public const val ROUTINES_EMPTY: String = "还没有例行任务。"
    public const val ROUTINE_SCHEDULE: String = "排程"
    public const val ROUTINE_NEXT_DUE: String = "下次到期"
    public const val ROUTINE_TIMEZONE: String = "时区"
    public const val ROUTINE_DELIVERY: String = "交付"
    public const val ROUTINE_DEFERRED: String = "安静时段延后"
    public const val ROUTINE_DEFERRED_VALUE: String = "原定 {from}，延后至 {until}"
    public const val ROUTINE_QUIET: String = "安静时段会延后"
    public const val ROUTINE_CREATOR: String = "设立者"
    public const val ROUTINE_CRITERIA: String = "完成条件"
    public const val ROUTINE_CONSTRAINTS: String = "约束"
    public const val ROUTINE_URGENT: String = "紧急：{reason}"
    public const val ROUTINE_URGENT_NONE: String = "未说明"
    public const val ROUTINE_FREE_TEXT_SUMMARY: String = "原文包含执行提示。"
    public const val ROUTINE_RECONCILIATION_TITLE: String = "这次运行的结果没有确认"
    public const val ROUTINE_RECONCILIATION_FALLBACK: String =
        "已尝试执行这次运行，结果未确认。"
    public const val ROUTINE_RECONCILIATION_REASON: String = "原因：{reason}"
    public const val ROUTINE_STATUS_STARTED: String = "运行中"
    public const val ROUTINE_STATUS_WAITING_APPROVAL: String = "等待审批"
    public const val ROUTINE_STATUS_RECONCILIATION: String = "待确认"
    public const val ROUTINE_STATUS_SCHEDULED: String = "等待触发"
    public const val ROUTINE_STATUS_ENABLED: String = "已启用"
    public const val ROUTINE_STATUS_PAUSED: String = "已暂停"
    public const val ROUTINE_PAUSE: String = "暂停"
    public const val ROUTINE_RESUME: String = "恢复"
    public const val ROUTINE_CANCEL_TITLE: String = "取消这次运行？"
    public const val ROUTINE_CANCEL_BODY: String = "正在执行的回合会被中止；已经产生的效果会保留。"
    public const val ROUTINE_CANCEL_BACK: String = "返回"
    public const val ROUTINE_DETAIL_SHOW: String = "查看详情"
    public const val ROUTINE_DETAIL_HIDE: String = "收起详情"
    public const val ROUTINE_DETAIL_ID: String = "任务编号"
    public const val ROUTINE_DETAIL_TIMEZONE: String = "时区标识"
    public const val ROUTINE_DETAIL_CREATOR: String = "设立者原始信息"
    public const val ROUTINE_DETAIL_CONSTRAINTS: String = "约束原文"
    public const val ROUTINE_DETAIL_CRITERIA: String = "完成条件原文"
    public const val ROUTINE_DETAIL_RUN: String = "运行编号"
    public const val ROUTINE_DETAIL_EFFECT: String = "效果记录"
    public const val ROUTINE_DETAIL_REASON: String = "原始原因"
    public const val ROUTINE_DETAIL_LAST_RESULT: String = "上次运行详情"

    // Grants / approvals (`BotInfoPage.swift:1649-1849`).
    public const val GRANTS_TITLE: String = "常设授权"
    public const val GRANTS_EMPTY: String = "还没有常设授权。"
    public const val GRANT_SOURCE: String = "来源：{source} · {time}"
    public const val GRANT_DETAIL: String = "详情"
    public const val GRANT_TOOL: String = "工具"
    public const val GRANT_OPERATION: String = "操作"
    public const val GRANT_RESOURCE: String = "完整资源"
    public const val GRANT_SESSION: String = "会话"
    public const val GRANT_REVOKE: String = "撤销这条授权"
    public const val APPROVALS_TITLE: String = "审批记录"
    public const val APPROVALS_EMPTY: String = "还没有审批记录。"

    public fun format(template: String, vararg values: Pair<String, Any>): String {
        var text = template
        for ((key, value) in values) text = text.replace("{$key}", value.toString())
        return text
    }
}

/** Stable ids from `spec/ui/v1/pages/bot-info.md` and the Swift identifiers. */
public object BotInfoTags {
    public const val ROOT: String = "bot.info"
    public const val LIST: String = "bot.info.list"
    public const val HEADER: String = "bot.info.header"
    public const val HEADER_FISH: String = "bot.info.header.fish"
    public const val NAME: String = "bot.info.name"
    public const val RENAME: String = "bot.info.rename"
    public const val RENAME_ERROR: String = "bot.info.rename.error"
    public const val APPEARANCE: String = "bot.info.appearance"
    public const val PRESENCE: String = "bot.info.presence"
    public const val PRESENCE_LEVEL: String = "bot.info.presence.level"
    public const val PRESENCE_NOTIFICATIONS: String = "bot.info.presence.notifications"
    public const val DND: String = "bot.info.dnd"
    public const val QUIET_START: String = "bot.info.quiet.start"
    public const val QUIET_END: String = "bot.info.quiet.end"
    public const val DATA_MEMORY: String = "bot.info.memory"
    public const val DATA_ROUTINES: String = "bot.info.routines"
    public const val DATA_APPROVALS: String = "bot.info.approvals"
    public const val DATA_GRANTS: String = "bot.info.grants"
    public const val DELETE: String = "bot.info.delete"
    public const val DELETE_ERROR: String = "bot.info.delete.error"
    public const val DELETE_CONFIRM: String = "bot.info.delete.confirm"
    public const val DELETE_CANCEL: String = "bot.info.delete.cancel"
    public const val ERROR: String = "bot.info.error"
    public const val DELETE_MESSAGE: String = "bot.info.delete.message"

    public const val MEMORY_LIST: String = "bot.memory.list"
    public const val MEMORY_LOADING: String = "bot.memory.loading"
    public const val MEMORY_FAILED: String = "bot.memory.failed"
    public const val MAINTENANCE_TOGGLE: String = "bot.memory.maintenance.toggle"
    public const val MAINTENANCE_BUDGET: String = "bot.memory.maintenance.budget"
    public const val MAINTENANCE_BATCH: String = "bot.memory.maintenance.batch"
    public const val MAINTENANCE_DETAIL: String = "bot.memory.maintenance.detail"
    public const val MAINTENANCE_ROLLBACK: String = "bot.memory.maintenance.rollback"
    public const val MEMORY_ERASE: String = "bot.memory.erase"
    public const val MEMORY_ERASE_SHARED: String = "bot.memory.erase.shared"
    public const val MEMORY_DOCUMENT_EVIDENCE: String = "bot.memory.document.evidence"
    public const val MEMORY_DOCUMENT_FORGET: String = "bot.memory.document.forget"
    public const val MEMORY_DOCUMENT_ERASE: String = "bot.memory.document.erase"
    public const val MEMORY_DOCUMENT_CONTENT: String = "bot.memory.document.content"
    public const val MEMORY_DOCUMENT_VERSIONS: String = "bot.memory.document.versions"
    public const val MEMORY_FORGET_CONFIRM: String = "bot.memory.forget.confirm"
    public const val MEMORY_FORGET_CANCEL: String = "bot.memory.forget.cancel"
    public const val MEMORY_ERASE_CONFIRM: String = "bot.memory.erase.confirm"
    public const val MEMORY_ERASE_SHARED_CONFIRM: String = "bot.memory.erase.shared.confirm"
    public const val MEMORY_ERASE_SHARED_AGAIN_CONFIRM: String = "bot.memory.erase.shared.again"
    public const val MAINTENANCE_ROLLBACK_CONFIRM: String = "bot.memory.maintenance.rollback.confirm"
    public const val MEMORY_DOCUMENT_ERASE_CONFIRM: String = "bot.memory.document.erase.confirm"

    public const val ROUTINES_LIST: String = "bot.routine.list"
    public const val ROUTINES_LOADING: String = "bot.routine.loading"
    public const val ROUTINES_FAILED: String = "bot.routine.failed"
    public const val ROUTINES_EMPTY: String = "bot.routine.empty"
    public const val APPROVALS_LIST: String = "bot.approvals.list"
    public const val APPROVALS_LOADING: String = "bot.approvals.loading"
    public const val APPROVALS_FAILED: String = "bot.approvals.failed"
    public const val APPROVALS_EMPTY: String = "bot.approvals.empty"
    public const val GRANTS_LIST: String = "bot.grant.list"
    public const val GRANTS_LOADING: String = "bot.grant.loading"
    public const val GRANTS_FAILED: String = "bot.grant.failed"
    public const val GRANTS_EMPTY: String = "bot.grant.empty"

    /** Per-entry load marker: `bot.info.<section>.<state>`. */
    public fun entryState(section: String, state: String): String = "bot.info.$section.$state"
    public fun dataEntry(section: String): String = "bot.info.$section"

    public fun presenceDeferred(routineID: String): String =
        "bot.info.presence.deferred.$routineID"

    public fun memoryDocument(path: String): String = "bot.memory.document.$path"
    public fun routineRow(routineID: String): String = "bot.routine.row.$routineID"
    public fun routineCancel(routineID: String): String = "bot.routine.cancel.$routineID"
    public fun routineToggle(routineID: String): String = "bot.routine.toggle.$routineID"
    public fun routineAck(routineID: String): String = "bot.routine.reconcile.ack.$routineID"
    public fun routineRetry(routineID: String): String = "bot.routine.reconcile.retry.$routineID"
    public fun routineDetail(routineID: String): String = "bot.routine.detail.$routineID"

    /** The confirmation dialog's destructive button (`bot.routine.cancel.<id>` opens it). */
    public const val ROUTINE_CANCEL_CONFIRM: String = "bot.routine.cancel.confirm"

    public fun grantDetail(grantID: String): String = "bot.grant.detail.$grantID"
    public fun grantRevoke(grantID: String): String = "bot.grant.revoke.$grantID"
}

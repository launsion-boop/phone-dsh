// SPDX-License-Identifier: MIT
//
// GENERATED from spec/ui/v1/bot/strings.json. Do not hand-edit a value:
// `BotUiStringsGoldenTest` proves every entry below is byte-identical to the
// normative JSON, so a spec/strings change either flows through or fails the
// build. The source anchors in strings.json are checked by check_bot_ui.py.
package com.phonedsh.ui.bot.state

/**
 * The normative UI copy from `spec/ui/v1/bot/strings.json`.
 *
 * Strings with `{name}` placeholders are formatted by [format]; the caller
 * passes exactly the names the template names. This object is data, not a
 * second copy of the contract: the golden test compares it with the spec file.
 */
public object BotUiStrings {
    /** question/steps settled by local dismiss id or durable status dismissed */
    public const val SETTLEMENT_DISMISSED: String = "已关闭"
    /** durable answered or accepted action; label resolved from optionID */
    public const val SETTLEMENT_SELECTED: String = "已选择：{label}"
    /** answered/accepted but the option label cannot be resolved */
    public const val SETTLEMENT_SENT: String = "已送出"
    /** card precedes the latest user text and was never handled */
    public const val SETTLEMENT_SKIPPED: String = "已略过"
    /** checklist result accepted */
    public const val SETTLEMENT_CHECKLISTSENT: String = "已发送勾选结果"
    /** checklist settled detail */
    public const val SETTLEMENT_CHECKLISTDETAIL: String = "{title} · 已完成 {done}/{total}"
    /** approval auto-denied by the next send */
    public const val SETTLEMENT_APPROVALAUTODECLINED: String = "已略过，视为拒绝"
    public const val SETTLEMENT_APPROVALALLOWEDONCE: String = "已允许一次"
    /** status always + scope session */
    public const val SETTLEMENT_APPROVALSESSIONALLOWED: String = "本次对话允许"
    /** status always + any other scope */
    public const val SETTLEMENT_APPROVALALWAYS: String = "已总是允许"
    /** status denied/never */
    public const val SETTLEMENT_APPROVALDENIED: String = "已拒绝"
    public const val SETTLEMENT_APPROVALTIMEDOUT: String = "已超时，视为拒绝"
    public const val SETTLEMENT_APPROVALEXPIRED: String = "已过期，视为拒绝"
    /** unknown settled status */
    public const val SETTLEMENT_APPROVALHANDLED: String = "已处理"
    /** fallback when neither the card nor ask carries an action */
    public const val SETTLEMENT_APPROVALDEFAULTACTION: String = "操作"
    /** steps prompt detail fallback */
    public const val SETTLEMENT_STEPSSUGGESTION: String = "建议下一步"
    public const val HEADER_WAITING_PLURAL: String = "{count} 项等你确认"
    /** single pending approval renders an empty detail; the activity line shows the waiting phrase */
    public const val HEADER_WAITING_SINGLE: String = ""
    /** separator for multi-line problem notices */
    public const val HEADER_PROBLEM_JOIN: String = "；"
    public const val ACTIVITY_THINKING_PRIMARY: String = "思考中"
    public const val ACTIVITY_READING_PRIMARY: String = "在翻文件"
    public const val ACTIVITY_SEARCHING_PRIMARY: String = "在搜内容"
    public const val ACTIVITY_BROWSING_PRIMARY: String = "在开网页"
    public const val ACTIVITY_RUNNING_PRIMARY: String = "处理中"
    public const val ACTIVITY_WRITING_PRIMARY: String = "在写文件"
    public const val ACTIVITY_MEMORY_PRIMARY: String = "在翻记忆"
    public const val ACTIVITY_MESSAGING_PRIMARY: String = "整理回复"
    public const val ACTIVITY_REVIEWING_PRIMARY: String = "看看结果"
    /** fixed, never rotates */
    public const val ACTIVITY_WAITING_PRIMARY: String = "等你确认"
    public const val ACTIVITY_REPLYING_PRIMARY: String = "正在回复"
    public const val ACTIVITY_GENERIC_PRIMARY: String = "处理中"
    public const val ACTIVITY_THINKING_ROTATION_0: String = "思考中…"
    public const val ACTIVITY_THINKING_ROTATION_1: String = "整理思绪…"
    public const val ACTIVITY_THINKING_ROTATION_2: String = "准备下一步…"
    public const val ACTIVITY_REVIEWING_ROTATION_0: String = "看看结果…"
    public const val ACTIVITY_REVIEWING_ROTATION_1: String = "检查一下…"
    public const val ACTIVITY_REVIEWING_ROTATION_2: String = "整理结论…"
    public const val ACTIVITY_REPLYING_ROTATION_0: String = "正在回复…"
    public const val ACTIVITY_REPLYING_ROTATION_1: String = "组织语言…"
    public const val ACTIVITY_REPLYING_ROTATION_2: String = "写回复中…"
    public const val ACTIVITY_GENERIC_ROTATION_0: String = "处理中…"
    public const val ACTIVITY_GENERIC_ROTATION_1: String = "正在处理…"
    public const val ACTIVITY_GENERIC_ROTATION_2: String = "马上就好…"
    /** model text cap: 19 characters + ellipsis (20 total) */
    public const val ACTIVITY_TEXT_ELLIPSIS: String = "…"
    /** target cap: 39 characters + ellipsis (42 total) */
    public const val ACTIVITY_TARGET_ELLIPSIS: String = "…"
    /** sustained-activity suffix */
    public const val ACTIVITY_MINUTES: String = " · {minutes} 分钟"
    public const val DRAWER_TITLE: String = "Bot"
    public const val DRAWER_MANAGE: String = "管理 Bot"
    public const val DRAWER_ADD: String = "添加 Bot"
    public const val DRAWER_EMPTY: String = "还没有 Bot。点上面的「添加 Bot」创建一个。"
    public const val DRAWER_PENDING: String = "{count} 项待审批"
    public const val DRAWER_STATE_THINKING: String = "思考中"
    public const val DRAWER_STATE_WORKING: String = "执行工具中"
    public const val DRAWER_STATE_REPLYING: String = "回复中"
    public const val DRAWER_STATE_ALERTING: String = "等待确认"
    public const val DRAWER_STATE_SLEEPING: String = "休息中"
    public const val DRAWER_STATE_RUNNING: String = "运行中"
    public const val DRAWER_NOMESSAGES: String = "还没有消息"
    public const val DRAWER_UNREAD: String = "{count} 条未读"
    public const val DRAWER_UNREAD_OVERFLOW: String = "99+"
    public const val DRAWER_MENU_RENAME: String = "改名"
    public const val DRAWER_MENU_APPEARANCE: String = "外观"
    public const val DRAWER_MENU_SETMAIN: String = "设为主 Bot"
    public const val DRAWER_MENU_HIDE: String = "隐藏"
    public const val DRAWER_MENU_UNHIDE: String = "取消隐藏"
    public const val DRAWER_MENU_DELETE: String = "删除 Bot"
    public const val DRAWER_MENU_LASTBOT: String = "这是最后一个 Bot，不能删除。"
    public const val DRAWER_DELETE_CONFIRM: String = "删除会中止运行、拒绝待审批、撤销授权、归档会话，并清除这个 Bot 的记忆、例行任务和待处理消息，无法撤销。"
    public const val DRAWER_ERROR_LASTBOT: String = "这是最后一个 Bot，不能删除。"
    public const val DRAWER_ERROR_UNKNOWNBOT: String = "这个 Bot 已经不存在。"
    public const val DRAWER_ERROR_RENAMEFAILED: String = "改名失败：{error}"
    public const val VALIDATION_NAME_EMPTY: String = "名称不能为空。"
    /** UTF-16 units, not grapheme clusters */
    public const val VALIDATION_NAME_TOOLONG: String = "名称最多 {max} 个字符，当前 {count} 个。"
    public const val DRAWER_CREATE: String = "创建"
    public const val DRAWER_CREATING: String = "创建中…"
    public const val CHAT_DRAWER_OPEN: String = "打开 Bot 列表"
    public const val CHAT_INFO_LABEL: String = "Bot 信息"
    public const val CHAT_MENU_SUMMARY: String = "跟进中 {following} · 需要你处理 {attention}"
    public const val CHAT_MENU_INFO: String = "Bot 信息与设置"
    public const val CHAT_DEEPLINK_UNAVAILABLE: String = "这条消息不可用或已过期。"
    public const val ERROR_RUNTIMEUNAVAILABLE: String = "Bot 运行时未连接：动作未执行。"
    public const val ERROR_WATCHFAILED: String = "Bot 实时更新失败：{error}"
    public const val ERROR_HISTORYFAILED: String = "历史加载失败：{error}"
    public const val ERROR_ATTACHMENTFAILED: String = "附件「{name}」未附加：{reason}"
    public const val RUNTIME_CONNECTING: String = "正在连接 Bot…"
    public const val RUNTIME_NOTREADY: String = "Bot 运行时还没有准备好。请先启动引擎，然后重试。"
    public const val INFO_RENAME_EMPTY: String = "Bot 名不能为空。"
    public const val INFO_RENAME_SYNCFAILED: String = "名字已写入对话，但资料同步失败：{error}"
    public const val INFO_RENAME_FAILED: String = "改名失败：{error}"
    public const val INFO_FORGET_FAILED: String = "忘记失败：{error}"
    public const val INFO_ERASE_FAILED: String = "抹除失败：{error}"
    public const val INFO_ERASESHARED_FAILED: String = "抹除共享 user/ 记忆失败：{error}"
    public const val INFO_MAINTENANCE_SAVEFAILED: String = "保存记忆整理开关失败：{error}"
    public const val INFO_MAINTENANCE_ROLLBACKFAILED: String = "回滚记忆整理失败：{error}"
    public const val INFO_PROACTIVE_SAVEFAILED: String = "打扰设置保存失败：{error}"
    public const val INFO_ROUTINE_UPDATEFAILED: String = "例行任务更新失败：{error}"
    public const val INFO_ROUTINE_CANCELFAILED: String = "取消运行失败：{error}"
    public const val INFO_GRANT_REVOKEFAILED: String = "撤销授权失败：{error}"
    public const val INFO_RECONCILE_FAILED: String = "处理对账失败：{error}"
    public const val INFO_READFAILED: String = "读取失败"
    public const val INFO_MEMORY_READFAILED: String = "记忆读取失败：{error}。这不代表没有记忆。"
    public const val INFO_MEMORY_AGENTROOT: String = "本 Bot 的记忆"
    public const val INFO_MEMORY_USERROOT: String = "所有 Bot 共享的记忆"
    public const val INFO_MEMORY_FORGET: String = "忘记"
    public const val INFO_MEMORY_ERASEBOT: String = "抹除这个 Bot 的记忆（含全部版本）"
    public const val INFO_MEMORY_ERASESHARED: String = "抹除所有 Bot 共享的记忆（含全部版本）"
    public const val INFO_MAINTENANCE_TITLE: String = "后台整理"
    public const val INFO_MAINTENANCE_ROLLBACK: String = "回滚这次整理"
    public const val INFO_ROUTINE_CANCEL: String = "取消运行"
    public const val INFO_RECONCILE_ACK: String = "确认完成"
    public const val INFO_RECONCILE_RETRY: String = "重试"
    public const val INFO_ROUTINE_READFAILED: String = "例行任务读取失败：{error}。这不代表没有例行任务。"
    public const val INFO_GRANT_READFAILED: String = "常设授权读取失败：{error}。这不代表没有授权。"
    public const val INFO_APPROVALS_READFAILED: String = "审批记录读取失败：{error}。"
    public const val GLYPH_DISMISSED: String = "xmark.circle"
    public const val GLYPH_ACCEPTED: String = "checkmark.circle"
    public const val GLYPH_APPROVALALLOWED: String = "checkmark.circle.fill"
    public const val GLYPH_SKIPPED: String = "minus.circle"

    /** Every normative id in `strings.json`, in the spec file order. */
    public val BY_ID: Map<String, String> = linkedMapOf(
        "settlement.dismissed" to SETTLEMENT_DISMISSED,
        "settlement.selected" to SETTLEMENT_SELECTED,
        "settlement.sent" to SETTLEMENT_SENT,
        "settlement.skipped" to SETTLEMENT_SKIPPED,
        "settlement.checklistSent" to SETTLEMENT_CHECKLISTSENT,
        "settlement.checklistDetail" to SETTLEMENT_CHECKLISTDETAIL,
        "settlement.approvalAutoDeclined" to SETTLEMENT_APPROVALAUTODECLINED,
        "settlement.approvalAllowedOnce" to SETTLEMENT_APPROVALALLOWEDONCE,
        "settlement.approvalSessionAllowed" to SETTLEMENT_APPROVALSESSIONALLOWED,
        "settlement.approvalAlways" to SETTLEMENT_APPROVALALWAYS,
        "settlement.approvalDenied" to SETTLEMENT_APPROVALDENIED,
        "settlement.approvalTimedOut" to SETTLEMENT_APPROVALTIMEDOUT,
        "settlement.approvalExpired" to SETTLEMENT_APPROVALEXPIRED,
        "settlement.approvalHandled" to SETTLEMENT_APPROVALHANDLED,
        "settlement.approvalDefaultAction" to SETTLEMENT_APPROVALDEFAULTACTION,
        "settlement.stepsSuggestion" to SETTLEMENT_STEPSSUGGESTION,
        "header.waiting.plural" to HEADER_WAITING_PLURAL,
        "header.waiting.single" to HEADER_WAITING_SINGLE,
        "header.problem.join" to HEADER_PROBLEM_JOIN,
        "activity.thinking.primary" to ACTIVITY_THINKING_PRIMARY,
        "activity.reading.primary" to ACTIVITY_READING_PRIMARY,
        "activity.searching.primary" to ACTIVITY_SEARCHING_PRIMARY,
        "activity.browsing.primary" to ACTIVITY_BROWSING_PRIMARY,
        "activity.running.primary" to ACTIVITY_RUNNING_PRIMARY,
        "activity.writing.primary" to ACTIVITY_WRITING_PRIMARY,
        "activity.memory.primary" to ACTIVITY_MEMORY_PRIMARY,
        "activity.messaging.primary" to ACTIVITY_MESSAGING_PRIMARY,
        "activity.reviewing.primary" to ACTIVITY_REVIEWING_PRIMARY,
        "activity.waiting.primary" to ACTIVITY_WAITING_PRIMARY,
        "activity.replying.primary" to ACTIVITY_REPLYING_PRIMARY,
        "activity.generic.primary" to ACTIVITY_GENERIC_PRIMARY,
        "activity.thinking.rotation.0" to ACTIVITY_THINKING_ROTATION_0,
        "activity.thinking.rotation.1" to ACTIVITY_THINKING_ROTATION_1,
        "activity.thinking.rotation.2" to ACTIVITY_THINKING_ROTATION_2,
        "activity.reviewing.rotation.0" to ACTIVITY_REVIEWING_ROTATION_0,
        "activity.reviewing.rotation.1" to ACTIVITY_REVIEWING_ROTATION_1,
        "activity.reviewing.rotation.2" to ACTIVITY_REVIEWING_ROTATION_2,
        "activity.replying.rotation.0" to ACTIVITY_REPLYING_ROTATION_0,
        "activity.replying.rotation.1" to ACTIVITY_REPLYING_ROTATION_1,
        "activity.replying.rotation.2" to ACTIVITY_REPLYING_ROTATION_2,
        "activity.generic.rotation.0" to ACTIVITY_GENERIC_ROTATION_0,
        "activity.generic.rotation.1" to ACTIVITY_GENERIC_ROTATION_1,
        "activity.generic.rotation.2" to ACTIVITY_GENERIC_ROTATION_2,
        "activity.text.ellipsis" to ACTIVITY_TEXT_ELLIPSIS,
        "activity.target.ellipsis" to ACTIVITY_TARGET_ELLIPSIS,
        "activity.minutes" to ACTIVITY_MINUTES,
        "drawer.title" to DRAWER_TITLE,
        "drawer.manage" to DRAWER_MANAGE,
        "drawer.add" to DRAWER_ADD,
        "drawer.empty" to DRAWER_EMPTY,
        "drawer.pending" to DRAWER_PENDING,
        "drawer.state.thinking" to DRAWER_STATE_THINKING,
        "drawer.state.working" to DRAWER_STATE_WORKING,
        "drawer.state.replying" to DRAWER_STATE_REPLYING,
        "drawer.state.alerting" to DRAWER_STATE_ALERTING,
        "drawer.state.sleeping" to DRAWER_STATE_SLEEPING,
        "drawer.state.running" to DRAWER_STATE_RUNNING,
        "drawer.noMessages" to DRAWER_NOMESSAGES,
        "drawer.unread" to DRAWER_UNREAD,
        "drawer.unread.overflow" to DRAWER_UNREAD_OVERFLOW,
        "drawer.menu.rename" to DRAWER_MENU_RENAME,
        "drawer.menu.appearance" to DRAWER_MENU_APPEARANCE,
        "drawer.menu.setMain" to DRAWER_MENU_SETMAIN,
        "drawer.menu.hide" to DRAWER_MENU_HIDE,
        "drawer.menu.unhide" to DRAWER_MENU_UNHIDE,
        "drawer.menu.delete" to DRAWER_MENU_DELETE,
        "drawer.menu.lastBot" to DRAWER_MENU_LASTBOT,
        "drawer.delete.confirm" to DRAWER_DELETE_CONFIRM,
        "drawer.error.lastBot" to DRAWER_ERROR_LASTBOT,
        "drawer.error.unknownBot" to DRAWER_ERROR_UNKNOWNBOT,
        "drawer.error.renameFailed" to DRAWER_ERROR_RENAMEFAILED,
        "validation.name.empty" to VALIDATION_NAME_EMPTY,
        "validation.name.tooLong" to VALIDATION_NAME_TOOLONG,
        "drawer.create" to DRAWER_CREATE,
        "drawer.creating" to DRAWER_CREATING,
        "chat.drawer.open" to CHAT_DRAWER_OPEN,
        "chat.info.label" to CHAT_INFO_LABEL,
        "chat.menu.summary" to CHAT_MENU_SUMMARY,
        "chat.menu.info" to CHAT_MENU_INFO,
        "chat.deeplink.unavailable" to CHAT_DEEPLINK_UNAVAILABLE,
        "error.runtimeUnavailable" to ERROR_RUNTIMEUNAVAILABLE,
        "error.watchFailed" to ERROR_WATCHFAILED,
        "error.historyFailed" to ERROR_HISTORYFAILED,
        "error.attachmentFailed" to ERROR_ATTACHMENTFAILED,
        "runtime.connecting" to RUNTIME_CONNECTING,
        "runtime.notReady" to RUNTIME_NOTREADY,
        "info.rename.empty" to INFO_RENAME_EMPTY,
        "info.rename.syncFailed" to INFO_RENAME_SYNCFAILED,
        "info.rename.failed" to INFO_RENAME_FAILED,
        "info.forget.failed" to INFO_FORGET_FAILED,
        "info.erase.failed" to INFO_ERASE_FAILED,
        "info.eraseShared.failed" to INFO_ERASESHARED_FAILED,
        "info.maintenance.saveFailed" to INFO_MAINTENANCE_SAVEFAILED,
        "info.maintenance.rollbackFailed" to INFO_MAINTENANCE_ROLLBACKFAILED,
        "info.proactive.saveFailed" to INFO_PROACTIVE_SAVEFAILED,
        "info.routine.updateFailed" to INFO_ROUTINE_UPDATEFAILED,
        "info.routine.cancelFailed" to INFO_ROUTINE_CANCELFAILED,
        "info.grant.revokeFailed" to INFO_GRANT_REVOKEFAILED,
        "info.reconcile.failed" to INFO_RECONCILE_FAILED,
        "info.readFailed" to INFO_READFAILED,
        "info.memory.readFailed" to INFO_MEMORY_READFAILED,
        "info.memory.agentRoot" to INFO_MEMORY_AGENTROOT,
        "info.memory.userRoot" to INFO_MEMORY_USERROOT,
        "info.memory.forget" to INFO_MEMORY_FORGET,
        "info.memory.eraseBot" to INFO_MEMORY_ERASEBOT,
        "info.memory.eraseShared" to INFO_MEMORY_ERASESHARED,
        "info.maintenance.title" to INFO_MAINTENANCE_TITLE,
        "info.maintenance.rollback" to INFO_MAINTENANCE_ROLLBACK,
        "info.routine.cancel" to INFO_ROUTINE_CANCEL,
        "info.reconcile.ack" to INFO_RECONCILE_ACK,
        "info.reconcile.retry" to INFO_RECONCILE_RETRY,
        "info.routine.readFailed" to INFO_ROUTINE_READFAILED,
        "info.grant.readFailed" to INFO_GRANT_READFAILED,
        "info.approvals.readFailed" to INFO_APPROVALS_READFAILED,
        "glyph.dismissed" to GLYPH_DISMISSED,
        "glyph.accepted" to GLYPH_ACCEPTED,
        "glyph.approvalAllowed" to GLYPH_APPROVALALLOWED,
        "glyph.skipped" to GLYPH_SKIPPED,
    )

    /** Resolves a normative id; an unknown id is a contract error, not a fallback. */
    public fun get(id: String): String =
        BY_ID[id] ?: throw IllegalArgumentException("unknown Bot UI string id: $id")

    /** Replaces `{name}` placeholders with `values`; an unknown placeholder is a contract error. */
    public fun format(id: String, vararg values: Pair<String, Any>): String {
        var text = get(id)
        for ((key, value) in values) {
            text = text.replace("{$key}", value.toString())
        }
        return text
    }
}

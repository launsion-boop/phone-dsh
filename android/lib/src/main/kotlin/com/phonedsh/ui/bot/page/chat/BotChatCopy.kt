// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import com.phonedsh.ui.bot.state.BotUiStrings

/**
 * Page copy the reference keeps as literals rather than in `strings.json`
 * (`BotChatPage.swift:145,181,365-368,417,520,645-657`; `bot-chat.md` §1/§4).
 * Labels that already have a `strings.json` id go through [BotUiStrings]; these
 * are the frozen page literals and every call site cites the page line.
 */
public object BotChatCopy {
    /** `BotChatPage.swift:145` / `bot-chat.md` §1. */
    public const val DRAWER_OPEN: String = "打开 Bot 列表"

    /** `BotChatPage.swift:181` / `bot-chat.md` §1. */
    public const val INFO_OPEN: String = "Bot 信息"

    /** `BotChatPage.swift:242`; the menu's non-clickable summary row. */
    public const val MENU_SUMMARY: String = "跟进中 {following} · 需要你处理 {attention}"

    /** `BotChatPage.swift:244-254`; all four rows open the info page today. */
    public const val MENU_INFO: String = "Bot 信息与设置"
    public const val MENU_MEMORY: String = "记忆"
    public const val MENU_ROUTINES: String = "例行任务"
    public const val MENU_APPROVALS: String = "审批记录"

    /** `BotChatPage.swift:365-368` / `bot-chat.md` §1. */
    public const val EMPTY_TITLE: String = "嗨，我是 {name}"
    public const val EMPTY_BODY: String = "我可以处理任务、整理文件和查找资料。\n想让我帮你做什么？"

    /** `BotChatPage.swift:417,427,520,645-657`. */
    public const val ATTACH: String = "添加附件"
    public const val INPUT_PLACEHOLDER: String = "向 {name} 提问"
    public const val SEND: String = "发送消息"
    public const val STEER: String = "发送并 steering"
    public const val STOP: String = "停止当前回合"
    public const val REMOVE_ATTACHMENT: String = "移除附件 {name}"
    public const val DISMISS_ATTACHMENT_NOTICE: String = "关闭附件提示"
    public const val RUNNING_TURN: String = "运行中"

    /** `BotCardView.swift:114,143`. */
    public const val DISMISS_CARD: String = "关闭卡片"
    public const val RECOMMENDED: String = "建议"

    /** `BotCardView.swift:256-269`. */
    public const val SHOW_STEPS: String = "查看步骤"
    public const val HIDE_STEPS: String = "收起步骤"
    public const val EXPANDED: String = "已展开"
    public const val COLLAPSED: String = "已折叠"
    public const val EXPAND: String = "展开"
    public const val COLLAPSE: String = "收起"

    /** `BotCardView.swift:298-322`. */
    public const val OPEN: String = "打开"
    public const val TASK_TITLE_FALLBACK: String = "后台任务"
    public const val DOCUMENT_TITLE_FALLBACK: String = "文档"
    public const val DOCUMENT_CONTENTS: String = "本页内容"
    public const val DOCUMENT_NO_BODY: String = "没有内嵌正文。"

    /** `BotWorkCardView.swift:27-102` progress. */
    public const val PROGRESS_MORE: String = "显示全部 {count} 步"
    public const val PROGRESS_PERCENT: String = "完成进度 {percent}%"

    /** `BotWorkCardView.swift:121-184` checklist. */
    public const val CHECKLIST_SEND: String = "把勾选结果发给 Bot"
    public const val CHECKLIST_SENT: String = "已发送勾选结果"

    /** `BotWorkCardView.swift:259-351` approval. */
    public const val APPROVAL_FALLBACK_ACTION: String = "操作"
    public const val APPROVAL_TITLE: String = "允许执行这个操作吗？"
    public const val APPROVAL_COMMAND: String = "将执行"
    public const val APPROVAL_COPY: String = "复制"
    public const val APPROVAL_COPIED: String = "已复制"
    public const val APPROVAL_EXPAND_ALL: String = "展开全部"
    public const val APPROVAL_ONCE: String = "允许一次"
    public const val APPROVAL_ALWAYS: String = "始终允许"
    public const val APPROVAL_SESSION: String = "本次对话都允许"
    public const val APPROVAL_DENY: String = "拒绝"
    public const val APPROVAL_PERSISTENT: String = "用户不在场，已转为待办。"
    public const val APPROVAL_HIGH_RISK: String = "高风险"

    /** `BotWorkCardView.swift:406-492` routines. */
    public const val AUTOMATION_URGENT: String = "紧急"
    public const val AUTOMATION_QUIET: String = "安静时段"
    public const val AUTOMATION_DURATION: String = "用时 {seconds} 秒"

    /** `BotChatModel.swift:156-163` failure copy used by a card's own line. */
    public const val ACTION_FAILED: String = "未能送出：{reason}"

    /** `BotChatModel.swift:1140`; a failed action without a driver reason. */
    public const val ACTION_NOT_COMPLETED: String = "动作未完成"

    /** `BotCardSettledLine` suffix; the model owns the values. */
    public const val SETTLEMENT_DETAIL_SEPARATOR: String = " · "
}

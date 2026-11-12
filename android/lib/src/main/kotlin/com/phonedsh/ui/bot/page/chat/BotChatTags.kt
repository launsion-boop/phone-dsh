// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

/**
 * Every accessibility id `spec/ui/v1/pages/bot-chat.md` §6 freezes, plus the
 * per-row/per-card ids the reference uses (`BotChatPage.swift`,
 * `BotCardView.swift`, `BotWorkCardView.swift`).
 */
public object BotChatTags {
    public const val DRAWER_OPEN: String = "bot.drawer.open"
    public const val INFO_OPEN: String = "bot.info.open"
    public const val CONNECT_DEVICE: String = "bot.connect-device"
    public const val HEADER_MENU: String = "bot.header.menu"

    public const val TRANSCRIPT: String = "bot.chat.transcript"
    public const val EMPTY: String = "bot.chat.empty"
    public const val HISTORY_LOADER: String = "bot.history.loader"
    public const val ACTIVITY_LINE: String = "bot.activity.line"
    public const val STREAMING_TEXT: String = "bot.streaming.text"

    public const val COMPOSER_INPUT: String = "bot.composer.input"
    public const val COMPOSER_ATTACH: String = "bot.composer.attach"
    public const val COMPOSER_SEND: String = "bot.composer.send"
    public const val COMPOSER_STOP: String = "bot.composer.stop"
    public const val COMPOSER_ATTACHMENT_NOTICE: String = "bot.composer.attachment.notice"
    public const val MESSAGE_ATTACHMENT: String = "bot.message.attachment"
    public const val AGENT_COMM_ROW: String = "bot.agent-comm.row"

    public const val CARD_SETTLED: String = "bot.card.settled"
    public const val CARD_AUTOMATION: String = "bot.card.automation"
    public const val CARD_NOTICE: String = "bot.card.notice"

    public const val CHOICE_DISMISS: String = "bot.choice.dismiss"
    public const val TASK_VERIFICATION: String = "bot.task.verification"
    public const val TASK_TOGGLE: String = "bot.task.toggle"
    public const val TASK_STEPS: String = "bot.task.steps"
    public const val ATTACHMENT_OPEN: String = "bot.attachment.open"
    public const val DOCUMENT_OPEN: String = "bot.document.open"
    public const val PROGRESS_MORE: String = "bot.progress.more"

    public const val CHECKLIST_SEND: String = "bot.checklist.send"

    public const val APPROVAL_ONCE: String = "bot.approval.once"
    public const val APPROVAL_ALWAYS: String = "bot.approval.always"
    public const val APPROVAL_DENY: String = "bot.approval.deny"
    public const val APPROVAL_COPY: String = "bot.approval.copy"
    public const val APPROVAL_EXPAND: String = "bot.approval.expand"
    public const val APPROVAL_PERSISTENT: String = "bot.approval.persistent"

    public const val HEADING_EXPAND: String = "bot.card.heading.expand"

    public fun attachmentChip(index: Int): String = "bot.composer.attachment.$index"
    public fun choiceOption(id: String): String = "bot.choice.option.$id"
    public fun checklistItem(id: String): String = "bot.checklist.item.$id"
    public fun linkOpen(id: String): String = "bot.link.open.$id"
    public fun row(id: String): String = "bot.message.row.$id"
}

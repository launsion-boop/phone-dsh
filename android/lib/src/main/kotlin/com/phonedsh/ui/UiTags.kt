// Stable test tags: the Compose tests address nodes by these names, so a UI
// SPDX-License-Identifier: MIT
// test never depends on a localised string. Components carry them through
// `Modifier.testTag`, which also gives a stable a11y identifier downstream.
package com.phonedsh.ui

/** One constant per addressable node; components and tests share this table. */
public object UiTags {
    /** Root of the chat scaffold (insets contract lives here). */
    public const val CHAT_ROOT: String = "pdsh.chat.root"

    /** The message list. */
    public const val CHAT_LIST: String = "pdsh.chat.list"

    /** The "no engine yet" empty/waiting state. */
    public const val CHAT_EMPTY: String = "pdsh.chat.empty"

    /** The goal bar slot. */
    public const val GOAL_BAR: String = "pdsh.chat.goal"

    /** The pending-answer slot (approval + question cards). */
    public const val ANSWER_SLOT: String = "pdsh.chat.answer-slot"

    public const val BUBBLE: String = "pdsh.surface.bubble"
    public const val TOOL_ROW: String = "pdsh.surface.tool-row"
    public const val TOOL_ROW_DETAIL: String = "pdsh.surface.tool-row.detail"
    public const val THINKING_PILL: String = "pdsh.surface.thinking-pill"
    public const val APPROVAL_CARD: String = "pdsh.surface.approval-card"
    public const val COMPOSER: String = "pdsh.surface.composer"
    public const val FAIL_LOUD_BANNER: String = "pdsh.surface.fail-loud-banner"

    public const val COMPOSER_FIELD: String = "pdsh.composer.field"
    public const val COMPOSER_SEND: String = "pdsh.composer.send"
    public const val COMPOSER_STOP: String = "pdsh.composer.stop"
    public const val COMPOSER_STAT: String = "pdsh.composer.stat"
    public const val COMPOSER_QUEUE: String = "pdsh.composer.queue"

    public const val APPROVAL_PRIMARY: String = "pdsh.approval.primary"
    public const val APPROVAL_SECONDARY: String = "pdsh.approval.secondary"

    public const val BANNER_RETRY: String = "pdsh.banner.retry"
    public const val BANNER_DISMISS: String = "pdsh.banner.dismiss"

    public const val FILES_LIST: String = "pdsh.files.list"
    public const val FILES_EMPTY: String = "pdsh.files.empty"
    public const val SETTINGS_LIST: String = "pdsh.settings.list"
    public const val SETTINGS_EMPTY: String = "pdsh.settings.empty"

    // P5 K2 settings/tools/files/memory/about pages. One tag per addressable
    // container; a value assertion uses `UiStrings`, never a literal.
    public const val SETTINGS_GROUP: String = "pdsh.settings.group"
    public const val SETTINGS_NOTES: String = "pdsh.settings.notes"

    public const val FILES_PREVIEW: String = "pdsh.files.preview"
    public const val FILES_UP: String = "pdsh.files.up"

    public const val TOOLS_LIST: String = "pdsh.tools.list"
    public const val TOOLS_EMPTY: String = "pdsh.tools.empty"
    public const val TOOL_DETAIL: String = "pdsh.tools.detail"

    public const val MEMORY_LIST: String = "pdsh.memory.list"
    public const val MEMORY_EMPTY: String = "pdsh.memory.empty"
    public const val MEMORY_BUDGET: String = "pdsh.memory.budget"
    public const val MEMORY_GROUP: String = "pdsh.memory.group"

    public const val ABOUT_LIST: String = "pdsh.about.list"
    public const val ABOUT_SECTION: String = "pdsh.about.section"

    // Turn-tail usage control and its medium sheet (iOS `NativeTurnTail` /
    // `NativeTurnUsageDetails`, `spec/ui/v1/pages/chat.json` `sheet-913`).
    public const val CHAT_TURN_USAGE: String = "pdsh.chat.turn-usage"
    public const val TURN_USAGE_SHEET: String = "pdsh.turn-usage.sheet"
}

// SPDX-License-Identifier: MIT
// The chat page's top failure line vs the empty state. When the transcript has
// no rows and shows the no-engine card, that card already says 引擎还没启动 and
// offers 启动本地引擎; repeating an engine-stopped line above it is noise.

package com.phonedsh.ui.page

import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatScreenState

/** The engine-down failure family; other failures keep their own banner. */
internal fun isEngineStoppedNotice(message: String): Boolean {
    val text = message.trim()
    if (text == "引擎停了" || text.startsWith("引擎停了：") || text.startsWith("引擎停了:")) return true
    if (!text.contains("引擎")) return false
    return listOf("停了", "没有启动成功", "还没恢复", "还没就绪").any(text::contains)
}

/**
 * Whether the page should draw its top failure line. A per-row failure is
 * rendered under its row instead. The engine-stopped line is suppressed only
 * while the no-engine empty state is actually on screen (`rows` empty means
 * the transcript's `EmptyTimeline` branch); mid-session it still shows.
 */
internal fun shouldShowChatFailureBanner(state: ChatScreenState): Boolean {
    if (state.failedItemID != null) return false
    val message = state.userFacingError ?: return false
    val engineEmptyStateVisible =
        state.rows.isEmpty() && state.empty == ChatEmpty.ENGINE_NOT_STARTED
    return !(engineEmptyStateVisible && isEngineStoppedNotice(message))
}

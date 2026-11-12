// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.bot.rows.BotRow

/** One page of live history rows (`projection.md` §12). */
public data class BotRowPage(
    public val rows: List<BotRow>,
    public val nextCursor: String?,
    public val hasMore: Boolean,
)

/** `invalidService("历史行游标不可用")` from the App paging surface. */
public class BotRowPagingException(
    public val code: String,
    message: String,
) : Exception(message)

/**
 * The frozen history-paging arithmetic (`projection.md` §12).
 *
 * This is the app-layer consumer helper, not part of the projector: a host may
 * page differently as long as it renders the same rows in display order. The
 * page is the last `max(1, limit)` rows of the prefix ending before [before]
 * (`null` means the newest window); [nextCursor] is the first id of the page.
 */
public object BotRowPaging {
    public fun page(
        rows: List<BotRow>,
        before: String? = null,
        limit: Int = 20,
    ): BotRowPage {
        val eligible = if (before == null) {
            rows
        } else {
            val index = rows.indexOfFirst { it.id == before }
            if (index < 0) {
                throw BotRowPagingException("invalidService", "历史行游标不可用")
            }
            rows.subList(0, index)
        }
        val clamped = maxOf(1, limit)
        val start = maxOf(0, eligible.size - clamped)
        val page = eligible.subList(start, eligible.size).toList()
        return BotRowPage(
            rows = page,
            nextCursor = page.firstOrNull()?.id,
            hasMore = eligible.size > page.size,
        )
    }
}

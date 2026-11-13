// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBody
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotRowKind
import com.phonedsh.bot.rows.BotRowProvenance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Focused arithmetic that the shared vectors do not reach: the 64-bit
 * `entrySeq` overflow branches (`projection.md` §3.2) and the App paging
 * arithmetic (§12, which the spec marks NOT_RUN on iOS).
 */
class BotProjectionUnitTest {
    @Test
    fun entrySeqUsesTheFrozenWrappingArithmetic() {
        assertEquals(1_000_001L, BotSessionLogProjector.entrySeq(1000, 1))
        assertEquals(1L, BotSessionLogProjector.entrySeq(0, 1001))
        assertEquals(Long.MAX_VALUE, BotSessionLogProjector.entrySeq(Long.MAX_VALUE, 1))
        assertEquals(Long.MIN_VALUE, BotSessionLogProjector.entrySeq(Long.MIN_VALUE, 1))
        // The low three decimal digits of sourceSeq are the only ones that count.
        assertEquals(4_004L, BotSessionLogProjector.entrySeq(4, 4))
        assertEquals(4_004L, BotSessionLogProjector.entrySeq(4, 1004))
        assertEquals(4_000L, BotSessionLogProjector.entrySeq(4, -1))
    }

    @Test
    fun pagingUsesTheFrozenDisplayOrderArithmetic() {
        val rows = (0..4).map { row("r$it", it.toLong()) }

        val newest = BotRowPaging.page(rows, before = null, limit = 2)
        assertEquals(listOf("r3", "r4"), newest.rows.map { it.id })
        assertEquals("r3", newest.nextCursor)
        assertTrue(newest.hasMore)

        val beforeR2 = BotRowPaging.page(rows, before = "r2", limit = 2)
        assertEquals(listOf("r0", "r1"), beforeR2.rows.map { it.id })
        assertEquals("r0", beforeR2.nextCursor)
        assertFalse(beforeR2.hasMore)

        val clamped = BotRowPaging.page(rows, before = null, limit = 0)
        assertEquals(listOf("r4"), clamped.rows.map { it.id })

        try {
            BotRowPaging.page(rows, before = "missing", limit = 2)
            fail("an unknown cursor must be rejected")
        } catch (error: BotRowPagingException) {
            assertEquals("invalidService", error.code)
            assertEquals("历史行游标不可用", error.message)
        }
    }

    private fun row(id: String, seq: Long): BotRow = BotRow(
        id = id,
        botID = "main",
        seq = seq,
        updatedSeq = seq,
        kind = BotRowKind.MESSAGE,
        role = "user",
        body = BotRowBody(type = BotRowBodyType.TEXT),
        provenance = BotRowProvenance(emptyList(), BotRowProvenance.OWNER_DIRECT, false),
        streaming = false,
        createdAt = seq,
    )
}

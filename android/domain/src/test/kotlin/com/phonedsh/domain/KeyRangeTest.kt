// The prefix-range maths that makes list() index-usable and exact.
// SPDX-License-Identifier: MIT
//
// These cases are host-only on purpose: they pin the arithmetic that both the
// SQLite backend and the in-memory fake consume, so a range bug cannot hide
// behind "both implementations agree" (they share the range, not the matching
// rule).

package com.phonedsh.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KeyRangeTest {
    @Test
    fun anEmptyPrefixCoversTheWholeKeySpace() {
        val range = keyRangeForPrefix("")

        assertEquals("", range.lower)
        assertNull(range.upper)
    }

    @Test
    fun anAsciiPrefixAdvancesItsLastCodePoint() {
        val range = keyRangeForPrefix("ab")

        assertEquals("ab", range.lower)
        assertEquals("ac", range.upper)
    }

    @Test
    fun aSupplementaryPrefixAdvancesByCodePointNotBySurrogate() {
        val prefix = "\uD83D\uDE42" // U+1F642, one code point, two UTF-16 units
        val range = keyRangeForPrefix(prefix)

        assertEquals(prefix, range.lower)
        // The successor is U+1F643, not "the high surrogate incremented".
        assertEquals("\uD83D\uDE43", range.upper)
    }

    @Test
    fun aBmpMaximumCarriesIntoTheNextCodePoint() {
        val range = keyRangeForPrefix("a\uFFFF")

        assertEquals("a\uFFFF", range.lower)
        assertEquals("a\uD800\uDC00", range.upper) // a + U+10000
    }

    @Test
    fun anAllMaximumPrefixHasNoUpperBound() {
        val range = keyRangeForPrefix("\uDBFF\uDFFF")

        assertEquals("\uDBFF\uDFFF", range.lower)
        assertNull(range.upper)
    }

    @Test
    fun theRangeIsExactForEverySampleKey() {
        val keys = listOf(
            "a",
            "ab",
            "ab\u0000",
            "aba",
            "ac",
            "b",
            "🙂",
            "🙂x",
            "🚀",
            "\uFFFF",
            "\uD800\uDC00",
            "\uD800\uDC00x",
            "\uDBFF\uDFFF",
            "\uDBFF\uDFFFx",
        )
        val prefixes = listOf("", "a", "ab", "🙂", "\uFFFF", "\uD800\uDC00", "\uDBFF\uDFFF")

        prefixes.forEach { prefix ->
            val range = keyRangeForPrefix(prefix)
            keys.forEach { key ->
                val inRange = compareUtf8(key, range.lower) >= 0 &&
                    (range.upper == null || compareUtf8(key, range.upper) < 0)
                assertEquals(
                    "prefix \"$prefix\", key \"$key\"",
                    key.startsWith(prefix),
                    inRange,
                )
            }
        }
    }

    private fun compareUtf8(left: String, right: String): Int {
        val a = left.toByteArray(Charsets.UTF_8)
        val b = right.toByteArray(Charsets.UTF_8)
        val common = minOf(a.size, b.size)
        for (index in 0 until common) {
            val difference = (a[index].toInt() and 0xFF) - (b[index].toInt() and 0xFF)
            if (difference != 0) return difference
        }
        return a.size - b.size
    }
}

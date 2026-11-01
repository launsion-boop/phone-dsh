// The half-open key range that makes prefix listing index-usable.
// SPDX-License-Identifier: MIT
//
// A prefix scan is expressed as `key >= lower AND key < upper` so SQLite can
// walk the (domain, key) primary key instead of evaluating `substr`/`LIKE` per
// row. `LIKE` is not an option: its default collation folds ASCII case, and
// `GLOB` has metacharacters that a user key may contain.
//
// `upper` is the successor of `prefix` in code-point order. UTF-8 byte order
// (SQLite BINARY) equals code-point order for well-formed strings, so the same
// bounds are valid for the SQLite implementation and for the in-memory fake.

package com.phonedsh.domain

/**
 * A half-open key interval `[lower, upper)` in UTF-8 byte order.
 *
 * [upper] is `null` when no key can sort at or after the successor — only a
 * prefix made entirely of U+10FFFF code points — meaning "no upper bound".
 */
class KeyRange(
    val lower: String,
    val upper: String?,
) {
    override fun toString(): String = "KeyRange(lower=$lower, upper=$upper)"
}

/**
 * The exact half-open range of keys that start with [prefix].
 *
 * An empty prefix is the whole key space: `["", null)`.
 */
internal fun keyRangeForPrefix(prefix: String): KeyRange {
    if (prefix.isEmpty()) return KeyRange("", null)

    val codePoints = ArrayList<Int>(prefix.length)
    var offset = 0
    while (offset < prefix.length) {
        val codePoint = prefix.codePointAt(offset)
        codePoints.add(codePoint)
        offset += Character.charCount(codePoint)
    }

    var last = codePoints.size - 1
    while (last >= 0 && codePoints[last] == Character.MAX_CODE_POINT) last--
    if (last < 0) {
        // Every code point is the maximum scalar value. No string sorts after
        // this prefix without also starting with it.
        return KeyRange(prefix, null)
    }

    codePoints[last] = codePoints[last] + 1
    val upper = StringBuilder()
    for (index in 0..last) upper.appendCodePoint(codePoints[index])
    return KeyRange(prefix, upper.toString())
}

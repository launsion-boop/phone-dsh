// Domain/key text validation shared by the store and its seam.
// SPDX-License-Identifier: MIT
//
// Domains, keys and prefix bounds are compared by SQLite's BINARY collation,
// which is UTF-8 byte order. That equality only holds for well-formed UTF-16:
// an unpaired surrogate is not valid UTF-8, the binding either rejects it or
// substitutes a replacement character, and two distinct Kotlin strings could
// then collide in the database. Rejecting the value at the boundary is cheaper
// than explaining a collision later.

package com.phonedsh.domain

/** Rejects a name that cannot be compared and stored faithfully. */
internal fun requireDomain(domain: String) {
    require(domain.isNotEmpty()) { "a domain name must not be empty" }
    require(domain.none { it == '\u0000' }) { "a domain name must not contain NUL" }
    require(domain.isWellFormedUtf16()) { "a domain name must be well-formed UTF-16" }
}

/** Rejects a key that cannot be compared and stored faithfully. */
internal fun requireKey(key: String) {
    require(key.isNotEmpty()) { "a key must not be empty" }
    require(key.none { it == '\u0000' }) { "a key must not contain NUL" }
    require(key.isWellFormedUtf16()) { "a key must be well-formed UTF-16" }
}

/** A prefix may be empty (list the whole domain) but is otherwise a key prefix. */
internal fun requirePrefix(prefix: String) {
    require(prefix.none { it == '\u0000' }) { "a key prefix must not contain NUL" }
    require(prefix.isWellFormedUtf16()) { "a key prefix must be well-formed UTF-16" }
}

/** Rejects a non-positive list limit; there is no implicit default cap. */
internal fun requireLimit(limit: Int) {
    require(limit > 0) { "a list limit must be greater than zero, was $limit" }
}

/**
 * True when every surrogate in [text] is paired.
 *
 * `String.codePointCount` would allocate a stream; this walk is the same check
 * SQLite's UTF-8 conversion needs and stays allocation-free.
 */
internal fun String.isWellFormedUtf16(): Boolean {
    var index = 0
    while (index < length) {
        val unit = this[index]
        when {
            unit.isHighSurrogate() -> {
                if (index + 1 >= length || !this[index + 1].isLowSurrogate()) return false
                index += 2
            }

            unit.isLowSurrogate() -> return false
            else -> index += 1
        }
    }
    return true
}

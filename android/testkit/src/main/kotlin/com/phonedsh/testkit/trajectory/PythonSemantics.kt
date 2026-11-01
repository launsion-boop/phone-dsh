// :testkit trajectory — the Python primitives the normative oracle is defined in terms of.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode

/**
 * Byte-for-byte ports of the Python runtime behaviour that `spec/v1/tools/trajectory_norm.py`
 * inherits from the standard library.
 *
 * These are not general-purpose "Python helpers": each one exists because the normalizer's
 * bytes depend on the exact Python semantics, not on the JVM's near-equivalent.
 *
 * * [splitlines] is `str.splitlines()`, which splits on eleven separators, not only on `\n`.
 * * [strip] is `str.strip()`, which strips the Unicode `isspace()` set (including `\u00a0`
 *   and `\u001c`..`\u001f`), not `String.trim()` and not `Character.isWhitespace`.
 * * [compareCodePoints] is Python's `str` ordering (Unicode code points). Kotlin's
 *   `String.compareTo` sorts UTF-16 code units, which puts a supplementary character before
 *   a BMP character above U+E000.
 * * [codePointLength] is `len(str)`; `String.length` counts UTF-16 units.
 * * [floatRepr] is `repr(float)` — the shortest decimal that round-trips, formatted with
 *   Python's fixed/scientific thresholds — because `json.dumps` writes floats with it.
 */
internal object PythonSemantics {
    /**
     * The characters Python's `\s` matches on `str`, as a regex character-class body.
     *
     * Java's `\p{IsWhite_Space}` (what `UNICODE_CHARACTER_CLASS` gives `\s`) omits the four
     * C0 separators U+001C..U+001F that Python's `isspace()` includes, while both include the
     * NBSP and narrow no-break space. The string is a regex fragment, not literal text.
     */
    internal const val SPACE_CLASS_CHARS: String =
        "\\t\\n\\x0B\\f\\r\\x1C-\\x1F \\x85\\xA0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000"

    /** `chr(code_point).isspace()` for every code point Python 3.9 accepts. */
    fun isSpace(codePoint: Int): Boolean = when {
        codePoint in 0x09..0x0D -> true
        codePoint in 0x1C..0x20 -> true
        codePoint == 0x85 -> true
        codePoint == 0xA0 -> true
        codePoint == 0x1680 -> true
        codePoint in 0x2000..0x200A -> true
        codePoint == 0x2028 || codePoint == 0x2029 -> true
        codePoint == 0x202F -> true
        codePoint == 0x205F -> true
        codePoint == 0x3000 -> true
        else -> false
    }

    /** Python `str.strip()` with no argument. */
    fun strip(text: String): String {
        var start = 0
        var end = text.length
        while (start < end) {
            val codePoint = text.codePointAt(start)
            if (!isSpace(codePoint)) break
            start += Character.charCount(codePoint)
        }
        while (end > start) {
            val codePoint = text.codePointBefore(end)
            if (!isSpace(codePoint)) break
            end -= Character.charCount(codePoint)
        }
        return text.substring(start, end)
    }

    /**
     * Python `str.splitlines()`: `\n`, `\r`, `\r\n`, `\u000b`, `\u000c`, `\u001c`,
     * `\u001d`, `\u001e`, `\u0085`, `\u2028` and `\u2029` all end a line, and a trailing
     * separator does not produce an extra empty line.
     */
    fun splitlines(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val lines = ArrayList<String>()
        var start = 0
        var index = 0
        while (index < text.length) {
            if (!isLineBreak(text[index])) {
                index++
                continue
            }
            lines += text.substring(start, index)
            if (text[index] == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
                index++
            }
            index++
            start = index
        }
        if (start < text.length) lines += text.substring(start)
        return lines
    }

    private fun isLineBreak(char: Char): Boolean = when (char) {
        '\n', '\r', '\u000B', '\u000C', '\u001C', '\u001D', '\u001E', '\u0085', '\u2028', '\u2029' -> true
        else -> false
    }

    /** Python `str` comparison: code point order, then length. */
    fun compareCodePoints(left: String, right: String): Int {
        var leftIndex = 0
        var rightIndex = 0
        while (leftIndex < left.length && rightIndex < right.length) {
            val leftCodePoint = left.codePointAt(leftIndex)
            val rightCodePoint = right.codePointAt(rightIndex)
            if (leftCodePoint != rightCodePoint) return leftCodePoint.compareTo(rightCodePoint)
            leftIndex += Character.charCount(leftCodePoint)
            rightIndex += Character.charCount(rightCodePoint)
        }
        return (left.length - leftIndex).compareTo(right.length - rightIndex)
    }

    /** Python `len(str)`. */
    fun codePointLength(text: String): Int = text.codePointCount(0, text.length)

    /**
     * Python `repr(float)` for a finite value.
     *
     * The algorithm is the same one CPython's `dtoa` implements: pick the smallest number of
     * significant decimal digits whose correctly-rounded decimal value converts back to the
     * argument, then print it fixed when the decimal exponent is in `-4..15` and scientific
     * otherwise. Scientific exponents always carry a sign and at least two digits (`1e-06`).
     * This is why `1.0` is not `1`, `1e16` is not `10000000000000000.0`, and `-0.0` stays
     * signed; Java's `Double.toString` uses different thresholds and one-decimal-part rules.
     */
    fun floatRepr(value: Double): String {
        require(value.isFinite()) { "repr() of a non-finite float is not a JSON number" }
        if (value == 0.0) return if (1.0 / value < 0.0) "-0.0" else "0.0"
        val negative = value < 0.0
        val magnitude = if (negative) -value else value
        val exact = BigDecimal(magnitude)
        var chosen: BigDecimal? = null
        for (precision in 1..MAX_SIGNIFICANT_DIGITS) {
            val rounded = exact.round(MathContext(precision, RoundingMode.HALF_EVEN))
            if (rounded.toDouble() == magnitude) {
                chosen = rounded
                break
            }
        }
        val decimal = (chosen ?: exact).stripTrailingZeros()
        val digits = decimal.unscaledValue().abs().toString()
        val exponent = digits.length - 1 - decimal.scale()
        val sign = if (negative) "-" else ""
        if (exponent in -4..15) {
            if (exponent >= 0) {
                val integerDigits = exponent + 1
                val integral = if (digits.length > integerDigits) {
                    digits.substring(0, integerDigits)
                } else {
                    digits + "0".repeat(integerDigits - digits.length)
                }
                val fraction = if (digits.length > integerDigits) digits.substring(integerDigits) else ""
                return sign + integral + "." + (fraction.ifEmpty { "0" })
            }
            return sign + "0." + "0".repeat(-exponent - 1) + digits
        }
        val mantissa = digits[0] + if (digits.length > 1) "." + digits.substring(1) else ""
        val exponentText = Math.abs(exponent).toString().padStart(2, '0')
        return sign + mantissa + "e" + (if (exponent >= 0) "+" else "-") + exponentText
    }

    /** The largest number of significant digits a finite IEEE-754 double can need. */
    private const val MAX_SIGNIFICANT_DIGITS = 17
}

// phone-dsh — :testkit trajectory: Python-runtime semantics the canonical bytes depend on.
// SPDX-License-Identifier: MIT
//
// The expected float strings below were captured from Python 3 (`repr(float)`). The linter
// that replaces the oracle cannot use Java's `Double.toString`, whose fixed/scientific
// thresholds and two-digit rules differ; this table is the regression guard for stage 5.

package com.phonedsh.testkit.trajectory

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PythonSemanticsTest {

    @Test
    fun `float repr matches python for fixed scientific and subnormal values`() {
        val cases = listOf(
            0.0 to "0.0",
            -0.0 to "-0.0",
            1.0 to "1.0",
            100.0 to "100.0",
            1.5 to "1.5",
            -2.5 to "-2.5",
            0.1 to "0.1",
            0.123456 to "0.123456",
            50.041 to "50.041",
            0.0001 to "0.0001",
            0.0001234 to "0.0001234",
            1e-5 to "1e-05",
            1e-6 to "1e-06",
            1e15 to "1000000000000000.0",
            9999999999999998.0 to "9999999999999998.0",
            1e16 to "1e+16",
            1e20 to "1e+20",
            1234567890123.1235 to "1234567890123.1235",
            0.30000000000000004 to "0.30000000000000004",
            1.2345678901234567E16 to "1.2345678901234568e+16",
            Double.MIN_VALUE to "5e-324",
            2.2250738585072014E-308 to "2.2250738585072014e-308",
            Double.MAX_VALUE to "1.7976931348623157e+308",
        )
        for ((value, expected) in cases) {
            assertEquals("repr($value)", expected, PythonSemantics.floatRepr(value))
        }
    }

    @Test
    fun `splitlines matches python for every line separator`() {
        assertEquals(emptyList<String>(), PythonSemantics.splitlines(""))
        assertEquals(listOf("a"), PythonSemantics.splitlines("a\n"))
        assertEquals(listOf("a", ""), PythonSemantics.splitlines("a\n\n"))
        assertEquals(listOf("a", "b"), PythonSemantics.splitlines("a\r\nb"))
        assertEquals(listOf("a", "b"), PythonSemantics.splitlines("a\rb"))
        assertEquals(
            listOf("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"),
            PythonSemantics.splitlines("a\nb\u000Bc\u000Cd\u001Ce\u001Df\u001Eg\u0085h\u2028i\u2029j\r\nk"),
        )
        assertEquals(listOf("a"), PythonSemantics.splitlines("a\u2028"))
    }

    @Test
    fun `strip uses the python isspace set not java trim`() {
        assertEquals("a", PythonSemantics.strip("\u00a0\u2007\u202f a \u3000\u001c"))
        assertEquals("a", PythonSemantics.strip("a"))
        assertEquals("", PythonSemantics.strip("\u0085\u00a0"))
        // Character.isWhitespace is false for these, so String.trim/strip would not match.
        assertFalse(Character.isWhitespace('\u00a0'))
        assertFalse(Character.isWhitespace('\u202f'))
    }

    @Test
    fun `code point ordering differs from utf16 ordering above the bmp`() {
        val replacement = "\uFFFD"
        val emoji = "\uD83D\uDE00"
        assertTrue("python compares code points", PythonSemantics.compareCodePoints(replacement, emoji) < 0)
        assertTrue("utf-16 compares code units", replacement.compareTo(emoji) > 0)
        assertEquals(0, PythonSemantics.compareCodePoints("abc", "abc"))
        assertTrue(PythonSemantics.compareCodePoints("ab", "abc") < 0)
        assertEquals(1, PythonSemantics.codePointLength(emoji))
        assertEquals(2, emoji.length)
    }
}

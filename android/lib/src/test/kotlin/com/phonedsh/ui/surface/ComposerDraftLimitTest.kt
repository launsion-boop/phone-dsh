// Unicode boundary tests for the native composer draft cap.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ComposerDraftLimitTest {
    @Test
    fun `under cap preserves selection and composition exactly`() {
        val value = TextFieldValue(
            text = "e\u0301😀",
            selection = TextRange(2, 1),
            composition = TextRange(0, 2),
        )

        val result = enforceComposerDraftLimit(value)

        assertEquals(value, result.value)
        assertFalse(result.truncated)
    }

    @Test
    fun `ASCII overflow clips to exactly 8000 graphemes with valid selection`() {
        val value = TextFieldValue(
            text = "a".repeat(8_001),
            selection = TextRange(8_001),
            composition = TextRange(0, 8_001),
        )

        val result = enforceComposerDraftLimit(value)

        assertTrue(result.truncated)
        assertEquals("a".repeat(8_000), result.value.text)
        assertEquals(TextRange(8_000), result.value.selection)
        assertEquals(null, result.value.composition)
    }

    @Test
    fun `supplementary emoji counts as one grapheme rather than two UTF16 units`() {
        val value = TextFieldValue("a".repeat(7_999) + "😀", selection = TextRange(8_001))

        val result = enforceComposerDraftLimit(value)

        assertFalse(result.truncated)
        assertEquals(value, result.value)
    }

    @Test
    fun `overflow drops a whole emoji grapheme instead of splitting its surrogate pair`() {
        val value = TextFieldValue("a".repeat(8_000) + "😀", selection = TextRange(8_002))

        val result = enforceComposerDraftLimit(value)

        assertTrue(result.truncated)
        assertEquals("a".repeat(8_000), result.value.text)
        assertFalse(result.value.text.any { it.isSurrogate() })
    }

    @Test
    fun `combining mark sequence stays together at the cap`() {
        val expected = "a".repeat(7_999) + "e\u0301"
        val result = enforceComposerDraftLimit(TextFieldValue(expected + "x"))

        assertTrue(result.truncated)
        assertEquals(expected, result.value.text)
    }

    @Test
    fun `ZWJ emoji sequence is one grapheme and is never partially kept`() {
        val sequence = "👩‍💻"
        val exactLimit = "a".repeat(7_999) + sequence
        val exact = enforceComposerDraftLimit(TextFieldValue(exactLimit))
        assertFalse(exact.truncated)
        assertEquals(exactLimit, exact.value.text)

        val overflow = enforceComposerDraftLimit(TextFieldValue(exactLimit + "x"))
        assertTrue(overflow.truncated)
        assertEquals(exactLimit, overflow.value.text)
    }

    private fun Char.isSurrogate(): Boolean = this in '\uD800'..'\uDFFF'
}

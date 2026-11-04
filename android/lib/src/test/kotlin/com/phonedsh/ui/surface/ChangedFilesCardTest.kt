// The changed-files card's model and its line diff, on the JVM.
// SPDX-License-Identifier: MIT
//
// The card's numbers are the only thing it can get wrong: the layout is visible,
// the +N -M is data. The iOS projector computes them with an LCS over lines
// (`NativeTranscriptProjector.swift:240-254`), so each expectation below is hand
// evaluated from that Swift source, not from this port.
package com.phonedsh.ui.surface

import org.junit.Assert.assertEquals
import org.junit.Test

class ChangedFilesCardTest {
    @Test
    fun `a one-line replacement is plus one minus one`() {
        // The official sample: old_string "旧结构", new_string "官方原生结构".
        assertEquals(1 to 1, lineDelta("旧结构", "官方原生结构"))
    }

    @Test
    fun `identical text changes nothing`() {
        assertEquals(0 to 0, lineDelta("a", "a"))
        assertEquals(0 to 0, lineDelta("a\nb\nc", "a\nb\nc"))
    }

    @Test
    fun `a create counts its lines as added`() {
        // iOS treats a missing old text as one empty line, so a two-line write is
        // +2 -1. That minus one is in the iOS projection; copying it is the point.
        assertEquals(2 to 1, lineDelta(null, "a\nb"))
        assertEquals(1 to 1, lineDelta(null, "one line"))
    }

    @Test
    fun `deletions and insertions are diffed by the longest common subsequence`() {
        assertEquals(0 to 1, lineDelta("a\nb\nc", "a\nc"))
        assertEquals(1 to 0, lineDelta("a\nc", "a\nb\nc"))
        assertEquals(1 to 0, lineDelta("a\nb", "a\nb\nc"))
        assertEquals(0 to 1, lineDelta("a\nb\nc", "a\nb"))
        // A reorder keeps one line common, so it is one add plus one delete.
        assertEquals(1 to 1, lineDelta("a\nb", "b\na"))
    }

    @Test
    fun `empty texts have no delta`() {
        assertEquals(0 to 0, lineDelta("", ""))
        assertEquals(0 to 0, lineDelta(null, ""))
    }

    @Test
    fun `every newline character separates a line like Foundation does`() {
        // `components(separatedBy: .newlines)` splits on each character, so "\r\n"
        // contributes an empty line and the same text on both sides is still 0/0.
        assertEquals(0 to 0, lineDelta("a\r\nb", "a\r\nb"))
        assertEquals(0 to 1, lineDelta("a\r\nb", "a\nb"))
    }

    @Test
    fun `the single-file title uses the file name, the multi-file title the count`() {
        val one = ChatFileChange("docs/design/DESIGN.md", "docs/design/DESIGN.md", 1, 1)
        assertEquals("DESIGN.md", one.fileName)
        assertEquals(6, (1..6).map { ChatFileChange("f$it.md", "f$it.md", 1, 1) }.sumOf { it.added })
    }
}

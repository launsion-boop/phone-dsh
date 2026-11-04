// The Markdown splitter: the block grammar the preview face can actually draw.
// SPDX-License-Identifier: MIT
//
// `parseMarkdown` and `parseInline` are pure, so the whole grammar is pinned here
// without a device. What the test protects is the *honesty* of the reader: anything
// the renderer cannot draw must stay literal text (never disappear), and an
// unterminated fence must swallow the rest of the document rather than be dropped.
package com.phonedsh.ui.surface.preview

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewMarkdownTest {

    @Test
    fun `headings keep their level`() {
        val blocks = parseMarkdown("# One\n\n### Three\n\n###### Six")
        assertEquals(
            listOf(
                MarkdownBlock.Heading(1, "One"),
                MarkdownBlock.Heading(3, "Three"),
                MarkdownBlock.Heading(6, "Six"),
            ),
            blocks,
        )
    }

    @Test
    fun `seven hashes is a paragraph, not a heading`() {
        val blocks = parseMarkdown("####### seven")
        assertEquals(listOf<MarkdownBlock>(MarkdownBlock.Paragraph("####### seven")), blocks)
    }

    @Test
    fun `paragraphs are joined exactly as written`() {
        val blocks = parseMarkdown("line one\nline two\n\nsecond")
        assertEquals(
            listOf(
                MarkdownBlock.Paragraph("line one\nline two"),
                MarkdownBlock.Paragraph("second"),
            ),
            blocks,
        )
    }

    @Test
    fun `a fenced block carries its info string and body`() {
        val blocks = parseMarkdown("intro\n\n```kotlin\nfun main() {}\n```\n\nafter")
        assertEquals(
            listOf(
                MarkdownBlock.Paragraph("intro"),
                MarkdownBlock.Code("kotlin", "fun main() {}"),
                MarkdownBlock.Paragraph("after"),
            ),
            blocks,
        )
    }

    @Test
    fun `an unterminated fence takes the rest of the document`() {
        val blocks = parseMarkdown("```py\nprint(1)\nprint(2)")
        assertEquals(listOf<MarkdownBlock>(MarkdownBlock.Code("py", "print(1)\nprint(2)")), blocks)
    }

    @Test
    fun `bullets and ordered items become lists`() {
        val blocks = parseMarkdown("- a\n- b\n\n1. one\n2. two")
        assertEquals(
            listOf(
                MarkdownBlock.Bullets(listOf("a", "b")),
                MarkdownBlock.Numbers(
                    listOf(NumberedItem("1.", "one"), NumberedItem("2.", "two")),
                ),
            ),
            blocks,
        )
    }

    @Test
    fun `a quote and a rule are their own blocks`() {
        val blocks = parseMarkdown("> first\n> second\n\n---")
        assertEquals(
            listOf(
                MarkdownBlock.Quote("first\nsecond"),
                MarkdownBlock.Rule,
            ),
            blocks,
        )
    }

    @Test
    fun `html is literal text, not a page`() {
        val blocks = parseMarkdown("<div class=\"x\">hi</div>")
        assertEquals(
            listOf<MarkdownBlock>(MarkdownBlock.Paragraph("<div class=\"x\">hi</div>")),
            blocks,
        )
    }

    @Test
    fun `inline markers become segments`() {
        val segments = parseInline("plain **bold** and *italic* and `code` and [link](https://example.org/x)")
        assertEquals(
            listOf(
                InlineSegment.Plain("plain "),
                InlineSegment.Bold("bold"),
                InlineSegment.Plain(" and "),
                InlineSegment.Italic("italic"),
                InlineSegment.Plain(" and "),
                InlineSegment.Code("code"),
                InlineSegment.Plain(" and "),
                InlineSegment.Link("link", "https://example.org/x"),
            ),
            segments,
        )
    }

    @Test
    fun `a code span keeps its markers literal`() {
        val segments = parseInline("`**not bold**`")
        assertEquals(listOf<InlineSegment>(InlineSegment.Code("**not bold**")), segments)
    }

    @Test
    fun `an unpaired marker stays literal`() {
        assertEquals(listOf<InlineSegment>(InlineSegment.Plain("a * b ** c")), parseInline("a * b ** c"))
        assertEquals(listOf<InlineSegment>(InlineSegment.Plain("[not a link")), parseInline("[not a link"))
    }

    @Test
    fun `everything the renderer cannot style is preserved verbatim`() {
        // Not a single character of the document may be lost by the splitter.
        val document = """
            # Title

            Some **text** with `code` and a [link](https://example.com).

            - one
            - two

            ```sh
            echo hi
            ```

            > quote

            ---

            | a | b |
            |---|---|
        """.trimIndent()
        val blocks = parseMarkdown(document)
        val flattened = blocks.joinToString("\n") { block ->
            when (block) {
                is MarkdownBlock.Heading -> block.text
                is MarkdownBlock.Paragraph -> block.text
                is MarkdownBlock.Code -> block.body
                is MarkdownBlock.Bullets -> block.items.joinToString("\n")
                is MarkdownBlock.Numbers -> block.items.joinToString("\n") { it.text }
                is MarkdownBlock.Quote -> block.text
                MarkdownBlock.Rule -> ""
            }
        }
        listOf("Title", "Some **text** with `code`", "one", "two", "echo hi", "quote", "| a | b |")
            .forEach { fragment ->
                assertTrue("the splitter dropped '$fragment'", flattened.contains(fragment))
            }
    }

    @Test
    fun `an empty document has no blocks`() {
        assertEquals(emptyList<MarkdownBlock>(), parseMarkdown(""))
        assertEquals(emptyList<MarkdownBlock>(), parseMarkdown("\n\n\n"))
    }
}

// Hostile markdown nesting must never take the app down, and a parser failure at
// the render boundary must keep the original text on screen.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MarkdownCrashRegressionTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `a five thousand deep quote keeps its leaf text`() {
        val blocks = MarkdownParser.parse(">".repeat(5000) + "x")
        assertTrue(flatten(blocks).contains("x"))
    }

    @Test
    fun `a three thousand level indented list keeps its deepest marker`() {
        val source = (0 until 3000).joinToString("\n") { " ".repeat(it) + "- n$it" }
        val blocks = MarkdownParser.parse(source)
        assertTrue(flatten(blocks).contains("n2999"))
    }

    @Test
    fun `quote nesting stops at the documented cap`() {
        val source = ">".repeat(MAX_MARKDOWN_BLOCK_DEPTH + 20) + "x"
        val blocks = MarkdownParser.parse(source)
        assertEquals(MAX_MARKDOWN_BLOCK_DEPTH, maxQuoteDepth(blocks))
        assertTrue(flatten(blocks).contains("x"))
    }

    @Test
    fun `list child nesting stops at the documented cap`() {
        val deepest = MAX_MARKDOWN_BLOCK_DEPTH + 20
        val source = (0..deepest).joinToString("\n") { " ".repeat(it) + "- n$it" }
        val blocks = MarkdownParser.parse(source)
        assertTrue(maxListDepth(blocks) <= MAX_MARKDOWN_BLOCK_DEPTH)
        assertTrue(flatten(blocks).contains("n$deepest"))
    }

    @Test
    fun `parse boundary falls back to the original text on any failure`() {
        val source = ">".repeat(5000) + "x"
        val stackOverflow = parseMarkdownOrPlain(source) { throw StackOverflowError("forced") }
        assertEquals(
            source,
            plainText((stackOverflow.single() as MarkdownBlock.Paragraph).inlines),
        )
        val parserError = parseMarkdownOrPlain(source) { error("forced") }
        assertEquals(
            source,
            plainText((parserError.single() as MarkdownBlock.Paragraph).inlines),
        )
    }

    @Test
    fun `MarkdownBody renders a deep quote document without an exception`() {
        val source = ">".repeat(5000) + "x\n\nvisible tail"
        compose.setContent {
            PdshTheme { MarkdownBody(markdown = source) }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(MARKDOWN_BODY_TAG).assertIsDisplayed()
        compose.onNodeWithText("visible tail").assertIsDisplayed()
        compose.onNodeWithText("x", substring = true).assertExists()
    }

    private fun flatten(blocks: List<MarkdownBlock>): String = buildString {
        val pending = ArrayDeque<MarkdownBlock>()
        pending.addAll(blocks)
        while (pending.isNotEmpty()) {
            when (val block = pending.removeFirst()) {
                is MarkdownBlock.Paragraph -> append(plainText(block.inlines)).append('\n')
                is MarkdownBlock.Heading -> append(plainText(block.inlines)).append('\n')
                is MarkdownBlock.Table -> {
                    block.header.forEach { append(plainText(it)).append('\n') }
                    block.rows.forEach { row -> row.forEach { append(plainText(it)).append('\n') } }
                }
                is MarkdownBlock.ListBlock -> block.items.forEach { item ->
                    append(plainText(item.inlines)).append('\n')
                    item.imageBlock?.let { pending.add(it) }
                    pending.addAll(item.children)
                }
                is MarkdownBlock.Quote -> pending.addAll(block.blocks)
                is MarkdownBlock.Code -> append(block.body).append('\n')
                is MarkdownBlock.Math -> append(block.latex).append('\n')
                is MarkdownBlock.Image -> append(block.alt).append('\n')
                MarkdownBlock.Rule -> Unit
            }
        }
    }

    private fun maxQuoteDepth(blocks: List<MarkdownBlock>): Int = blocks.maxOfOrNull { block ->
        when (block) {
            is MarkdownBlock.Quote -> 1 + maxQuoteDepth(block.blocks)
            else -> 0
        }
    } ?: 0

    private fun maxListDepth(blocks: List<MarkdownBlock>): Int = blocks.maxOfOrNull { block ->
        when (block) {
            is MarkdownBlock.ListBlock -> 1 + (block.items.maxOfOrNull { maxListDepth(it.children) } ?: 0)
            else -> 0
        }
    } ?: 0

    private fun plainText(inlines: List<MarkdownInline>): String = inlines.joinToString("") { part ->
        when (part) {
            is MarkdownInline.Text -> part.text
            is MarkdownInline.Strong -> plainText(part.children)
            is MarkdownInline.Emphasis -> plainText(part.children)
            is MarkdownInline.Delete -> plainText(part.children)
            is MarkdownInline.Code -> part.code
            is MarkdownInline.Link -> plainText(part.children)
            is MarkdownInline.Image -> part.alt
            is MarkdownInline.Math -> part.latex
            is MarkdownInline.Footnote -> "[^${part.id}]"
        }
    }
}

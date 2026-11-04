// The markdown block/inline parser, on the JVM.
// SPDX-License-Identifier: MIT
//
// Each case is one thing the iOS renderer draws differently from plain prose:
// a GFM table, display and inline TeX, a literal HTML tag, a footnote reference
// plus the section it appends, and a fenced code block.
package com.phonedsh.ui.surface

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.CompositionLocalProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.UiType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MarkdownBodyTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `a GFM table keeps its header, rows and column alignment`() {
        val blocks = MarkdownParser.parse(
            """
            | 模块 | 状态 |
            |:--|--:|
            | Markdown | 原生 |
            | TeX | ${'$'}x^2${'$'} |
            """.trimIndent(),
        )
        val table = blocks.single() as MarkdownBlock.Table
        assertEquals(2, table.header.size)
        assertEquals(2, table.rows.size)
        assertEquals(MarkdownTableAlign.LEFT, table.alignments[0])
        assertEquals(MarkdownTableAlign.RIGHT, table.alignments[1])
        assertEquals(
            listOf(MarkdownInline.Text("Markdown")),
            table.rows[0][0],
        )
        assertEquals(listOf(MarkdownInline.Text("原生")), table.rows[0][1])
    }

    @Test
    fun `a display math block is one math block, multi-line included`() {
        val single = MarkdownParser.parse("\$\$E = mc^2\$\$").single() as MarkdownBlock.Math
        assertEquals("E = mc^2", single.latex)
        val multi = MarkdownParser.parse("\$\$\nE = mc^2\n\$\$").single() as MarkdownBlock.Math
        assertEquals("E = mc^2", multi.latex)
    }

    @Test
    fun `math-bearing paragraph uses the injected native span backend and keeps source text`() {
        val rendered = mutableListOf<Triple<String, Float, Boolean>>()
        val fake = MarkdownMathSpanBackend { _, latex, fontSizeDp, _, displayMode ->
            rendered += Triple(latex, fontSizeDp, displayMode)
            TestReplacementSpan()
        }
        compose.setContent {
            CompositionLocalProvider(LocalMarkdownMathSpanBackend provides fake) {
                PdshTheme {
                    MarkdownBody(markdown = "Inline ${'$'}x^2${'$'} remains selectable text.")
                }
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).assertIsDisplayed()
        assertEquals("x^2", rendered.single().first)
        assertTrue(rendered.single().second > 0f)
        assertEquals(false, rendered.single().third)
    }

    @Test
    fun `pure prose remains on the original Compose text path`() {
        val fake = MarkdownMathSpanBackend { _, _, _, _, _ -> error("pure prose asked for a math span") }
        compose.setContent {
            CompositionLocalProvider(LocalMarkdownMathSpanBackend provides fake) {
                PdshTheme { MarkdownBody(markdown = "Plain prose stays Compose text.") }
            }
        }
        compose.onNodeWithText("Plain prose stays Compose text.").assertIsDisplayed()
        compose.onAllNodesWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).assertCountEquals(0)
    }

    @Test
    fun `inline math inside a table cell becomes a math run`() {
        val table = MarkdownParser.parse(
            "| a | b |\n|--|--|\n| TeX | ${'$'}x^2 + y^2 = z^2${'$'} |",
        ).single() as MarkdownBlock.Table
        assertEquals(
            listOf(MarkdownInline.Math("x^2 + y^2 = z^2")),
            table.rows[0][1],
        )
    }

    @Test
    fun `raw HTML stays literal text, it is never parsed`() {
        val paragraph = MarkdownParser.parse(
            "原始 HTML 保持字面：<b>不会执行</b>。",
        ).single() as MarkdownBlock.Paragraph
        assertEquals(
            "原始 HTML 保持字面：<b>不会执行</b>。",
            plainText(paragraph.inlines),
        )
    }

    @Test
    fun `a footnote reference is an inline node and the section is appended`() {
        val blocks = MarkdownParser.parse(
            "正文。[^note]\n\n[^note]: 流式与历史恢复使用同一事件投影。",
        )
        val paragraph = blocks[0] as MarkdownBlock.Paragraph
        assertEquals(listOf(MarkdownInline.Footnote("note")), paragraph.inlines.drop(1))
        // The definition line is lifted out of the body and appended afterward.
        assertTrue(plainText(paragraph.inlines).contains("正文。"))
        assertFalse(plainText(paragraph.inlines).contains("流式"))
        val heading = blocks[1] as MarkdownBlock.Paragraph
        assertEquals("脚注", plainText(heading.inlines))
        val definition = blocks[2] as MarkdownBlock.Paragraph
        assertEquals("[note] 流式与历史恢复使用同一事件投影。", plainText(definition.inlines))
    }

    @Test
    fun `a fenced block keeps its language and body`() {
        val code = MarkdownParser.parse(
            "```swift\nstruct NativeChat: View {\n    let official = true\n}\n```",
        ).single() as MarkdownBlock.Code
        assertEquals("swift", code.language)
        assertEquals("struct NativeChat: View {\n    let official = true\n}", code.body)
    }

    @Test
    fun `an unterminated fence stays prose so a stream never flashes a card`() {
        val blocks = MarkdownParser.parse("正文\n```swift\nstruct S {")
        assertEquals(1, blocks.size)
        assertTrue(blocks.single() is MarkdownBlock.Paragraph)
    }

    @Test
    fun `a standalone image paragraph preserves source alt and title`() {
        val image = MarkdownParser.parse("![架构图](https://example.com/diagram.png \"topology\")").single()
            as MarkdownBlock.Image
        assertEquals("https://example.com/diagram.png", image.source)
        assertEquals("架构图", image.alt)
        assertEquals("topology", image.title)
    }

    @Test
    fun `inline image alt text stays unchanged inside prose`() {
        val paragraph = MarkdownParser.parse("See ![架构图](https://example.com/diagram.png) here.").single()
            as MarkdownBlock.Paragraph
        assertEquals(listOf(MarkdownInline.Text("See "), MarkdownInline.Image("架构图"), MarkdownInline.Text(" here.")), paragraph.inlines)
        assertEquals("See 架构图 here.", plainText(paragraph.inlines))
    }

    @Test
    fun `image followed by prose without a blank line stays one inline paragraph`() {
        val paragraph = MarkdownParser.parse("![架构图](diagram.png) caption on next line").single()
            as MarkdownBlock.Paragraph
        assertEquals("架构图 caption on next line", plainText(paragraph.inlines))
    }

    @Test
    fun `an image-only list item preserves a block source while mixed item content keeps inline alt`() {
        val standalone = MarkdownParser.parse("- ![diagram](diagram.png \"list image\")").single()
            as MarkdownBlock.ListBlock
        assertEquals("diagram.png", standalone.items.single().imageBlock?.source)
        assertEquals("list image", standalone.items.single().imageBlock?.title)
        assertTrue(standalone.items.single().inlines.isEmpty())

        val mixed = MarkdownParser.parse("- ![diagram](diagram.png) caption").single() as MarkdownBlock.ListBlock
        assertEquals(null, mixed.items.single().imageBlock)
        assertEquals("diagram caption", plainText(mixed.items.single().inlines))
    }

    @Test
    fun `strong, delete and code spans keep their kind`() {
        val paragraph = MarkdownParser.parse("**粗体**、~~删除线~~、`Package.swift`").single()
            as MarkdownBlock.Paragraph
        assertEquals(MarkdownInline.Strong(listOf(MarkdownInline.Text("粗体"))), paragraph.inlines[0])
        assertEquals(MarkdownInline.Delete(listOf(MarkdownInline.Text("删除线"))), paragraph.inlines[2])
        assertEquals(MarkdownInline.Code("Package.swift"), paragraph.inlines[4])
    }

    @Test
    fun `soft breaks become spaces and hard breaks remain line breaks`() {
        val soft = MarkdownParser.parse("first\nsecond").single() as MarkdownBlock.Paragraph
        assertEquals("first second", plainText(soft.inlines))
        val hard = MarkdownParser.parse("first  \nsecond").single() as MarkdownBlock.Paragraph
        assertEquals("first\nsecond", plainText(hard.inlines))
    }

    @Test
    fun `a task list keeps its checked state`() {
        val list = MarkdownParser.parse("- [x] 完成\n- [ ] 没完成").single() as MarkdownBlock.ListBlock
        assertEquals(false, list.ordered)
        assertEquals(listOf(true, false), list.items.map { it.checked })
    }

    @Test
    fun `a nested list stays nested under its parent item`() {
        val list = MarkdownParser.parse("- parent\n  - child").single() as MarkdownBlock.ListBlock
        assertEquals(listOf(MarkdownInline.Text("parent")), list.items.single().inlines)
        val child = list.items.single().children.single() as MarkdownBlock.ListBlock
        assertEquals(listOf(MarkdownInline.Text("child")), child.items.single().inlines)
    }

    @Test
    fun `a safe workspace link is routed through the provided callback`() {
        var opened: String? = null
        compose.setContent {
            PdshTheme {
                MarkdownBody(
                    markdown = "[Open file](docs/design/PR22.md)",
                    onOpenFile = { opened = it },
                )
            }
        }
        compose.onNodeWithText("Open file").performClick()
        assertEquals("docs/design/PR22.md", opened)
    }

    @Test
    fun `native workspace resource URIs preserve their full addresses`() {
        assertEquals(
            MarkdownLinkTarget.ResourceUri("file:///dsh/workspace/docs/readme.md"),
            markdownLinkTarget("file:///dsh/workspace/docs/readme.md"),
        )
        assertEquals(
            MarkdownLinkTarget.ResourceUri("sandbox:docs/file%20name.md"),
            markdownLinkTarget("sandbox:docs/file%20name.md"),
        )
        assertEquals(
            MarkdownLinkTarget.ResourceUri("dsh-resource://file/session/session-A/dsh/workspace/docs/readme.md"),
            markdownLinkTarget("dsh-resource://file/session/session-A/dsh/workspace/docs/readme.md"),
        )
        assertEquals(null, markdownLinkTarget("file://remote-host/docs/readme.md"))
        assertEquals(null, markdownLinkTarget("dsh-resource://other/session/turn-1/docs/readme.md"))
        assertEquals(null, markdownLinkTarget("sandbox:%2e%2e/private.txt"))
        assertEquals(null, markdownLinkTarget("dsh-resource://file/unknown/turn-1/docs/readme.md"))
    }

    @Test
    fun `a session resource link preserves its session through the resource callback`() {
        val resource = "dsh-resource://file/session/session-A/dsh/workspace/docs/readme.md"
        var opened: String? = null
        compose.setContent {
            PdshTheme {
                MarkdownBody(
                    markdown = "[Open file]($resource)",
                    onOpenResource = { opened = it },
                )
            }
        }
        compose.onNodeWithText("Open file").performClick()
        assertEquals(resource, opened)
    }

    @Test
    fun `native resource link stays unlinked without a resource callback`() {
        compose.setContent {
            PdshTheme {
                MarkdownBody(
                    markdown = "[Open file](dsh-resource://file/session/session-A/docs/readme.md)",
                )
            }
        }
        compose.onNodeWithText("Open file").assertHasNoClickAction()
    }

    @Test
    fun `inline code uses the preferred code role plus one point`() {
        val fontFamily = FontFamily.Serif
        compose.setContent {
            PdshTheme {
                val base = UiType.fromSpec()
                CompositionLocalProvider(
                    LocalUiType provides base.copy(
                        code = base.code.copy(fontSize = 17.sp, fontFamily = fontFamily),
                    ),
                ) {
                    MarkdownInlineText(
                        inlines = listOf(MarkdownInline.Code("let x = 1")),
                        style = TextStyle(fontSize = 16.sp),
                    )
                }
            }
        }
        val results = mutableListOf<TextLayoutResult>()
        val node = compose.onNodeWithText("let x = 1").fetchSemanticsNode()
        node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results)
        val codeSpan = requireNotNull(results.singleOrNull()).layoutInput.text.spanStyles.single().item
        assertEquals(18.sp, codeSpan.fontSize)
        assertEquals(fontFamily, codeSpan.fontFamily)
    }

    @Test
    fun `compact markdown uses native 13pt secondary typography and natural leading`() {
        var style: TextStyle? = null
        compose.setContent {
            PdshTheme {
                style = markdownBodyStyle(MarkdownVariant.COMPACT)
            }
        }
        compose.waitForIdle()
        val compact = requireNotNull(style)
        assertEquals(13.sp, compact.fontSize)
        assertEquals(TextUnit.Unspecified, compact.lineHeight)
    }

    @Test
    fun `compact markdown renders headings lists quotes and tables`() {
        compose.setContent {
            PdshTheme {
                MarkdownBody(
                    markdown = """# Compact heading

compact paragraph

- compact list item

> compact quote

| Name | Value |
| --- | --- |
| mode | compact |
""".trimIndent(),
                    variant = MarkdownVariant.COMPACT,
                )
            }
        }
        compose.onNodeWithText("Compact heading").assertIsDisplayed()
        compose.onNodeWithText("compact paragraph").assertIsDisplayed()
        compose.onNodeWithText("compact list item").assertIsDisplayed()
        compose.onNodeWithText("compact quote").assertIsDisplayed()
        compose.onNodeWithText("compact").assertIsDisplayed()
    }

    @Test
    fun `compact inline code uses fixed 13pt monospaced type`() {
        compose.setContent {
            PdshTheme {
                val base = UiType.fromSpec()
                CompositionLocalProvider(
                    LocalUiType provides base.copy(
                        code = base.code.copy(fontSize = 17.sp, fontFamily = FontFamily.Serif),
                    ),
                ) {
                    MarkdownInlineText(
                        inlines = listOf(MarkdownInline.Code("let x = 1")),
                        style = markdownBodyStyle(MarkdownVariant.COMPACT),
                        variant = MarkdownVariant.COMPACT,
                    )
                }
            }
        }
        val results = mutableListOf<TextLayoutResult>()
        val node = compose.onNodeWithText("let x = 1").fetchSemanticsNode()
        node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results)
        val codeSpan = requireNotNull(results.singleOrNull()).layoutInput.text.spanStyles.single().item
        assertEquals(13.sp, codeSpan.fontSize)
        assertEquals(FontFamily.Monospace, codeSpan.fontFamily)
    }

    @Test
    fun `unsafe markdown URI schemes are not routed`() {
        assertEquals(null, markdownLinkTarget("javascript:alert(1)"))
        assertEquals(null, markdownLinkTarget("../../outside.txt"))
        assertEquals(MarkdownLinkTarget.Uri("https://example.com"), markdownLinkTarget("https://example.com"))
    }

    @Test
    fun `workspace resource URI remains inert when no host callback is bound`() {
        compose.setContent {
            PdshTheme {
                MarkdownBody(markdown = "[Open file](file:///dsh/workspace/docs/readme.md)")
            }
        }
        compose.onNodeWithText("Open file").assertHasNoClickAction()
    }

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

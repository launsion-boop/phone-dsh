// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Spanned
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ClickableSpan
import android.text.style.ReplacementSpan
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MarkdownMathSpannableTest {
    @Test
    fun `math source is retained under replacement span for accessibility and copy`() {
        val latex = "\\frac{a_1+b}{\\sqrt{x+1}}"
        val span = TestReplacementSpan()
        val text = buildMarkdownSpannable(
            inlines = listOf(MarkdownInline.Text("before "), MarkdownInline.Math(latex), MarkdownInline.Text(" after")),
            mathSpans = mapOf(latex to span),
            baseWeight = 400,
            baseItalic = false,
            baseFamily = "sans-serif",
            codeFamily = "monospace",
            codeSizePx = 42,
            baseColor = 0xff111111.toInt(),
            accentColor = 0xff3366cc.toInt(),
            tertiaryColor = 0xff777777.toInt(),
            inlineCodeColor = 0xffeeeeee.toInt(),
            footnoteSizePx = 27,
            footnoteRaisePx = 18,
            onOpenFile = null,
            onOpenResource = null,
            openExternal = {},
        )
        assertEquals("before $latex after", text.toString())
        assertFalse(text.contains('\uFFFC'))
        val spans = (text as Spanned).getSpans(0, text.length, ReplacementSpan::class.java)
        assertEquals(1, spans.size)
        assertEquals(7, text.getSpanStart(span))
        assertEquals(7 + latex.length, text.getSpanEnd(span))
    }

    @Test
    fun `renderer failure fallback keeps TeX literal and surrounding text`() {
        val latex = "\\unknown{z}"
        val text = buildMarkdownSpannable(
            inlines = listOf(MarkdownInline.Text("before "), MarkdownInline.Math(latex), MarkdownInline.Text(" after")),
            mathSpans = emptyMap(),
            baseWeight = 400,
            baseItalic = false,
            baseFamily = null,
            codeFamily = "monospace",
            codeSizePx = 42,
            baseColor = 0xff111111.toInt(),
            accentColor = 0xff3366cc.toInt(),
            tertiaryColor = 0xff777777.toInt(),
            inlineCodeColor = 0xffeeeeee.toInt(),
            footnoteSizePx = 27,
            footnoteRaisePx = 18,
            onOpenFile = null,
            onOpenResource = null,
            openExternal = {},
        )
        assertEquals("before $latex after", text.toString())
        assertNull((text as Spanned).getSpans(0, text.length, ReplacementSpan::class.java).firstOrNull())
    }

    @Test
    fun `math inside validated links preserves exact host routes`() {
        val latex = "x^2"
        val file = "docs/math.md"
        val resource = "dsh-resource://file/session/session-A/dsh/workspace/math.md"
        val opened = mutableListOf<String>()
        val text = buildMarkdownSpannable(
            inlines = listOf(
                MarkdownInline.Link(file, listOf(MarkdownInline.Text("workspace "), MarkdownInline.Math(latex))),
                MarkdownInline.Text(" "),
                MarkdownInline.Link(resource, listOf(MarkdownInline.Text("resource"))),
            ),
            mathSpans = mapOf(latex to TestReplacementSpan()),
            baseWeight = 400,
            baseItalic = false,
            baseFamily = null,
            codeFamily = "monospace",
            codeSizePx = 42,
            baseColor = 0xff111111.toInt(),
            accentColor = 0xff3366cc.toInt(),
            tertiaryColor = 0xff777777.toInt(),
            inlineCodeColor = 0xffeeeeee.toInt(),
            footnoteSizePx = 27,
            footnoteRaisePx = 18,
            onOpenFile = { opened += it },
            onOpenResource = { opened += it },
            openExternal = { opened += it },
        ) as Spanned

        val clickable = text.getSpans(0, text.length, ClickableSpan::class.java)
        assertEquals(2, clickable.size)
        val widget = TextView(ApplicationProvider.getApplicationContext<Context>())
        clickable.forEach { it.onClick(widget) }
        assertEquals(listOf(file, resource), opened)
        assertEquals("workspace $latex resource", text.toString())
        assertTrue(text.getSpans(0, text.length, ReplacementSpan::class.java).isNotEmpty())
    }

    @Test
    fun `nested emphasis code and footnote keep their spans alongside math`() {
        val latex = "a+b"
        val text = buildMarkdownSpannable(
            inlines = listOf(
                MarkdownInline.Strong(
                    listOf(
                        MarkdownInline.Emphasis(listOf(MarkdownInline.Text("bold italic"))),
                        MarkdownInline.Text(" "),
                        MarkdownInline.Code("mono"),
                    ),
                ),
                MarkdownInline.Text(" "),
                MarkdownInline.Footnote("n"),
                MarkdownInline.Text(" "),
                MarkdownInline.Math(latex),
            ),
            mathSpans = mapOf(latex to TestReplacementSpan()),
            baseWeight = 400,
            baseItalic = false,
            baseFamily = null,
            codeFamily = "monospace",
            codeSizePx = 39,
            baseColor = 0xff111111.toInt(),
            accentColor = 0xff3366cc.toInt(),
            tertiaryColor = 0xff777777.toInt(),
            inlineCodeColor = 0xffeeeeee.toInt(),
            footnoteSizePx = 27,
            footnoteRaisePx = 18,
            onOpenFile = null,
            onOpenResource = null,
            openExternal = {},
        ) as Spanned

        assertEquals("bold italic mono [n] $latex", text.toString())
        assertNotNull(text.getSpans(0, text.length, BackgroundColorSpan::class.java).firstOrNull())
        assertEquals(1, text.getSpans(0, text.length, ReplacementSpan::class.java).size)
        assertTrue(text.getSpanStart(text.getSpans(0, text.length, ReplacementSpan::class.java).single()) > text.indexOf("[n]"))
    }
}

internal class TestReplacementSpan : ReplacementSpan() {
    override fun getSize(
        paint: Paint,
        text: CharSequence?,
        start: Int,
        end: Int,
        fm: Paint.FontMetricsInt?,
    ): Int {
        fm?.let {
            it.ascent = -40
            it.top = it.ascent
            it.descent = 12
            it.bottom = it.descent
        }
        return 56
    }

    override fun draw(
        canvas: Canvas,
        text: CharSequence?,
        start: Int,
        end: Int,
        x: Float,
        top: Int,
        y: Int,
        bottom: Int,
        paint: Paint,
    ) {
        canvas.drawRect(RectF(x, y - 40f, x + 56f, y + 12f), paint)
    }
}

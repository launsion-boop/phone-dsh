// Real AndroidTextView + RaTeXSpan integration: math metrics, wrapping, links and selection.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.screenshot

import android.graphics.Color
import android.os.SystemClock
import android.text.Spanned
import android.text.style.ClickableSpan
import android.text.style.ReplacementSpan
import android.view.View
import android.view.ViewGroup
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.surface.MARKDOWN_MATH_TAG
import com.phonedsh.ui.surface.MARKDOWN_MATH_TEXT_VIEW_TAG
import com.phonedsh.ui.surface.MarkdownBody
import com.phonedsh.ui.surface.MarkdownVariant
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.PdshTheme
import io.ratex.RaTeXEngine
import io.ratex.RaTeXFontLoader
import io.ratex.RaTeXRenderer
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MarkdownMathDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun mathParagraphWrapsKeepsSourceRoutesLinksAndSelectsTeX() = runBlocking {
        val context = compose.activity.applicationContext
        RaTeXFontLoader.clear()
        val loaded = withContext(Dispatchers.IO) { RaTeXFontLoader.ensureLoaded(context) }
        assertEquals(19, loaded)
        val filePath = "docs/math-source.md"
        val resourceUri = "dsh-resource://file/session/session-A/dsh/workspace/docs/math-source.md"
        val externalUri = "https://example.com/math"
        val fraction = "\\frac{a_1+b}{\\sqrt{x+1}}"
        val root = "\\sqrt{a^2+b^2}"
        val matrix = "\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}"
        val markdown = buildString {
            append("A long inline answer starts with a fraction ${'$'}$fraction${'$'} and enough ordinary prose before the root ")
            append("${'$'}$root${'$'} to force Android to wrap the same paragraph over several lines. Matrix: ")
            append("${'$'}$matrix${'$'}. Links stay native: [workspace-target]($filePath), ")
            append("[resource-target]($resourceUri), and [external-target]($externalUri).")
            append("\n\nA separate neighbor paragraph starts after the math paragraph.")
        }
        val openedFile = mutableStateOf<String?>(null)
        val openedResource = mutableStateOf<String?>(null)
        val openedExternal = mutableStateOf<String?>(null)
        val uriHandler = object : androidx.compose.ui.platform.UriHandler {
            override fun openUri(uri: String) { openedExternal.value = uri }
        }
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides uriHandler) {
                PdshTheme(darkTheme = false) {
                    MarkdownBody(
                        markdown = markdown,
                        onOpenFile = { openedFile.value = it },
                        onOpenResource = { openedResource.value = it },
                    )
                }
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).assertIsDisplayed()
        compose.onNodeWithText("A separate neighbor paragraph starts after the math paragraph.").assertIsDisplayed()

        val mathCases = listOf(fraction, root, matrix)
        val textView = findTextViewContaining("workspace-target")
        compose.waitUntil(20_000) {
            val current = textView.text as? Spanned ?: return@waitUntil false
            mathCases.all { latex ->
                val start = current.toString().indexOf(latex)
                start >= 0 && current.getSpans(0, current.length, ReplacementSpan::class.java)
                    .any { current.getSpanStart(it) == start && current.getSpanEnd(it) == start + latex.length }
            }
        }
        val spanned = textView.text as Spanned
        val viewBounds = compose.onNodeWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).fetchSemanticsNode().boundsInRoot
        val neighborBounds = compose.onNodeWithText("A separate neighbor paragraph starts after the math paragraph.")
            .fetchSemanticsNode().boundsInRoot
        val metrics = mutableListOf<String>()
        assertTrue("math paragraph did not wrap", textView.layout.lineCount >= 4)
        assertFalse("TextView backing content lost selection", spanned.toString().contains('\uFFFC'))
        mathCases.forEach { latex ->
            assertTrue("TeX source missing from TextView content: $latex", spanned.toString().contains(latex))
            val start = spanned.toString().indexOf(latex)
            val mathSpan = spanned.getSpans(0, spanned.length, ReplacementSpan::class.java)
                .singleOrNull { spanned.getSpanStart(it) == start && spanned.getSpanEnd(it) == start + latex.length }
                ?: error("missing RaTeX ReplacementSpan for $latex. Found: ${spanned.getSpans(0, spanned.length, ReplacementSpan::class.java).map { spanned.getSpanStart(it) to spanned.getSpanEnd(it) }}")
            val line = textView.layout.getLineForOffset(start)
            val baseline = textView.layout.getLineBaseline(line).toFloat()
            val layoutResult = withContext(Dispatchers.Default) {
                RaTeXEngine.parseBlocking(latex, displayMode = false, color = Color.BLACK)
            }
            val renderer = RaTeXRenderer(layoutResult, 48f) { RaTeXFontLoader.getTypeface(it) }
            val formulaTop = baseline - renderer.heightPx
            val formulaBottom = baseline + renderer.depthPx
            val lineTop = textView.layout.getLineTop(line).toFloat()
            val lineBottom = textView.layout.getLineBottom(line).toFloat()
            assertTrue("$latex ascent exceeds line top ($formulaTop vs $lineTop)", formulaTop >= lineTop - 1f)
            assertTrue("$latex depth exceeds line bottom ($formulaBottom vs $lineBottom)", formulaBottom <= lineBottom + 1f)
            val spanWidth = mathSpan.getSize(textView.paint, spanned, start, start + latex.length, null)
            assertTrue("span width differs from renderer extent by more than bitmap rounding",
                spanWidth >= renderer.widthPx && spanWidth - renderer.widthPx < 1.1f)
            metrics += "formula=$latex line=$line lineBounds=$lineTop..$lineBottom baseline=$baseline formulaBounds=$formulaTop..$formulaBottom"
        }
        assertTrue("math text overlaps the following paragraph", viewBounds.bottom <= neighborBounds.top)

        fun tapText(label: String) {
            val start = spanned.toString().indexOf(label)
            assertTrue("missing link label $label", start >= 0)
            val line = textView.layout.getLineForOffset(start)
            val x0 = textView.layout.getPrimaryHorizontal(start)
            val x1 = textView.layout.getPrimaryHorizontal(start + label.length)
            val x = (x0 + x1) / 2f + textView.paddingLeft
            val y = (textView.layout.getLineTop(line) + textView.layout.getLineBottom(line)) / 2f + textView.paddingTop
            compose.onNodeWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).performTouchInput { click(Offset(x, y)) }
            compose.waitForIdle()
        }
        assertEquals(3, spanned.getSpans(0, spanned.length, ClickableSpan::class.java).size)
        tapText("workspace-target")
        assertEquals(filePath, openedFile.value)
        tapText("resource-target")
        assertEquals(resourceUri, openedResource.value)
        tapText("external-target")
        assertEquals(externalUri, openedExternal.value)

        // Long-press inside a ReplacementSpan and prove the selected backing text is TeX source.
        val formulaStart = spanned.toString().indexOf(fraction)
        val formulaLine = textView.layout.getLineForOffset(formulaStart)
        val formulaX0 = textView.layout.getPrimaryHorizontal(formulaStart)
        val formulaX1 = textView.layout.getPrimaryHorizontal(formulaStart + fraction.length)
        val formulaX = (formulaX0 + formulaX1) / 2f + textView.paddingLeft
        val formulaY = (textView.layout.getLineTop(formulaLine) + textView.layout.getLineBottom(formulaLine)) / 2f + textView.paddingTop
        dispatchAndroidLongPress(textView, formulaX, formulaY)
        compose.waitForIdle()
        val selectionStart = textView.selectionStart
        val selectionEnd = textView.selectionEnd
        assertTrue("long press did not select text", selectionStart >= 0 && selectionEnd > selectionStart)
        val selected = textView.text.subSequence(selectionStart, selectionEnd).toString()
        assertFalse("selected TeX was replaced by U+FFFC", selected.contains('\uFFFC'))
        assertTrue("math selection lost its TeX source: $selected", fraction.contains(selected) || selected.contains(fraction))

        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val output = File(context.getExternalFilesDir(null), "math-production-candidate").apply { mkdirs() }
        FileOutputStream(File(output, "inline-math-links-selection-light.png")).use { stream ->
            assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream))
        }
        File(output, "inline-math-links-selection-metrics.txt").writeText(
            (listOf("lineCount=${textView.layout.lineCount}", "viewBounds=${viewBounds.top}..${viewBounds.bottom}",
                "neighborTop=${neighborBounds.top}", "selected=<$selected>") + metrics).joinToString("\n", postfix = "\n"),
        )
    }

    @Test
    fun darkCompactInlineAndDisplayMathUseSourceRolesAndHorizontalDisplayScroll() = runBlocking {
        val context = compose.activity.applicationContext
        val compactLatex = "\\sqrt{a^2+b^2}"
        val displayLatex = "\\begin{bmatrix}x_1&x_2&x_3\\\\y_1&y_2&y_3\\end{bmatrix}"
        val markdown = "Compact line " + '$' + compactLatex + '$' + " stays in the same paragraph.\n\n" +
            "\$\$\n$displayLatex\n\$\$"
        val expectedColor = mutableStateOf<Int?>(null)
        compose.setContent {
            PdshTheme(darkTheme = true) {
                val tokens = LocalUiTokens.current
                expectedColor.value = tokens.colors.tertiary.toArgb()
                Box(Modifier.fillMaxSize().background(tokens.colors.background)) {
                    MarkdownBody(markdown = markdown, variant = MarkdownVariant.COMPACT)
                }
            }
        }
        compose.waitForIdle()
        val inlineView = findTextViewContaining(compactLatex)
        assertEquals("compact math TextView changed source color", expectedColor.value, inlineView.currentTextColor)
        assertTrue("compact TeX source was not retained", inlineView.text.toString().contains(compactLatex))
        compose.onNodeWithTag(MARKDOWN_MATH_TAG).assertIsDisplayed()
        val displayView = findTextViewContaining(displayLatex)
        assertTrue("display math must allow horizontal overflow scrolling", displayView.isHorizontallyScrollable)
        assertTrue("display formula lost the source text", displayView.text.toString().contains(displayLatex))

        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val output = File(context.getExternalFilesDir(null), "math-production-candidate").apply { mkdirs() }
        FileOutputStream(File(output, "compact-dark-display-math.png")).use { stream ->
            assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream))
        }
    }

    private fun findTextViewContaining(source: String): TextView {
        val candidates = ArrayList<View>()
        (compose.activity.window.decorView as ViewGroup).findViewsWithText(
            candidates,
            source,
            View.FIND_VIEWS_WITH_TEXT,
        )
        return candidates.filterIsInstance<TextView>().firstOrNull { it.text?.toString()?.contains(source) == true }
            ?: error("no TextView backing source text: $source")
    }

    private fun dispatchAndroidLongPress(view: TextView, x: Float, y: Float) {
        val downTime = SystemClock.uptimeMillis()
        compose.runOnUiThread {
            MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0).let { event ->
                view.dispatchTouchEvent(event)
                event.recycle()
            }
        }
        Thread.sleep(ViewConfiguration.getLongPressTimeout().toLong() + 150L)
        val upTime = SystemClock.uptimeMillis()
        compose.runOnUiThread {
            MotionEvent.obtain(downTime, upTime, MotionEvent.ACTION_UP, x, y, 0).let { event ->
                view.dispatchTouchEvent(event)
                event.recycle()
            }
        }
    }
}

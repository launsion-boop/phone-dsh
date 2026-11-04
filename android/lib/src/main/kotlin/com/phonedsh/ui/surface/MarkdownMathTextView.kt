// Native Android text paragraph adapter for Markdown containing TeX.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.content.Context
import android.graphics.Color as AndroidColor
import android.graphics.Typeface
import android.os.Build
import android.text.SpannableStringBuilder
import android.text.Selection
import android.text.Spannable
import android.text.Spanned
import android.text.TextPaint
import android.text.method.LinkMovementMethod
import android.text.style.BackgroundColorSpan
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.TextView
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.viewinterop.AndroidView
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.theme.LocalUiTokens
import io.ratex.RaTeXException
import io.ratex.RaTeXSpan
import kotlin.math.max
import kotlin.math.roundToInt

internal const val MARKDOWN_MATH_TEXT_VIEW_TAG: String = "pdsh.surface.markdown.math.textview"

/** Explicitly injectable for non-native tests; product rendering defaults to the real RaTeX span. */
internal fun interface MarkdownMathSpanBackend {
    public suspend fun create(
        context: Context,
        latex: String,
        fontSizeDp: Float,
        color: Int,
        displayMode: Boolean,
    ): ReplacementSpan?
}

internal object RaTeXMarkdownMathSpanBackend : MarkdownMathSpanBackend {
    override suspend fun create(
        context: Context,
        latex: String,
        fontSizeDp: Float,
        color: Int,
        displayMode: Boolean,
    ): ReplacementSpan? = try {
        RaTeXSpan.create(
            context = context,
            latex = latex,
            fontSize = fontSizeDp,
            color = color,
            displayMode = displayMode,
        )
    } catch (_: RaTeXException) {
        // iOS MathImage falls back to the original TeX source on a renderer error.
        null
    }
}

internal val LocalMarkdownMathSpanBackend = compositionLocalOf<MarkdownMathSpanBackend> {
    RaTeXMarkdownMathSpanBackend
}

/** True when any inline descendant needs the native span paragraph. */
internal fun containsMarkdownMath(inlines: List<MarkdownInline>): Boolean = inlines.any { part ->
    when (part) {
        is MarkdownInline.Math -> true
        is MarkdownInline.Strong -> containsMarkdownMath(part.children)
        is MarkdownInline.Emphasis -> containsMarkdownMath(part.children)
        is MarkdownInline.Delete -> containsMarkdownMath(part.children)
        is MarkdownInline.Link -> containsMarkdownMath(part.children)
        else -> false
    }
}

private fun mathSources(inlines: List<MarkdownInline>): List<String> = buildList {
    fun collect(parts: List<MarkdownInline>) {
        parts.forEach { part ->
            when (part) {
                is MarkdownInline.Math -> add(part.latex)
                is MarkdownInline.Strong -> collect(part.children)
                is MarkdownInline.Emphasis -> collect(part.children)
                is MarkdownInline.Delete -> collect(part.children)
                is MarkdownInline.Link -> collect(part.children)
                else -> Unit
            }
        }
    }
    collect(inlines)
}.distinct()

/**
 * One TextView per math-bearing paragraph/cell/heading. The underlying text keeps the literal TeX
 * range (for copying and accessibility text); RaTeXSpan only replaces how that range is painted.
 */
@Composable
internal fun MarkdownMathTextView(
    inlines: List<MarkdownInline>,
    style: TextStyle,
    codeFontFamily: FontFamily?,
    codeFontSize: TextUnit,
    modifier: Modifier = Modifier,
    onOpenFile: ((String) -> Unit)? = null,
    onOpenResource: ((String) -> Unit)? = null,
    displayMode: Boolean = false,
    testTag: String = MARKDOWN_MATH_TEXT_VIEW_TAG,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val tokens = LocalUiTokens.current
    val uriHandler = LocalUriHandler.current
    val backend = LocalMarkdownMathSpanBackend.current
    val linkFailure = remember(inlines) { mutableStateOf(false) }
    val openExternal: (String) -> Unit = { value ->
        openMarkdownExternalUri(uriHandler, value) { linkFailure.value = true }
    }
    val color = style.color.takeIf { it != Color.Unspecified }?.toArgb() ?: tokens.colors.primary.toArgb()
    val accent = tokens.colors.accent.toArgb()
    val tertiary = tokens.colors.tertiary.toArgb()
    val inlineCode = tokens.colors.inlineCode.toArgb()
    val codeFamily = androidFamilyName(codeFontFamily)
    val baseFamily = androidFamilyName(style.fontFamily)
    val baseSizeSp = style.fontSize.takeIf { it.isSp }?.value ?: 16f
    val baseWeight = style.fontWeight?.weight ?: FontWeight.Normal.weight
    val baseItalic = style.fontStyle == FontStyle.Italic
    val codeSizePx = remember(codeFontSize, context.resources.displayMetrics.scaledDensity) {
        codeFontSize.toPixelSize(context)
    }
    val footnoteSizePx = remember(context.resources.displayMetrics.scaledDensity) {
        spPixels(context, ChatMetrics.MARKDOWN_FOOTNOTE_SIZE_PT.toFloat())
    }
    val footnoteRaisePx = remember(context.resources.displayMetrics.density) {
        dpPixels(context, ChatMetrics.MARKDOWN_FOOTNOTE_BASELINE_OFFSET_PT.toFloat())
    }
    val fallback = remember(
        inlines, baseWeight, baseItalic, baseFamily, codeFamily, codeSizePx, color, accent, tertiary,
        inlineCode, footnoteSizePx, footnoteRaisePx, onOpenFile, onOpenResource, uriHandler,
    ) {
        buildMarkdownSpannable(
            inlines = inlines,
            mathSpans = emptyMap(),
            baseWeight = baseWeight,
            baseItalic = baseItalic,
            baseFamily = baseFamily,
            codeFamily = codeFamily,
            codeSizePx = codeSizePx,
            baseColor = color,
            accentColor = accent,
            tertiaryColor = tertiary,
            inlineCodeColor = inlineCode,
            footnoteSizePx = footnoteSizePx,
            footnoteRaisePx = footnoteRaisePx,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            openExternal = openExternal,
        )
    }
    var rendered by remember(
        inlines, style, codeFamily, codeSizePx, color, accent, tertiary, inlineCode, footnoteSizePx,
        footnoteRaisePx, onOpenFile, onOpenResource, uriHandler, backend,
    ) { mutableStateOf<CharSequence>(fallback) }
    val fontSizeDp = remember(style.fontSize, density.density, density.fontScale) {
        val sp = style.fontSize.takeIf { it.isSp }?.value ?: 16f
        sp * density.fontScale
    }
    LaunchedEffect(inlines, style, fontSizeDp, color, backend, onOpenFile, onOpenResource, uriHandler) {
        val mathSpans = LinkedHashMap<String, ReplacementSpan>()
        for (latex in mathSources(inlines)) {
            backend.create(
                context = context.applicationContext,
                latex = latex,
                fontSizeDp = fontSizeDp,
                color = color,
                displayMode = displayMode,
            )?.let { mathSpans[latex] = it }
        }
        rendered = buildMarkdownSpannable(
            inlines = inlines,
            mathSpans = mathSpans,
            baseWeight = baseWeight,
            baseItalic = baseItalic,
            baseFamily = baseFamily,
            codeFamily = codeFamily,
            codeSizePx = codeSizePx,
            baseColor = color,
            accentColor = accent,
            tertiaryColor = tertiary,
            inlineCodeColor = inlineCode,
            footnoteSizePx = footnoteSizePx,
            footnoteRaisePx = footnoteRaisePx,
            onOpenFile = onOpenFile,
            onOpenResource = onOpenResource,
            openExternal = openExternal,
        )
    }

    val configure: (TextView) -> Unit = { view -> configureMarkdownTextView(view, style, baseSizeSp, color, displayMode) }
    Column(modifier = modifier) {
        AndroidView(
            factory = { viewContext ->
                TextView(viewContext).apply {
                    configure(this)
                    text = fallback
                }
            },
            modifier = if (displayMode) {
                Modifier.wrapContentWidth().horizontalScroll(rememberScrollState()).testTag(testTag)
            } else {
                Modifier.fillMaxWidth().testTag(testTag)
            },
            update = { view ->
                configure(view)
                if (view.text !== rendered) {
                    val selectionStart = Selection.getSelectionStart(view.text)
                    val selectionEnd = Selection.getSelectionEnd(view.text)
                    view.text = rendered
                    val currentText = view.text
                    if (selectionStart >= 0 && selectionEnd >= selectionStart && selectionEnd <= currentText.length && currentText is Spannable) {
                        Selection.setSelection(currentText, selectionStart, selectionEnd)
                    }
                }
            },
        )
        if (linkFailure.value) MarkdownLinkFailureNotice()
    }
}

/** Builds a source-preserving Spannable; a missing map entry leaves its TeX readable as text. */
internal fun buildMarkdownSpannable(
    inlines: List<MarkdownInline>,
    mathSpans: Map<String, ReplacementSpan>,
    baseWeight: Int,
    baseItalic: Boolean,
    baseFamily: String?,
    codeFamily: String?,
    codeSizePx: Int,
    baseColor: Int,
    accentColor: Int,
    tertiaryColor: Int,
    inlineCodeColor: Int,
    footnoteSizePx: Int,
    footnoteRaisePx: Int,
    onOpenFile: ((String) -> Unit)?,
    onOpenResource: ((String) -> Unit)?,
    openExternal: (String) -> Unit,
): CharSequence {
    val builder = SpannableStringBuilder()
    val base = MarkdownInlineAppearance(
        weight = baseWeight,
        italic = baseItalic,
        family = baseFamily,
        foreground = baseColor,
    )

    fun applyAppearance(start: Int, end: Int, appearance: MarkdownInlineAppearance) {
        if (end <= start) return
        builder.setSpan(
            MarkdownTypefaceSpan(appearance.family, appearance.weight, appearance.italic),
            start,
            end,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        appearance.foreground?.let {
            builder.setSpan(ForegroundColorSpan(it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        appearance.background?.let {
            builder.setSpan(BackgroundColorSpan(it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        appearance.fontSizePx?.let {
            builder.setSpan(android.text.style.AbsoluteSizeSpan(it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (appearance.strike) builder.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (appearance.underline) builder.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    fun appendText(value: String, appearance: MarkdownInlineAppearance) {
        if (value.isEmpty()) return
        val start = builder.length
        builder.append(value)
        applyAppearance(start, builder.length, appearance)
    }

    fun append(parts: List<MarkdownInline>, appearance: MarkdownInlineAppearance) {
        parts.forEach { part ->
            when (part) {
                is MarkdownInline.Text -> appendText(part.text, appearance)
                is MarkdownInline.Strong -> append(
                    part.children,
                    appearance.copy(weight = max(appearance.weight, FontWeight.SemiBold.weight)),
                )
                is MarkdownInline.Emphasis -> append(part.children, appearance.copy(italic = true))
                is MarkdownInline.Delete -> append(part.children, appearance.copy(strike = true))
                is MarkdownInline.Code -> appendText(
                    part.code,
                    appearance.copy(
                        family = codeFamily ?: "monospace",
                        fontSizePx = codeSizePx.takeIf { it > 0 },
                        background = inlineCodeColor,
                    ),
                )
                is MarkdownInline.Link -> {
                    val target = markdownLinkTarget(part.destination)
                    val canOpen = when (target) {
                        is MarkdownLinkTarget.Uri -> true
                        is MarkdownLinkTarget.WorkspacePath -> onOpenFile != null
                        is MarkdownLinkTarget.ResourceUri -> onOpenResource != null
                        null -> false
                    }
                    if (!canOpen || target == null) {
                        append(part.children, appearance)
                    } else {
                        val start = builder.length
                        append(part.children, appearance.copy(foreground = accentColor, underline = true))
                        val end = builder.length
                        if (end > start) {
                            builder.setSpan(
                                object : ClickableSpan() {
                                    override fun onClick(widget: View) {
                                        when (target) {
                                            is MarkdownLinkTarget.Uri -> openExternal(target.value)
                                            is MarkdownLinkTarget.WorkspacePath -> onOpenFile?.invoke(target.value)
                                            is MarkdownLinkTarget.ResourceUri -> onOpenResource?.invoke(target.value)
                                        }
                                    }

                                    override fun updateDrawState(ds: TextPaint) {
                                        ds.color = accentColor
                                        ds.isUnderlineText = true
                                    }
                                },
                                start,
                                end,
                                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                            )
                        }
                    }
                }
                is MarkdownInline.Image -> appendText(
                    part.alt,
                    appearance.copy(italic = true, foreground = tertiaryColor),
                )
                is MarkdownInline.Math -> {
                    val start = builder.length
                    // Keep source characters in the backing text: selection/copy and accessibility text
                    // never see the U+FFFC marker used by many inline-image adapters.
                    builder.append(part.latex)
                    val span = mathSpans[part.latex]
                    if (span != null && part.latex.isNotEmpty()) {
                        builder.setSpan(span, start, builder.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    } else {
                        applyAppearance(start, builder.length, appearance)
                    }
                }
                is MarkdownInline.Footnote -> {
                    val start = builder.length
                    builder.append("[${part.id}]")
                    if (builder.length > start) {
                        builder.setSpan(
                            MarkdownFootnoteSpan(footnoteSizePx, footnoteRaisePx),
                            start,
                            builder.length,
                            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                        )
                    }
                }
            }
        }
    }

    append(inlines, base)
    return builder
}

private data class MarkdownInlineAppearance(
    val weight: Int,
    val italic: Boolean,
    val family: String?,
    val foreground: Int?,
    val background: Int? = null,
    val fontSizePx: Int? = null,
    val strike: Boolean = false,
    val underline: Boolean = false,
)

private class MarkdownTypefaceSpan(
    private val family: String?,
    private val weight: Int,
    private val italic: Boolean,
) : MetricAffectingSpan() {
    override fun updateMeasureState(textPaint: TextPaint) = apply(textPaint)
    override fun updateDrawState(textPaint: TextPaint) = apply(textPaint)

    private fun apply(textPaint: TextPaint) {
        val current = textPaint.typeface ?: Typeface.DEFAULT
        val targetWeight = if (weight >= FontWeight.SemiBold.weight) max(weight, current.weightOrStyle()) else current.weightOrStyle()
        val familyBase = family?.let { Typeface.create(it, Typeface.NORMAL) } ?: current
        textPaint.typeface = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Typeface.create(familyBase, targetWeight, italic)
        } else {
            val style = (if (targetWeight >= FontWeight.SemiBold.weight) Typeface.BOLD else Typeface.NORMAL) or
                (if (italic) Typeface.ITALIC else Typeface.NORMAL)
            Typeface.create(familyBase, style)
        }
    }
}

private class MarkdownFootnoteSpan(
    private val sizePx: Int,
    private val raisePx: Int,
) : MetricAffectingSpan() {
    override fun updateMeasureState(textPaint: TextPaint) = apply(textPaint)
    override fun updateDrawState(textPaint: TextPaint) = apply(textPaint)

    private fun apply(textPaint: TextPaint) {
        textPaint.textSize = sizePx.toFloat()
        textPaint.baselineShift -= raisePx
    }
}

private fun Typeface.weightOrStyle(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
    weight
} else {
    if (isBold) FontWeight.Bold.weight else FontWeight.Normal.weight
}

private fun androidFamilyName(family: FontFamily?): String? = when (family) {
    FontFamily.Monospace -> "monospace"
    FontFamily.Serif -> "serif"
    FontFamily.SansSerif -> "sans-serif"
    FontFamily.Cursive -> "cursive"
    else -> null
}

private fun TextUnit.toPixelSize(context: Context): Int = if (isSp) spPixels(context, value) else 0
private fun spPixels(context: Context, value: Float): Int = TypedValue.applyDimension(
    TypedValue.COMPLEX_UNIT_SP,
    value,
    context.resources.displayMetrics,
).roundToInt()
private fun dpPixels(context: Context, value: Float): Int = TypedValue.applyDimension(
    TypedValue.COMPLEX_UNIT_DIP,
    value,
    context.resources.displayMetrics,
).roundToInt()

private fun configureMarkdownTextView(
    view: TextView,
    style: TextStyle,
    sizeSp: Float,
    color: Int,
    displayMode: Boolean,
) {
    val family = androidFamilyName(style.fontFamily)
    val weight = style.fontWeight?.weight ?: FontWeight.Normal.weight
    val italic = style.fontStyle == FontStyle.Italic
    val base = family?.let { Typeface.create(it, Typeface.NORMAL) } ?: view.typeface ?: Typeface.DEFAULT
    view.typeface = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        Typeface.create(base, weight, italic)
    } else {
        val typefaceStyle = (if (weight >= FontWeight.SemiBold.weight) Typeface.BOLD else Typeface.NORMAL) or
            (if (italic) Typeface.ITALIC else Typeface.NORMAL)
        Typeface.create(base, typefaceStyle)
    }
    view.includeFontPadding = false
    view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
    view.setTextColor(color)
    view.setPadding(0, 0, 0, 0)
    view.setBackgroundColor(AndroidColor.TRANSPARENT)
    view.highlightColor = AndroidColor.TRANSPARENT
    view.setTextIsSelectable(true)
    view.movementMethod = LinkMovementMethod.getInstance()
    view.setHorizontallyScrolling(displayMode)
    view.gravity = when (style.textAlign) {
        TextAlign.Center -> Gravity.CENTER_HORIZONTAL
        TextAlign.End -> Gravity.END
        TextAlign.Justify -> Gravity.START
        else -> Gravity.START
    }
    if (style.lineHeight.isSp) {
        val heightPx = spPixels(view.context, style.lineHeight.value)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            view.setLineHeight(heightPx)
        } else {
            val metrics = view.paint.fontMetricsInt
            val plainHeightPx = metrics.descent - metrics.ascent
            // On API 26–27 this keeps prose at the requested baseline spacing and lets
            // ReplacementSpan metrics enlarge math lines, at the cost of extra math leading.
            view.setLineSpacing(max(0, heightPx - plainHeightPx).toFloat(), 1f)
        }
    } else {
        view.setLineSpacing(0f, 1f)
    }
}

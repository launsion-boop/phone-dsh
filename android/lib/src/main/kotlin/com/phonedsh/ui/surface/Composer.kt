// Signature surface 5/6 - the composer.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "composer" + §3 + §4 + `tokens.json`
// `signatureSurfaces.composer`.
//
// The card mirrors `ChatPage.swift` `composer` clause for clause: one elevated
// card, a text field that grows to `geometry.composerMaxHeight`, the tool row
// docked inside its lower edge and the two mutually exclusive keys at the bottom
// trailing corner. While a turn runs and the draft *can* be submitted to it the
// send key stays and a small stop key sits beside it; when the draft cannot be
// submitted the stop key takes the send key's place (iOS `actionButton`).
//
// A pending ask keeps the dock visible but disabled (never hidden). The dock is
// a ScreenState-owned widget: it has no event anchor, so it never becomes a
// UiState node.
package com.phonedsh.ui.surface

import android.icu.text.BreakIterator
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.state.SessionStats
import com.phonedsh.ui.state.SessionTokenUsage
import com.phonedsh.ui.state.ContextPressure
import com.phonedsh.ui.state.ContextBreakdown
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialSheetColors
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.util.Locale
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** Which key the dock's trailing corner shows. */
public enum class ComposerMode {
    /** The accent send key. */
    SEND,

    /** A turn runs and the draft cannot be submitted to it: the stop key. */
    STOP,
}

/**
 * The token inventory of this surface: exactly `signatureSurfaces.composer.tokens`.
 *
 * The typed-text ink and the internal control gap used to be documented gaps; the
 * spec declares them now, so the gaps list is empty and a missing token fails this
 * surface instead of being excused as review debt.
 */
public object ComposerTokens {
    public val declared: List<String> = listOf(
        UiTokenNames.COLORS_SURFACE,
        UiTokenNames.COLORS_PRIMARY_BUTTON,
        UiTokenNames.COLORS_PRIMARY_BUTTON_INK,
        UiTokenNames.COLORS_USER_BUBBLE,
        UiTokenNames.COLORS_INPUT_PLACEHOLDER,
        UiTokenNames.COLORS_ICON_MUTED,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_BORDER_LIGHT,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.RADIUS_COMPOSER_OPEN,
        UiTokenNames.GEOMETRY_COMPOSER_OPEN_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_SEND_BUTTON,
        UiTokenNames.GEOMETRY_COMPOSER_ICON,
        UiTokenNames.GEOMETRY_CHROME_INSET,
        UiTokenNames.GEOMETRY_COMPOSER_MAX_HEIGHT,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_HEIGHT,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_TOP,
        UiTokenNames.GEOMETRY_COMPOSER_PORT_TOP,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_TOP,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_BOTTOM,
        UiTokenNames.GEOMETRY_STAT_PILL_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_SIZE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
    )

    /** No reviewed deviations: every token this surface uses is declared by the spec. */
    public val gaps: List<String> = emptyList()

    public val refs: List<String> get() = declared + gaps
}

/**
 * The input card.
 *
 * @param text the draft; owned by the screen state, never by this composable.
 * @param onTextChange draft updates.
 * @param placeholder the three-case placeholder the screen already resolved
 *   (idle / steer / queue); it is both the hint and the field's label.
 * @param mode send or stop for the trailing key.
 * @param enabled false while a pending ask is on screen (visible, disabled).
 * @param canSubmit iOS `canSubmit`: the send key is live.
 * @param running a turn is running (keeps the small stop key beside a live send).
 * @param onSend send the draft.
 * @param onStop stop the running turn.
 * @param stat optional usage pill text; `null` hides it.
 * @param contextPercent optional context-window share; `null` hides the ring.
 * @param sendLabel the send key's accessibility label (the screen resolves it
 *   from the idle/steer/queue case).
 * @param controls the tool row docked inside the card (plus / permissions /
 *   model / running spinner); `null` leaves the row empty.
 * @param onTruncated the draft exceeded 8000 extended graphemes and was cut.
 */
@Composable
public fun Composer(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    mode: ComposerMode,
    enabled: Boolean,
    canSubmit: Boolean,
    running: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    stat: String? = null,
    contextPercent: Int? = null,
    sendLabel: String = UiStrings.COMPOSER_SEND_LABEL,
    controls: (@Composable () -> Unit)? = null,
    onTruncated: () -> Unit = {},
    onMenuKey: (KeyEvent) -> Boolean = { false },
    onMenuSubmit: () -> Boolean = { false },
    sessionStats: SessionStats? = null,
    tokenUsage: SessionTokenUsage? = null,
    contextPressure: ContextPressure? = null,
    contextBreakdown: ContextBreakdown? = null,
    statsMode: ComposerStatsMode = ComposerStatsMode.DETAILED,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.composer)
    val focusRequester = remember { FocusRequester() }
    // Keep selection/composition data from the platform editor while the host
    // continues to own the plain-text draft. External command/reference picks
    // are synchronized without resetting an in-progress IME composition.
    var fieldValue by remember { mutableStateOf(TextFieldValue(text)) }
    SideEffect {
        if (fieldValue.text != text && fieldValue.composition == null) {
            fieldValue = TextFieldValue(text, selection = TextRange(text.length))
        }
    }

    fun handleHardwareEnter(event: KeyEvent): Boolean {
        if (event.key != Key.Enter || event.type != KeyEventType.KeyDown || event.isShiftPressed) return false
        // Leave Enter to the IME while it owns a composing region; sending then
        // would commit only a prefix of CJK input.
        if (fieldValue.composition != null) return false
        if (!onMenuSubmit() && enabled && canSubmit) onSend()
        return true
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag(UiTags.COMPOSER)
            .padding(
                start = tokens.geometry.composerOuterMarginH,
                end = tokens.geometry.composerOuterMarginH,
                top = tokens.geometry.composerOuterMarginTop,
                // PR22 ChatPage.swift removes the former 8 pt dock bottom inset;
                // only the system navigation safe area remains below this card.
                bottom = ChatMetrics.COMPOSER_OUTER_MARGIN_BOTTOM_PT.dp,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .onPreviewKeyEvent(onMenuKey)
                .heightIn(min = ChatMetrics.COMPOSER_HEIGHT_PT.dp)
                .shadow(
                    elevation = tokens.shadow.composerRadius,
                    shape = shape,
                    clip = false,
                    ambientColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = tokens.shadow.composerOpacity),
                    spotColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = tokens.shadow.composerOpacity),
                )
                .background(color = tokens.colors.surface, shape = shape)
                // ChatPage.swift's card tap focuses the editor; nested button
                // click targets consume their own tap and keep their actions.
                .pointerInput(enabled, focusRequester) {
                    detectTapGestures(onTap = { if (enabled) focusRequester.requestFocus() })
                }
                .testTag(COMPOSER_CARD_TAG),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = tokens.geometry.composerPortTop),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            start = ChatMetrics.COMPOSER_PORT_LEADING_PT.dp,
                            end = ChatMetrics.COMPOSER_PORT_TRAILING_PT.dp,
                        ),
                ) {
                    if (text.isEmpty()) {
                        BasicText(
                            text = placeholder,
                            style = type.body.copy(color = tokens.colors.inputPlaceholder),
                            maxLines = 2,
                            modifier = Modifier.padding(
                                start = ChatMetrics.COMPOSER_PLACEHOLDER_LEADING_PT.dp,
                                top = ChatMetrics.COMPOSER_PLACEHOLDER_TOP_PT.dp,
                            ),
                        )
                    }
                    BasicTextField(
                        value = fieldValue,
                        onValueChange = { value ->
                            val limited = enforceComposerDraftLimit(value)
                            fieldValue = limited.value
                            onTextChange(limited.value.text)
                            if (limited.truncated) onTruncated()
                        },
                        enabled = enabled,
                        textStyle = type.body.copy(
                            color = tokens.colors.textPrimary,
                        ),
                        cursorBrush = SolidColor(tokens.colors.accent),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.Sentences,
                            // iOS gives the software keyboard a Send return key and
                            // intercepts Return before it inserts a newline. Keep
                            // multiline editing for hardware/newline input, while
                            // the soft keyboard's primary action submits the draft.
                            imeAction = ImeAction.Send,
                        ),
                        keyboardActions = KeyboardActions(
                            onSend = {
                                if (fieldValue.composition == null && !onMenuSubmit() && enabled && canSubmit) onSend()
                            },
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(
                                // The UIKit text view itself floors at 56 pt even
                                // though its containing row's minimum is 36 pt.
                                min = ChatMetrics.COMPOSER_TEXT_MIN_HEIGHT_PT.dp,
                                max = tokens.geometry.composerMaxHeight,
                            )
                            .focusRequester(focusRequester)
                            .onPreviewKeyEvent(::handleHardwareEnter)
                            .testTag(UiTags.COMPOSER_FIELD)
                            .semantics {
                                contentDescription = placeholder
                                if (!enabled) stateDescription = UiStrings.PENDING_SLOT.format(1)
                            },
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        // PR22 keeps actions inline in composerControls. The model
                        // is measured only after the action cluster takes its width.
                        .padding(
                            start = ChatMetrics.COMPOSER_CONTROL_LEADING_PT.dp,
                            end = ChatMetrics.COMPOSER_CONTROL_TRAILING_PT.dp,
                            top = tokens.geometry.composerControlTop,
                            bottom = tokens.geometry.composerControlBottom,
                        )
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().height(tokens.geometry.composerControlRowHeight),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(modifier = Modifier.weight(1f).fillMaxWidth()) { controls?.invoke() }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // Stop remains available while a draft cannot yet be
                            // queued/steered. Its host capability is independent
                            // of the send action and the non-empty draft.
                            if (running && mode != ComposerMode.STOP) StopKey(onClick = onStop)
                            if (mode == ComposerMode.STOP) {
                                StopKey(onClick = onStop)
                            } else {
                                SendKey(enabled = enabled && canSubmit, label = sendLabel, onClick = onSend)
                            }
                        }
                    }
                }
            }
        }
        Row(
            // NativeComposerStats retains an empty detailed HStack with
            // 2pt top padding. The 6pt parent gap therefore remains even
            // when no metrics have arrived; hiding it shifts the card 8pt.
            modifier = Modifier.fillMaxWidth().padding(top = com.phonedsh.ui.ChatMetrics.COMPOSER_STATS_TOP_PT.dp),
            // ios-chat-official.png: the stats line sits under the card's leading
            // edge (x 29.3), not centred under it.
            horizontalArrangement = Arrangement.spacedBy(if (statsMode == ComposerStatsMode.COMPACT) 8.dp else 4.dp, Alignment.Start),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (sessionStats != null || tokenUsage != null || contextPressure != null || contextBreakdown != null) {
                ComposerMetrics(statsMode, sessionStats, tokenUsage, contextPressure, contextBreakdown)
            } else {
                if (stat != null) {
                    StatPill(modifier = Modifier.testTag(UiTags.COMPOSER_STAT)) {
                        BasicText(text = stat, style = type.secondary.copy(color = tokens.colors.tertiary), maxLines = 1)
                    }
                }
                if (contextPercent != null) {
                    StatPill {
                        ContextRing(percent = contextPercent)
                        BasicText(text = "$contextPercent%", style = type.secondary.copy(color = tokens.colors.tertiary), maxLines = 1)
                    }
                }
            }
        }
    }
}

private enum class ComposerMetricDetail { ACTIVITY, USAGE, CONTEXT }

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
private fun ComposerMetrics(
    mode: ComposerStatsMode,
    stats: SessionStats?,
    usage: SessionTokenUsage?,
    pressure: ContextPressure?,
    breakdown: ContextBreakdown?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val pillStyle = type.secondary.copy(
        fontSize = 11.sp,
        fontFeatureSettings = "tnum",
        color = tokens.colors.tertiary,
    )
    var detail by remember { mutableStateOf<ComposerMetricDetail?>(null) }
    val detailSheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val closeDetail: () -> Unit = {
        detail = null
        scope.launch {
            detailSheetState.hide()
        }
    }
    val speed = stats?.tokensPerSecond?.takeIf(Double::isFinite)
    val cacheHit = usage?.cacheHitPercent
    if (mode == ComposerStatsMode.COMPACT) {
        StatPill(modifier = Modifier.testTag("pdsh.composer.metrics.compact"), contentSpacing = 8.dp) {
            if (speed != null) {
                PdshIconView(PdshIcon.GAUGE, 14.dp, tokens.colors.tertiary, null)
                BasicText("${speed.roundToInt()} tok/s", style = pillStyle, maxLines = 1)
            }
            if (cacheHit != null) {
                PdshIconView(PdshIcon.DATABASE, 14.dp, tokens.colors.tertiary, null)
                BasicText("缓存命中 ${formatMetricPercent(cacheHit)}%", style = pillStyle, maxLines = 1)
            }
        }
    } else {
        if (stats != null && (stats.steps > 0 || speed != null)) {
            StatPill(
                modifier = Modifier.testTag("pdsh.composer.metrics.activity"),
                onClick = { detail = ComposerMetricDetail.ACTIVITY },
            ) {
                PdshIconView(PdshIcon.GAUGE, 14.dp, tokens.colors.tertiary, null)
                if (stats.steps > 0) BasicText("${stats.turns} 轮 ${stats.steps} 步", style = pillStyle, maxLines = 1)
                if (speed != null) BasicText((if (stats.steps > 0) "· " else "") + "${speed.roundToInt()} tok/s", style = pillStyle, maxLines = 1)
            }
        }
        if (usage != null && (usage.billedInputTokens > 0 || usage.outputTokens > 0)) {
            StatPill(
                modifier = Modifier.testTag("pdsh.composer.metrics.usage"),
                onClick = { detail = ComposerMetricDetail.USAGE },
            ) {
                PdshIconView(PdshIcon.DATABASE, 14.dp, tokens.colors.tertiary, null)
                BasicText("${compactMetricTokens(usage.totalTokens)} tok", style = pillStyle, maxLines = 1)
                if (cacheHit != null) BasicText("· 缓存命中 ${formatMetricPercent(cacheHit)}%", style = pillStyle, maxLines = 1)
            }
        }
        val percent = pressure?.percent
        if (percent != null) {
            StatPill(
                modifier = Modifier.testTag("pdsh.composer.metrics.context"),
                onClick = { detail = ComposerMetricDetail.CONTEXT },
            ) {
                ContextRing(percent)
                BasicText("$percent%", style = pillStyle, maxLines = 1)
            }
        }
    }
    val selected = detail ?: return
    val title = when (selected) {
        ComposerMetricDetail.ACTIVITY -> "会话统计"
        ComposerMetricDetail.USAGE -> "Token 用量"
        ComposerMetricDetail.CONTEXT -> "上下文"
    }
    val detailRows = buildList {
        when (selected) {
            ComposerMetricDetail.ACTIVITY -> stats?.let {
                add("轮 / 步" to "${it.turns} / ${it.steps}")
                if (it.llmMs > 0) add("模型用时" to formatMetricDuration(it.llmMs))
                if (it.toolMs > 0) add("工具调用用时" to formatMetricDuration(it.toolMs))
                if (it.ttftSteps > 0) add("首 token 平均（TTFT）" to formatMetricDuration(it.ttftMs / it.ttftSteps))
                speed?.let { rate -> add("输出速度（TPS）" to "${rate.roundToInt()} tok/s") }
            }
            ComposerMetricDetail.USAGE -> usage?.let {
                cacheHit?.let { hit -> add("缓存命中" to "${formatMetricPercent(hit)}%") }
                add("未缓存输入" to "${it.uncachedInputTokens} tok")
                add("缓存读取" to "${it.cacheReadTokens} tok")
                if (it.cacheWriteTokens > 0) add("缓存写入" to "${it.cacheWriteTokens} tok")
                add("输出" to "${it.outputTokens} tok")
                add("合计" to "${it.totalTokens} tok")
            }
            ComposerMetricDetail.CONTEXT -> {
                if (pressure != null) {
                    pressure.usedTokens?.let { used ->
                        add("上下文已用" to "${pressure.percent ?: 0}%")
                        add("估算用量 / 容量" to "~${compactMetricTokens(used)} / ${compactMetricTokens(pressure.contextWindow)}")
                    }
                }
                breakdown?.let {
                    add("系统提示" to "~${compactMetricTokens(it.systemTokens)}")
                    add("工具" to "~${compactMetricTokens(it.toolsTokens)}")
                    add("对话" to "~${compactMetricTokens(it.messageTokens)}")
                }
            }
        }
    }
    val sheetPalette = materialSheetColors(tokens)
    androidx.compose.material3.ModalBottomSheet(
        sheetState = detailSheetState,
        onDismissRequest = { detail = null },
        containerColor = sheetPalette.container,
        contentColor = sheetPalette.content,
    ) {
        com.phonedsh.ui.surface.SettingsSubPageFrame(
            modifier = Modifier.fillMaxWidth().height((LocalConfiguration.current.screenHeightDp * 0.5f).dp),
            title = title,
            grouped = true,
            trailing = {
                com.phonedsh.ui.surface.SettingsNavAction(
                    text = "完成",
                    onClick = closeDetail,
                    tag = "pdsh.composer.metrics.done",
                    description = "完成",
                )
            },
        ) {
            androidx.compose.foundation.layout.Column(
                modifier = Modifier.fillMaxSize().verticalScroll(androidx.compose.foundation.rememberScrollState())
                    .padding(top = 16.dp, bottom = 24.dp),
            ) {
                com.phonedsh.ui.surface.SettingsGroupCard {
                    detailRows.forEachIndexed { index, row ->
                        com.phonedsh.ui.surface.SettingsGroupedRow(
                            title = row.first,
                            value = row.second,
                            dividerBelow = index != detailRows.lastIndex,
                        )
                    }
                }
            }
        }
    }
}

private fun compactMetricTokens(value: Long): String = when {
    value < 1_000 -> value.toString()
    value < 1_000_000 -> scaledMetric(value / 1_000.0) + "K"
    else -> scaledMetric(value / 1_000_000.0) + "M"
}

private fun scaledMetric(value: Double): String = if (value >= 100) value.roundToInt().toString() else (value * 10).roundToInt().div(10.0).toString()
private fun formatMetricPercent(value: Double): String = if (value >= 10) value.roundToInt().toString() else (value * 10).roundToInt().div(10.0).toString()
private fun formatMetricDuration(milliseconds: Double): String {
    val seconds = milliseconds / 1_000.0
    return if (seconds < 60) "${(seconds * 10).roundToInt() / 10.0}秒" else {
        val whole = seconds.roundToInt()
        "${whole / 60}分${whole % 60}秒"
    }
}

/** The 36pt source circle is trailing-aligned inside a 44pt Android tap target. */
@Composable
private fun SendKey(
    enabled: Boolean,
    label: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .size(ChatMetrics.SEND_HIT_PT.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .testTag(UiTags.COMPOSER_SEND)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.CenterEnd,
    ) {
        Box(
            modifier = Modifier.size(tokens.geometry.sendButtonDiameter)
                .clip(CircleShape)
                .background(if (enabled) tokens.colors.primaryButton else tokens.colors.userBubble)
                .testTag(COMPOSER_SEND_CIRCLE_TAG),
            contentAlignment = Alignment.Center,
        ) {
            PdshIconView(
                icon = PdshIcon.SEND,
                size = ChatMetrics.SEND_GLYPH_PT.dp,
                tint = if (enabled) tokens.colors.primaryButtonInk else tokens.colors.iconMuted,
                contentDescription = null,
            )
        }
    }
}

/** Same trailing-aligned source circle; adjacent targets leave an 8pt visual gap. */
@Composable
private fun StopKey(
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .size(ChatMetrics.SEND_HIT_PT.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .testTag(UiTags.COMPOSER_STOP)
            .semantics { contentDescription = UiStrings.COMPOSER_STOP_LABEL },
        contentAlignment = Alignment.CenterEnd,
    ) {
        Box(
            modifier = Modifier.size(tokens.geometry.sendButtonDiameter)
                .clip(CircleShape)
                .background(tokens.colors.primaryButton)
                .testTag(COMPOSER_STOP_CIRCLE_TAG),
            contentAlignment = Alignment.Center,
        ) {
            androidx.compose.foundation.Canvas(Modifier.size(ChatMetrics.STOP_GLYPH_PT.dp)) {
                drawRoundRect(
                    color = tokens.colors.primaryButtonInk,
                    size = androidx.compose.ui.geometry.Size(size.width, size.height),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(ChatMetrics.STOP_GLYPH_RADIUS_PT.dp.toPx()),
                )
            }
        }
    }
}

/**
 * One stat pill: a 20 pt-tall, tertiary-ink line with a 2 pt horizontal pad.
 *
 * A detail-bearing pill owns its click target here, outside the caller's
 * semantics and before the token-driven text box, with the platform's 48 dp
 * minimum: the hit node then wraps the drawn label instead of being reported
 * above it, and the text stays centred inside it. Pills without a destination
 * keep the 20 pt line so the stats row's compact form is unchanged.
 */
@Composable
private fun StatPill(
    modifier: Modifier = Modifier,
    contentSpacing: androidx.compose.ui.unit.Dp = 6.dp,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val touchTarget = if (onClick != null) {
        // The platform's 48 dp minimum, owned by the outermost node so the
        // bounds reported to accessibility include the padding and the drawn
        // label. `sizeIn` keeps the pill's token-driven type and colours intact.
        Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
    } else {
        Modifier
    }
    Row(
        modifier = touchTarget
            .then(modifier)
            .then(
                if (onClick != null) {
                    Modifier.clickable(role = Role.Button, onClick = onClick)
                } else {
                    Modifier
                },
            )
            .heightIn(min = tokens.geometry.statPillMinHeight)
            .padding(horizontal = 2.dp, vertical = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(contentSpacing),
    ) {
        content()
    }
}

/** The context-window ring (iOS `NativeContextRing`): a trimmed 2 pt stroke. */
@Composable
private fun ContextRing(percent: Int) {
    val tokens = LocalUiTokens.current
    val size = 14.dp
    androidx.compose.foundation.Canvas(modifier = Modifier.size(size)) {
        val stroke = tokens.stroke.hairline.value * 2f
        val radius = (this.size.minDimension - stroke) / 2f
        drawCircle(
            color = tokens.colors.borderLight,
            radius = radius,
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        drawArc(
            color = tokens.colors.tertiary,
            startAngle = -90f,
            sweepAngle = 360f * (percent.coerceIn(0, 100) / 100f),
            useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(radius * 2f, radius * 2f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
    }
}

/** The draft cap the field enforces (iOS `value.count > 8_000`, extended graphemes). */
private const val MAX_DRAFT_GRAPHEMES: Int = 8_000

internal data class ComposerDraftLimitResult(
    val value: TextFieldValue,
    val truncated: Boolean,
)

/** Applies the native extended-grapheme cap without disturbing valid under-cap edits. */
internal fun enforceComposerDraftLimit(
    value: TextFieldValue,
    maxGraphemes: Int = MAX_DRAFT_GRAPHEMES,
): ComposerDraftLimitResult {
    require(maxGraphemes >= 0)
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(value.text)
    var boundary = iterator.first()
    var clusters = 0
    while (clusters < maxGraphemes) {
        val next = iterator.next()
        if (next == BreakIterator.DONE) return ComposerDraftLimitResult(value, truncated = false)
        boundary = next
        clusters++
    }
    if (iterator.next() == BreakIterator.DONE) return ComposerDraftLimitResult(value, truncated = false)
    val clipped = value.text.substring(0, boundary)
    return ComposerDraftLimitResult(
        value = value.copy(text = clipped, selection = TextRange(clipped.length), composition = null),
        truncated = true,
    )
}
private const val COMPOSER_CARD_TAG: String = "pdsh.composer.card"

/** Tag for the 36pt painted send circle inside its 44pt tap target. */
private const val COMPOSER_SEND_CIRCLE_TAG: String = "pdsh.composer.send-circle"
private const val COMPOSER_STOP_CIRCLE_TAG: String = "pdsh.composer.stop-circle"

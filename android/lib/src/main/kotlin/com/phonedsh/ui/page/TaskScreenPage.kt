// The task-screen preview: its status line, the dimming level and the report.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row TaskScreenPage (任务屏预览; entry: 设置 →
// 探针工具（仅 DEBUG）; exit: push; P5 `later`), §3.1 (the ScreenState layer: the
// status line and the brightness are local events, exactly like a composer
// draft) and §5 (`insets`).
//
// This is a line-for-line port of the iOS baseline's `TaskScreenPage.swift`:
//
//   Task screen  the description, the Status line field, the
//                "Minimum brightness: 0.00" label with its 0…0.5 Slider, and the
//                prominent Show black task screen action
//   Report       presented, the minimum brightness the host applied, and the
//                best-effort footnote
//
// The brightness Slider is the baseline's `Slider(value:in: 0...0.5)` and is a
// standard Material 3 `Slider` here. Its half-point upper bound is the baseline
// range, kept as one named constant because it is an input domain, not a
// layout length.
//
// Two decisions this page records rather than hides:
//
//  1. The status line and the brightness are local drafts and the only local UI
//     events of the page; `TaskScreenLocalState` is a pure value and `apply` a
//     pure reducer, so the draft sequence is replayable in a JVM test (§3.1
//     rule 2: a value that reflects local input is ScreenState, not UiState).
//  2. The black low-brightness screen itself is not drawn here. `:lib` has no
//     token for pure black (`colors.background` is unmeasured by design) and
//     cannot change the window brightness, so the screen is a platform surface:
//     the page hands the host the status line and the selected brightness
//     through `onShowTaskScreen` and reports the host's `presented` fact. The
//     page never invents a black fill or a brightness value.
//
// The brightness is read as a measured number and rendered with locale-free
// integer arithmetic (two decimals); a value the host did not measure is 未知,
// never 0 and never 未显示.
//
// ScreenState: `TaskScreenScreenState.from(facts, local)` is pure; the page reads
// no clock, no window and no screen brightness.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import kotlin.math.round

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The host's read-only task-screen snapshot.
 *
 * @param statusLine the status line the host currently shows.
 * @param presented whether the task screen is up right now.
 * @param minimumBrightness the brightness the host applied; `null` when the
 *   platform read failed (the host reports it, the page never reads the screen).
 * @param lastError the host's last presentation error.
 */
@Immutable
public data class TaskScreenSnapshot(
    public val statusLine: String? = null,
    public val presented: FactState = FactState.UNKNOWN,
    public val minimumBrightness: Double? = null,
    public val lastError: String? = null,
) {
    /** True when the host measured at least one fact of this page. */
    internal val hasMeasurement: Boolean
        get() = statusLine != null || presented != FactState.UNKNOWN ||
            minimumBrightness != null || lastError != null
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null renders the fail-loud line.
 */
@Immutable
public data class TaskScreenFacts(
    public val snapshot: TaskScreenSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class TaskScreenStatus {
    /** The host reported at least one measured fact. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last read failed. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never 未显示. */
    UNKNOWN,
}

/**
 * The complete task-screen state.
 *
 * @param status the four-state outcome; a failed read wins.
 * @param statusLine the effective line: the local draft, else the host's line,
 *   else the page's default (a placeholder, not a measurement).
 * @param brightness the Slider's value: the local draft, else the baseline's
 *   0.00 default. It is a control value, never a measured fact.
 * @param presented whether the task screen is up.
 * @param reportedBrightness the brightness the host applied, `null` when
 *   unmeasured.
 * @param lastError the host's last presentation error.
 * @param failure the read failure, `null` unless FAILED.
 */
@Immutable
public data class TaskScreenScreenState(
    public val status: TaskScreenStatus,
    public val statusLine: String,
    public val brightness: Double,
    public val presented: FactState,
    public val reportedBrightness: Double?,
    public val lastError: String?,
    public val failure: String?,
) {
    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == TaskScreenStatus.EMPTY

    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == TaskScreenStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == TaskScreenStatus.FAILED

    /** True when at least one rendered value is 未知 inside a measured report. */
    public val hasUnmeasuredValues: Boolean
        get() = status == TaskScreenStatus.READY &&
            (presented == FactState.UNKNOWN || reportedBrightness == null)

    /**
     * A display-free signature of the sequence-relevant state.
     *
     * The status line and the brightness are part of the signature because both
     * are this page's local events: two drafts must produce different states.
     */
    public fun signature(): String = buildString {
        append(status.name).append('|').append(presented.name)
        append("|line=").append(statusLine)
        append("|brightness=").append(brightness)
        append("|reported=").append(reportedBrightness)
        if (lastError != null) append("|error")
        if (failure != null) append("|failure")
    }

    public companion object {
        /** The baseline's `in: 0...0.5` upper bound for the dimming control. */
        public const val MAX_MINIMUM_BRIGHTNESS: Double = 0.5

        /**
         * Projects (facts, local drafts) into the screen state.
         *
         * Pure: no clock, no brightness read and no window. The host owns the
         * screen, so the same facts and the same drafts always yield the same
         * state sequence (§3.1).
         */
        public fun from(
            facts: TaskScreenFacts,
            local: TaskScreenLocalState = TaskScreenLocalState(),
        ): TaskScreenScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure
            val status = when {
                failure != null -> TaskScreenStatus.FAILED
                snapshot == null -> TaskScreenStatus.UNKNOWN
                !snapshot.hasMeasurement -> TaskScreenStatus.EMPTY
                else -> TaskScreenStatus.READY
            }
            val measured = snapshot.takeIf { status == TaskScreenStatus.READY }
            return TaskScreenScreenState(
                status = status,
                statusLine = local.statusDraft
                    ?: measured?.statusLine
                    ?: UiStrings.TASK_SCREEN_DEFAULT_STATUS,
                // The baseline initialises its local `minimumBrightness` to 0.0;
                // that is a control default, not a measurement.
                brightness = local.brightnessDraft ?: 0.0,
                presented = measured?.presented ?: FactState.UNKNOWN,
                reportedBrightness = measured?.minimumBrightness,
                lastError = measured?.lastError?.takeUnless { it.isBlank() },
                failure = failure,
            )
        }
    }
}

/** The local UI events of the task-screen page: the line and the brightness. */
public sealed interface TaskScreenUiEvent {
    /** Replace the draft status line with the field's new text. */
    public data class EditStatusLine(public val text: String) : TaskScreenUiEvent

    /** Replace the draft brightness with the Slider's new value. */
    public data class EditMinimumBrightness(public val value: Double) : TaskScreenUiEvent
}

/**
 * The draft script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param statusDraft the local line; `null` means the host's line is shown.
 * @param brightnessDraft the local Slider value; `null` means 0.00.
 */
@Immutable
public data class TaskScreenLocalState(
    public val statusDraft: String? = null,
    public val brightnessDraft: Double? = null,
) {
    /** Applies one local event. */
    public fun apply(event: TaskScreenUiEvent): TaskScreenLocalState = when (event) {
        is TaskScreenUiEvent.EditStatusLine -> copy(statusDraft = event.text)
        is TaskScreenUiEvent.EditMinimumBrightness -> copy(brightnessDraft = event.value)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The task-screen preview page.
 *
 * @param state the pure screen state (`TaskScreenScreenState.from`).
 * @param onBack leave the page (push, per §1).
 * @param onShowTaskScreen hand the status line and brightness to the host (the
 *   baseline's `model.store.noteTaskScreenPresented`, `TaskScreenPage.swift:83`).
 *   The black surface itself is the page's, not the host's: iOS presents it from
 *   its own `@State presenting` as a `.fullScreenCover` (`:65`–`:84`), so the page
 *   draws it here too and this callback only reports what was shown.
 * @param onStatusLineChange the field's new text; the host applies
 *   `TaskScreenUiEvent.EditStatusLine` and re-projects.
 * @param onBrightnessChange the Slider's new value; the host applies
 *   `TaskScreenUiEvent.EditMinimumBrightness` and re-projects.
 * @param modifier the caller's modifier.
 * @param onRetry retry the host read; `null` hides the retry.
 * @param onDismissFailure dismiss the failure line; `null` hides it.
 */
@Composable
public fun TaskScreenPage(
    state: TaskScreenScreenState,
    onBack: () -> Unit,
    onShowTaskScreen: (String, Double) -> Unit,
    onStatusLineChange: (String) -> Unit,
    onBrightnessChange: (Double) -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    // The screen's own presentation state, exactly like the baseline's
    // `@State private var presenting` (`TaskScreenPage.swift:15`): the cover is a
    // local surface, not a route and not a host fact.
    var presenting by rememberSaveable { mutableStateOf(false) }
    Box(modifier = modifier.fillMaxSize()) {
        PageFrame(
            title = UiStrings.TASK_SCREEN_TITLE,
            onBack = onBack,
            rootTag = UiPageTags.TASK_SCREEN_ROOT,
        ) {
            ProbeControlsTheme {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.TASK_SCREEN_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    state.failure?.let { failure ->
                        item(key = "task.failure") {
                            SessionFailureLine(
                                message = failure,
                                tag = UiPageTags.TASK_SCREEN_FAILURE,
                                retryLabel = if (onRetry != null) UiStrings.RETRY else null,
                                onRetry = onRetry,
                                onDismiss = onDismissFailure,
                            )
                        }
                    }
                    formBlock(
                        state = state,
                        onShow = {
                            // Two effects, both the baseline's: present the cover, and
                            // tell the host what was presented.
                            presenting = true
                            onShowTaskScreen(state.statusLine, state.brightness)
                        },
                        onStatusLineChange = onStatusLineChange,
                        onBrightnessChange = onBrightnessChange,
                    )
                    reportBlock(state)
                }
            }
        }
        if (presenting) {
            TaskScreenCover(
                statusLine = state.statusLine,
                onClose = { presenting = false },
            )
        }
    }
}

/**
 * The landed black screen (`TaskScreenPage.swift:65`–`:84`): pure black, the status
 * line, and the ✕ that closes it.
 *
 * iOS mounts `PhoneDSH.Background.TaskScreen` with `dimsScreen: true`, which also
 * lowers `UIScreen.main.brightness`. `:lib` has no window: a page composable cannot
 * set the system brightness, so that one half is the host's and the page says so
 * (see the lane receipt) instead of pretending to dim. What the page *can* do — and
 * therefore does — is everything visible: the black surface, the status line and
 * the close control, so the button is not a dead tap.
 *
 * @param statusLine the line the baseline passes as `TaskScreenConfiguration.status`.
 * @param onClose the ✕ (`Image(systemName: "xmark.circle.fill")`, `:77`).
 */
@Composable
private fun TaskScreenCover(statusLine: String, onClose: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.TASK_SCREEN_ROOT + ".presented")
            .background(tokens.colors.taskScreen)
            .semantics { contentDescription = UiStrings.TASK_SCREEN_PRESENTED },
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .fillMaxWidth()
                .padding(TASK_SCREEN_CONTENT_INSET.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(TASK_SCREEN_CONTENT_GAP.dp),
        ) {
            // The baseline passes all three values to TaskScreen. The Android
            // cover previously omitted its title and hint and dismissed when
            // any part of the black surface was tapped.
            BasicText(
                text = TASK_SCREEN_COVER_TITLE,
                style = type.headline.copy(color = Color.White.copy(alpha = 0.55f)),
            )
            BasicText(
                text = statusLine,
                style = type.caption.copy(
                    fontSize = TASK_SCREEN_STATUS_SIZE.sp,
                    color = Color.White.copy(alpha = 0.38f),
                    textAlign = TextAlign.Center,
                ),
            )
            BasicText(
                text = TASK_SCREEN_COVER_HINT,
                style = type.caption.copy(
                    fontSize = TASK_SCREEN_HINT_SIZE.sp,
                    color = Color.White.copy(alpha = 0.28f),
                    textAlign = TextAlign.Center,
                ),
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(TASK_SCREEN_CLOSE_INSET.dp)
                .sizeIn(minWidth = TASK_SCREEN_CLOSE_TARGET.dp, minHeight = TASK_SCREEN_CLOSE_TARGET.dp)
                .clickable(role = Role.Button, onClick = onClose)
                .semantics { contentDescription = UiStrings.TASK_SCREEN_CLOSE },
            contentAlignment = Alignment.Center,
        ) {
            TaskScreenCloseGlyph()
        }
    }
}

/** A small vector rendition of iOS `xmark.circle.fill`. */
@Composable
private fun TaskScreenCloseGlyph() {
    Canvas(Modifier.size(TASK_SCREEN_CLOSE_GLYPH.dp)) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val ink = Color.White.copy(alpha = 0.35f)
        drawCircle(color = ink, radius = size.minDimension / 2f, center = center)
        val inset = size.minDimension * 0.34f
        val cross = Color.Black.copy(alpha = 0.7f)
        drawLine(
            color = cross,
            start = Offset(inset, inset),
            end = Offset(size.width - inset, size.height - inset),
            strokeWidth = size.minDimension * 0.09f,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = cross,
            start = Offset(size.width - inset, inset),
            end = Offset(inset, size.height - inset),
            strokeWidth = size.minDimension * 0.09f,
            cap = StrokeCap.Round,
        )
    }
}

private const val TASK_SCREEN_COVER_TITLE: String = "phone DSH probe"
private const val TASK_SCREEN_COVER_HINT: String =
    "Screen dimmed for long tasks. The phone can still lock manually."
private const val TASK_SCREEN_STATUS_SIZE: Int = 13
private const val TASK_SCREEN_HINT_SIZE: Int = 11
private const val TASK_SCREEN_CONTENT_INSET: Int = 28
private const val TASK_SCREEN_CONTENT_GAP: Int = 14
private const val TASK_SCREEN_CLOSE_INSET: Int = 16
private const val TASK_SCREEN_CLOSE_TARGET: Int = 44
private const val TASK_SCREEN_CLOSE_GLYPH: Int = 22

/** The description, the status line, the brightness Slider and the show action. */
private fun LazyListScope.formBlock(
    state: TaskScreenScreenState,
    onShow: () -> Unit,
    onStatusLineChange: (String) -> Unit,
    onBrightnessChange: (Double) -> Unit,
) {
    item(key = "task.section") {
        SessionSectionLabel(
            text = UiStrings.TASK_SCREEN_SECTION_EN,
            modifier = Modifier.testTag(UiPageTags.TASK_SCREEN_DESCRIPTION),
        )
    }
    item(key = "task.description") {
        ProbeNote(
            text = UiStrings.TASK_SCREEN_DESCRIPTION,
            ink = ProbeInk.SECONDARY,
            modifier = Modifier.padding(
                horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
            ),
        )
    }
    item(key = "task.status") {
        StatusLineField(value = state.statusLine, onValueChange = onStatusLineChange)
    }
    item(key = "task.brightness.control") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            Text(
                text = UiStrings.TASK_SCREEN_BRIGHTNESS_LABEL.format(
                    brightnessText(state.brightness),
                ),
                style = type.caption.copy(color = tokens.colors.primary),
            )
            Slider(
                value = state.brightness.toFloat().coerceIn(
                    0f,
                    TaskScreenScreenState.MAX_MINIMUM_BRIGHTNESS.toFloat(),
                ),
                onValueChange = { value -> onBrightnessChange(value.toDouble()) },
                valueRange = 0f..TaskScreenScreenState.MAX_MINIMUM_BRIGHTNESS.toFloat(),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.TASK_SCREEN_SLIDER),
            )
        }
    }
    item(key = "task.show") {
        Button(
            onClick = onShow,
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                    vertical = LocalUiTokens.current.spacing.badgeInsetV,
                )
                .testTag(UiPageTags.TASK_SCREEN_SHOW),
        ) {
            Text(
                text = UiStrings.TASK_SCREEN_ACTION_SHOW_EN,
                style = LocalUiType.current.secondary,
            )
        }
    }
}

/** What the host measured: whether the screen is up and at which brightness. */
private fun LazyListScope.reportBlock(state: TaskScreenScreenState) {
    item(key = "task.report.label") {
        SessionSectionLabel(
            text = UiStrings.TASK_SCREEN_SECTION_REPORT_EN,
            modifier = Modifier.testTag(UiPageTags.TASK_SCREEN_REPORT),
        )
    }
    item(key = "task.presented") {
        InfoRow(
            title = UiStrings.TASK_SCREEN_PRESENTED_LABEL,
            value = when (state.presented) {
                FactState.YES -> UiStrings.TASK_SCREEN_PRESENTED
                FactState.NO -> UiStrings.TASK_SCREEN_NOT_PRESENTED
                FactState.UNKNOWN -> UiStrings.UNKNOWN
            },
            tone = if (state.presented == FactState.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            modifier = Modifier.testTag(UiPageTags.TASK_SCREEN_PRESENTED),
        )
    }
    item(key = "task.brightness") {
        InfoRow(
            title = UiStrings.TASK_SCREEN_BRIGHTNESS,
            value = brightnessText(state.reportedBrightness),
            subtitle = UiStrings.TASK_SCREEN_BRIGHTNESS_HINT,
            tone = if (state.reportedBrightness == null) PageTone.UNKNOWN else PageTone.NORMAL,
            modifier = Modifier.testTag(UiPageTags.TASK_SCREEN_BRIGHTNESS),
        )
    }
    state.lastError?.let { error ->
        item(key = "task.last.error") {
            ProbeNote(
                text = error,
                ink = ProbeInk.DANGER,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.TASK_SCREEN_FAILURE),
            )
        }
    }
}

/**
 * The status-line field: a composer-like draft, so the field only renders the
 * state and reports edits (it keeps no copy that could drift from the sequence).
 */
@Composable
private fun StatusLineField(value: String, onValueChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = type.body.copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        modifier = Modifier
            .fillMaxWidth()
            // Page-level geometry: the field is a page row, so its margin and its
            // floor are the page's own values, not a signature surface's.
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .testTag(UiPageTags.TASK_SCREEN_STATUS_FIELD)
            .semantics { contentDescription = UiStrings.TASK_SCREEN_STATUS_LINE },
        decorationBox = { inner ->
            if (value.isEmpty()) {
                BasicText(
                    text = UiStrings.TASK_SCREEN_STATUS_PLACEHOLDER,
                    style = type.body.copy(color = tokens.colors.tertiary),
                )
            }
            inner()
        },
    )
}

/**
 * The measured brightness with two decimals, or 未知.
 *
 * Locale-free integer arithmetic: a locale-formatted decimal would change the
 * separator, and the rendered string is a measured value the sequence tests
 * compare.
 */
private fun brightnessText(value: Double?): String {
    if (value == null) return UiStrings.UNKNOWN
    val hundredths = round(value * 100.0).toLong()
    val fraction = (hundredths % 100).toString().padStart(2, '0')
    return "${hundredths / 100}.$fraction"
}

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object TaskScreenPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.primary",
        "colors.tertiary",
        // L75: the presented black cover.
        "colors.taskScreen",
        "geometry.pageOuterMarginH",
        "geometry.pageRowMinHeight",
        "spacing.badgeInsetV",
        "typography.body",
        "typography.caption",
        // The presented cover's ✕ (headline ink) and its status line (secondary).
        "typography.headline",
        "typography.secondary",
    )
}

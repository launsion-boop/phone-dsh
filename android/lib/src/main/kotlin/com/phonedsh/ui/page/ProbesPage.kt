// Device probes and their G0 report.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row ProbesPage (设备探针与报告; entry: 设置 →
// 探针工具（仅 DEBUG）; exit: push; P5 `later`), §3.1 rule 3 (a page with no
// harness event anchor projects the host's read-only snapshot) and §5 (`insets`).
//
// This is a line-for-line port of the iOS baseline's `ProbesPage.swift`, not a
// reconstruction from §1:
//
//   Environment section  Environment / OS / Bundle + the suite note
//   LockdownBadge        the system Lockdown flag, never a guess
//   actions              Run all probes (prominent), Run one group (a menu whose
//                        entries are the probe groups), the in-flight spinner,
//                        the host status line and the G0-failed line
//   Rows                 "Rows (N)" with PASS/FAIL/INFO, G0 and one block per row;
//                        "Rows" with the empty copy when no probe has run
//   G0 thresholds        the bound table, one block per bound
//
// The two controls the baseline draws are standard controls here too: the run
// actions are a `Button` plus a Material 3 `DropdownMenu`, and the row status is
// a `ProbeStatusChip`. They do not invent a page-local component: a standard
// platform control with one call site is still the platform's control.
//
// The row statuses are a projection of the host's probe report, never a second
// measurement: the page reads no clock, no process info and no device signal. A
// probe that did not run has no row; a value the host did not measure renders
// 未知 (or the baseline's em dash for a null metric), never 0.
//
// ScreenState: `ProbesScreenState.from(facts)` is the whole projection. The page
// owns no local UI event beyond the menu's open/closed state and the scroll
// position, so `ProbesPageTest` drives a script of host snapshots.
//
// Geometry: the shared `PageFrame`, `InfoRow` and section label own most
// lengths. The blocks below read the declared tokens this file lists in
// `ProbesPageTokens`; the badge margins reuse `spacing.badgeInsetH` /
// `spacing.badgeInsetV`, and the 2×2 visible anchor reuses
// `geometry.summaryDotDiameter` (unverified geometry: the baseline's 2 pt anchor
// has no page-level token, so the thinking pill's 2 pt dot is the nearest
// declared value).
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One measured value of a probe row.
 *
 * @param name the metric's key, shown as the row label.
 * @param value the host's display text; `null` when the metric was not measured.
 */
@Immutable
public data class ProbeMetric(
    public val name: String,
    public val value: String? = null,
)

/**
 * The G0 bound a probe row was compared against (`PLAN §2.5`,
 * `spec/v1/budgets.md` §4 per the baseline copy).
 *
 * @param name the bound's name.
 * @param comparison the host's comparison operator text, for example `<=`.
 * @param bound the numeric bound as the host formatted it.
 * @param unit the unit the bound is expressed in.
 * @param met whether the measurement met the bound; `null` when not compared.
 * @param gating whether the bound gates G0.
 * @param source the declaration the bound comes from.
 */
@Immutable
public data class ProbeThreshold(
    public val name: String,
    public val comparison: String? = null,
    public val bound: String? = null,
    public val unit: String? = null,
    public val met: Boolean? = null,
    public val gating: Boolean? = null,
    public val source: String? = null,
)

/** The outcome a probe row reports; `UNKNOWN` is a row the host could not grade. */
public enum class ProbeStatus {
    PASS,
    FAIL,
    INFO,
    UNKNOWN,
}

/**
 * One probe row: the probe's name, its status, its metrics and its bound.
 *
 * @param id a stable row id (the probe's name is not guaranteed unique).
 * @param probe the probe's display name.
 * @param status the measured outcome.
 * @param metrics the measured values, in the host's order.
 * @param threshold the bound this row was compared against; `null` when none.
 * @param gating whether the row counts towards G0; `null` when unstated.
 * @param detail the host's explanatory line; `null` when absent.
 * @param environment the environment the row was recorded in.
 * @param recordedAt the host-formatted record time; the page never reads a clock.
 */
@Immutable
public data class ProbeRow(
    public val id: String,
    public val probe: String,
    public val status: ProbeStatus = ProbeStatus.UNKNOWN,
    public val metrics: List<ProbeMetric> = emptyList(),
    public val threshold: ProbeThreshold? = null,
    public val gating: Boolean? = null,
    public val detail: String? = null,
    public val environment: String? = null,
    public val recordedAt: String? = null,
)

/**
 * The run's summary; every field is nullable because a partial report is a real
 * host answer and the page must not turn a missing count into 0.
 */
@Immutable
public data class ProbeSummary(
    public val passed: Int? = null,
    public val failed: Int? = null,
    public val info: Int? = null,
    public val g0Passed: Boolean? = null,
    public val failedGatingProbes: List<String> = emptyList(),
)

/** One group the operator may run on its own (the baseline's group menu). */
@Immutable
public data class ProbeGroup(
    public val id: String,
    public val title: String,
)

/**
 * The host's read-only probe snapshot.
 *
 * @param environment the running environment identifier.
 * @param os the host-formatted OS version.
 * @param bundle the app identifier, or `null` when the host has none.
 * @param running whether a run is in flight; `null` when unreported.
 * @param statusText the host's own run line (for example 已运行 12 项).
 * @param summary the run summary; `null` when the host reported no summary.
 * @param rows the probe rows; `null` means the host reported no row list at all.
 * @param groups the groups the operator may run; empty when the host offers none.
 * @param thresholds the G0 bound table; `null` when the host did not report it.
 * @param lockdown the system Lockdown flag; [FactState.UNKNOWN] when unread.
 */
@Immutable
public data class ProbesSnapshot(
    public val environment: String? = null,
    public val os: String? = null,
    public val bundle: String? = null,
    public val running: Boolean? = null,
    public val statusText: String? = null,
    public val summary: ProbeSummary? = null,
    public val rows: List<ProbeRow>? = null,
    public val groups: List<ProbeGroup> = emptyList(),
    public val thresholds: List<ProbeThreshold>? = null,
    public val lockdown: FactState = FactState.UNKNOWN,
) {
    /** True when the host measured at least one fact of this page. */
    internal val hasMeasurement: Boolean
        get() = environment != null || os != null || bundle != null ||
            running != null || statusText != null || summary != null ||
            rows != null || thresholds != null || groups.isNotEmpty() ||
            lockdown != FactState.UNKNOWN
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null renders the fail-loud line.
 */
@Immutable
public data class ProbesFacts(
    public val snapshot: ProbesSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class ProbesStatus {
    /** The host reported at least one measured fact. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last host read failed. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never 0 rows. */
    UNKNOWN,
}

/**
 * The complete probes screen state.
 *
 * All values are projected from the host snapshot; a missing value stays `null`
 * (rendered 未知) and is never replaced by a zero.
 */
@Immutable
public data class ProbesScreenState(
    public val status: ProbesStatus,
    public val environment: String?,
    public val os: String?,
    public val bundle: String?,
    public val running: Boolean,
    public val statusText: String?,
    public val summary: ProbeSummary?,
    public val rows: List<ProbeRow>,
    public val groups: List<ProbeGroup>,
    public val thresholds: List<ProbeThreshold>,
    public val lockdown: FactState,
    public val failure: String?,
) {
    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == ProbesStatus.EMPTY

    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == ProbesStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == ProbesStatus.FAILED

    /** True when at least one rendered value is 未知 inside a measured report. */
    public val hasUnmeasuredValues: Boolean
        get() = status == ProbesStatus.READY && (
            environment == null || os == null || bundle == null ||
                summary == null || summary.passed == null || summary.failed == null ||
                summary.info == null || summary.g0Passed == null ||
                lockdown == FactState.UNKNOWN ||
                rows.any { row ->
                    row.environment == null || row.recordedAt == null ||
                        row.metrics.any { it.value == null } ||
                        (row.threshold != null && row.threshold.bound == null)
                }
            )

    /**
     * A display-free signature of the sequence-relevant state.
     *
     * The row ids and statuses are included, the visible values are not, so an
     * A/B replay compares the state shape without depending on host copy.
     */
    public fun signature(): String = buildString {
        append(status.name)
        rows.forEach { row -> append('|').append(row.id).append('=').append(row.status.name) }
        append("|summary=").append(summary?.passed).append('/').append(summary?.failed)
            .append('/').append(summary?.info).append('/').append(summary?.g0Passed)
        append("|thresholds=").append(thresholds.joinToString(",") { it.name })
        append("|groups=").append(groups.joinToString(",") { it.id })
        append("|lockdown=").append(lockdown.name)
        append(if (running) "|running" else "|idle")
        if (failure != null) append("|failure")
    }

    public companion object {
        /**
         * Projects (facts) into the screen state.
         *
         * Pure: no clock, no process read and no probe execution. The host owns
         * the run, so the same facts always yield the same state (§3.1).
         */
        public fun from(facts: ProbesFacts): ProbesScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure
            val status = when {
                failure != null -> ProbesStatus.FAILED
                snapshot == null -> ProbesStatus.UNKNOWN
                !snapshot.hasMeasurement -> ProbesStatus.EMPTY
                else -> ProbesStatus.READY
            }
            val measured = snapshot.takeIf { status == ProbesStatus.READY }
            return ProbesScreenState(
                status = status,
                environment = measured?.environment,
                os = measured?.os,
                bundle = measured?.bundle,
                running = measured?.running == true,
                statusText = measured?.statusText?.takeUnless { it.isBlank() },
                summary = measured?.summary,
                rows = measured?.rows.orEmpty(),
                groups = measured?.groups.orEmpty(),
                thresholds = measured?.thresholds.orEmpty(),
                lockdown = measured?.lockdown ?: FactState.UNKNOWN,
                failure = failure,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Probe-family shared views
// ---------------------------------------------------------------------------

/**
 * The token palette the standard Material controls read inside the probe pages.
 *
 * `PdshTheme` deliberately provides no `MaterialTheme` (the token table is the
 * only colour source). A standard control nevertheless reads a Material scheme,
 * so this wrapper feeds it the already-resolved tokens instead of letting the
 * library fall back to its own palette. It is shared by the probe-page family.
 */
@Composable
internal fun ProbeControlsTheme(content: @Composable () -> Unit) {
    val tokens = LocalUiTokens.current
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val surface = tokens.colors.input
    val scheme = if (dark) {
        darkColorScheme(
            primary = tokens.colors.accent,
            onPrimary = tokens.colors.onAccent,
            surface = surface,
            onSurface = tokens.colors.primary,
            surfaceContainer = surface,
            surfaceContainerHigh = tokens.colors.selector,
            surfaceVariant = tokens.colors.selector,
            onSurfaceVariant = tokens.colors.secondary,
            secondaryContainer = tokens.colors.selector,
            onSecondaryContainer = tokens.colors.primary,
            outline = tokens.colors.border,
            error = tokens.colors.danger,
            onError = tokens.colors.onAccent,
        )
    } else {
        lightColorScheme(
            primary = tokens.colors.accent,
            onPrimary = tokens.colors.onAccent,
            surface = surface,
            onSurface = tokens.colors.primary,
            surfaceContainer = surface,
            surfaceContainerHigh = tokens.colors.selector,
            surfaceVariant = tokens.colors.selector,
            onSurfaceVariant = tokens.colors.secondary,
            secondaryContainer = tokens.colors.selector,
            onSecondaryContainer = tokens.colors.primary,
            outline = tokens.colors.border,
            error = tokens.colors.danger,
            onError = tokens.colors.onAccent,
        )
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/**
 * The Lockdown Mode indicator (the baseline's `LockdownBadge`).
 *
 * It reads a measured fact, never a guess: [FactState.UNKNOWN] says the flag was
 * not read instead of rendering "off".
 */
@Composable
internal fun LockdownBadge(lockdown: FactState, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val label = when (lockdown) {
        FactState.YES -> UiStrings.LOCKDOWN_ON
        FactState.NO -> UiStrings.LOCKDOWN_OFF
        FactState.UNKNOWN -> UiStrings.LOCKDOWN_UNKNOWN
    }
    val ink = when (lockdown) {
        FactState.YES -> tokens.colors.danger
        FactState.NO -> tokens.colors.secondary
        FactState.UNKNOWN -> tokens.colors.tertiary
    }
    val glyph = when (lockdown) {
        FactState.YES -> UiStrings.LOCKDOWN_GLYPH_ON
        FactState.NO -> UiStrings.LOCKDOWN_GLYPH_OFF
        FactState.UNKNOWN -> UiStrings.LOCKDOWN_GLYPH_UNKNOWN
    }
    Row(
        modifier = modifier
            .clip(CircleShape)
            // unverified colour: the baseline capsule tint is a 0.12 / 0.10
            // opacity of red / secondary and has no token of its own.
            .background(ink.copy(alpha = 0.12f))
            .padding(
                horizontal = tokens.spacing.badgeInsetH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(text = glyph, style = type.caption.copy(color = ink))
        BasicText(text = label, style = type.caption.copy(color = ink))
    }
}

/**
 * The baseline's one-point `VisibleAnchorView` slot.
 *
 * The page hierarchy keeps a window-attached anchor for the probe WKWebViews on
 * iOS; on Android the WebView attachment is host-owned, but the slot stays in
 * the page tree exactly where the baseline puts it so the page composition does
 * not silently drop a host contract. It draws nothing visible.
 */
@Composable
internal fun VisibleAnchorSlot(modifier: Modifier = Modifier, tag: String) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            // unverified geometry: the baseline's 2×2 pt anchor has no page-level
            // token; the nearest declared 2 pt value is the summary dot diameter.
            .size(tokens.geometry.summaryDotDiameter)
            .testTag(tag),
    )
}

/** The ink a probe note uses; each branch resolves to a token. */
internal enum class ProbeInk {
    SECONDARY,
    TERTIARY,
    DANGER,
    SUCCESS,
}

@Composable
private fun ProbeInk.color(): Color {
    val tokens = LocalUiTokens.current
    return when (this) {
        ProbeInk.SECONDARY -> tokens.colors.secondary
        ProbeInk.TERTIARY -> tokens.colors.tertiary
        ProbeInk.DANGER -> tokens.colors.danger
        ProbeInk.SUCCESS -> tokens.colors.success
    }
}

/** One compact caption line; the baseline's `KeyValueLine` is the same shape. */
@Composable
internal fun ProbeKeyValue(
    key: String,
    value: String,
    modifier: Modifier = Modifier,
    valueInk: ProbeInk = ProbeInk.SECONDARY,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = valueInk.color()
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = tokens.spacing.badgeInsetV),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = key,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = value,
            style = type.code.copy(color = ink, textAlign = TextAlign.End),
        )
    }
}

/** A caption line with no trailing value (the host's own status / a footnote). */
@Composable
internal fun ProbeNote(
    text: String,
    modifier: Modifier = Modifier,
    ink: ProbeInk = ProbeInk.SECONDARY,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = ink.color()),
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = tokens.spacing.badgeInsetV),
    )
}

/** The PASS / FAIL / INFO chip; the baseline's `ProbeStatusChip`. */
@Composable
internal fun ProbeStatusChip(status: ProbeStatus, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when (status) {
        ProbeStatus.PASS -> tokens.colors.success
        ProbeStatus.FAIL -> tokens.colors.danger
        ProbeStatus.INFO -> tokens.colors.warning
        ProbeStatus.UNKNOWN -> tokens.colors.tertiary
    }
    Box(
        modifier = modifier
            .clip(CircleShape)
            // unverified colour: the baseline chip tint is a 0.15 opacity of the
            // status colour and has no token of its own.
            .background(ink.copy(alpha = 0.15f))
            .padding(
                horizontal = tokens.spacing.badgeInsetH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    ) {
        BasicText(
            text = status.chipLabel(),
            style = type.codeLabel.copy(color = ink, fontWeight = FontWeight.Bold),
        )
    }
}

/**
 * The host controls: the prominent run-all button, the group `Menu`, the
 * in-flight spinner, the host status line and the G0 failure line.
 */
@Composable
private fun runActions(
    state: ProbesScreenState,
    onRunAll: () -> Unit,
    onRunGroup: ((String) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var menuOpen by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Button(
            onClick = onRunAll,
            enabled = !state.running,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(UiPageTags.PROBES_RUN_ALL),
            colors = ButtonDefaults.buttonColors(
                containerColor = tokens.colors.accent,
                contentColor = tokens.colors.onAccent,
                disabledContainerColor = tokens.colors.selector,
                disabledContentColor = tokens.colors.tertiary,
            ),
        ) {
            Text(text = UiStrings.PROBES_ACTION_RUN_ALL_EN, style = type.secondary)
        }
        Box(modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(
                onClick = { menuOpen = true },
                enabled = !state.running && onRunGroup != null && state.groups.isNotEmpty(),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.PROBES_MENU),
                border = androidx.compose.foundation.BorderStroke(
                    tokens.stroke.hairline,
                    tokens.colors.border,
                ),
            ) {
                Text(text = UiStrings.PROBES_ACTION_RUN_GROUP_EN, style = type.secondary)
            }
            // The baseline's `Menu`: one entry per runnable probe group.
            DropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false },
                modifier = Modifier.testTag(UiPageTags.PROBES_MENU_LIST),
            ) {
                state.groups.forEach { group ->
                    DropdownMenuItem(
                        text = { Text(text = group.title, style = type.secondary) },
                        onClick = {
                            menuOpen = false
                            onRunGroup?.invoke(group.id)
                        },
                        modifier = Modifier
                            .testTag(UiPageTags.PROBES_GROUP_PREFIX + group.id),
                    )
                }
            }
        }
        if (state.running) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(UiPageTags.PROBES_PROGRESS),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(color = tokens.colors.accent)
            }
        }
        state.statusText?.let { status ->
            ProbeNote(text = status)
        }
        if (!state.running && state.summary?.g0Passed == false) {
            ProbeNote(
                text = UiStrings.PROBES_G0_FAILED_LIST.format(
                    state.summary.failedGatingProbes.joinToString(", "),
                ),
                ink = ProbeInk.DANGER,
                modifier = Modifier.testTag(UiPageTags.PROBES_G0_FAILED),
            )
        }
    }
}

/** One probe row: name + status chip, metrics, the G0 line, flags and detail. */
@Composable
private fun ProbeRowView(row: ProbeRow, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = row.probe,
                style = type.code.copy(
                    color = tokens.colors.primary,
                    fontWeight = FontWeight.SemiBold,
                ),
                modifier = Modifier.weight(1f),
            )
            ProbeStatusChip(status = row.status)
        }
        // The baseline iterates `row.metrics.keys.sorted()`.
        row.metrics.sortedBy { it.name }.forEach { metric ->
            ProbeKeyValue(
                key = metric.name,
                value = metric.value ?: UiStrings.PROBES_VALUE_NONE,
                valueInk = if (metric.value == null) ProbeInk.TERTIARY else ProbeInk.SECONDARY,
            )
        }
        row.threshold?.let { threshold ->
            ProbeNote(text = threshold.lineText(), ink = ProbeInk.TERTIARY)
        }
        if (row.gating == false) {
            ProbeNote(text = UiStrings.PROBES_NON_GATING_ROW, ink = ProbeInk.TERTIARY)
        }
        row.detail?.takeUnless { it.isBlank() }?.let { detail ->
            ProbeNote(text = detail, ink = ProbeInk.SECONDARY)
        }
        ProbeNote(text = row.recordedText(), ink = ProbeInk.TERTIARY)
    }
}

/** One G0 bound block: name, bound, gating and the declaration it comes from. */
@Composable
private fun ProbeThresholdView(threshold: ProbeThreshold, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = threshold.name,
            style = type.code.copy(
                color = tokens.colors.primary,
                fontWeight = FontWeight.SemiBold,
            ),
        )
        ProbeKeyValue(key = UiStrings.PROBES_BOUND, value = threshold.tableBoundText())
        ProbeKeyValue(
            key = UiStrings.PROBES_GATING,
            value = when (threshold.gating) {
                true -> UiStrings.YES
                false -> UiStrings.NO
                null -> UiStrings.UNKNOWN
            },
        )
        threshold.source?.takeUnless { it.isBlank() }?.let { source ->
            ProbeNote(text = source, ink = ProbeInk.SECONDARY)
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The device-probe page.
 *
 * @param state the pure screen state (`ProbesScreenState.from`).
 * @param onBack leave the page (push, per §1).
 * @param onRunAll run every probe; the host applies it and re-projects.
 * @param modifier the caller's modifier.
 * @param onReset clear the recorded rows (the baseline's trailing Reset toolbar
 *   action). The control is always drawn; `null` renders it disabled, because the
 *   baseline draws it unconditionally (`ProbesPage.swift:42`).
 * @param onRunGroup run one group from the Run one group menu; `null` disables it.
 * @param onRetry retry the host read; `null` hides the retry.
 * @param onDismissFailure dismiss the failure line; `null` hides it.
 */
@Composable
public fun ProbesPage(
    state: ProbesScreenState,
    onBack: () -> Unit,
    onRunAll: () -> Unit,
    modifier: Modifier = Modifier,
    onReset: (() -> Unit)? = null,
    onRunGroup: ((String) -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.PROBES_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.PROBES_ROOT,
        modifier = modifier,
        // L75: the baseline's `Reset` is an unconditional toolbar item
        // (`ProbesPage.swift:42`), so it is drawn unconditionally here too. Before
        // this it sat behind `if (onReset != null)`, and the only caller
        // (`SettingsSurfaces.kt`) passes no `onReset` — the label existed in the
        // source and never rendered (the L64 false-green shape that
        // `page_structure_check` now reports as `conditional-action`). A host that
        // cannot reset says so by leaving the control disabled, not by deleting it:
        // the control stays where the baseline puts it, and a disabled control is a
        // state a screen reader reports, unlike an absent one.
        actions = {
            SessionTextAction(
                label = UiStrings.PROBES_ACTION_RESET_EN,
                onClick = { onReset?.invoke() },
                tone = SessionActionTone.SECONDARY,
                enabled = onReset != null && !state.running,
                modifier = Modifier.testTag(UiPageTags.PROBES_RESET),
            )
        },
    ) {
        ProbeControlsTheme {
            Box(modifier = Modifier.fillMaxSize()) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.PROBES_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    state.failure?.let { failure ->
                        item(key = "probes.failure") {
                            SessionFailureLine(
                                message = failure,
                                tag = UiPageTags.PROBES_FAILURE,
                                retryLabel = if (onRetry != null) UiStrings.RETRY else null,
                                onRetry = onRetry,
                                onDismiss = onDismissFailure,
                            )
                        }
                    }
                    environmentSection(state)
                    item(key = "probes.lockdown") {
                        LockdownBadge(
                            lockdown = state.lockdown,
                            modifier = Modifier
                                .padding(
                                    horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
                                )
                                .testTag(UiPageTags.PROBES_LOCKDOWN),
                        )
                    }
                    item(key = "probes.actions") {
                        runActions(state, onRunAll, onRunGroup)
                    }
                    rowsSection(state)
                    thresholdsSection(state)
                }
                VisibleAnchorSlot(
                    modifier = Modifier.align(Alignment.TopStart),
                    tag = UiPageTags.PROBES_ANCHOR,
                )
            }
        }
    }
}

/** The environment reads; an unread value is 未知, never an empty string. */
private fun LazyListScope.environmentSection(state: ProbesScreenState) {
    item(key = "probes.environment.label") {
        SessionSectionLabel(UiStrings.PROBES_SECTION_ENVIRONMENT_EN)
    }
    item(key = "probes.environment") {
        InfoRow(
            title = UiStrings.PROBES_ENVIRONMENT,
            value = state.environment ?: UiStrings.UNKNOWN,
            tone = measuredTone(state.environment),
            modifier = Modifier.testTag(UiPageTags.PROBES_ENVIRONMENT),
        )
    }
    item(key = "probes.os") {
        InfoRow(
            title = UiStrings.PROBES_OS,
            value = state.os ?: UiStrings.UNKNOWN,
            tone = measuredTone(state.os),
            modifier = Modifier.testTag(UiPageTags.PROBES_OS),
        )
    }
    item(key = "probes.bundle") {
        InfoRow(
            title = UiStrings.PROBES_BUNDLE,
            value = state.bundle ?: UiStrings.UNKNOWN,
            tone = measuredTone(state.bundle),
            modifier = Modifier.testTag(UiPageTags.PROBES_BUNDLE),
        )
    }
    item(key = "probes.environment.note") {
        ProbeNote(
            text = UiStrings.PROBES_ENVIRONMENT_NOTE,
            ink = ProbeInk.TERTIARY,
            modifier = Modifier.testTag(UiPageTags.PROBES_ENVIRONMENT_NOTE),
        )
    }
}

/** "Rows (N)" with the summary and one block per row, or the baseline empty copy. */
private fun LazyListScope.rowsSection(state: ProbesScreenState) {
    if (state.rows.isEmpty()) {
        item(key = "probes.rows.label") {
            SessionSectionLabel(
                text = UiStrings.PROBES_SECTION_ROWS_EN,
                modifier = Modifier.testTag(UiPageTags.PROBES_ROWS),
            )
        }
        item(key = "probes.rows.empty") {
            ProbeNote(
                text = UiStrings.PROBES_EMPTY_NOTE,
                ink = ProbeInk.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.PROBES_EMPTY),
            )
        }
        return
    }
    item(key = "probes.rows.label") {
        SessionSectionLabel(
            // `ProbesPage.swift:112` is `PageSection("Rows (\(model.probeRows.count))")`:
            // the title is a template plus one rendered value, so the page formats the
            // measured count instead of showing the baseline's interpolation source.
            // `PROBES_SECTION_ROWS_COUNT_EN` is that source copied verbatim and must
            // never be rendered; it stays because this lane only appends copy.
            text = UiStrings.PROBES_SECTION_ROWS_COUNT.format(state.rows.size),
            modifier = Modifier.testTag(UiPageTags.PROBES_ROWS),
        )
    }
    item(key = "probes.counts") {
        InfoRow(
            title = UiStrings.PROBES_COUNTS_LABEL,
            value = countsText(state.summary),
            tone = if (state.summary?.passed == null) PageTone.UNKNOWN else PageTone.NORMAL,
            modifier = Modifier.testTag(UiPageTags.PROBES_COUNTS),
        )
    }
    item(key = "probes.g0") {
        InfoRow(
            title = UiStrings.PROBES_G0,
            value = when (state.summary?.g0Passed) {
                true -> UiStrings.PROBES_G0_PASSED
                false -> UiStrings.PROBES_G0_FAILED
                null -> UiStrings.UNKNOWN
            },
            tone = when (state.summary?.g0Passed) {
                true -> PageTone.ON
                false -> PageTone.DEGRADED
                null -> PageTone.UNKNOWN
            },
            modifier = Modifier.testTag(UiPageTags.PROBES_G0),
        )
    }
    state.rows.forEach { row ->
        item(key = "probes.row.divider.${row.id}") {
            SessionHairline()
        }
        item(key = "probes.row.${row.id}") {
            ProbeRowView(
                row = row,
                modifier = Modifier.testTag(UiPageTags.PROBES_ROW_PREFIX + row.id),
            )
        }
    }
}

/** The G0 bound table, one block per bound; an unreported table is 未知. */
private fun LazyListScope.thresholdsSection(state: ProbesScreenState) {
    item(key = "probes.thresholds.label") {
        SessionSectionLabel(
            text = UiStrings.PROBES_SECTION_THRESHOLDS_EN,
            modifier = Modifier.testTag(UiPageTags.PROBES_THRESHOLDS),
        )
    }
    if (state.thresholds.isEmpty()) {
        item(key = "probes.thresholds.unknown") {
            InfoRow(
                title = UiStrings.PROBES_SECTION_THRESHOLDS_EN,
                value = UiStrings.UNKNOWN,
                tone = PageTone.UNKNOWN,
                modifier = Modifier.testTag(UiPageTags.PROBES_THRESHOLD_TABLE_PREFIX + "unknown"),
            )
        }
        return
    }
    state.thresholds.forEachIndexed { index, threshold ->
        item(key = "probes.threshold.table.$index") {
            ProbeThresholdView(
                threshold = threshold,
                modifier = Modifier.testTag(
                    UiPageTags.PROBES_THRESHOLD_TABLE_PREFIX + index,
                ),
            )
        }
        if (index != state.thresholds.lastIndex) {
            item(key = "probes.threshold.divider.$index") {
                SessionHairline()
            }
        }
    }
}

/** The counts line; each slot is the measured count or 未知. */
private fun countsText(summary: ProbeSummary?): String = UiStrings.PROBES_COUNTS.format(
    summary?.passed?.toString() ?: UiStrings.UNKNOWN,
    summary?.failed?.toString() ?: UiStrings.UNKNOWN,
    summary?.info?.toString() ?: UiStrings.UNKNOWN,
)

/** A measured string is plain ink; an absent one is the unknown ink. */
private fun measuredTone(value: String?): PageTone =
    if (value == null) PageTone.UNKNOWN else PageTone.NORMAL

/** The chip text is the baseline's raw status value, never the enum name. */
private fun ProbeStatus.chipLabel(): String = when (this) {
    ProbeStatus.PASS -> UiStrings.PROBES_CHIP_PASS
    ProbeStatus.FAIL -> UiStrings.PROBES_CHIP_FAIL
    ProbeStatus.INFO -> UiStrings.PROBES_CHIP_INFO
    ProbeStatus.UNKNOWN -> UiStrings.UNKNOWN
}

/** The bound in one line: comparison, value and unit, or 未知 when unmeasured. */
private fun ProbeThreshold.boundText(): String {
    val measured = listOfNotNull(comparison, bound, unit).filter { it.isNotBlank() }
    return if (measured.isEmpty()) UiStrings.UNKNOWN else measured.joinToString(" ")
}

/** The G0 table's `bound` value: value and unit only, as the baseline prints it. */
private fun ProbeThreshold.tableBoundText(): String {
    val measured = listOfNotNull(bound, unit).filter { it.isNotBlank() }
    return if (measured.isEmpty()) UiStrings.UNKNOWN else measured.joinToString(" ")
}

/**
 * The row's G0 line, exactly the baseline's shape:
 * `G0 <name>: <comparison> <value> <unit>[ · met=<bool>]`.
 */
private fun ProbeThreshold.lineText(): String {
    val bound = listOfNotNull(comparison, bound, unit)
        .filter { it.isNotBlank() }
        .joinToString(" ")
    val head = UiStrings.PROBES_ROW_THRESHOLD.format(name, bound)
    val met = this.met ?: return head
    return head + UiStrings.PROBES_ROW_MET.format(met.toString())
}

/** `environment · recordedAt`; an unreported half renders 未知 rather than missing. */
private fun ProbeRow.recordedText(): String = listOf(
    environment ?: UiStrings.UNKNOWN,
    recordedAt ?: UiStrings.UNKNOWN,
).joinToString(" · ")

/**
 * Every token this file reads directly.
 *
 * `PageTokenReferenceTest` holds this list equal to the source. The entries come
 * from the shared probe-family views above (the badge, the status chip, the key
 * value line, the standard-control palette and the 2 pt anchor), all of which
 * are composed by at least this page; the shared `PageFrame` and `InfoRow` read
 * their own tokens and are not listed here.
 */
internal object ProbesPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.border",
        "colors.danger",
        "colors.input",
        "colors.onAccent",
        "colors.primary",
        "colors.secondary",
        "colors.selector",
        "colors.success",
        "colors.tertiary",
        "colors.warning",
        "geometry.pageOuterMarginH",
        "geometry.summaryDotDiameter",
        "spacing.badgeInsetH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "stroke.hairline",
        "typography.caption",
        "typography.code",
        "typography.codeLabel",
        "typography.secondary",
    )
}

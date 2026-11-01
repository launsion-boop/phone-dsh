// Background keep-alive diagnostics: one matrix cell, its observation and the log.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row BackgroundPage (后台保活诊断; entry: 设置 →
// 探针工具（仅 DEBUG）; exit: push; P5 `later`), §3.1 rule 3 (a page with no
// harness event anchor projects the host's read-only snapshot) and §5 (`insets`,
// and `fgs-notification` / platform `platform.bgtask-drain-window` for the
// Android form of keep-alive).
//
// This is a line-for-line port of the iOS baseline's `BackgroundPage.swift`:
//
//   Matrix cell   Scenario picker, the continued-processing toggle, its note,
//                 the required-window picker and its note
//   Run           Start cell + Cancel, the missing-bundle line, the operator
//                 instruction, the phase and the host status line
//   Observation   OS window, lock observed, background interval, recovered,
//                 recovery, host state, the last error and the Lockdown badge
//   Matrix results one block per recorded cell (scenario + continued-processing
//                 flag + MEASURED status, arm, observed, held window, recovered,
//                 detail) and the simulator footnote
//   Transitions   the last 14 transitions, or the empty copy
//
// The two pickers are the baseline's segmented `Picker` and are standard
// Material 3 segmented buttons here; the toggle is the baseline's `Toggle` and
// is a Material 3 `Switch`. They are platform controls, not a page-invented
// component, and they exist even when the host has no snapshot (the selection
// is then simply empty and the values render 未知).
//
// The page takes the mechanism, the window and every timestamp as host strings
// and interprets none of them: it cannot tell whether Android kept the host
// alive with a foreground service or whether the window was ten minutes, and it
// must not pretend to. A cell that was not recorded is absent; an observed value
// the host did not measure renders 未知, never 0 seconds and never 未运行.
//
// ScreenState: `BackgroundScreenState.from(facts)` is the whole projection. The
// picker/toggle selections are host-owned settings projected back into the
// snapshot, so the page's only local event is the menu-like control gesture that
// calls the host.
//
// Geometry: the shared `PageFrame`, `InfoRow`, section label and the probe-family
// views own most lengths; the rest is listed in `BackgroundPageTokens`.
package com.phonedsh.ui.page

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import kotlin.math.abs
import kotlin.math.round

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** The two cells of the baseline matrix; the page names them, the host runs one. */
public enum class BackgroundScenario {
    /** The operator leaves the app with Home. */
    BACKGROUND,

    /** The operator locks the device with the side button. */
    LOCK,
}

/**
 * What the platform was observed doing while the cell ran.
 *
 * @param openedArm the OS window kind the host reports it opened (`openedArm`).
 * @param lockObserved whether a lock signal was observed ([FactState.UNKNOWN]
 *   when the platform emitted none and the host cannot tell "not locked" from
 *   "no signal").
 * @param backgroundSeconds the measured time away from the foreground.
 * @param recovered whether the host came back.
 * @param recoverySeconds the measured time to recovery.
 * @param hostState the host's own state label.
 */
@Immutable
public data class BackgroundObservation(
    public val openedArm: String? = null,
    public val lockObserved: FactState = FactState.UNKNOWN,
    public val backgroundSeconds: Double? = null,
    public val recovered: FactState = FactState.UNKNOWN,
    public val recoverySeconds: Double? = null,
    public val hostState: String? = null,
)

/**
 * One recorded matrix cell.
 *
 * @param id a stable cell id.
 * @param scenario the scenario that was run.
 * @param continuedProcessing whether the continued-processing arm was requested.
 * @param status the host's status label for the cell (`MEASURED` is the one the
 *   baseline inks green).
 * @param arm the OS window kind the host armed.
 * @param observedSeconds the measured time away from the foreground.
 * @param heldFullWindow whether the window was held to the end.
 * @param recovered whether the host came back.
 * @param detail the host's explanation; `null` when absent.
 */
@Immutable
public data class BackgroundCell(
    public val id: String,
    public val scenario: BackgroundScenario? = null,
    public val continuedProcessing: FactState = FactState.UNKNOWN,
    public val status: String? = null,
    public val arm: String? = null,
    public val observedSeconds: Double? = null,
    public val heldFullWindow: FactState = FactState.UNKNOWN,
    public val recovered: FactState = FactState.UNKNOWN,
    public val detail: String? = null,
)

/**
 * One recorded transition.
 *
 * @param id a stable transition id.
 * @param kind the host's transition kind (for example `didEnterBackground`).
 * @param from the state the host left, `null` when unreported.
 * @param to the state the host entered, `null` when unreported.
 * @param detail the host's detail, `null` when absent.
 * @param at the host-formatted timestamp; the page never reads a clock.
 */
@Immutable
public data class BackgroundTransition(
    public val id: String,
    public val kind: String,
    public val from: String? = null,
    public val to: String? = null,
    public val detail: String? = null,
    public val at: String? = null,
)

/**
 * The host's read-only background-diagnostics snapshot.
 *
 * @param running whether a cell is running right now.
 * @param scenario the scenario the host is armed for, `null` when unarmed.
 * @param continuedProcessing whether the continued-processing arm is on.
 * @param requiredSeconds the window the cell asks for (600 or 60 in the
 *   baseline); `null` when unreported.
 * @param bundleInstalled whether the Worker bundle is present.
 * @param bundleDetail the host's explanation when it is missing.
 * @param phase the host's run phase label.
 * @param statusText the host's own status line.
 * @param lastError the last run error; non-null renders a fail-loud line.
 * @param observation the current observation; `null` when nothing was observed.
 * @param cells the recorded cells; `null` means the host reported no cell list.
 * @param transitions the transition log; `null` means the host reported none.
 * @param lockdown the system Lockdown flag; [FactState.UNKNOWN] when unread.
 */
@Immutable
public data class BackgroundSnapshot(
    public val running: FactState = FactState.UNKNOWN,
    public val scenario: BackgroundScenario? = null,
    public val continuedProcessing: FactState = FactState.UNKNOWN,
    public val requiredSeconds: Double? = null,
    public val bundleInstalled: FactState = FactState.UNKNOWN,
    public val bundleDetail: String? = null,
    public val phase: String? = null,
    public val statusText: String? = null,
    public val lastError: String? = null,
    public val observation: BackgroundObservation? = null,
    public val cells: List<BackgroundCell>? = null,
    public val transitions: List<BackgroundTransition>? = null,
    public val lockdown: FactState = FactState.UNKNOWN,
) {
    /** True when the host measured at least one fact of this page. */
    internal val hasMeasurement: Boolean
        get() = running != FactState.UNKNOWN || scenario != null ||
            continuedProcessing != FactState.UNKNOWN || requiredSeconds != null ||
            bundleInstalled != FactState.UNKNOWN || phase != null ||
            statusText != null || lastError != null || observation != null ||
            cells != null || transitions != null || lockdown != FactState.UNKNOWN
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null makes the state FAILED.
 */
@Immutable
public data class BackgroundFacts(
    public val snapshot: BackgroundSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class BackgroundStatus {
    /** The host reported at least one measured fact. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last host read failed. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never 0 seconds. */
    UNKNOWN,
}

/**
 * The complete background-diagnostics screen state.
 *
 * @param status the four-state outcome; a failure wins because a failed read
 *   proves nothing about the diagnostics.
 * @param running whether a cell runs right now.
 * @param scenario the armed scenario, `null` when unarmed.
 * @param continuedProcessing whether the continued-processing arm is on.
 * @param requiredSeconds the requested window, `null` when unreported.
 * @param bundleInstalled whether the Worker bundle is present.
 * @param bundleDetail the host's explanation when it is missing.
 * @param phase the host's phase label.
 * @param statusText the host's status line.
 * @param lastError the last run error, `null` when the last run had none.
 * @param observation the current observation, `null` when unreported.
 * @param cells the recorded cells, `null` when unreported, empty when none.
 * @param transitions the transition log, `null` when unreported, empty when none.
 * @param lockdown the system Lockdown flag.
 * @param failure the failure message, `null` unless FAILED.
 */
@Immutable
public data class BackgroundScreenState(
    public val status: BackgroundStatus,
    public val running: FactState,
    public val scenario: BackgroundScenario?,
    public val continuedProcessing: FactState,
    public val requiredSeconds: Double?,
    public val bundleInstalled: FactState,
    public val bundleDetail: String?,
    public val phase: String?,
    public val statusText: String?,
    public val lastError: String?,
    public val observation: BackgroundObservation?,
    public val cells: List<BackgroundCell>?,
    public val transitions: List<BackgroundTransition>?,
    public val lockdown: FactState,
    public val failure: String?,
) {
    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == BackgroundStatus.EMPTY

    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == BackgroundStatus.UNKNOWN

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == BackgroundStatus.FAILED

    /** True when a cell may be started: only a measured running state blocks it. */
    public val canStart: Boolean
        get() = status == BackgroundStatus.READY &&
            running != FactState.YES && bundleInstalled != FactState.NO

    /** True when a cancel is offered: a measured idle cell has nothing to cancel. */
    public val canCancel: Boolean
        get() = status == BackgroundStatus.READY && running != FactState.NO

    /** True when the host reported an empty cell table. */
    public val cellsEmpty: Boolean get() = cells != null && cells.isEmpty()

    /** True when the host reported an empty transition log. */
    public val transitionsEmpty: Boolean get() = transitions != null && transitions.isEmpty()

    /** The baseline's operator instruction for the selected scenario. */
    public val instruction: String?
        get() = when (scenario) {
            BackgroundScenario.BACKGROUND -> UiStrings.BACKGROUND_INSTRUCTION_BACKGROUND
            BackgroundScenario.LOCK -> UiStrings.BACKGROUND_INSTRUCTION_LOCK
            null -> null
        }

    /** True when at least one rendered value is 未知 inside a measured report. */
    public val hasUnmeasuredValues: Boolean
        get() {
            if (status != BackgroundStatus.READY) return false
            if (running == FactState.UNKNOWN || scenario == null || phase == null) return true
            if (continuedProcessing == FactState.UNKNOWN || requiredSeconds == null) return true
            if (bundleInstalled == FactState.UNKNOWN || lockdown == FactState.UNKNOWN) return true
            val observed = observation ?: return true
            if (observed.openedArm == null || observed.lockObserved == FactState.UNKNOWN) return true
            if (observed.backgroundSeconds == null || observed.recoverySeconds == null) return true
            if (observed.recovered == FactState.UNKNOWN || observed.hostState == null) return true
            return cells.orEmpty().any { cell ->
                cell.scenario == null || cell.status == null || cell.arm == null ||
                    cell.observedSeconds == null ||
                    cell.continuedProcessing == FactState.UNKNOWN ||
                    cell.heldFullWindow == FactState.UNKNOWN ||
                    cell.recovered == FactState.UNKNOWN
            }
        }

    /**
     * A display-free signature of the sequence-relevant state.
     *
     * Only ids, phases and fact states are included: a replay compares the shape
     * without depending on host copy or on the measured numbers.
     */
    public fun signature(): String = buildString {
        append(status.name).append('|').append(running.name)
        append("|scenario=").append(scenario?.name)
        append("|continued=").append(continuedProcessing.name)
        append("|required=").append(requiredSeconds)
        append("|bundle=").append(bundleInstalled.name)
        append("|phase=").append(phase)
        append("|lockdown=").append(lockdown.name)
        cells.orEmpty().forEach { cell ->
            append("|cell=").append(cell.id).append(':').append(cell.recovered.name)
        }
        transitions.orEmpty().forEach { transition ->
            append("|transition=").append(transition.id).append(':').append(transition.kind)
        }
        if (lastError != null) append("|error")
        if (failure != null) append("|failure")
    }

    public companion object {
        /** The two windows the baseline picker offers. */
        public const val PLAN_SECONDS: Double = 600.0
        public const val UI_CHECK_SECONDS: Double = 60.0

        /**
         * Projects (facts) into the screen state.
         *
         * Pure: no clock, no platform signal read and no run. The host owns the
         * run, so the same facts always yield the same state (§3.1).
         */
        public fun from(facts: BackgroundFacts): BackgroundScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure
            val status = when {
                failure != null -> BackgroundStatus.FAILED
                snapshot == null -> BackgroundStatus.UNKNOWN
                !snapshot.hasMeasurement -> BackgroundStatus.EMPTY
                else -> BackgroundStatus.READY
            }
            val measured = snapshot.takeIf { status == BackgroundStatus.READY }
            return BackgroundScreenState(
                status = status,
                running = measured?.running ?: FactState.UNKNOWN,
                scenario = measured?.scenario,
                continuedProcessing = measured?.continuedProcessing ?: FactState.UNKNOWN,
                requiredSeconds = measured?.requiredSeconds,
                bundleInstalled = measured?.bundleInstalled ?: FactState.UNKNOWN,
                bundleDetail = measured?.bundleDetail?.takeUnless { it.isBlank() },
                phase = measured?.phase?.takeUnless { it.isBlank() },
                statusText = measured?.statusText?.takeUnless { it.isBlank() },
                lastError = measured?.lastError?.takeUnless { it.isBlank() },
                observation = measured?.observation,
                cells = measured?.cells,
                transitions = measured?.transitions,
                lockdown = measured?.lockdown ?: FactState.UNKNOWN,
                failure = failure,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The background keep-alive diagnostics page.
 *
 * @param state the pure screen state (`BackgroundScreenState.from`).
 * @param onBack leave the page (push, per §1).
 * @param onStart arm and run the selected cell.
 * @param modifier the caller's modifier.
 * @param onCancel cancel the running cell; `null` hides the action.
 * @param onScenarioChange pick one matrix scenario; `null` disables the picker.
 * @param onContinuedProcessingChange switch the continued-processing arm;
 *   `null` disables the toggle.
 * @param onRequiredWindowChange pick the required window; `null` disables it.
 * @param onRetry retry the host read; `null` hides the retry.
 * @param onDismissFailure dismiss the failure line; `null` hides it.
 */
@Composable
public fun BackgroundPage(
    state: BackgroundScreenState,
    onBack: () -> Unit,
    onStart: () -> Unit,
    modifier: Modifier = Modifier,
    onCancel: (() -> Unit)? = null,
    onScenarioChange: ((BackgroundScenario) -> Unit)? = null,
    onContinuedProcessingChange: ((Boolean) -> Unit)? = null,
    onRequiredWindowChange: ((Double) -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.BACKGROUND_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.BACKGROUND_ROOT,
        modifier = modifier,
    ) {
        ProbeControlsTheme {
            Box(modifier = Modifier.fillMaxSize()) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag(UiPageTags.BACKGROUND_LIST),
                    verticalArrangement = Arrangement.spacedBy(pageListGap),
                ) {
                    state.failure?.let { failure ->
                        item(key = "background.failure") {
                            SessionFailureLine(
                                message = failure,
                                tag = UiPageTags.BACKGROUND_FAILURE,
                                retryLabel = if (onRetry != null) UiStrings.RETRY else null,
                                onRetry = onRetry,
                                onDismiss = onDismissFailure,
                            )
                        }
                    }
                    matrixCellSection(state, onScenarioChange, onContinuedProcessingChange, onRequiredWindowChange)
                    runSection(state, onStart, onCancel)
                    observationSection(state)
                    cellsSection(state)
                    transitionsSection(state)
                }
                VisibleAnchorSlot(
                    modifier = Modifier.align(Alignment.TopStart),
                    tag = UiPageTags.BACKGROUND_ANCHOR,
                )
            }
        }
    }
}

/** The baseline's Matrix cell block: two segmented pickers and one toggle. */
private fun LazyListScope.matrixCellSection(
    state: BackgroundScreenState,
    onScenarioChange: ((BackgroundScenario) -> Unit)?,
    onContinuedProcessingChange: ((Boolean) -> Unit)?,
    onRequiredWindowChange: ((Double) -> Unit)?,
) {
    item(key = "background.matrix.cell.label") {
        SessionSectionLabel(UiStrings.BACKGROUND_SECTION_MATRIX_CELL_EN)
    }
    item(key = "background.scenario") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        val scenarios = BackgroundScenario.entries
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .testTag(UiPageTags.BACKGROUND_SCENARIO),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Text(
                text = UiStrings.BACKGROUND_LABEL_SCENARIO_EN,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                scenarios.forEachIndexed { index, scenario ->
                    SegmentedButton(
                        selected = state.scenario == scenario,
                        onClick = { onScenarioChange?.invoke(scenario) },
                        enabled = onScenarioChange != null,
                        shape = SegmentedButtonDefaults.itemShape(
                            index = index,
                            count = scenarios.size,
                        ),
                        modifier = Modifier.testTag(
                            UiPageTags.BACKGROUND_SCENARIO + "." + scenario.name,
                        ),
                    ) {
                        Text(text = scenario.label(), style = type.secondary)
                    }
                }
            }
        }
    }
    item(key = "background.continued") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Text(
                text = UiStrings.BACKGROUND_LABEL_CONTINUED_EN,
                style = type.secondary.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            if (state.continuedProcessing == FactState.UNKNOWN) {
                Text(
                    text = UiStrings.UNKNOWN,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
            Switch(
                checked = state.continuedProcessing == FactState.YES,
                onCheckedChange = { checked -> onContinuedProcessingChange?.invoke(checked) },
                enabled = onContinuedProcessingChange != null &&
                    state.continuedProcessing != FactState.UNKNOWN,
                modifier = Modifier.testTag(UiPageTags.BACKGROUND_CONTINUED_SWITCH),
            )
        }
        ProbeNote(
            text = UiStrings.BACKGROUND_CONTINUED_PROCESSING_NOTE,
            ink = ProbeInk.TERTIARY,
            modifier = Modifier.padding(
                horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
            ),
        )
    }
    item(key = "background.required") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        val windows = listOf(
            BackgroundScreenState.PLAN_SECONDS to UiStrings.BACKGROUND_WINDOW_10MIN,
            BackgroundScreenState.UI_CHECK_SECONDS to UiStrings.BACKGROUND_WINDOW_60S,
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                )
                .testTag(UiPageTags.BACKGROUND_REQUIRED_PICKER),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            Text(
                text = UiStrings.BACKGROUND_LABEL_REQUIRED_EN,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                windows.forEachIndexed { index, (seconds, label) ->
                    SegmentedButton(
                        selected = state.requiredSeconds?.let { abs(it - seconds) < 0.5 } == true,
                        onClick = { onRequiredWindowChange?.invoke(seconds) },
                        enabled = onRequiredWindowChange != null,
                        shape = SegmentedButtonDefaults.itemShape(
                            index = index,
                            count = windows.size,
                        ),
                        modifier = Modifier.testTag(
                            UiPageTags.BACKGROUND_REQUIRED_PICKER + "." + seconds.toInt(),
                        ),
                    ) {
                        Text(text = label, style = type.secondary)
                    }
                }
            }
        }
        ProbeNote(
            text = UiStrings.BACKGROUND_REQUIRED_NOTE,
            ink = ProbeInk.TERTIARY,
            modifier = Modifier.padding(
                horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
            ),
        )
    }
}

/** The run block: the two buttons in the baseline's order, then its facts. */
private fun LazyListScope.runSection(
    state: BackgroundScreenState,
    onStart: () -> Unit,
    onCancel: (() -> Unit)?,
) {
    item(key = "background.run.label") {
        SessionSectionLabel(UiStrings.BACKGROUND_SECTION_RUN_EN)
    }
    item(key = "background.run.buttons") {
        val tokens = LocalUiTokens.current
        val type = LocalUiType.current
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                onClick = onStart,
                enabled = state.canStart,
                modifier = Modifier
                    .weight(1f)
                    .testTag(UiPageTags.BACKGROUND_START),
                colors = ButtonDefaults.buttonColors(
                    containerColor = tokens.colors.accent,
                    contentColor = tokens.colors.onAccent,
                    disabledContainerColor = tokens.colors.selector,
                    disabledContentColor = tokens.colors.tertiary,
                ),
            ) {
                Text(text = UiStrings.BACKGROUND_ACTION_START_EN, style = type.secondary)
            }
            if (onCancel != null) {
                OutlinedButton(
                    onClick = onCancel,
                    enabled = state.canCancel,
                    modifier = Modifier.testTag(UiPageTags.BACKGROUND_CANCEL),
                    border = BorderStroke(tokens.stroke.hairline, tokens.colors.danger),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = tokens.colors.danger,
                        disabledContentColor = tokens.colors.tertiary,
                    ),
                ) {
                    Text(text = UiStrings.BACKGROUND_ACTION_CANCEL_EN, style = type.secondary)
                }
            }
        }
    }
    if (state.running != FactState.YES && state.bundleInstalled == FactState.NO) {
        item(key = "background.bundle") {
            ProbeNote(
                text = state.bundleDetail ?: UiStrings.UNKNOWN,
                ink = ProbeInk.DANGER,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.BACKGROUND_BUNDLE_HINT),
            )
        }
    }
    item(key = "background.instruction") {
        ProbeNote(
            text = state.instruction ?: UiStrings.UNKNOWN,
            ink = ProbeInk.TERTIARY,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_INSTRUCTION),
        )
    }
    item(key = "background.phase") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_PHASE,
            value = state.phase ?: UiStrings.UNKNOWN,
            valueInk = if (state.phase == null) ProbeInk.TERTIARY else ProbeInk.SECONDARY,
            modifier = Modifier.padding(
                horizontal = LocalUiTokens.current.geometry.pageOuterMarginH,
            ),
        )
    }
    item(key = "background.status") {
        ProbeNote(
            text = state.statusText ?: UiStrings.UNKNOWN,
            ink = ProbeInk.SECONDARY,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_STATUS),
        )
    }
}

/** The observation block; every unmeasured value is 未知, never a zero. */
private fun LazyListScope.observationSection(state: BackgroundScreenState) {
    item(key = "background.observation.label") {
        SessionSectionLabel(UiStrings.BACKGROUND_SECTION_OBSERVATION_EN)
    }
    val observation = state.observation
    item(key = "background.window") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_WINDOW,
            value = observation?.openedArm ?: UiStrings.UNKNOWN,
            valueInk = if (observation?.openedArm == null) ProbeInk.TERTIARY else ProbeInk.SECONDARY,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_WINDOW),
        )
    }
    item(key = "background.lock") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_LOCK_OBSERVED,
            value = (observation?.lockObserved ?: FactState.UNKNOWN).yesNo(),
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_LOCK),
        )
    }
    item(key = "background.interval") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_BACKGROUND_SECONDS,
            value = secondsText(observation?.backgroundSeconds, decimals = 1),
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_INTERVAL),
        )
    }
    item(key = "background.recovered") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_RECOVERED,
            value = (observation?.recovered ?: FactState.UNKNOWN).yesNo(),
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_RECOVERED),
        )
    }
    item(key = "background.recovery") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_RECOVERY_SECONDS,
            value = secondsText(observation?.recoverySeconds, decimals = 2),
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_RECOVERY),
        )
    }
    item(key = "background.host") {
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_HOST_STATE,
            value = observation?.hostState ?: UiStrings.UNKNOWN,
            valueInk = if (observation?.hostState == null) ProbeInk.TERTIARY else ProbeInk.SECONDARY,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_HOST),
        )
    }
    state.lastError?.let { error ->
        item(key = "background.error") {
            ProbeNote(
                text = error,
                ink = ProbeInk.DANGER,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.BACKGROUND_LAST_ERROR),
            )
        }
    }
    item(key = "background.lockdown") {
        LockdownBadge(
            lockdown = state.lockdown,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_LOCKDOWN),
        )
    }
}

/** The recorded matrix cells; a cell that did not run is simply absent. */
private fun LazyListScope.cellsSection(state: BackgroundScreenState) {
    item(key = "background.cells.label") {
        SessionSectionLabel(
            text = UiStrings.BACKGROUND_SECTION_CELLS_EN,
            modifier = Modifier.testTag(UiPageTags.BACKGROUND_CELLS),
        )
    }
    val cells = state.cells.orEmpty()
    cells.forEach { cell ->
        item(key = "background.cell.${cell.id}") {
            CellBlock(cell = cell, modifier = Modifier.testTag(UiPageTags.BACKGROUND_CELL_PREFIX + cell.id))
        }
        if (cell.scenario != cells.lastOrNull()?.scenario) {
            item(key = "background.cell.divider.${cell.id}") {
                SessionHairline()
            }
        }
    }
    item(key = "background.cells.note") {
        ProbeNote(
            text = UiStrings.BACKGROUND_SIMULATOR_NOTE,
            ink = ProbeInk.TERTIARY,
            modifier = Modifier
                .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                .testTag(UiPageTags.BACKGROUND_NOTE),
        )
    }
}

/** One matrix-cell block; `MEASURED` is the one status the baseline inks green. */
@Composable
private fun CellBlock(cell: BackgroundCell, modifier: Modifier = Modifier) {
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
                text = cell.scenario?.label() ?: UiStrings.UNKNOWN,
                style = type.caption.copy(
                    color = tokens.colors.primary,
                    fontWeight = FontWeight.SemiBold,
                ),
            )
            BasicText(
                text = when (cell.continuedProcessing) {
                    FactState.YES -> UiStrings.BACKGROUND_CONTINUED_ON
                    FactState.NO -> UiStrings.BACKGROUND_CONTINUED_OFF
                    FactState.UNKNOWN -> UiStrings.UNKNOWN
                },
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = cell.status ?: UiStrings.UNKNOWN,
                style = type.codeLabel.copy(
                    color = if (cell.status == MEASURED) {
                        tokens.colors.success
                    } else {
                        tokens.colors.secondary
                    },
                ),
            )
        }
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_ARM,
            value = cell.arm ?: UiStrings.UNKNOWN,
            valueInk = if (cell.arm == null) ProbeInk.TERTIARY else ProbeInk.SECONDARY,
        )
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_OBSERVED,
            value = secondsText(cell.observedSeconds, decimals = 1),
        )
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_HELD,
            value = cell.heldFullWindow.yesNo(),
        )
        ProbeKeyValue(
            key = UiStrings.BACKGROUND_RECOVERED,
            value = cell.recovered.yesNo(),
        )
        cell.detail?.takeUnless { it.isBlank() }?.let { detail ->
            ProbeNote(text = detail, ink = ProbeInk.SECONDARY)
        }
    }
}

/** The transition log, last 14 only; every timestamp is the host's. */
private fun LazyListScope.transitionsSection(state: BackgroundScreenState) {
    item(key = "background.transitions.label") {
        SessionSectionLabel(
            text = UiStrings.BACKGROUND_SECTION_TRANSITIONS_EN,
            modifier = Modifier.testTag(UiPageTags.BACKGROUND_TRANSITIONS),
        )
    }
    val transitions = state.transitions
    when {
        transitions == null -> item(key = "background.transitions.unknown") {
            ProbeNote(
                text = UiStrings.UNKNOWN,
                ink = ProbeInk.TERTIARY,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.BACKGROUND_TRANSITIONS_UNKNOWN),
            )
        }

        transitions.isEmpty() -> item(key = "background.transitions.empty") {
            ProbeNote(
                text = UiStrings.BACKGROUND_TRANSITION_EMPTY,
                ink = ProbeInk.TERTIARY,
                modifier = Modifier
                    .padding(horizontal = LocalUiTokens.current.geometry.pageOuterMarginH)
                    .testTag(UiPageTags.BACKGROUND_TRANSITIONS_EMPTY),
            )
        }

        else -> transitions.takeLast(TRANSITION_LIMIT).forEach { transition ->
            item(key = "background.transition.${transition.id}") {
                val tokens = LocalUiTokens.current
                val type = LocalUiType.current
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = tokens.geometry.pageOuterMarginH,
                            vertical = tokens.spacing.badgeInsetV,
                        )
                        .testTag(UiPageTags.BACKGROUND_TRANSITION_PREFIX + transition.id),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        text = transition.kind,
                        style = type.code.copy(
                            color = tokens.colors.primary,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    )
                    BasicText(
                        text = transition.text(),
                        style = type.caption.copy(color = tokens.colors.secondary),
                    )
                }
            }
        }
    }
}

/** The scenario in words; the enum name never reaches the screen. */
private fun BackgroundScenario.label(): String = when (this) {
    BackgroundScenario.BACKGROUND -> UiStrings.BACKGROUND_SCENARIO_BACKGROUND
    BackgroundScenario.LOCK -> UiStrings.BACKGROUND_SCENARIO_LOCK
}

/** A host boolean in words: yes, no, or 未知 when the host could not read it. */
private fun FactState.yesNo(): String = when (this) {
    FactState.YES -> UiStrings.YES
    FactState.NO -> UiStrings.NO
    FactState.UNKNOWN -> UiStrings.UNKNOWN
}

/**
 * A duration in seconds, or 未知.
 *
 * The formatting is locale-free integer arithmetic on purpose: a
 * locale-formatted decimal would change the decimal separator, and the rendered
 * string is a measured value the sequence tests compare.
 */
private fun secondsText(value: Double?, decimals: Int): String {
    if (value == null) return UiStrings.UNKNOWN
    val unit = if (decimals == 2) 100L else 10L
    val scaled = round(abs(value) * unit).toLong()
    val whole = scaled / unit
    val fraction = (scaled % unit).toString().padStart(decimals, '0')
    val sign = if (value < 0) "-" else ""
    return UiStrings.BACKGROUND_SECONDS.format("$sign$whole.$fraction")
}

/** The transition's text: endpoints, detail and timestamp joined the baseline way. */
private fun BackgroundTransition.text(): String {
    val parts = mutableListOf<String>()
    if (from != null && to != null) parts += "$from -> $to"
    else {
        from?.let { parts += it }
        to?.let { parts += it }
    }
    detail?.takeUnless { it.isBlank() }?.let { parts += it }
    at?.takeUnless { it.isBlank() }?.let { parts += it }
    return if (parts.isEmpty()) UiStrings.UNKNOWN else parts.joinToString(" · ")
}

/** The baseline's `suffix(14)`: the newest fourteen transitions only. */
private const val TRANSITION_LIMIT: Int = 14

/** `MEASURED` is the raw status the baseline inks green. */
private const val MEASURED: String = "MEASURED"

/**
 * Every token this file reads directly; `PageTokenReferenceTest` holds the list
 * equal to the source. The entries come from the segmented pickers, the
 * continued-processing switch, the two run buttons and the matrix-cell block.
 */
internal object BackgroundPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.danger",
        "colors.onAccent",
        "colors.primary",
        "colors.secondary",
        "colors.selector",
        "colors.success",
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "stroke.hairline",
        "typography.caption",
        "typography.code",
        "typography.codeLabel",
        "typography.secondary",
    )
}

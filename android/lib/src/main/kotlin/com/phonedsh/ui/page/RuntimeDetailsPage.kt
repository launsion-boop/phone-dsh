// Runtime details: the engine, WebView, memory budget, power signals and FGS.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row RuntimeDetailsPage (运行时状态、停止与重启;
// entry: 页头运行状态点、设置行; exit: sheet), §3.1 (the ScreenState layer) and
// §5 (`insets`).
//
// The page has no harness event anchor: every fact is a host read, so §3.1 rule 3
// makes the read-only snapshot the UiState-side input and `from(snapshot, local)`
// a pure function. The only local events are the section fold and the stop
// confirmation, which is why the stop/restart and fold sequence replays on the JVM.
//
// Nothing is fabricated. A value the host did not measure renders 未知 with the
// shared explanation, never a zero and never a default tier. The three platform
// rows this page mirrors are `platform.webview-version-gate` (provider, version,
// feature probe; the version is telemetry only), `platform.budgettier-memory`
// (tier chosen once per boot, budget and usage) and `platform.thermal-battery`
// (thermal level plus battery/charging/battery-saver signals; an unread signal is
// never treated as normal). The FGS availability row is the Android signal that
// decides whether a background turn can outlive the foreground.
//
// Since L35 the page is a superset of both baselines, not a port of either. The
// iOS runtime-status page opens with 本次运行 (模型调用 / 输入 Token / 输出 Token)
// and 最近出错 before its stop/restart action; those two groups sit at the top of
// this page, and the five Android diagnostics groups follow. The five are not
// invented here: they are registered as `androidOnly` sections in
// `spec/ui/v1/pages/_android-only-items.json`, the contract's mechanism for a
// group Android must have and the iOS page does not carry (deliberately not
// `_whitelist.json`, which is for platform-forced copy differences). The three
// iOS rows are host reads this host does not perform yet — [RuntimeRunCounts] and
// [RuntimeLastError] are nullable — so an absent read renders 未知 / 读取不到
// instead of borrowing iOS's in-process answer; a measured zero stays a zero.
//
// Geometry: this page adds no length of its own. It reads the page-level tokens
// `geometry.pageOuterMarginH` and `geometry.pageRowMinHeight` for its action and
// note rows (the header and InfoRow floors live in `PageScaffold.kt`), plus the
// list gap through `pageListGap`. No signature-surface geometry is reused here, so
// no `unverified geometry` marker applies; all colours, spacing and type come from
// the token table through `LocalUiTokens`/`LocalUiType`.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsFormRow
import com.phonedsh.ui.surface.SettingsSectionHeader
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * `platform.webview-version-gate` as the host read it.
 *
 * @param provider `WebViewCompat.getCurrentWebViewPackage()`'s package name.
 * @param version the same package's version; telemetry only, never the gate.
 * @param featureGate the boot-time `WebViewFeature.isFeatureSupported` probe.
 * @param featureGateDetail the host's own list of missing features; shown only
 *   when [featureGate] is [FactState.NO].
 */
@Immutable
public data class WebViewRuntime(
    public val provider: String? = null,
    public val version: String? = null,
    public val featureGate: FactState = FactState.UNKNOWN,
    public val featureGateDetail: String? = null,
) {
    /** True when at least one WebView fact was measured. */
    public val hasMeasurement: Boolean
        get() = provider != null || version != null || featureGate != FactState.UNKNOWN
}

/**
 * `platform.budgettier-memory` as the host read it.
 *
 * The tier table is device independent; the tier is chosen once per boot from the
 * device's memory signal. A `null` field is unmeasured, never zero.
 *
 * @param tier the BudgetTable tier key the host selected.
 * @param budgetBytes the tier's quota, in bytes.
 * @param usedBytes what the host measured as used, in bytes.
 */
@Immutable
public data class RuntimeMemory(
    public val tier: String? = null,
    public val budgetBytes: Long? = null,
    public val usedBytes: Long? = null,
) {
    /** True when at least one memory fact was measured. */
    public val hasMeasurement: Boolean
        get() = tier != null || budgetBytes != null || usedBytes != null
}

/**
 * The Android thermal level.
 *
 * The names are the `PowerManager` status values, not the iOS `thermalState`
 * cases: `platform.thermal-battery` records that Android's granularity is coarser
 * and that the conservative mapping table is future spec work, so the page prints
 * the platform's own level instead of inventing an iOS equivalent.
 */
public enum class ThermalLevel {
    NONE,
    LIGHT,
    MODERATE,
    SEVERE,
    CRITICAL,
    EMERGENCY,
    SHUTDOWN,
}

/**
 * `platform.thermal-battery` plus the battery signals that drive the same
 * conservative policy.
 *
 * @param thermal `PowerManager.getCurrentThermalStatus`; `null` when unread.
 * @param batteryPercent 0..100, or `null` when unread.
 * @param charging whether the device is charging; [FactState.UNKNOWN] when unread.
 * @param batterySaver whether the platform battery saver is on; unread when unknown.
 */
@Immutable
public data class RuntimePower(
    public val thermal: ThermalLevel? = null,
    public val batteryPercent: Int? = null,
    public val charging: FactState = FactState.UNKNOWN,
    public val batterySaver: FactState = FactState.UNKNOWN,
) {
    /** True when at least one power fact was measured. */
    public val hasMeasurement: Boolean
        get() = thermal != null || batteryPercent != null ||
            charging != FactState.UNKNOWN || batterySaver != FactState.UNKNOWN
}

/**
 * 本次运行 as the host read it: this run's model requests and token counts.
 *
 * The baseline shows the group only when it has counts (`model.modelRequests >
 * 0 || model.inputTokens > 0 || model.outputTokens > 0`). Android must not read
 * `null` as zero, so the two questions are separated: a `null` counter is 未知
 * (the host did not read it), a measured `0` is a real zero, and [isIdle] is true
 * only when every counter was measured and all of them are zero — the one case
 * the baseline's condition would hide.
 *
 * @param modelRequests how many model requests this run made; `null` when unread.
 * @param inputTokens prompt tokens summed for this run; `null` when unread.
 * @param outputTokens completion tokens summed for this run; `null` when unread.
 */
@Immutable
public data class RuntimeRunCounts(
    public val modelRequests: Long? = null,
    public val inputTokens: Long? = null,
    public val outputTokens: Long? = null,
) {
    /** True when at least one counter was measured. */
    public val hasMeasurement: Boolean
        get() = modelRequests != null || inputTokens != null || outputTokens != null

    /**
     * The baseline's `hasCounts == false`: every counter measured, every one zero.
     *
     * A `null` counter is not zero, so an unread count is never idle.
     */
    public val isIdle: Boolean
        get() = modelRequests == 0L && inputTokens == 0L && outputTokens == 0L
}

/**
 * 最近出错 as the host read it.
 *
 * The baseline renders `model.userFacingError ?? "最近没有出错"`, which folds
 * "no error" and "not read" together because the model is in-process. Android
 * reads the session's last error across the process boundary, so the page keeps
 * the two answers apart: a `null` object means the host never reported the read
 * (the row says 读取不到), while an object with a `null` [message] means the read
 * happened and found no error (the row says 最近没有出错).
 *
 * @param message the last user-facing error, or `null` when the read found none.
 */
@Immutable
public data class RuntimeLastError(public val message: String? = null)

/**
 * The host's read-only runtime snapshot.
 *
 * @param engine whether the local engine is started; unread when unknown.
 * @param uptimeMs how long it has been running, measured by the host. A duration,
 *   not a timestamp: the page never reads a clock.
 * @param webView the WebView facts; `null` when that read did not happen.
 * @param memory the memory budget facts; `null` when that read did not happen.
 * @param power the thermal/battery facts; `null` when that read did not happen.
 * @param foregroundService whether a foreground service can be started.
 * @param foregroundServiceReason the host's own reason when it cannot.
 * @param run this run's model/token counters; `null` when that read did not happen.
 * @param lastError the last user-facing error; `null` when that read did not happen.
 */
@Immutable
public data class RuntimeSnapshot(
    public val engine: FactState = FactState.UNKNOWN,
    public val uptimeMs: Long? = null,
    public val webView: WebViewRuntime? = null,
    public val memory: RuntimeMemory? = null,
    public val power: RuntimePower? = null,
    public val foregroundService: FactState = FactState.UNKNOWN,
    public val foregroundServiceReason: String? = null,
    public val run: RuntimeRunCounts? = null,
    public val lastError: RuntimeLastError? = null,
) {
    /** True when the snapshot carries at least one measured fact. */
    public val hasMeasurement: Boolean
        get() = engine != FactState.UNKNOWN ||
            uptimeMs != null ||
            webView?.hasMeasurement == true ||
            memory?.hasMeasurement == true ||
            power?.hasMeasurement == true ||
            foregroundService != FactState.UNKNOWN ||
            run?.hasMeasurement == true ||
            lastError != null
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one
 *   (未知), while a snapshot with no measured fact is the empty state.
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class RuntimeFacts(
    public val snapshot: RuntimeSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the page distinguishes. */
public enum class RuntimeStatus {
    /** At least one runtime fact was measured. */
    READY,

    /** The host returned a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last host read failed; no fact claim survives it. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知 instead of "nothing". */
    UNKNOWN,
}

/** Which engine action the page offers; [NONE] when the state is not readable. */
public enum class RuntimeAction {
    STOP,
    START,
    NONE,
}

/** How one row draws; the two shapes the baseline page uses. */
public enum class RuntimeRowKind {
    /** A label on the left and a value on the right (every diagnostics row). */
    LABEL_VALUE,

    /**
     * One sentence that fills the row (`最近出错`).
     *
     * The baseline deliberately does not repeat the group title inside the row
     * (`// 组标题已经说了「最近出错」`), so the sentence is the row's whole text.
     */
    TEXT,
}

/** One label/value row, or one sentence row when [kind] is [RuntimeRowKind.TEXT]. */
@Immutable
public data class RuntimeRowView(
    public val id: String,
    public val title: String,
    /** The right-hand value; `null` for a [RuntimeRowKind.TEXT] row. */
    public val value: String?,
    public val tone: PageTone = PageTone.NORMAL,
    /** The explanation under the value; an unmeasured row says why it is 未知. */
    public val subtitle: String? = null,
    public val kind: RuntimeRowKind = RuntimeRowKind.LABEL_VALUE,
)

/** One collapsible runtime group. */
@Immutable
public data class RuntimeSectionView(
    public val id: String,
    public val title: String,
    public val rows: List<RuntimeRowView>,
    public val expanded: Boolean,
)

/**
 * The complete runtime-details screen state.
 *
 * @param status the four-state outcome; [RuntimeStatus.FAILED] wins because a
 *   failed read proves nothing about the values.
 * @param engine the engine fact, kept outside the rows for the action decision.
 * @param engineValue the visible engine word.
 * @param uptimeValue the formatted uptime, or `null` when unmeasured.
 * @param action the offered action; [RuntimeAction.NONE] for an unread state.
 * @param actionLabel the action's copy, or `null` when [action] is [NONE].
 * @param stopConfirmationOpen true while the inline stop confirmation is open.
 * @param sections the visible groups; empty unless [status] is READY. The order is
 *   the baseline's, with the Android-only diagnostics after it: 引擎 (the single
 *   状态 row), 本次运行 (when it is not a measured, idle run), 最近出错, then
 *   WebView / 内存 / 电源与散热 / 前台服务.
 * @param failure the host's failure message, re-shown by the page.
 * @param notes cross-cutting degradation lines.
 * @param hasUnmeasuredValues true when a visible row is 未知, so the page can
 *   explain the word once.
 * @param unmeasuredGroups the titles of the groups that contain an 未知 row, in
 *   block order. The page prints them in ONE line above the blocks: this is the
 *   whole explanation the page gives for an unmeasured value, and every row's
 *   own repeated sentence was removed in favour of it (L76). Empty unless a row
 *   is unmeasured.
 */
@Immutable
public data class RuntimeDetailsScreenState(
    public val status: RuntimeStatus,
    public val engine: FactState,
    public val engineValue: String,
    public val uptimeValue: String?,
    public val action: RuntimeAction,
    public val actionLabel: String?,
    public val stopConfirmationOpen: Boolean,
    public val sections: List<RuntimeSectionView>,
    public val failure: String?,
    public val notes: List<PageNote>,
    public val hasUnmeasuredValues: Boolean,
    public val unmeasuredGroups: List<String> = emptyList(),
) {
    /** True when the host reported no snapshot at all. */
    public val isUnknown: Boolean get() = status == RuntimeStatus.UNKNOWN

    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == RuntimeStatus.EMPTY

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == RuntimeStatus.FAILED

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * The sequence test compares these strings and then replays the script, so a
     * clock, an I/O read or an engine call would show up as a mismatch.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append(engine.name).append(':')
        append(action.name).append(':')
        append(if (stopConfirmationOpen) "confirm" else "idle").append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete").append(':')
        append(
            sections.joinToString(",") { section ->
                "${section.id}=${if (section.expanded) "1" else "0"}"
            },
        )
    }

    public companion object {
        public const val RUN_SECTION_ID: String = "runtime.run"
        public const val ERROR_SECTION_ID: String = "runtime.error"
        public const val ENGINE_SECTION_ID: String = "runtime.engine"
        public const val WEBVIEW_SECTION_ID: String = "runtime.webview"
        public const val MEMORY_SECTION_ID: String = "runtime.memory"
        public const val POWER_SECTION_ID: String = "runtime.power"
        public const val FGS_SECTION_ID: String = "runtime.fgs"

        /**
         * Projects (facts, local script) into the screen state.
         *
         * Pure: no clock, no I/O, no engine call. The host supplies uptime as a
         * duration, so the same facts and the same fold/confirmation script always
         * yield the same state sequence (§3.1).
         */
        public fun from(
            facts: RuntimeFacts,
            local: RuntimeLocalState = RuntimeLocalState(),
        ): RuntimeDetailsScreenState {
            val snapshot = facts.snapshot
            val status = when {
                facts.failure != null -> RuntimeStatus.FAILED
                snapshot == null -> RuntimeStatus.UNKNOWN
                !snapshot.hasMeasurement -> RuntimeStatus.EMPTY
                else -> RuntimeStatus.READY
            }
            if (status != RuntimeStatus.READY) {
                return RuntimeDetailsScreenState(
                    status = status,
                    engine = snapshot?.engine ?: FactState.UNKNOWN,
                    engineValue = engineText(snapshot?.engine ?: FactState.UNKNOWN),
                    uptimeValue = snapshot?.uptimeMs?.takeIf { it >= 0 }?.let(::formatUptime),
                    action = RuntimeAction.NONE,
                    actionLabel = null,
                    // A stale confirmation cannot survive a state that offers no stop.
                    stopConfirmationOpen = false,
                    sections = emptyList(),
                    failure = facts.failure,
                    notes = emptyList(),
                    hasUnmeasuredValues = false,
                )
            }
            val measured = requireNotNull(snapshot)
            val engine = measured.engine
            val uptimeMs = measured.uptimeMs?.takeIf { it >= 0 }
            val uptimeValue = uptimeMs?.let(::formatUptime)
            val webView = measured.webView
            val memory = measured.memory
            val power = measured.power
            val foregroundService = measured.foregroundService
            val budget = memory?.budgetBytes?.takeIf { it >= 0 }
            val used = memory?.usedBytes?.takeIf { it >= 0 }
            val overBudget = budget != null && used != null && used > budget
            val batteryPercent = power?.batteryPercent?.takeIf { it in 0..100 }
            val thermal = power?.thermal
            val gate = webView?.featureGate ?: FactState.UNKNOWN
            val runRows = listOf(
                countRow(
                    "runtime.run.requests",
                    UiStrings.RUNTIME_MODEL_REQUESTS,
                    measured.run?.modelRequests,
                ),
                countRow(
                    "runtime.run.input",
                    UiStrings.RUNTIME_INPUT_TOKENS,
                    measured.run?.inputTokens,
                ),
                countRow(
                    "runtime.run.output",
                    UiStrings.RUNTIME_OUTPUT_TOKENS,
                    measured.run?.outputTokens,
                ),
            )
            val errorRows = listOf(lastErrorRow(measured.lastError))
            // iOS renders ONE `状态` line above 本次运行 (`ChatPage.swift:4183-4186`)
            // and folds the uptime into its value (`statusValue`, `:4168-4176`):
            // `"运行中 · 已运行2 分钟"`, or a bare `已停止` when the engine is down.
            // The page used to split that line into `状态` + `已运行` rows; the split
            // is gone, and the counters lose the per-row 读取不到 explanation too
            // (see [RuntimeDetailsScreenState.unmeasuredGroups]).
            val engineRows = listOf(
                RuntimeRowView(
                    id = "runtime.engine.status",
                    title = UiStrings.RUNTIME_STATUS,
                    value = statusValue(engine, uptimeValue),
                    tone = engineTone(engine),
                ),
            )
            // Every row below carries its own explanation only when the value was
            // MEASURED (the baseline's own hints). An unmeasured row says 未知 and
            // nothing else: one page-level line names the groups the host did not
            // report, which is where the six repeated 读取不到 sentences went.
            val webViewRows = listOf(
                RuntimeRowView(
                    id = "runtime.webview.provider",
                    title = UiStrings.RUNTIME_WEBVIEW_PROVIDER,
                    value = webView?.provider ?: UiStrings.UNKNOWN,
                    tone = if (webView?.provider == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                RuntimeRowView(
                    id = "runtime.webview.version",
                    title = UiStrings.RUNTIME_WEBVIEW_VERSION,
                    value = webView?.version ?: UiStrings.UNKNOWN,
                    tone = if (webView?.version == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (webView?.version == null) {
                        null
                    } else {
                        UiStrings.RUNTIME_WEBVIEW_VERSION_HINT
                    },
                ),
                RuntimeRowView(
                    id = "runtime.webview.features",
                    title = UiStrings.RUNTIME_WEBVIEW_FEATURES,
                    value = when (gate) {
                        FactState.YES -> UiStrings.RUNTIME_FEATURE_SUPPORTED
                        FactState.NO -> UiStrings.RUNTIME_FEATURE_UNSUPPORTED
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (gate) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.DEGRADED
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                    subtitle = when (gate) {
                        FactState.YES -> UiStrings.RUNTIME_WEBVIEW_FEATURE_HINT
                        FactState.NO -> webView?.featureGateDetail
                            ?: UiStrings.RUNTIME_WEBVIEW_GATE_MISSING
                        FactState.UNKNOWN -> null
                    },
                ),
            )
            val memoryRows = listOf(
                RuntimeRowView(
                    id = "runtime.memory.tier",
                    title = UiStrings.MEMORY_TIER,
                    value = memory?.tier ?: UiStrings.UNKNOWN,
                    tone = if (memory?.tier == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (memory?.tier == null) {
                        null
                    } else {
                        UiStrings.RUNTIME_MEMORY_TIER_HINT
                    },
                ),
                RuntimeRowView(
                    id = "runtime.memory.budget",
                    title = UiStrings.RUNTIME_MEMORY_BUDGET,
                    value = budget?.let(::formatByteSize) ?: UiStrings.UNKNOWN,
                    tone = if (budget == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                RuntimeRowView(
                    id = "runtime.memory.used",
                    title = UiStrings.MEMORY_USED,
                    value = used?.let(::formatByteSize) ?: UiStrings.UNKNOWN,
                    tone = when {
                        overBudget -> PageTone.DEGRADED
                        used == null -> PageTone.UNKNOWN
                        else -> PageTone.NORMAL
                    },
                ),
            )
            val powerRows = listOf(
                RuntimeRowView(
                    id = "runtime.power.thermal",
                    title = UiStrings.RUNTIME_THERMAL,
                    value = thermal?.let(::thermalText) ?: UiStrings.UNKNOWN,
                    tone = when {
                        thermal == null -> PageTone.UNKNOWN
                        thermal >= ThermalLevel.SEVERE -> PageTone.DEGRADED
                        else -> PageTone.NORMAL
                    },
                    subtitle = if (thermal == null) {
                        null
                    } else {
                        UiStrings.RUNTIME_THERMAL_HINT
                    },
                ),
                RuntimeRowView(
                    id = "runtime.power.battery",
                    title = UiStrings.RUNTIME_BATTERY,
                    value = batteryPercent?.let { UiStrings.RUNTIME_BATTERY_PERCENT.format(it) }
                        ?: UiStrings.UNKNOWN,
                    tone = if (batteryPercent == null) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                RuntimeRowView(
                    id = "runtime.power.charging",
                    title = UiStrings.RUNTIME_CHARGING,
                    value = chargingValue(power?.charging ?: FactState.UNKNOWN),
                    tone = if ((power?.charging ?: FactState.UNKNOWN) == FactState.UNKNOWN) {
                        PageTone.UNKNOWN
                    } else {
                        PageTone.NORMAL
                    },
                ),
                RuntimeRowView(
                    id = "runtime.power.saver",
                    title = UiStrings.RUNTIME_BATTERY_SAVER,
                    value = saverValue(power?.batterySaver ?: FactState.UNKNOWN),
                    tone = if ((power?.batterySaver ?: FactState.UNKNOWN) == FactState.UNKNOWN) {
                        PageTone.UNKNOWN
                    } else {
                        PageTone.NORMAL
                    },
                ),
            )
            val fgsRows = listOf(
                RuntimeRowView(
                    id = "runtime.fgs.available",
                    title = UiStrings.RUNTIME_FGS,
                    value = when (foregroundService) {
                        FactState.YES -> UiStrings.RUNTIME_FGS_AVAILABLE
                        FactState.NO -> UiStrings.UNAVAILABLE
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (foregroundService) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.DEGRADED
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                    subtitle = when (foregroundService) {
                        FactState.YES -> UiStrings.RUNTIME_FGS_AVAILABLE_HINT
                        FactState.NO -> measured.foregroundServiceReason
                            ?: UiStrings.RUNTIME_FGS_UNAVAILABLE_HINT
                        FactState.UNKNOWN -> null
                    },
                ),
            )
            // The baseline's block order, with the Android-only diagnostics after
            // the blocks it does draw: 状态 (`:4183`), 本次运行 (`:4194`), 最近出错
            // (`:4208`), the stop/start action (`:4211-4231`) and its footer
            // (`:4232`), then WebView / 内存 / 电源与散热 / 前台服务 — the four
            // `androidOnly` groups `spec/ui/v1/pages/_android-only-items.json`
            // registers. 本次运行 still hides itself when the baseline's
            // `hasCounts` is false (a measured, all-zero run).
            val runVisible = measured.run?.isIdle != true
            val sections = buildList {
                add(
                    RuntimeSectionView(
                        ENGINE_SECTION_ID,
                        UiStrings.RUNTIME_SECTION_ENGINE,
                        engineRows,
                        true,
                    ),
                )
                if (runVisible) {
                    add(
                        RuntimeSectionView(
                            RUN_SECTION_ID,
                            UiStrings.RUNTIME_SECTION_RUN,
                            runRows,
                            true,
                        ),
                    )
                }
                add(
                    RuntimeSectionView(
                        ERROR_SECTION_ID,
                        UiStrings.RUNTIME_SECTION_ERROR,
                        errorRows,
                        true,
                    ),
                )
                add(RuntimeSectionView(WEBVIEW_SECTION_ID, UiStrings.RUNTIME_SECTION_WEBVIEW, webViewRows, true))
                add(RuntimeSectionView(MEMORY_SECTION_ID, UiStrings.RUNTIME_SECTION_MEMORY, memoryRows, true))
                add(RuntimeSectionView(POWER_SECTION_ID, UiStrings.RUNTIME_SECTION_POWER, powerRows, true))
                add(RuntimeSectionView(FGS_SECTION_ID, UiStrings.RUNTIME_SECTION_FGS, fgsRows, true))
            }.map { section ->
                section.copy(expanded = local.fold.isExpanded(section.id))
            }
            val action = when (engine) {
                FactState.YES -> RuntimeAction.STOP
                FactState.NO -> RuntimeAction.START
                FactState.UNKNOWN -> RuntimeAction.NONE
            }
            val notes = buildList {
                if (overBudget) {
                    add(
                        PageNote(
                            id = "runtime.memory.over",
                            text = UiStrings.RUNTIME_MEMORY_OVER_BUDGET,
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (gate == FactState.NO) {
                    add(
                        PageNote(
                            id = "runtime.webview.gate",
                            text = UiStrings.RUNTIME_WEBVIEW_GATE_MISSING,
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (thermal != null && thermal >= ThermalLevel.SEVERE) {
                    add(
                        PageNote(
                            id = "runtime.thermal.pressure",
                            text = UiStrings.RUNTIME_THERMAL_PRESSURE,
                            tone = PageTone.DEGRADED,
                        ),
                    )
                }
                if (engine == FactState.UNKNOWN) {
                    add(
                        PageNote(
                            id = "runtime.engine.unknown",
                            text = UiStrings.RUNTIME_ENGINE_UNKNOWN_HINT,
                            tone = PageTone.UNKNOWN,
                        ),
                    )
                }
            }
            // ONE answer for every unmeasured value (L76): the groups whose rows
            // are 未知, in block order. The page renders this list once, above the
            // blocks; no row repeats the sentence. The baseline has no such line —
            // it is the Android replacement for a read the baseline performs
            // in-process, and it is the only place that says it.
            val unmeasuredGroups = sections
                .filter { section -> section.rows.any { row -> row.tone == PageTone.UNKNOWN } }
                .map { section -> section.title }
            return RuntimeDetailsScreenState(
                status = RuntimeStatus.READY,
                engine = engine,
                engineValue = engineText(engine),
                uptimeValue = uptimeValue,
                action = action,
                actionLabel = when (action) {
                    RuntimeAction.STOP -> UiStrings.RUNTIME_STOP
                    RuntimeAction.START -> UiStrings.RUNTIME_START
                    RuntimeAction.NONE -> null
                },
                stopConfirmationOpen = local.stopConfirmationOpen && action == RuntimeAction.STOP,
                sections = sections,
                failure = null,
                notes = notes,
                hasUnmeasuredValues = unmeasuredGroups.isNotEmpty(),
                unmeasuredGroups = unmeasuredGroups,
            )
        }

        private fun engineText(state: FactState): String = when (state) {
            FactState.YES -> UiStrings.RUNNING
            FactState.NO -> UiStrings.RUNTIME_STOPPED
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

        /**
         * The baseline's one `状态` line (`ChatPage.swift:4168-4176`, `:4183-4186`).
         *
         * `statusValue` is `"\(displayStatus) · 已运行\(elapsed)"` and needs a
         * `startedAt`; when the model has none it falls back to the bare
         * `displayStatus`. Android's equivalent is "engine started + a measured
         * uptime": no uptime means the bare word, a stopped engine means 已停止,
         * and an unread engine means 未知 — never an invented duration.
         */
        private fun statusValue(state: FactState, uptime: String?): String = when {
            state == FactState.UNKNOWN -> UiStrings.UNKNOWN
            state == FactState.NO -> UiStrings.RUNTIME_STOPPED
            uptime == null -> UiStrings.RUNNING
            else -> UiStrings.RUNTIME_STATUS_UPTIME_FORMAT.format(UiStrings.RUNNING, uptime)
        }

        /** One counter: a measured number, or a bare 未知 (the page explains it once). */
        private fun countRow(id: String, title: String, value: Long?): RuntimeRowView =
            RuntimeRowView(
                id = id,
                title = title,
                value = value?.toString() ?: UiStrings.UNKNOWN,
                tone = if (value == null) PageTone.UNKNOWN else PageTone.NORMAL,
            )

        /**
         * The one sentence under 最近出错.
         *
         * Three answers, never two: a missing object is "the host did not report
         * the read" (读取不到), a null message is "the read found no error"
         * (最近没有出错), and a message is the error. The baseline folds the first
         * two together because its model is in-process; Android must not borrow
         * 最近没有出错 for a read that never happened.
         */
        private fun lastErrorRow(error: RuntimeLastError?): RuntimeRowView {
            val message = error?.message
            return when {
                error == null -> RuntimeRowView(
                    id = "runtime.error.last",
                    title = UiStrings.RUNTIME_ERROR_UNREAD,
                    value = null,
                    tone = PageTone.UNKNOWN,
                    kind = RuntimeRowKind.TEXT,
                )
                message == null -> RuntimeRowView(
                    id = "runtime.error.last",
                    title = UiStrings.RUNTIME_NO_ERROR,
                    value = null,
                    kind = RuntimeRowKind.TEXT,
                )
                else -> RuntimeRowView(
                    id = "runtime.error.last",
                    title = message,
                    value = null,
                    tone = PageTone.DEGRADED,
                    kind = RuntimeRowKind.TEXT,
                )
            }
        }

        private fun engineTone(state: FactState): PageTone = when (state) {
            FactState.YES -> PageTone.ON
            FactState.NO -> PageTone.NORMAL
            FactState.UNKNOWN -> PageTone.UNKNOWN
        }

        private fun chargingValue(state: FactState): String = when (state) {
            FactState.YES -> UiStrings.RUNTIME_CHARGING_ON
            FactState.NO -> UiStrings.RUNTIME_CHARGING_OFF
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

        private fun saverValue(state: FactState): String = when (state) {
            FactState.YES -> UiStrings.RUNTIME_BATTERY_SAVER_ON
            FactState.NO -> UiStrings.RUNTIME_BATTERY_SAVER_OFF
            FactState.UNKNOWN -> UiStrings.UNKNOWN
        }

        private fun thermalText(level: ThermalLevel): String = when (level) {
            ThermalLevel.NONE -> UiStrings.RUNTIME_THERMAL_NONE
            ThermalLevel.LIGHT -> UiStrings.RUNTIME_THERMAL_LIGHT
            ThermalLevel.MODERATE -> UiStrings.RUNTIME_THERMAL_MODERATE
            ThermalLevel.SEVERE -> UiStrings.RUNTIME_THERMAL_SEVERE
            ThermalLevel.CRITICAL -> UiStrings.RUNTIME_THERMAL_CRITICAL
            ThermalLevel.EMERGENCY -> UiStrings.RUNTIME_THERMAL_EMERGENCY
            ThermalLevel.SHUTDOWN -> UiStrings.RUNTIME_THERMAL_SHUTDOWN
        }
    }
}

/**
 * Formats an engine uptime in the baseline's words.
 *
 * Pure and locale-free by construction: the host supplies a duration and the
 * rendering is identical on every host. A negative duration is a caller bug.
 */
public fun formatUptime(millis: Long): String {
    require(millis >= 0) { "an uptime is never negative" }
    val seconds = millis / 1000
    return when {
        seconds < 60 -> UiStrings.RUNTIME_UPTIME_UNDER_MINUTE
        seconds < 3600 -> UiStrings.RUNTIME_UPTIME_MINUTES.format(seconds / 60)
        else -> {
            val hours = seconds / 3600
            val minutes = (seconds % 3600) / 60
            if (minutes == 0L) {
                UiStrings.RUNTIME_UPTIME_HOURS.format(hours)
            } else {
                UiStrings.RUNTIME_UPTIME_HOURS_MINUTES.format(hours, minutes)
            }
        }
    }
}

/** The local UI events of the runtime page: a fold and the stop confirmation. */
public sealed interface RuntimeUiEvent {
    /** Collapse or expand one section. */
    public data class ToggleSection(public val id: String) : RuntimeUiEvent

    /** Open the inline stop confirmation. */
    public data object RequestStop : RuntimeUiEvent

    /** Close the confirmation without stopping. */
    public data object CancelStop : RuntimeUiEvent

    /** The user confirmed; the host performs the stop and re-projects. */
    public data object ConfirmStop : RuntimeUiEvent
}

/**
 * The local script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param fold which sections the user collapsed.
 * @param stopConfirmationOpen whether the inline stop confirmation is open.
 */
@Immutable
public data class RuntimeLocalState(
    public val fold: FoldState = FoldState(),
    public val stopConfirmationOpen: Boolean = false,
) {
    /** Applies one local event. */
    public fun apply(event: RuntimeUiEvent): RuntimeLocalState = when (event) {
        is RuntimeUiEvent.ToggleSection -> copy(fold = fold.toggle(event.id))
        RuntimeUiEvent.RequestStop -> copy(stopConfirmationOpen = true)
        RuntimeUiEvent.CancelStop -> copy(stopConfirmationOpen = false)
        RuntimeUiEvent.ConfirmStop -> copy(stopConfirmationOpen = false)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The runtime-details sheet.
 *
 * @param state the pure screen state (`RuntimeDetailsScreenState.from`).
 * @param onBack leave the sheet.
 * @param onToggleSection a section header was tapped; the host applies
 *   `RuntimeUiEvent.ToggleSection` and re-projects.
 * @param onRequestStop open the stop confirmation.
 * @param onCancelStop close it without stopping.
 * @param onConfirmStop stop the local engine; the host re-reads the snapshot.
 * @param onRestart start a stopped engine.
 * @param onRetry retry the failed read; `null` renders no retry row.
 * @param onDismissFailure dismiss the failure line; `null` renders no dismiss row.
 */
@Composable
public fun RuntimeDetailsPage(
    state: RuntimeDetailsScreenState,
    onBack: () -> Unit,
    onToggleSection: (String) -> Unit,
    onRequestStop: () -> Unit,
    onCancelStop: () -> Unit,
    onConfirmStop: () -> Unit,
    onRestart: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissFailure: (() -> Unit)? = null,
) {
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = UiStrings.RUNTIME_TITLE,
        onBack = onBack,
        modifier = modifier,
        rootTag = UiPageTags.RUNTIME_ROOT,
    ) {
        when (state.status) {
            RuntimeStatus.FAILED -> RuntimeFailureBlock(
                failure = state.failure,
                onRetry = onRetry,
                onDismissFailure = onDismissFailure,
            )

            RuntimeStatus.UNKNOWN -> EmptyHint(
                title = UiStrings.RUNTIME_UNKNOWN_STATE,
                hint = UiStrings.RUNTIME_UNKNOWN_HINT,
                tag = UiPageTags.RUNTIME_UNKNOWN,
            )

            RuntimeStatus.EMPTY -> EmptyHint(
                title = UiStrings.RUNTIME_EMPTY,
                hint = UiStrings.RUNTIME_EMPTY_HINT,
                tag = UiPageTags.RUNTIME_EMPTY,
            )

            RuntimeStatus.READY -> RuntimeContent(
                state = state,
                onToggleSection = onToggleSection,
                onRequestStop = onRequestStop,
                onCancelStop = onCancelStop,
                onConfirmStop = onConfirmStop,
                onRestart = onRestart,
            )
        }
    }
}

/** The measured runtime groups, the cross-cutting notes and the engine action. */
@Composable
private fun RuntimeContent(
    state: RuntimeDetailsScreenState,
    onToggleSection: (String) -> Unit,
    onRequestStop: () -> Unit,
    onCancelStop: () -> Unit,
    onConfirmStop: () -> Unit,
    onRestart: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.RUNTIME_LIST),
        verticalArrangement = Arrangement.Top,
    ) {
        if (state.hasUnmeasuredValues) {
            // The page's ONE explanation for every unmeasured value. The baseline
            // has no such sentence (its model is in-process), so this is where the
            // Android read has to say what it could not get — once, and with the
            // group names, instead of the same 读取不到 sentence under 16 rows
            // (6 of them fit on one screen; L64 counted those).
            item(key = "runtime.unmeasured") {
                Column(modifier = Modifier.fillMaxWidth()) {
                    RuntimeNoteRow(
                        text = UiStrings.RUNTIME_UNMEASURED_GROUPS.format(
                            state.unmeasuredGroups.joinToString(
                                UiStrings.RUNTIME_UNMEASURED_GROUPS_SEPARATOR,
                            ),
                        ),
                        tone = PageTone.UNKNOWN,
                        tag = UiPageTags.RUNTIME_UNMEASURED,
                    )
                    RuntimeNoteRow(
                        text = UiStrings.RUNTIME_UNMEASURED_HINT,
                        tone = PageTone.UNKNOWN,
                    )
                }
            }
        }
        state.sections.forEach { section ->
            item(key = "header-${section.id}") {
                // The baseline's `groupHeader` is a bare title (`ChatPage.swift:4150-4160`):
                // no count, no trailing slot. The count Android used to add here was
                // the only "N 项" the baseline page never shows.
                SettingsSectionHeader(
                    title = section.title,
                    expanded = section.expanded,
                    onToggle = { onToggleSection(section.id) },
                    tag = UiPageTags.RUNTIME_SECTION_PREFIX + section.id,
                )
            }
            if (section.expanded) {
                items(count = section.rows.size, key = { index -> section.rows[index].id }) { index ->
                    val row = section.rows[index]
                    when (row.kind) {
                        RuntimeRowKind.LABEL_VALUE -> SettingsFormRow(
                            title = row.title,
                            value = row.value,
                            tone = row.tone,
                            subtitle = row.subtitle,
                        )
                        RuntimeRowKind.TEXT -> RuntimeTextRow(row)
                    }
                }
            }
            // The baseline's stop/start section sits directly under 最近出错
            // (`ChatPage.swift:4211-4231`), before anything else. On Android the
            // four diagnostics-only groups follow it, which is the same relative
            // place the baseline gives the action.
            if (section.id == RuntimeDetailsScreenState.ERROR_SECTION_ID) {
                item(key = "runtime.action") {
                    RuntimeActionBlock(
                        state = state,
                        onRequestStop = onRequestStop,
                        onCancelStop = onCancelStop,
                        onConfirmStop = onConfirmStop,
                        onRestart = onRestart,
                    )
                }
            }
        }
        state.notes.forEach { note ->
            item(key = "note-${note.id}") {
                RuntimeNoteRow(text = note.text, tone = note.tone)
            }
        }
    }
}

/**
 * One sentence row (`最近出错`).
 *
 * The baseline renders this row as a `Text` with the group header already naming
 * the group, so the row carries no second label. The ink is the row's own state:
 * an error is the danger token, an unread read is the unknown ink, and "no error"
 * is secondary ink. It never borrows a tone from the group.
 */
@Composable
private fun RuntimeTextRow(row: RuntimeRowView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when (row.tone) {
        PageTone.DEGRADED -> tokens.colors.danger
        PageTone.UNKNOWN -> tokens.colors.tertiary
        else -> tokens.colors.secondary
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalArrangement = Arrangement.Center,
    ) {
        BasicText(text = row.title, style = type.body.copy(color = ink))
        if (row.subtitle != null) {
            BasicText(
                text = row.subtitle,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
    }
}

/**
 * The stop/restart affordance.
 *
 * The confirmation is inline rather than a dialog: the ScreenState then carries
 * the confirmation itself, so the same `(facts, script)` replay proves the
 * confirmation opens and closes without a window or a clock.
 */
@Composable
private fun RuntimeActionBlock(
    state: RuntimeDetailsScreenState,
    onRequestStop: () -> Unit,
    onCancelStop: () -> Unit,
    onConfirmStop: () -> Unit,
    onRestart: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    if (state.stopConfirmationOpen) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(UiPageTags.RUNTIME_STOP_CONFIRM),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = UiStrings.RUNTIME_STOP_CONFIRM,
                style = type.body.copy(color = tokens.colors.primary),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    ),
            )
            BasicText(
                text = UiStrings.RUNTIME_STOP_CONFIRM_DETAIL,
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = tokens.geometry.pageOuterMarginH),
            )
            RuntimeActionRow(
                // The baseline's confirmation key is the short 停止, not the row's
                // 停止本地引擎: the group already says what is being stopped
                // (ChatPage.swift:4247, `Button("停止", role: .destructive)`).
                label = UiStrings.STOP,
                tag = UiPageTags.RUNTIME_STOP_CONFIRM_ACTION,
                danger = true,
                onClick = onConfirmStop,
            )
            RuntimeActionRow(
                label = UiStrings.CANCEL,
                tag = UiPageTags.RUNTIME_STOP_CANCEL,
                danger = false,
                onClick = onCancelStop,
            )
        }
        return
    }
    when (state.action) {
        RuntimeAction.STOP -> RuntimeActionRow(
            label = UiStrings.RUNTIME_STOP,
            tag = UiPageTags.RUNTIME_STOP,
            danger = true,
            onClick = onRequestStop,
        )

        RuntimeAction.START -> RuntimeActionRow(
            label = UiStrings.RUNTIME_START,
            tag = UiPageTags.RUNTIME_START,
            danger = false,
            onClick = onRestart,
        )

        RuntimeAction.NONE -> Unit
    }
    // The baseline's footer belongs to the action's Section, not to the stop
    // branch: it renders under 启动本地引擎 too (`ChatPage.swift:4231-4234`).
    if (state.action != RuntimeAction.NONE) {
        RuntimeNoteRow(text = UiStrings.RUNTIME_STOP_FOOTER, tone = PageTone.NORMAL)
    }
}

/** One full-width action row; the ink is a token, the floor a page-level token. */
@Composable
private fun RuntimeActionRow(
    label: String,
    tag: String,
    danger: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick)
            // Page-level geometry: an action is a page row, not a signature button.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = type.body.copy(
                color = if (danger) tokens.colors.danger else tokens.colors.accent,
            ),
        )
    }
}

/** One explanatory line; the tone is never a second colour source. */
@Composable
private fun RuntimeNoteRow(
    text: String,
    tone: PageTone,
    tag: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tone.ink(tokens)),
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The failure line: the host's message, a retry row and a dismiss row. */
@Composable
private fun RuntimeFailureBlock(
    failure: String?,
    onRetry: (() -> Unit)?,
    onDismissFailure: (() -> Unit)?,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        SettingsFormRow(
            title = UiStrings.RUNTIME_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.RUNTIME_FAILURE),
        )
        if (onRetry != null) {
            SettingsFormRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.RUNTIME_RETRY),
            )
        }
        if (onDismissFailure != null) {
            SettingsFormRow(
                title = UiStrings.DISMISS,
                value = null,
                onClick = onDismissFailure,
                modifier = Modifier.testTag(UiPageTags.RUNTIME_DISMISS),
            )
        }
    }
}

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object RuntimeDetailsTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.danger",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "geometry.pageRowMinHeight",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
    )
}

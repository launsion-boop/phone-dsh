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
) {
    /** True when the snapshot carries at least one measured fact. */
    public val hasMeasurement: Boolean
        get() = engine != FactState.UNKNOWN ||
            uptimeMs != null ||
            webView?.hasMeasurement == true ||
            memory?.hasMeasurement == true ||
            power?.hasMeasurement == true ||
            foregroundService != FactState.UNKNOWN
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

/** One label/value row. */
@Immutable
public data class RuntimeRowView(
    public val id: String,
    public val title: String,
    public val value: String,
    public val tone: PageTone = PageTone.NORMAL,
    /** The explanation under the value; an unmeasured row says why it is 未知. */
    public val subtitle: String? = null,
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
 * @param sections the visible groups; empty unless [status] is READY.
 * @param failure the host's failure message, re-shown by the page.
 * @param notes cross-cutting degradation lines.
 * @param hasUnmeasuredValues true when a visible row is 未知, so the page can
 *   explain the word once.
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
            val engineRows = listOf(
                RuntimeRowView(
                    id = "runtime.engine.status",
                    title = UiStrings.RUNTIME_STATUS,
                    value = engineText(engine),
                    tone = engineTone(engine),
                    subtitle = if (engine == FactState.UNKNOWN) {
                        UiStrings.SETTINGS_UNKNOWN_HINT
                    } else {
                        null
                    },
                ),
                RuntimeRowView(
                    id = "runtime.engine.uptime",
                    title = UiStrings.RUNTIME_UPTIME,
                    value = uptimeValue ?: UiStrings.UNKNOWN,
                    tone = if (uptimeValue == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (uptimeValue == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
                ),
            )
            val webViewRows = listOf(
                RuntimeRowView(
                    id = "runtime.webview.provider",
                    title = UiStrings.RUNTIME_WEBVIEW_PROVIDER,
                    value = webView?.provider ?: UiStrings.UNKNOWN,
                    tone = if (webView?.provider == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (webView?.provider == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
                ),
                RuntimeRowView(
                    id = "runtime.webview.version",
                    title = UiStrings.RUNTIME_WEBVIEW_VERSION,
                    value = webView?.version ?: UiStrings.UNKNOWN,
                    tone = if (webView?.version == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (webView?.version == null) {
                        UiStrings.SETTINGS_UNKNOWN_HINT
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
                        FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
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
                        UiStrings.SETTINGS_UNKNOWN_HINT
                    } else {
                        UiStrings.RUNTIME_MEMORY_TIER_HINT
                    },
                ),
                RuntimeRowView(
                    id = "runtime.memory.budget",
                    title = UiStrings.RUNTIME_MEMORY_BUDGET,
                    value = budget?.let(::formatByteSize) ?: UiStrings.UNKNOWN,
                    tone = if (budget == null) PageTone.UNKNOWN else PageTone.NORMAL,
                    subtitle = if (budget == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
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
                    subtitle = if (used == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
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
                        UiStrings.SETTINGS_UNKNOWN_HINT
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
                    subtitle = if (batteryPercent == null) UiStrings.SETTINGS_UNKNOWN_HINT else null,
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
                    subtitle = if ((power?.charging ?: FactState.UNKNOWN) == FactState.UNKNOWN) {
                        UiStrings.SETTINGS_UNKNOWN_HINT
                    } else {
                        null
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
                    subtitle = if ((power?.batterySaver ?: FactState.UNKNOWN) == FactState.UNKNOWN) {
                        UiStrings.SETTINGS_UNKNOWN_HINT
                    } else {
                        null
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
                        FactState.UNKNOWN -> UiStrings.SETTINGS_UNKNOWN_HINT
                    },
                ),
            )
            val sections = listOf(
                RuntimeSectionView(ENGINE_SECTION_ID, UiStrings.RUNTIME_SECTION_ENGINE, engineRows, true),
                RuntimeSectionView(WEBVIEW_SECTION_ID, UiStrings.RUNTIME_SECTION_WEBVIEW, webViewRows, true),
                RuntimeSectionView(MEMORY_SECTION_ID, UiStrings.RUNTIME_SECTION_MEMORY, memoryRows, true),
                RuntimeSectionView(POWER_SECTION_ID, UiStrings.RUNTIME_SECTION_POWER, powerRows, true),
                RuntimeSectionView(FGS_SECTION_ID, UiStrings.RUNTIME_SECTION_FGS, fgsRows, true),
            ).map { section ->
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
            val hasUnmeasuredValues = sections.any { section ->
                section.rows.any { row -> row.tone == PageTone.UNKNOWN }
            }
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
                hasUnmeasuredValues = hasUnmeasuredValues,
            )
        }

        private fun engineText(state: FactState): String = when (state) {
            FactState.YES -> UiStrings.RUNNING
            FactState.NO -> UiStrings.RUNTIME_STOPPED
            FactState.UNKNOWN -> UiStrings.UNKNOWN
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
    PageFrame(
        title = UiStrings.RUNTIME_TITLE,
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
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.hasUnmeasuredValues) {
            item(key = "runtime.unmeasured") {
                RuntimeNoteRow(
                    text = UiStrings.RUNTIME_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    tag = UiPageTags.RUNTIME_UNMEASURED,
                )
            }
        }
        state.sections.forEach { section ->
            item(key = "header-${section.id}") {
                SectionHeader(
                    title = section.title,
                    expanded = section.expanded,
                    onToggle = { onToggleSection(section.id) },
                    trailing = UiStrings.ROW_COUNT.format(section.rows.size),
                    tag = UiPageTags.RUNTIME_SECTION_PREFIX + section.id,
                )
            }
            if (section.expanded) {
                items(count = section.rows.size, key = { index -> section.rows[index].id }) { index ->
                    val row = section.rows[index]
                    InfoRow(
                        title = row.title,
                        value = row.value,
                        tone = row.tone,
                        subtitle = row.subtitle,
                    )
                }
            }
        }
        state.notes.forEach { note ->
            item(key = "note-${note.id}") {
                RuntimeNoteRow(text = note.text, tone = note.tone)
            }
        }
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
                label = UiStrings.RUNTIME_STOP,
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
        RuntimeAction.STOP -> {
            RuntimeActionRow(
                label = UiStrings.RUNTIME_STOP,
                tag = UiPageTags.RUNTIME_STOP,
                danger = true,
                onClick = onRequestStop,
            )
            RuntimeNoteRow(text = UiStrings.RUNTIME_STOP_FOOTER, tone = PageTone.NORMAL)
        }

        RuntimeAction.START -> RuntimeActionRow(
            label = UiStrings.RUNTIME_START,
            tag = UiPageTags.RUNTIME_START,
            danger = false,
            onClick = onRestart,
        )

        RuntimeAction.NONE -> Unit
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
        InfoRow(
            title = UiStrings.RUNTIME_FAILED,
            value = null,
            subtitle = failure,
            modifier = Modifier.testTag(UiPageTags.RUNTIME_FAILURE),
        )
        if (onRetry != null) {
            InfoRow(
                title = UiStrings.RETRY,
                value = null,
                onClick = onRetry,
                modifier = Modifier.testTag(UiPageTags.RUNTIME_RETRY),
            )
        }
        if (onDismissFailure != null) {
            InfoRow(
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
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "geometry.pageRowMinHeight",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
    )
}

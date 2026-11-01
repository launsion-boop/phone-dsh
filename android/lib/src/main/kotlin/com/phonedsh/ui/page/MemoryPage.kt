// Memory: the iOS memory-pressure probe, card for card.
// SPDX-License-Identifier: MIT
//
// Authority: examples/probe-app/PhoneDSHProbe/MemoryPage.swift. That page is not a
// memory-entries list: it boots the host with the packed Worker image and a
// synthetic overlay, runs a scripted long session, and records the WebContent
// termination count plus process proxy metrics. Its body is six cards, in order:
// Worker bundle, Overlay levels, Progress, Live samples, Measured levels, Session.
// Every card and every line below mirrors that order and that copy, which is
// English in the baseline and is kept verbatim.
//
// `spec/ui/v1/README.md` §1 still describes MemoryPage as 记忆条目与来源. The iOS
// page never listed memory entries; the description is a spec error and this file
// follows the Swift authority, as the mirror rules require. The old strings stay
// in `UiStrings` (that file is append-only) but this page no longer uses them.
//
// Data: MemoryFacts is the host's read-only snapshot. Fields the host cannot
// report are null and render the baseline's own "no value" glyph 一, or 未知 for a
// text field the baseline never leaves empty (phase, status). No number is
// invented and no 0 stands in for an unmeasured value.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`, `geometry.statusDotDiameter`) plus the card shell's
// `radius.card` / `spacing.cardInset`, which are the same tokens the baseline's
// PageSection uses (12pt radius, 12pt inset, 12pt between cards).
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.util.Locale

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One live sample: the process footprint and the memory still available at a
 * scripted offset.
 *
 * @param offsetSeconds the scripted stage offset the baseline prints as `t+Ns`.
 * @param footprintBytes the App process footprint, or `null` when unmeasured.
 * @param availableBytes `os_proc_available_memory`, or `null` when unmeasured.
 * @param hostState the host state label the runner recorded; `null` renders 一.
 */
@Immutable
public data class MemorySample(
    public val offsetSeconds: Double,
    public val footprintBytes: Long? = null,
    public val availableBytes: Long? = null,
    public val hostState: String? = null,
)

/**
 * One measured overlay level.
 *
 * @param overlayMB the synthetic overlay size in MB.
 * @param status the probe's own status word (`MEASURED`, `FAILED`, …). The
 *   baseline compares this literal, so a host speaks the same vocabulary.
 */
@Immutable
public data class MemoryLevel(
    public val overlayMB: Int,
    public val status: String,
    public val bootSeconds: Double? = null,
    public val durationSeconds: Double? = null,
    public val webContentTerminations: Int? = null,
    public val peakFootprintBytes: Long? = null,
    public val minAvailableBytes: Long? = null,
    public val sampleCount: Int? = null,
    public val detail: String? = null,
)

/**
 * The scripted session record.
 *
 * @param status the session status word; `null` means unread (rendered 未知).
 */
@Immutable
public data class MemorySession(
    public val status: String? = null,
    public val plannedRestarts: Int? = null,
    public val webContentTerminations: Int? = null,
    public val peakFootprintBytes: Long? = null,
    public val sampleCount: Int? = null,
    public val detail: String? = null,
)

/**
 * The page's read-only input.
 *
 * @param bundleInstalled whether the packed Worker image is installed. `UNKNOWN`
 *   is its own answer: the baseline only knows installed / not installed, so an
 *   unread value says so instead of claiming the bundle is missing.
 * @param bundleDetail the runner's explanation, shown only when the bundle is
 *   not installed; `null` renders 未知.
 * @param lockdown the Lockdown Mode flag; the badge is on every render.
 * @param overlayLevelsMB the levels the host can run; `null` means unread.
 * @param runningLevelMB the level being run right now; `null` while a long
 *   session runs.
 * @param phase the runner's phase word; `null` renders 未知.
 * @param statusText the runner's status line; `null` renders 未知.
 * @param lastRunAt the last run's start, already formatted by the host.
 * @param liveSamples the recorded samples; `null` means unread, `emptyList` means
 *   the run recorded none.
 * @param measuredLevels the measured results; `null` means unread.
 * @param session the scripted session; `null` means unread.
 */
@Immutable
public data class MemoryFacts(
    public val bundleInstalled: FactState = FactState.UNKNOWN,
    public val bundleDetail: String? = null,
    public val lockdown: FactState = FactState.UNKNOWN,
    public val overlayLevelsMB: List<Int>? = null,
    public val runningLevelMB: Int? = null,
    public val isRunning: Boolean = false,
    public val phase: String? = null,
    public val statusText: String? = null,
    public val lastRunAt: String? = null,
    public val liveSamples: List<MemorySample>? = null,
    public val measuredLevels: List<MemoryLevel>? = null,
    public val session: MemorySession? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One key/value line, the baseline's KeyValueLine. */
@Immutable
public data class MemoryLine(public val key: String, public val value: String)

/** One runnable overlay level. */
@Immutable
public data class MemoryRunView(
    public val levelMB: Int,
    public val label: String,
    public val running: Boolean,
)

/** Worker bundle card. */
@Immutable
public data class MemoryBundleView(
    public val stateLine: MemoryLine? = null,
    public val detail: String? = null,
    public val note: String? = null,
    public val lockdown: String? = null,
    public val lockdownTone: PageTone = PageTone.NORMAL,
)

/** Overlay levels card. */
@Immutable
public data class MemoryOverlayView(
    public val runs: List<MemoryRunView> = emptyList(),
    public val unknown: Boolean = false,
    public val note: String = UiStrings.MEMORY_OVERLAY_NOTE,
    public val enabled: Boolean = false,
    public val running: Boolean = false,
)

/** Progress card. */
@Immutable
public data class MemoryProgressView(
    public val lines: List<MemoryLine> = emptyList(),
    public val statusText: String? = null,
)

/** Live samples card. */
@Immutable
public data class MemoryLiveView(
    public val lines: List<MemoryLine> = emptyList(),
    public val empty: Boolean = false,
    public val unknown: Boolean = false,
    public val note: String? = null,
)

/** One measured level block. */
@Immutable
public data class MemoryLevelView(
    public val overlayMB: Int,
    public val title: String,
    public val status: String,
    public val statusTone: PageTone,
    public val lines: List<MemoryLine> = emptyList(),
    public val detail: String? = null,
    public val divider: Boolean = false,
)

/** Measured levels card. */
@Immutable
public data class MemoryMeasuredView(
    public val levels: List<MemoryLevelView> = emptyList(),
    public val unknown: Boolean = false,
)

/** Session card. */
@Immutable
public data class MemorySessionView(
    public val statusLine: MemoryLine? = null,
    public val lines: List<MemoryLine> = emptyList(),
    public val empty: Boolean = false,
    public val note: String = UiStrings.MEMORY_SESSION_EMPTY,
    public val detail: String? = null,
)

/** The complete memory probe screen state. */
@Immutable
public data class MemoryScreenState(
    public val bundle: MemoryBundleView = MemoryBundleView(),
    public val overlay: MemoryOverlayView = MemoryOverlayView(),
    public val progress: MemoryProgressView = MemoryProgressView(),
    public val live: MemoryLiveView = MemoryLiveView(),
    public val measured: MemoryMeasuredView = MemoryMeasuredView(),
    public val session: MemorySessionView = MemorySessionView(),
    /** True while a run is in flight: the only thing the Cancel action reads. */
    public val running: Boolean = false,
) {
    public companion object {
        /** The probe's status words; the baseline compares these literals. */
        public const val STATUS_MEASURED: String = "MEASURED"
        public const val STATUS_FAILED: String = "FAILED"
        public const val STATUS_NOT_VERIFIED: String = "NOT_VERIFIED"

        /** The samples card shows at most the last eight samples. */
        public const val LIVE_SAMPLE_LIMIT: Int = 8

        /** Projects the facts into the six cards; pure, no clock and no I/O. */
        public fun from(facts: MemoryFacts): MemoryScreenState = MemoryScreenState(
            bundle = bundleView(facts),
            overlay = overlayView(facts),
            progress = progressView(facts),
            live = liveView(facts),
            measured = measuredView(facts),
            session = sessionView(facts),
            running = facts.isRunning,
        )

        private fun bundleView(facts: MemoryFacts): MemoryBundleView {
            val lockdown = when (facts.lockdown) {
                FactState.YES -> UiStrings.MEMORY_LOCKDOWN_ON
                FactState.NO -> UiStrings.MEMORY_LOCKDOWN_OFF
                FactState.UNKNOWN -> UiStrings.UNKNOWN
            }
            val lockdownTone = when (facts.lockdown) {
                // Lockdown Mode switches the local harness off: a degradation.
                FactState.YES -> PageTone.DEGRADED
                FactState.NO -> PageTone.NORMAL
                FactState.UNKNOWN -> PageTone.UNKNOWN
            }
            return when (facts.bundleInstalled) {
                FactState.YES -> MemoryBundleView(
                    stateLine = MemoryLine(UiStrings.MEMORY_BUNDLE_KEY, UiStrings.MEMORY_BUNDLE_INSTALLED),
                    note = UiStrings.MEMORY_BUNDLE_REFRESH_NOTE,
                    lockdown = lockdown,
                    lockdownTone = lockdownTone,
                )

                FactState.NO -> MemoryBundleView(
                    detail = facts.bundleDetail ?: UiStrings.UNKNOWN,
                    note = UiStrings.MEMORY_BUNDLE_MISSING_NOTE,
                    lockdown = lockdown,
                    lockdownTone = lockdownTone,
                )

                // Neither branch is true: the row says 未知 and quotes neither note.
                FactState.UNKNOWN -> MemoryBundleView(
                    stateLine = MemoryLine(UiStrings.MEMORY_BUNDLE_KEY, UiStrings.UNKNOWN),
                    lockdown = lockdown,
                    lockdownTone = lockdownTone,
                )
            }
        }

        private fun overlayView(facts: MemoryFacts): MemoryOverlayView {
            val levels = facts.overlayLevelsMB.orEmpty()
            return MemoryOverlayView(
                runs = levels.map { level ->
                    MemoryRunView(
                        levelMB = level,
                        label = UiStrings.MEMORY_RUN_OVERLAY.format(level),
                        running = facts.isRunning && facts.runningLevelMB == level,
                    )
                },
                unknown = facts.overlayLevelsMB == null,
                enabled = !facts.isRunning && facts.bundleInstalled == FactState.YES,
                running = facts.isRunning,
            )
        }

        private fun progressView(facts: MemoryFacts): MemoryProgressView = MemoryProgressView(
            lines = buildList {
                add(MemoryLine(UiStrings.MEMORY_KEY_PHASE, facts.phase ?: UiStrings.UNKNOWN))
                if (facts.lastRunAt != null) {
                    add(MemoryLine(UiStrings.MEMORY_KEY_LAST_RUN, facts.lastRunAt))
                }
            },
            statusText = facts.statusText ?: UiStrings.UNKNOWN,
        )

        private fun liveView(facts: MemoryFacts): MemoryLiveView {
            val samples = facts.liveSamples
            return when {
                samples == null -> MemoryLiveView(
                    lines = listOf(MemoryLine(UiStrings.MEMORY_KEY_SAMPLES, UiStrings.UNKNOWN)),
                    unknown = true,
                )

                samples.isEmpty() -> MemoryLiveView(empty = true, note = UiStrings.MEMORY_LIVE_EMPTY)

                else -> MemoryLiveView(
                    lines = samples.takeLast(LIVE_SAMPLE_LIMIT).map { sample ->
                        MemoryLine(
                            key = UiStrings.MEMORY_SAMPLE_KEY.format(sample.offsetSeconds.toInt()),
                            value = UiStrings.MEMORY_SAMPLE_VALUE.format(
                                bytes(sample.footprintBytes),
                                bytes(sample.availableBytes),
                                sample.hostState ?: UiStrings.MEMORY_UNSET_DASH,
                            ),
                        )
                    },
                    note = UiStrings.MEMORY_LIVE_NOTE,
                )
            }
        }

        private fun measuredView(facts: MemoryFacts): MemoryMeasuredView {
            val levels = facts.measuredLevels
                ?: return MemoryMeasuredView(unknown = true)
            return MemoryMeasuredView(
                levels = levels.mapIndexed { index, level ->
                    val measured = level.status == STATUS_MEASURED || level.status == STATUS_FAILED
                    MemoryLevelView(
                        overlayMB = level.overlayMB,
                        title = UiStrings.MEMORY_LEVEL_MB.format(level.overlayMB),
                        status = level.status,
                        // The baseline inks MEASURED green and every other word secondary.
                        statusTone = if (level.status == STATUS_MEASURED) PageTone.ON else PageTone.NORMAL,
                        lines = if (measured) {
                            listOf(
                                MemoryLine(UiStrings.MEMORY_KEY_BOOT, seconds(level.bootSeconds)),
                                MemoryLine(UiStrings.MEMORY_KEY_DURATION, seconds(level.durationSeconds)),
                                MemoryLine(UiStrings.MEMORY_KEY_WEBCONTENT, count(level.webContentTerminations)),
                                MemoryLine(UiStrings.MEMORY_KEY_PEAK, bytes(level.peakFootprintBytes)),
                                MemoryLine(UiStrings.MEMORY_KEY_MIN_AVAILABLE, bytes(level.minAvailableBytes)),
                                MemoryLine(UiStrings.MEMORY_KEY_SAMPLES, count(level.sampleCount)),
                            )
                        } else {
                            emptyList()
                        },
                        detail = level.detail,
                        divider = index < levels.lastIndex,
                    )
                },
            )
        }

        private fun sessionView(facts: MemoryFacts): MemorySessionView {
            val record = facts.session
            val status = record?.status ?: UiStrings.UNKNOWN
            val statusLine = MemoryLine(UiStrings.MEMORY_KEY_STATUS, status)
            if (record == null) {
                // Unread: the status line says 未知 and neither branch's copy is quoted.
                return MemorySessionView(statusLine = statusLine)
            }
            if (record.status == STATUS_NOT_VERIFIED) {
                return MemorySessionView(
                    statusLine = statusLine,
                    empty = true,
                    note = UiStrings.MEMORY_SESSION_EMPTY,
                    detail = record.detail,
                )
            }
            return MemorySessionView(
                statusLine = statusLine,
                lines = listOf(
                    MemoryLine(UiStrings.MEMORY_KEY_PLANNED_RESTARTS, count(record.plannedRestarts)),
                    MemoryLine(UiStrings.MEMORY_KEY_WEBCONTENT, count(record.webContentTerminations)),
                    MemoryLine(UiStrings.MEMORY_KEY_PEAK, bytes(record.peakFootprintBytes)),
                    MemoryLine(UiStrings.MEMORY_KEY_SAMPLES, count(record.sampleCount)),
                ),
                detail = record.detail,
            )
        }

        /** The baseline's byte formatter: a binary quantity, 一 when unmeasured. */
        private fun bytes(value: Long?): String =
            value?.takeIf { it >= 0 }?.let { formatByteSize(it) } ?: UiStrings.MEMORY_UNSET_DASH

        /** The baseline's duration formatter: two decimals and a space before s. */
        private fun seconds(value: Double?): String =
            value?.let { String.format(Locale.ROOT, "%.2f s", it) } ?: UiStrings.MEMORY_UNSET_DASH

        /** The baseline's optional integer formatter. */
        private fun count(value: Int?): String = value?.toString() ?: UiStrings.MEMORY_UNSET_DASH
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The memory probe page.
 *
 * @param state the pure screen state (`MemoryScreenState.from`).
 * @param onRunOverlay run one synthetic overlay level.
 * @param onRunLongSession run the long scripted session without an overlay.
 * @param onCancel the toolbar's destructive Cancel, disabled unless a run is in
 *   flight (the baseline disables it the same way).
 * @param onBack leave the page.
 */
@Composable
public fun MemoryPage(
    state: MemoryScreenState,
    onRunOverlay: (Int) -> Unit,
    onRunLongSession: () -> Unit,
    onCancel: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    PageFrame(
        title = UiStrings.MEMORY_PROBE_TITLE,
        onBack = onBack,
        modifier = modifier,
        actions = { MemoryCancelAction(enabled = state.running, onCancel = onCancel) },
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.MEMORY_LIST)
                .padding(horizontal = tokens.geometry.pageOuterMarginH),
            // The baseline stacks its cards 12pt apart; tokens.json has no
            // page-level card-stack gap, so the page-level card inset (also 12)
            // carries it instead of borrowing the fail-loud banner's geometry.
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
            contentPadding = PaddingValues(vertical = tokens.spacing.cardInset),
        ) {
            item(key = "bundle") {
                MemorySectionView(title = UiStrings.MEMORY_SECTION_BUNDLE, tag = UiPageTags.MEMORY_BUNDLE) {
                    state.bundle.stateLine?.let { MemoryKeyValueLine(it, tag = UiPageTags.MEMORY_BUNDLE_STATE) }
                    state.bundle.detail?.let { MemoryDetailLine(it, PageTone.DEGRADED) }
                    state.bundle.note?.let { MemoryNoteLine(it) }
                    state.bundle.lockdown?.let { MemoryBadgeLine(it, state.bundle.lockdownTone) }
                }
            }
            item(key = "overlay") {
                MemorySectionView(
                    title = UiStrings.MEMORY_SECTION_OVERLAY,
                    tag = UiPageTags.MEMORY_SECTION_PREFIX + "overlay",
                ) {
                    if (state.overlay.unknown) {
                        MemoryKeyValueLine(
                            MemoryLine(UiStrings.MEMORY_KEY_LEVELS, UiStrings.UNKNOWN),
                            tag = UiPageTags.MEMORY_UNKNOWN,
                        )
                    }
                    state.overlay.runs.forEach { run ->
                        MemoryLevelRow(
                            run = run,
                            enabled = state.overlay.enabled,
                            onClick = { onRunOverlay(run.levelMB) },
                        )
                    }
                    // The one labelled action of this card; the level labels are
                    // dynamic (taken from the state), exactly like the baseline's
                    // `Run \(level) MB overlay` interpolation.
                    MemoryLongSessionRow(
                        label = UiStrings.MEMORY_RUN_LONG,
                        enabled = state.overlay.enabled,
                        onClick = onRunLongSession,
                    )
                    MemoryNoteLine(state.overlay.note)
                }
            }
            item(key = "progress") {
                MemorySectionView(
                    title = UiStrings.MEMORY_SECTION_PROGRESS,
                    tag = UiPageTags.MEMORY_SECTION_PREFIX + "progress",
                ) {
                    state.progress.lines.forEach { line ->
                        MemoryKeyValueLine(line, tag = if (line.key == UiStrings.MEMORY_KEY_PHASE) UiPageTags.MEMORY_PHASE else null)
                    }
                    state.progress.statusText?.let { MemoryNoteLine(it, tag = UiPageTags.MEMORY_STATUS) }
                }
            }
            item(key = "live") {
                MemorySectionView(title = UiStrings.MEMORY_SECTION_LIVE, tag = UiPageTags.MEMORY_LIVE) {
                    when {
                        state.live.empty -> MemoryNoteLine(state.live.note.orEmpty(), tag = UiPageTags.MEMORY_LIVE_EMPTY)
                        state.live.unknown -> state.live.lines.forEach { MemoryKeyValueLine(it, tag = UiPageTags.MEMORY_UNKNOWN) }
                        else -> state.live.lines.forEach { MemoryKeyValueLine(it) }
                    }
                    if (!state.live.empty && !state.live.unknown) {
                        state.live.note?.let { MemoryNoteLine(it) }
                    }
                }
            }
            item(key = "measured") {
                MemorySectionView(
                    title = UiStrings.MEMORY_SECTION_MEASURED,
                    tag = UiPageTags.MEMORY_SECTION_PREFIX + "measured",
                ) {
                    if (state.measured.unknown) {
                        MemoryKeyValueLine(
                            MemoryLine(UiStrings.MEMORY_KEY_LEVELS, UiStrings.UNKNOWN),
                            tag = UiPageTags.MEMORY_UNKNOWN,
                        )
                    }
                    state.measured.levels.forEach { level ->
                        MemoryLevelBlock(level)
                    }
                }
            }
            item(key = "session") {
                MemorySectionView(title = UiStrings.MEMORY_SECTION_SESSION, tag = UiPageTags.MEMORY_SESSION) {
                    state.session.statusLine?.let { MemoryKeyValueLine(it) }
                    state.session.lines.forEach { MemoryKeyValueLine(it) }
                    if (state.session.empty) {
                        MemoryNoteLine(state.session.note)
                    }
                    state.session.detail?.let { MemoryDetailLine(it, PageTone.NORMAL) }
                }
            }
        }
    }
}

/** One card: the baseline's PageSection (radius.card, cardInset, 8pt inner gap). */
@Composable
private fun MemorySectionView(
    title: String,
    tag: String,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(
            text = title,
            style = type.subheadline.copy(color = tokens.colors.secondary),
            modifier = Modifier.semantics { heading() },
        )
        content()
    }
}

/** One measured level: size + status, then its metrics when they exist. */
@Composable
private fun MemoryLevelBlock(level: MemoryLevelView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.MEMORY_LEVEL_PREFIX + level.overlayMB),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = level.title,
                style = type.caption.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = level.status,
                style = type.code.copy(color = level.statusTone.settingsLevelInk(tokens)),
            )
        }
        level.lines.forEach { MemoryKeyValueLine(it) }
        level.detail?.let { MemoryDetailLine(it, PageTone.NORMAL) }
        if (level.divider) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(tokens.stroke.hairline)
                    .background(tokens.colors.border),
            )
        }
    }
}

/** The baseline's KeyValueLine: caption key on the left, mono caption value right. */
@Composable
private fun MemoryKeyValueLine(line: MemoryLine, tag: String? = null) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
    ) {
        BasicText(
            text = line.key,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = line.value,
            style = type.code.copy(color = tokens.colors.secondary),
        )
    }
}

/** A note under a card's rows: caption, secondary ink. */
@Composable
private fun MemoryNoteLine(text: String, tag: String? = null) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
    )
}

/** A failure or result line in a tone's ink. */
@Composable
private fun MemoryDetailLine(text: String, tone: PageTone) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tone.settingsLevelInk(tokens)),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** The Lockdown Mode badge: one line, in the ink its state earns. */
@Composable
private fun MemoryBadgeLine(text: String, tone: PageTone) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tone.settingsLevelInk(tokens)),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.MEMORY_LOCKDOWN),
    )
}

/** One overlay level: an outlined row, disabled while a run is in flight. */
@Composable
private fun MemoryLevelRow(
    run: MemoryRunView,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.MEMORY_RUN_PREFIX + run.levelMB)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .then(if (enabled) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = run.label,
            style = type.secondary.copy(
                color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
            ),
            modifier = Modifier.weight(1f),
        )
        if (run.running) {
            // The baseline shows an indeterminate ProgressView. An animated
            // indicator would keep a Compose test clock busy forever, so the port
            // marks the running row with a static accent dot and the same
            // announcement through the accessibility description.
            Box(
                modifier = Modifier
                    .size(tokens.geometry.statusDotDiameter)
                    .testTag(UiPageTags.MEMORY_RUNNING)
                    .background(tokens.colors.accent, CircleShape)
                    .semantics { contentDescription = UiStrings.MEMORY_RUNNING_LABEL },
            )
        }
    }
}

/** The long scripted session: the card's one labelled action. */
@Composable
private fun MemoryLongSessionRow(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.MEMORY_RUN_LONG)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .then(if (enabled) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.secondary.copy(
                color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
            ),
            modifier = Modifier.weight(1f),
        )
    }
}

/** The toolbar's destructive Cancel; disabled unless a run is in flight. */
@Composable
private fun MemoryCancelAction(enabled: Boolean, onCancel: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = UiStrings.MEMORY_CANCEL,
        style = type.body.copy(
            color = if (enabled) tokens.colors.danger else tokens.colors.tertiary,
        ),
        modifier = Modifier
            .testTag(UiPageTags.MEMORY_CANCEL_TAG)
            .clickable(enabled = enabled, role = Role.Button, onClick = onCancel)
            .padding(tokens.spacing.iconText),
    )
}

/** The ink for a tone on this page; 一 is never inked as a failure. */
private fun PageTone.settingsLevelInk(tokens: com.phonedsh.ui.theme.UiTokens): androidx.compose.ui.graphics.Color =
    when (this) {
        PageTone.NORMAL -> tokens.colors.secondary
        PageTone.ON -> tokens.colors.success
        PageTone.DEGRADED -> tokens.colors.danger
        PageTone.UNKNOWN -> tokens.colors.tertiary
    }

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads. The card shell and the row shapes are page-local here (the baseline's
 * PageSection is not one of the shared row components), so every token they read
 * is listed.
 */
internal object MemoryPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_SUBHEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_CODE_TOOLBAR,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_STATUS_DOT_DIAMETER,
    )
}

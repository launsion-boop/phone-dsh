// Scheduled automation: the catalog, one schedule's detail and its delivery history.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row NativeAutomationPage (定时任务、计划详情与历史;
// entries: 设置 › 定时任务、会话页入口; exit: push; child pages
// ScheduleDetailPage, ScheduleHistoryPage, ScheduleEditorPage), §3.1 (the
// ScreenState layer) and §5 (`insets`).
//
// The page has no harness event anchor: every schedule, time string and delivery
// is a host read, so §3.1 rule 3 makes the read-only snapshot the UiState-side
// input and `from(snapshot, local)` a pure function. The page never reads a
// clock: `nextRun`, `latestDelivery`, `deliveredAt` and `scheduledAt` are already
// formatted by the host, and a missing one renders 未知 with an explanation.
//
// ---------------------------------------------------------------------------
// Structure: the iOS page, element for element
// ---------------------------------------------------------------------------
// `NativeAutomationPage.swift` is one `List` under a 44 pt bar and a 34 pt large
// title:
//
//   .navigationTitle("定时任务")                    -> 34 pt large title (17 pt inset,
//                                                      14 pt below the 44 pt bar)
//   ToolbarItem(.topBarLeading)  refresh            -> leading 刷新, beside the ✕
//   ToolbarItem(.topBarTrailing) 新建 (accent)       -> trailing 新建
//   if scheduleRecords.isEmpty                      -> empty block: 17/600 title,
//                                                      13 pt secondary hint, a
//                                                      50 pt / radius 12 accent
//                                                      CTA (list row + 16 pt inset)
//   else ForEach(scheduleRecords)                   -> one row per schedule
//   if let error = management.error                 -> Section("需要处理") with the
//                                                      host's sentence in red 13 pt
//
// The failure is the structural point this page used to get wrong. On iOS
// `management.error` is a field *beside* `scheduleRecords` (DSHManagementModel
// .swift:120,137): a failed read keeps the catalog the host reported and adds a
// red section under it. The Android page used to fold the failure into a
// page-wide state that dropped the catalog, so the same facts rendered as one
// grey sentence and the empty block, the CTA and the red line never appeared.
// `AutomationScreenState` therefore carries the content outcome and the failure
// as two fields, and the failure never erases a reported list.
//
// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
// The measured iOS boxes (1206 x 2622 px @3, `pt = px / 3`):
//
//   34 pt title ink      y 125.3..155.3, x 17.0
//   empty title ink      y 194.7..209.7, centred (x 142.7..258.7)
//   hint ink             y 222.3..234.7, centred
//   CTA box              y 252.0..301.7 (50 pt), x 32.0..369.7 (337.7 pt), r 12
//   "需要处理" ink        y 356.3..371.3, x 32.7
//   red error ink        y 401.7..431.3, x 32.7, 18 pt line box
//
// The bar, the large title and their insets come from the shared surface chrome
// (`SettingsNavBar`, `SettingsLargeTitle`, `settingsLargeTitleStyle` in
// `ui/surface/SettingsChrome.kt`), the same pieces the five iOS-aligned settings
// sub-pages use; `AutomationFrame` only spells the twelve-line Column around them,
// because iOS puts two controls in the leading slot (✕ and 刷新) and the shared
// frame exposes one. The page therefore does not re-type a bar height, a title
// inset, a title role or a system-bar inset. The empty block reuses L6's measured
// constants: the 8 pt gap and 24 pt vertical padding are
// `ShellFilesMetrics.EMPTY_STATE_*` (the iOS `FilesPage.swift:101,112` values;
// `NativeAutomationPage.swift:19,41` declares the same two numbers), the CTA
// height is `SessionsMetrics.CTA_HEIGHT_PT` (`SessionsPage.swift:223`
// `.frame(height: 50)`; `NativeAutomationPage.swift:14` declares
// `primaryButtonHeight = 50` for the same control), and the CTA's corner is
// `radius.card` (12, `NativeAutomationPage.swift:35`). The section label and the
// red sentence both start at `SettingsSectionLabelIndent` (33 pt), which is the
// measured 32.7 pt of both the 需要处理 header and the error text.
//
// The page body re-uses the page-level tokens (`geometry.pageOuterMarginH`,
// `geometry.pageListRowMinHeight`) and the page's own list gap; it borrows no
// signature-surface geometry, so no `unverified geometry` marker applies.
package com.phonedsh.ui.page

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.SessionsMetrics
import com.phonedsh.ui.ShellFilesMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsLargeTitle
import com.phonedsh.ui.surface.SettingsNavAction
import com.phonedsh.ui.surface.SettingsNavBar
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSectionLabelIndent
import com.phonedsh.ui.surface.SettingsSubPageFootnote
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialSheetColors
import com.phonedsh.ui.theme.LocalUiType
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.UUID

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/** The schedule's state as the host reported it. [UNKNOWN] is not `已停止`. */
public enum class ScheduleStatus {
    ACTIVE,
    STOPPED,
    UNKNOWN,
}

/**
 * One schedule in the host's read-only snapshot.
 *
 * @param id the host's stable id; also the row tag suffix.
 * @param title the schedule name.
 * @param prompt what the scheduled turn will be asked; `null` when unreported.
 * @param status the active/stopped fact; [ScheduleStatus.UNKNOWN] when unread.
 * @param rule the host's rule spelling (`after`, `every`, a cron expression...).
 * @param nextRun the host-formatted next run; the page never computes it.
 * @param latestDelivery the host-formatted last delivery, if one happened.
 * @param sessionTitle the target session's title, if the host resolved it.
 * @param detail an optional host-supplied one-line detail.
 * @param timing the rule's own fields when the host reported them
 *   (`DSHManagementModel.expectedRecord` on the baseline); `null` when the host
 *   only reported the rule's spelling. The editor seeds its form from this and
 *   never invents a value it did not receive.
 */
@Immutable
public data class AutomationSchedule(
    public val id: String,
    public val title: String,
    public val prompt: String? = null,
    public val status: ScheduleStatus = ScheduleStatus.UNKNOWN,
    public val rule: String? = null,
    public val nextRun: String? = null,
    public val latestDelivery: String? = null,
    public val sessionTitle: String? = null,
    public val detail: String? = null,
    public val timing: AutomationTiming? = null,
)

/**
 * One delivery row in a schedule's history.
 *
 * @param id the host's stable id.
 * @param deliveredAt the host-formatted delivery time.
 * @param scheduledAt the host-formatted planned time.
 * @param prompt the delivered prompt, when the host retains it.
 */
@Immutable
public data class AutomationDelivery(
    public val id: String,
    public val deliveredAt: String,
    public val scheduledAt: String,
    public val prompt: String? = null,
)

// ---------------------------------------------------------------------------
// ScheduleEditorPage: the form's facts (`NativeAutomationPage.swift:212`–`:420`)
// ---------------------------------------------------------------------------
//
// The baseline's editor is a `.sheet` over this page (`:92`, `:99`) whose
// `@State` fields are seeded from `ManagedSchedule` and `expectedRecord`
// (`:233`–`:248`), validated by `timingChange()` (`:350`) and reported by
// `timingValidationMessage()` (`:397`). The iOS struct is `private` in
// `NativeAutomationPage.swift` and README §1 makes it an embedded subpage, so the
// port keeps the same three pieces in this file, in the same order: the facts
// (below), the pure draft + its validation, and the composable.

/**
 * The six timing rules the editor's 规则 picker offers
 * (`NativeAutomationPage.swift:264`–`:269`).
 *
 * @param wire the host's spelling, which is also the tag suffix of the option row.
 * @param optionLabel the baseline's visible option word.
 */
public enum class AutomationRule(public val wire: String, public val optionLabel: String) {
    AFTER("after", UiStrings.AUTOMATION_EDITOR_RULE_AFTER),
    AT("at", UiStrings.AUTOMATION_EDITOR_RULE_AT),
    EVERY("every", UiStrings.AUTOMATION_EDITOR_RULE_EVERY),
    DAILY("daily", UiStrings.AUTOMATION_EDITOR_RULE_DAILY),
    WEEKLY("weekly", UiStrings.AUTOMATION_EDITOR_RULE_WEEKLY),
    CRON("cron", UiStrings.AUTOMATION_EDITOR_RULE_CRON),
    ;

    public companion object {
        /** The rule [wire] names, or `null` when the host reported another spelling. */
        public fun fromWire(wire: String?): AutomationRule? =
            values().firstOrNull { rule -> rule.wire == wire }
    }
}

/**
 * One schedule's rule as the host reported its fields.
 *
 * iOS keeps them in `ManagedSchedule.expectedRecord` (`afterSeconds`,
 * `everySeconds`, `time`, `timeZone`, `weekdays`, `expression`), which the editor
 * reads to seed the form. Every field is `null` when the host did not report it,
 * so the editor can tell "not reported" from an empty value.
 */
@Immutable
public data class AutomationTiming(
    public val rule: AutomationRule,
    public val afterSeconds: String? = null,
    public val at: String? = null,
    public val everySeconds: String? = null,
    public val localTime: String? = null,
    public val timeZone: String? = null,
    public val weekdays: String? = null,
    public val cron: String? = null,
)

/**
 * The editable form, as typed.
 *
 * It is the baseline's twelve `@State` fields (`:218`–`:228`) in one value: a new
 * schedule starts from the same defaults the baseline's `init` uses, and an
 * existing one is seeded by [from].
 *
 * Two deliberate differences from the baseline, both because this page is pure
 * (§3.1: no clock, no I/O):
 *
 *  * the 指定时间 field starts **blank** instead of `now + 1h` — the page never
 *    reads a clock, and an invented timestamp would be a value nobody measured.
 *    The baseline's own hint (`:296`) is printed above the field instead;
 *  * the IANA timezone default comes from the caller ([from]'s `timeZone`
 *    argument) rather than `TimeZone.current`: a platform read belongs to the
 *    route, not to the state function.
 *
 * @param id the schedule being edited; `null` for a new one (iOS `schedule == nil`).
 * @param title the 名称 field.
 * @param prompt the 提醒内容 field.
 * @param changeTiming the 修改计划时间 toggle (`:260`); ignored for a new schedule.
 * @param rule the 规则 picker's selection.
 * @param afterSeconds / @param at / @param everySeconds / @param localTime /
 *   @param timeZone / @param weekdays / @param cron the rule's own fields, as typed.
 */
@Immutable
public data class AutomationScheduleDraft(
    public val id: String? = null,
    public val title: String = "",
    public val prompt: String = "",
    public val changeTiming: Boolean = true,
    public val rule: AutomationRule = AutomationRule.AFTER,
    public val afterSeconds: String = DEFAULT_AFTER_SECONDS,
    public val at: String = "",
    public val everySeconds: String = DEFAULT_EVERY_SECONDS,
    public val localTime: String = DEFAULT_LOCAL_TIME,
    public val timeZone: String = "",
    public val weekdays: String = DEFAULT_WEEKDAYS,
    public val cron: String = DEFAULT_CRON,
) {
    /** True for the 新建自动化 form (`schedule == nil`). */
    public val isNew: Boolean get() = id == null

    /**
     * True while the timing block is shown: always for a new schedule, and for an
     * edit only after 修改计划时间 is on (`:262`).
     */
    public val editsTiming: Boolean get() = isNew || changeTiming

    /** iOS disables 保存 while either text field is blank (`:284`–`:285`). */
    public val canSubmit: Boolean get() = title.isNotBlank() && prompt.isNotBlank()

    /**
     * The rule's validation sentence, or `null` when the timing block validates.
     *
     * `null` also when the timing block is not being edited: the baseline sends
     * `timing: nil` then (`:327`, `:333`) and validates nothing.
     */
    public fun timingError(): String? {
        if (!editsTiming) return null
        return when (rule) {
            AutomationRule.AFTER -> if ((afterSeconds.trim().toIntOrNull() ?: 0) > 0) {
                null
            } else {
                UiStrings.AUTOMATION_EDITOR_ERROR_AFTER
            }

            AutomationRule.AT ->
                if (offsetDateTimeOrNull(at) != null) {
                    null
                } else {
                    UiStrings.AUTOMATION_EDITOR_ERROR_AT
                }

            AutomationRule.EVERY -> if ((everySeconds.trim().toIntOrNull() ?: 0) >= MINIMUM_INTERVAL_SECONDS) {
                null
            } else {
                UiStrings.AUTOMATION_EDITOR_ERROR_EVERY
            }

            AutomationRule.DAILY ->
                if (isLocalTime(localTime) && zoneOrNull(timeZone) != null) {
                    null
                } else {
                    UiStrings.AUTOMATION_EDITOR_ERROR_DAILY
                }

            AutomationRule.WEEKLY ->
                if (isLocalTime(localTime) && zoneOrNull(timeZone) != null && parseWeekdays(weekdays) != null) {
                    null
                } else {
                    UiStrings.AUTOMATION_EDITOR_ERROR_WEEKLY
                }

            AutomationRule.CRON ->
                if (cron.split(WHITESPACE).count { it.isNotEmpty() } == CRON_FIELD_COUNT &&
                    zoneOrNull(timeZone) != null
                ) {
                    null
                } else {
                    UiStrings.AUTOMATION_EDITOR_ERROR_CRON
                }
        }
    }

    public companion object {
        /**
         * Seeds a form from a reported schedule, or the baseline's defaults for a
         * new one.
         *
         * @param schedule the schedule to edit; `null` for a new one.
         * @param timeZone the IANA zone the caller measured
         *   (`TimeZone.current.identifier` on the baseline, `:225`). A field the
         *   host reported wins over it.
         */
        public fun from(schedule: AutomationSchedule?, timeZone: String): AutomationScheduleDraft {
            val timing = schedule?.timing
            val reported = timing?.rule ?: AutomationRule.fromWire(schedule?.rule?.substringBefore(' '))
            return AutomationScheduleDraft(
                id = schedule?.id,
                title = schedule?.title.orEmpty(),
                prompt = schedule?.prompt.orEmpty(),
                // The baseline shows the timing block for a new schedule only
                // (`:247`: `changeTiming = schedule == nil`).
                changeTiming = schedule == null,
                rule = reported ?: AutomationRule.AFTER,
                afterSeconds = timing?.afterSeconds ?: DEFAULT_AFTER_SECONDS,
                at = timing?.at.orEmpty(),
                everySeconds = timing?.everySeconds ?: DEFAULT_EVERY_SECONDS,
                localTime = timing?.localTime ?: DEFAULT_LOCAL_TIME,
                timeZone = timing?.timeZone ?: timeZone,
                weekdays = timing?.weekdays ?: DEFAULT_WEEKDAYS,
                cron = timing?.cron ?: DEFAULT_CRON,
            )
        }
    }
}

/** The form's local state: the draft, plus whether 保存 has been attempted. */
@Immutable
public data class AutomationEditorState(
    public val draft: AutomationScheduleDraft,
    /** False until 保存 is pressed; the baseline reports the rule only then (`:320`). */
    public val submitted: Boolean = false,
    /** Per-attempt id; a host receipt must match before the sheet can close. */
    public val submissionID: String? = null,
    /** The form stays locked until the host reports this attempt. */
    public val saving: Boolean = false,
    /** iOS disables 新建保存 when no actual worker session id exists. */
    public val targetAvailable: Boolean = true,
) {
    /** The sentence the 错误 section prints, or `null`. */
    public val error: String? get() = if (submitted) draft.timingError() else null

    /** 保存 is enabled exactly while the two required fields carry text (`:284`). */
    public val canSubmit: Boolean get() = draft.canSubmit && targetAvailable && !saving
}

/**
 * The `指定时间` field's parser.
 *
 * iOS uses `ISO8601DateFormatter` (`:390`–`:395`), which accepts an RFC 3339
 * instant with a mandatory zone designator; `OffsetDateTime.parse` is the same
 * grammar (an offset or `Z` is required, a date alone is refused). The rule the
 * baseline cares about — "需要包含时区" — is therefore enforced on both sides.
 */
internal fun offsetDateTimeOrNull(value: String): OffsetDateTime? =
    runCatching { OffsetDateTime.parse(value.trim()) }.getOrNull()

/** The IANA zone [value] names, or `null` (`TimeZone(identifier:)`, `:364`). */
internal fun zoneOrNull(value: String): ZoneId? = runCatching { ZoneId.of(value.trim()) }.getOrNull()

/** `HH:mm` or `HH:mm:ss[.SSS]`, the baseline's regex (`:386`–`:388`). */
internal fun isLocalTime(value: String): Boolean = LOCAL_TIME_PATTERN.matches(value.trim())

/**
 * The ISO weekdays [value] lists, or `null` when the list is unusable.
 *
 * The baseline splits on `,`, drops tokens that are not integers and then requires
 * a non-empty, duplicate-free list inside `1...7` (`:369`–`:371`). This port
 * refuses an unparsable token instead of dropping it: "1,x,2" is a typo, and
 * silently running on Monday and Tuesday would hide it.
 */
internal fun parseWeekdays(value: String): List<Int>? {
    val tokens = value.split(',').map { it.trim() }.filter { it.isNotEmpty() }
    if (tokens.isEmpty()) return null
    val days = tokens.map { it.toIntOrNull() ?: return null }
    if (days.toSet().size != days.size) return null
    if (days.any { it !in ISO_MIN_WEEKDAY..ISO_MAX_WEEKDAY }) return null
    return days
}

/**
 * One schedule's delivery history as the host reported it.
 *
 * @param scheduleId which schedule this history belongs to.
 * @param deliveries the rows; `null` means the host did not report them, while
 *   `emptyList()` means it reported "none".
 * @param notice the host's own explanation line (for example a retention
 *   notice), never page-invented.
 * @param hasMore whether the host says older rows can still be loaded.
 * @param failure a failure specific to this history read, or `null`.
 */
@Immutable
public data class AutomationHistory(
    public val scheduleId: String,
    public val deliveries: List<AutomationDelivery>? = null,
    public val notice: String? = null,
    public val hasMore: Boolean = false,
    /** Opaque host cursor to pass back as `before` for the next page. */
    public val before: String? = null,
    public val failure: String? = null,
)

/** A write receipt only exists after the host has reread the resulting record. */
@Immutable
public data class AutomationWriteReceipt(
    public val requestID: String,
    public val savedSchedule: AutomationSchedule? = null,
    public val failure: String? = null,
)

/**
 * The host's read-only automation snapshot.
 *
 * @param schedules the catalog; `null` means the list was not reported (未知),
 *   while `emptyList()` is the empty state.
 * @param history the history for the selected schedule, if the host sent one.
 */
@Immutable
public data class AutomationSnapshot(
    public val schedules: List<AutomationSchedule>? = null,
    public val history: AutomationHistory? = null,
)

/**
 * The host's automation facts and verified scheduler responses.
 *
 * @param snapshot the host's snapshot; `null` means no snapshot was reported.
 * @param failure the host's read failure; non-null when the last read failed.
 *   It is carried beside [snapshot], never instead of it: iOS keeps
 *   `scheduleRecords` and sets `error` in the same read (`DSHManagementModel
 *   .swift:702-717`).
 * @param writable whether the host can perform schedule writes.
 * @param writeReceipt a matching save response, with the catalog record the host
 *   reread; the editor remains open until this contains a saved record.
 * @param currentSessionID the active DSH session id for new schedules, if any.
 */
@Immutable
public data class AutomationFacts(
    public val snapshot: AutomationSnapshot? = null,
    public val failure: String? = null,
    public val writable: FactState = FactState.UNKNOWN,
    public val writeReceipt: AutomationWriteReceipt? = null,
    /** Current DSH worker session for a new reminder, never the App chat id. */
    public val currentSessionID: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * The three outcomes the catalog content has.
 *
 * There is deliberately no `FAILED` member. On iOS a failed read is not a
 * content state: it leaves the reported catalog on screen and adds the
 * 需要处理 section, so folding it into this enum would delete the very rows a
 * failure does not disprove. [AutomationScreenState.failure] carries it instead.
 */
public enum class AutomationStatus {
    /** At least one schedule was reported. */
    READY,

    /** The host reported an empty schedule list. */
    EMPTY,

    /** The schedule list was not reported: the page says 未知, never `0 条`. */
    UNKNOWN,
}

/** Which child view of the page is showing. Pure local state, not a UiState node. */
public enum class AutomationRoute {
    CATALOG,
    DETAIL,
    HISTORY,

    /**
     * The embedded `ScheduleEditorPage` (`NativeAutomationPage.swift:212`).
     *
     * The baseline presents it as a `.sheet` over the catalog/detail face; the
     * route state records which page remains underneath the modal.
     */
    EDITOR,
}

/** The four outcomes of one schedule's delivery history. */
public enum class AutomationHistoryStatus {
    READY,
    EMPTY,
    FAILED,
    UNKNOWN,
}

/** One display-ready schedule row. Missing host values are 未知, never a default. */
@Immutable
public data class AutomationScheduleView(
    public val id: String,
    public val title: String,
    public val prompt: String,
    public val statusText: String,
    public val statusTone: PageTone,
    public val ruleText: String,
    public val nextRunText: String,
    public val latestDeliveryText: String,
    /**
     * The host's last delivery, or `null` when it reported none. The detail page's
     * `最近投递：…` line exists only when this is non-null
     * (`NativeAutomationPage.swift:142`–`:145`), which is why the page needs the
     * absence as a fact and not only as the 未知 word.
     */
    public val latestDeliveryAt: String?,
    public val sessionText: String,
    public val detailText: String?,
    /** True when a visible value is 未知, so the page can explain the word once. */
    public val hasUnmeasuredValues: Boolean,
)

/** One display-ready delivery row. */
@Immutable
public data class AutomationDeliveryView(
    public val id: String,
    public val deliveredAt: String,
    public val scheduledAt: String,
    public val prompt: String?,
)

/**
 * The complete automation screen state.
 *
 * @param status the three-state catalog outcome, from the snapshot alone.
 * @param route the pure child route; forced to [AutomationRoute.CATALOG] unless
 *   the catalog is [AutomationStatus.READY], so a stale detail page cannot
 *   outlive the schedule list it belongs to.
 * @param schedules the display-ready catalog rows, in host order.
 * @param scheduleCount the reported count; `null` for 未知, `0` only for a
 *   reported empty list.
 * @param selectedScheduleId the resolved selected id, or `null`.
 * @param detail the selected schedule's display row, or `null` when missing.
 * @param detailMissing true when the local route still points at a schedule the
 *   new snapshot no longer contains; the page then says 任务不存在.
 * @param historyStatus the selected schedule's history outcome.
 * @param deliveries the display-ready delivery rows; empty unless READY.
 * @param historyCount the reported delivery count; `null` when unread.
 * @param historyNotice the host's own history notice, or `null`.
 * @param historyHasMore true while the host offers older rows.
 * @param historyFailure the history-specific failure message, or `null`.
 * @param failure the host's last read failure, or `null`. Orthogonal to
 *   [status]: it renders as the 需要处理 section below whatever content the
 *   snapshot still supports.
 * @param hasUnmeasuredValues true when a visible catalog/detail value is 未知.
 * @param editor the `ScheduleEditorPage`'s form while [route] is
 *   [AutomationRoute.EDITOR]; `null` on every other route.
 * @param writable whether the host can persist a submitted schedule.
 * @param editorReturnRoute the catalog or detail face underneath the sheet.
 * @param writeReceipt the host response used to confirm and dismiss a save.
 */
@Immutable
public data class AutomationScreenState(
    public val status: AutomationStatus,
    public val route: AutomationRoute,
    public val schedules: List<AutomationScheduleView>,
    public val scheduleCount: Int?,
    public val selectedScheduleId: String?,
    public val detail: AutomationScheduleView?,
    public val detailMissing: Boolean,
    public val historyStatus: AutomationHistoryStatus,
    public val deliveries: List<AutomationDeliveryView>,
    public val historyCount: Int?,
    public val historyNotice: String?,
    public val historyHasMore: Boolean,
    public val historyFailure: String?,
    public val failure: String?,
    public val hasUnmeasuredValues: Boolean,
    /** The schedule whose 删除 confirmation is open; `null` when it is closed. */
    public val confirmDeleteId: String? = null,
    public val editor: AutomationEditorState? = null,
    public val writable: FactState = FactState.UNKNOWN,
    /** Route that remains visible beneath the editor sheet. */
    public val editorReturnRoute: AutomationRoute = AutomationRoute.CATALOG,
    /** Opaque cursor from the last history read. */
    public val historyCursor: String? = null,
    /** The latest host write receipt, backed by a catalog record reread. */
    public val writeReceipt: AutomationWriteReceipt? = null,
    /** The actual DSH worker session id, if one is open. */
    public val currentSessionID: String? = null,
) {
    /** True when the catalog list was not reported. */
    public val isUnknown: Boolean get() = status == AutomationStatus.UNKNOWN

    /** True when the host reported an empty catalog. */
    public val isEmpty: Boolean get() = status == AutomationStatus.EMPTY

    /** True when the host reported something to handle; the content stays on screen. */
    public val hasFailure: Boolean get() = failure != null

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * The sequence test compares these strings and then replays the script, so a
     * clock, an I/O read or a schedule store call would show up as a mismatch.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append(route.name).append(':')
        append(selectedScheduleId ?: "-").append(':')
        append(scheduleCount?.toString() ?: "-").append(':')
        append(historyStatus.name).append(':')
        append(historyCount?.toString() ?: "-").append(':')
        append(if (historyHasMore) "more" else "end").append(':')
        append(if (hasFailure) "failure" else "clear").append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete").append(':')
        append(editor?.draft?.rule?.wire ?: "-").append(':')
        append(if (editor?.submitted == true) "submitted" else "draft").append(':')
        append(editor?.submissionID ?: "-").append(':')
        append(editorReturnRoute.name).append(':')
        append(writeReceipt?.requestID ?: "-").append(':')
        append(currentSessionID ?: "-").append(':')
        append(schedules.joinToString(",") { it.id }).append(':')
        append(deliveries.joinToString(",") { it.id })
    }

    public companion object {
        /**
         * Projects (facts, local script) into the screen state.
         *
         * Pure: no clock, no I/O and no engine call. The host supplies every time
         * string, so the same facts and the same route script always yield the
         * same state sequence (§3.1).
         *
         * The failure is copied through in every branch and subtracts nothing:
         * `status` answers "what did the snapshot say", `failure` answers "what
         * did the last read report". iOS renders both at once.
         */
        public fun from(
            facts: AutomationFacts,
            local: AutomationLocalState = AutomationLocalState(),
        ): AutomationScreenState {
            val rawSchedules = facts.snapshot?.schedules
            val status = when {
                rawSchedules == null -> AutomationStatus.UNKNOWN
                rawSchedules.isEmpty() -> AutomationStatus.EMPTY
                else -> AutomationStatus.READY
            }
            // The editor is the one child view that does not need a reported
            // schedule: the baseline opens 新建自动化 from the empty state too
            // (`NativeAutomationPage.swift:27`), so it survives every status.
            val editorRoute = local.route == AutomationRoute.EDITOR && local.editor != null
            val editor = local.editor.takeIf { editorRoute }?.let { current ->
                val receipt = facts.writeReceipt
                current.copy(
                    saving = current.submissionID != null && receipt?.requestID != current.submissionID,
                    targetAvailable = !current.draft.isNew || !facts.currentSessionID.isNullOrBlank(),
                )
            }
            if (status != AutomationStatus.READY) {
                return AutomationScreenState(
                    status = status,
                    route = if (editorRoute) AutomationRoute.EDITOR else AutomationRoute.CATALOG,
                    schedules = emptyList(),
                    scheduleCount = if (status == AutomationStatus.EMPTY) 0 else null,
                    selectedScheduleId = null,
                    detail = null,
                    detailMissing = false,
                    historyStatus = AutomationHistoryStatus.UNKNOWN,
                    deliveries = emptyList(),
                    historyCount = null,
                    historyNotice = null,
                    historyHasMore = false,
                    historyFailure = null,
                    failure = facts.failure ?: facts.writeReceipt?.failure,
                    hasUnmeasuredValues = false,
                    editor = editor,
                    writable = facts.writable,
                    editorReturnRoute = local.editorReturnRoute,
                    writeReceipt = facts.writeReceipt,
                    currentSessionID = facts.currentSessionID,
                )
            }
            val schedules = rawSchedules.orEmpty().map(::scheduleView)
            val selected = local.selectedScheduleId?.let { id -> schedules.firstOrNull { it.id == id } }
            val detailMissing = local.route != AutomationRoute.CATALOG && selected == null
            val history = facts.snapshot?.history?.takeIf { it.scheduleId == selected?.id }
            val historyStatus = when {
                selected == null -> AutomationHistoryStatus.UNKNOWN
                history == null -> AutomationHistoryStatus.UNKNOWN
                history.failure != null -> AutomationHistoryStatus.FAILED
                history.deliveries == null -> AutomationHistoryStatus.UNKNOWN
                history.deliveries.isEmpty() -> AutomationHistoryStatus.EMPTY
                else -> AutomationHistoryStatus.READY
            }
            val deliveries = if (historyStatus == AutomationHistoryStatus.READY) {
                history?.deliveries.orEmpty().map { delivery ->
                    AutomationDeliveryView(
                        id = delivery.id,
                        deliveredAt = delivery.deliveredAt,
                        scheduledAt = delivery.scheduledAt,
                        prompt = delivery.prompt,
                    )
                }
            } else {
                emptyList()
            }
            val route = if (local.route == AutomationRoute.EDITOR && editor == null) {
                // No draft means no form: fall back to the list instead of
                // rendering an empty editor frame.
                AutomationRoute.CATALOG
            } else {
                local.route
            }
            return AutomationScreenState(
                status = AutomationStatus.READY,
                route = route,
                schedules = schedules,
                scheduleCount = schedules.size,
                selectedScheduleId = selected?.id,
                detail = selected,
                detailMissing = detailMissing,
                historyStatus = historyStatus,
                deliveries = deliveries,
                historyCount = when (historyStatus) {
                    AutomationHistoryStatus.READY,
                    AutomationHistoryStatus.EMPTY,
                    -> deliveries.size

                    AutomationHistoryStatus.FAILED,
                    AutomationHistoryStatus.UNKNOWN,
                    -> null
                },
                historyNotice = history?.notice,
                historyHasMore = historyStatus == AutomationHistoryStatus.READY && history?.hasMore == true,
                historyFailure = history?.failure,
                failure = facts.failure ?: facts.writeReceipt?.failure,
                hasUnmeasuredValues = schedules.any { it.hasUnmeasuredValues },
                // A confirmation for a schedule the new snapshot dropped is stale.
                confirmDeleteId = local.deleteConfirmId?.takeIf { id -> schedules.any { it.id == id } },
                editor = editor,
                writable = facts.writable,
                editorReturnRoute = local.editorReturnRoute,
                historyCursor = history?.before,
                writeReceipt = facts.writeReceipt,
                currentSessionID = facts.currentSessionID,
            )
        }

        private fun scheduleView(schedule: AutomationSchedule): AutomationScheduleView {
            val statusText = when (schedule.status) {
                ScheduleStatus.ACTIVE -> UiStrings.AUTOMATION_ACTIVE
                ScheduleStatus.STOPPED -> UiStrings.AUTOMATION_STOPPED
                ScheduleStatus.UNKNOWN -> UiStrings.AUTOMATION_STATUS_UNKNOWN
            }
            val statusTone = when (schedule.status) {
                ScheduleStatus.ACTIVE -> PageTone.ON
                ScheduleStatus.STOPPED -> PageTone.NORMAL
                ScheduleStatus.UNKNOWN -> PageTone.UNKNOWN
            }
            val prompt = schedule.prompt?.takeUnless { it.isBlank() }
            val rule = schedule.rule?.takeUnless { it.isBlank() }
            val nextRun = schedule.nextRun?.takeUnless { it.isBlank() }
            val latest = schedule.latestDelivery?.takeUnless { it.isBlank() }
            val session = schedule.sessionTitle?.takeUnless { it.isBlank() }
            return AutomationScheduleView(
                id = schedule.id,
                title = schedule.title,
                prompt = prompt ?: UiStrings.UNKNOWN,
                statusText = statusText,
                statusTone = statusTone,
                ruleText = rule ?: UiStrings.UNKNOWN,
                nextRunText = nextRun ?: UiStrings.UNKNOWN,
                latestDeliveryText = latest ?: UiStrings.UNKNOWN,
                latestDeliveryAt = latest,
                sessionText = session ?: UiStrings.AUTOMATION_SESSION_UNKNOWN,
                detailText = schedule.detail?.takeUnless { it.isBlank() },
                hasUnmeasuredValues = schedule.status == ScheduleStatus.UNKNOWN ||
                    prompt == null ||
                    rule == null ||
                    nextRun == null ||
                    latest == null ||
                    session == null,
            )
        }
    }
}

/** The local UI events of the automation page: navigation, the delete confirmation and the editor. */
public sealed interface AutomationUiEvent {
    /** Open one schedule's detail. */
    public data class OpenDetail(public val id: String) : AutomationUiEvent

    /** Open one schedule's delivery history. */
    public data class OpenHistory(public val id: String) : AutomationUiEvent

    /** Go back one child level; the catalog is the root of this page. */
    public data object Back : AutomationUiEvent

    /** Ask for the 删除 confirmation on one schedule (`NativeAutomationPage.swift:64`). */
    public data class RequestDelete(public val id: String) : AutomationUiEvent

    /** Close the 删除 confirmation without deleting. */
    public data object CancelDelete : AutomationUiEvent

    /**
     * Present the embedded editor on [draft] — the 新建任务 / 新建 / 编辑 gestures
     * (`NativeAutomationPage.swift:30`, `:83`, `:63`).
     *
     * The draft is built by the caller ([AutomationScheduleDraft.from]) because
     * seeding it needs the platform timezone, a read the state function must not
     * make (§3.1).
     */
    public data class OpenEditor(public val draft: AutomationScheduleDraft) : AutomationUiEvent

    /** One field changed; [draft] is the whole form after the edit. */
    public data class EditDraft(public val draft: AutomationScheduleDraft) : AutomationUiEvent

    /** 保存 (`NativeAutomationPage.swift:283`): record the attempt, keep the values. */
    public data class SubmitDraft(public val requestID: String) : AutomationUiEvent

    /** 取消 (`:281`): drop the draft and return to the catalog. */
    public data object CancelEditor : AutomationUiEvent
}

/**
 * The route script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param route which child view is showing.
 * @param selectedScheduleId the schedule the child view belongs to.
 * @param deleteConfirmId the schedule whose 删除 confirmation is open, or `null`.
 * @param editor the form's draft while the embedded editor is presented, or `null`.
 */
@Immutable
public data class AutomationLocalState(
    public val route: AutomationRoute = AutomationRoute.CATALOG,
    /** The catalog/detail face that remains behind the editor sheet. */
    public val editorReturnRoute: AutomationRoute = AutomationRoute.CATALOG,
    public val selectedScheduleId: String? = null,
    public val deleteConfirmId: String? = null,
    public val editor: AutomationEditorState? = null,
) {
    /** Applies one local event. */
    public fun apply(event: AutomationUiEvent): AutomationLocalState = when (event) {
        is AutomationUiEvent.OpenDetail -> copy(
            route = AutomationRoute.DETAIL,
            selectedScheduleId = event.id,
            deleteConfirmId = null,
        )

        is AutomationUiEvent.OpenHistory -> copy(
            route = AutomationRoute.HISTORY,
            selectedScheduleId = event.id,
            deleteConfirmId = null,
        )

        is AutomationUiEvent.RequestDelete -> copy(deleteConfirmId = event.id)

        AutomationUiEvent.CancelDelete -> copy(deleteConfirmId = null)

        // The editor is a child view of whatever presented it, so opening and
        // closing it keep the catalog selection untouched.
        is AutomationUiEvent.OpenEditor -> copy(
            route = AutomationRoute.EDITOR,
            editorReturnRoute = if (route == AutomationRoute.EDITOR) editorReturnRoute else route,
            editor = AutomationEditorState(event.draft),
            deleteConfirmId = null,
        )

        is AutomationUiEvent.EditDraft -> copy(editor = editor?.copy(draft = event.draft))

        is AutomationUiEvent.SubmitDraft -> copy(
            editor = editor?.copy(
                submitted = true,
                submissionID = event.requestID,
                saving = true,
            ),
        )

        AutomationUiEvent.CancelEditor -> copy(
            route = editorReturnRoute,
            editorReturnRoute = AutomationRoute.CATALOG,
            editor = null,
            deleteConfirmId = null,
        )

        AutomationUiEvent.Back -> when (route) {
            // 取消 and the system back are the same act on the form: the draft is
            // dropped and nothing is submitted (`:281`).
            AutomationRoute.EDITOR -> copy(
                route = editorReturnRoute,
                editorReturnRoute = AutomationRoute.CATALOG,
                editor = null,
                deleteConfirmId = null,
            )

            AutomationRoute.HISTORY -> if (selectedScheduleId != null) {
                copy(route = AutomationRoute.DETAIL, deleteConfirmId = null)
            } else {
                copy(
                    route = AutomationRoute.CATALOG,
                    selectedScheduleId = null,
                    deleteConfirmId = null,
                )
            }

            AutomationRoute.DETAIL -> copy(
                route = AutomationRoute.CATALOG,
                selectedScheduleId = null,
                deleteConfirmId = null,
            )
            AutomationRoute.CATALOG -> copy(deleteConfirmId = null)
        }
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The scheduled-automation page.
 *
 * The three routes share one chrome ([AutomationFrame]): the catalog draws the
 * 34 pt large title, the two child views draw the inline bar title iOS gives them
 * (定时任务 / 投递记录, `NativeAutomationPage.swift:152,205`).
 *
 * @param state the pure screen state (`AutomationScreenState.from`).
 * @param onBack close the page (the catalog is the page root).
 * @param onOpenDetail open one schedule's detail; the host applies
 *   `AutomationUiEvent.OpenDetail`.
 * @param onOpenHistory open one schedule's history; the host applies
 *   `AutomationUiEvent.OpenHistory`.
 * @param onBackToCatalog leave a child view; the host applies
 *   `AutomationUiEvent.Back`.
 * @param onRefresh re-read the snapshot; `null` hides the leading 刷新 control.
 *   This is also the page's recovery after a failed read — iOS has no in-content
 *   retry, the toolbar's arrow.clockwise (and pull-to-refresh) is the retry.
 * @param onNewSchedule present the page's own editor for a new schedule (`:30`,
 *   `:83`); `null` hides the trailing 新建 control and the empty-state CTA. The
 *   host applies `AutomationUiEvent.OpenEditor`.
 * @param onEditSchedule present the editor sheet for an existing schedule
 *   (`:63`, `:157`); `null` leaves the toolbar menu action disabled.
 * @param onLoadMoreHistory ask the host for older delivery rows; `null` hides
 *   the action even when the host says more exist.
 * @param onDraftChange one field of the editor's form changed; the host applies
 *   `AutomationUiEvent.EditDraft`.
 * @param onSubmitDraft 保存 (`:283`); the host applies
 *   `AutomationUiEvent.SubmitDraft` and sends the validated draft plus its
 *   unique request id to the scheduler.
 * @param onCancelEditor 取消 (`:281`); the host applies
 *   `AutomationUiEvent.CancelEditor`. `null` hides the control.
 * @param onEditorSaved close the sheet after the matching host receipt contains
 *   a reread schedule record.
 */
@Composable
public fun NativeAutomationPage(
    state: AutomationScreenState,
    onBack: () -> Unit,
    onOpenDetail: (String) -> Unit,
    onOpenHistory: (String) -> Unit,
    onBackToCatalog: () -> Unit,
    modifier: Modifier = Modifier,
    onRefresh: (() -> Unit)? = null,
    onNewSchedule: (() -> Unit)? = null,
    onEditSchedule: ((String) -> Unit)? = null,
    onLoadMoreHistory: ((String, String?) -> Unit)? = null,
    onRequestDelete: ((String) -> Unit)? = null,
    onConfirmDelete: ((String) -> Unit)? = null,
    onCancelDelete: (() -> Unit)? = null,
    onDraftChange: ((AutomationScheduleDraft) -> Unit)? = null,
    onSubmitDraft: ((AutomationScheduleDraft, String) -> Unit)? = null,
    onCancelEditor: (() -> Unit)? = null,
    onEditorSaved: (() -> Unit)? = null,
) {
    // `.confirmationDialog("删除此自动化任务？", …)` (:102–:109): a modal on the
    // baseline, so it is the standard Material dialog, not an inline panel.
    val confirmDeleteId = state.confirmDeleteId
    if (confirmDeleteId != null) {
        AutomationDeleteDialog(
            onConfirm = { onConfirmDelete?.invoke(confirmDeleteId) },
            onCancel = { onCancelDelete?.invoke() },
        )
    }
    val editorOverlay = state.route == AutomationRoute.EDITOR
    val visibleRoute = if (editorOverlay) state.editorReturnRoute else state.route
    when (visibleRoute) {
        AutomationRoute.CATALOG -> AutomationFrame(
            largeTitle = UiStrings.AUTOMATION_TITLE,
            // iOS `.topBarLeading` holds 刷新 beside the sheet's ✕; the bar slot
            // takes both, in that order (`NativeAutomationPage.swift:78-81`).
            leading = {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(LocalUiTokens.current.spacing.iconText),
                ) {
                    SettingsNavAction(
                        text = SETTINGS_CLOSE_GLYPH,
                        onClick = onBack,
                        tag = UiPageTags.AUTOMATION_BACK,
                        description = UiStrings.BACK,
                    )
                    if (onRefresh != null) {
                        SettingsNavAction(
                            text = UiStrings.AUTOMATION_REFRESH,
                            onClick = onRefresh,
                            tag = UiPageTags.AUTOMATION_REFRESH,
                        )
                    }
                }
            },
            // L75: iOS draws 新建 as an unconditional toolbar item
            // (`NativeAutomationPage.swift:83`). Before this it was a `trailing`
            // slot only when the host passed `onNewSchedule`; `page_structure_check`
            // now reports that shape as `conditional-action`, because a label behind
            // `if (cb != null)` is a control that may never render. A host that cannot
            // create one leaves the verb disabled instead, in the place the baseline
            // puts it.
            trailing = {
                AutomationBarAction(
                    label = UiStrings.AUTOMATION_NEW_SHORT,
                    onClick = { onNewSchedule?.invoke() },
                    tag = UiPageTags.AUTOMATION_NEW,
                    enabled = onNewSchedule != null && !state.currentSessionID.isNullOrBlank(),
                )
            },
            rootTag = UiPageTags.AUTOMATION_ROOT,
            modifier = modifier,
        ) {
            AutomationCatalogContent(
                state = state,
                onOpenDetail = onOpenDetail,
                onNewSchedule = onNewSchedule,
            )
        }

        AutomationRoute.DETAIL -> AutomationFrame(
            // iOS shows the same 定时任务 inline title on the child page (:152).
            title = UiStrings.AUTOMATION_TITLE,
            onBack = onBackToCatalog,
            backTag = UiPageTags.AUTOMATION_BACK,
            trailing = {
                AutomationDetailMenu(
                    scheduleID = state.detail?.id,
                    onEdit = onEditSchedule,
                    onDelete = onRequestDelete,
                )
            },
            rootTag = UiPageTags.AUTOMATION_ROOT,
            modifier = modifier,
        ) {
            AutomationDetailContent(
                state = state,
                onOpenHistory = onOpenHistory,
                onEditSchedule = onEditSchedule,
                onRequestDelete = onRequestDelete,
            )
        }

        AutomationRoute.HISTORY -> AutomationFrame(
            title = UiStrings.AUTOMATION_HISTORY_TITLE,
            onBack = onBackToCatalog,
            backTag = UiPageTags.AUTOMATION_BACK,
            rootTag = UiPageTags.AUTOMATION_ROOT,
            modifier = modifier,
        ) {
            AutomationHistoryContent(state = state, onLoadMore = onLoadMoreHistory)
        }
        AutomationRoute.EDITOR -> Unit
    }

    if (editorOverlay && state.editor != null) {
        AutomationEditorSheet(
            state = state,
            onCancel = { onCancelEditor?.invoke() },
            onSubmit = { draft, requestID -> onSubmitDraft?.invoke(draft, requestID) },
            onDraftChange = onDraftChange,
            modifier = modifier,
        )
    }
    LaunchedEffect(state.editor?.submissionID, state.writeReceipt) {
        val requestID = state.editor?.submissionID ?: return@LaunchedEffect
        val receipt = state.writeReceipt?.takeIf { it.requestID == requestID } ?: return@LaunchedEffect
        if (receipt.savedSchedule != null) onEditorSaved?.invoke()
    }
}

/** The editor is a modal sheet over its catalog or detail parent, as on iOS. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AutomationEditorSheet(
    state: AutomationScreenState,
    onCancel: () -> Unit,
    onSubmit: (AutomationScheduleDraft, String) -> Unit,
    onDraftChange: ((AutomationScheduleDraft) -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val palette = materialSheetColors(tokens)
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(sheetState) { sheetState.show() }
    BoxWithConstraints(modifier.fillMaxSize()) {
        val editorSheetHeight = maxHeight * AUTOMATION_EDITOR_SHEET_HEIGHT_RATIO
        ModalBottomSheet(
            onDismissRequest = onCancel,
            sheetState = sheetState,
            modifier = Modifier.fillMaxWidth(),
            containerColor = palette.container,
            contentColor = palette.content,
        ) {
            Box(Modifier.fillMaxWidth().height(editorSheetHeight)) {
                ScheduleEditorPage(
                    state = state,
                    onCancel = onCancel,
                    onSubmit = onSubmit,
                    onDraftChange = onDraftChange,
                )
            }
        }
    }
}

/**
 * The 44 pt bar / 34 pt large title shell.
 *
 * This is `SettingsSubPageFrame`'s shell (`ui/surface/SettingsChrome.kt`) with the
 * one difference this page needs: iOS puts two controls in `.topBarLeading`
 * (the sheet's ✕ and 刷新), and the shared frame exposes a single leading slot.
 * Rather than widen a surface another lane is editing, the twelve lines are
 * spelled here and every element inside them (`SettingsNavBar`,
 * `SettingsLargeTitle`, `SettingsSectionLabel`, `settingsLargeTitleStyle`) is the
 * shared one, so the bar height, the title inset, the title role and the
 * system-bar insets still have exactly one owner.
 *
 * @param title the inline (centred) bar title; the child routes use it.
 * @param largeTitle the 34 pt heading drawn in the content; the catalog uses it.
 * @param leading the leading slot; the catalog puts ✕ and 刷新 in it.
 * @param trailing the trailing slot; the catalog puts 新建 in it.
 */
@Composable
private fun AutomationFrame(
    modifier: Modifier = Modifier,
    title: String? = null,
    largeTitle: String? = null,
    onBack: (() -> Unit)? = null,
    backTag: String? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    rootTag: String? = null,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    // `colors.background` is tier: unmeasured, so an unspecified value leaves the
    // platform surface in place instead of an invented sRGB fill (same rule as
    // `SettingsSubPageFrame` / `PageFrame`).
    val background = if (tokens.colors.background.isSpecified) {
        Modifier.background(tokens.colors.background)
    } else {
        Modifier
    }
    Column(
        modifier = (if (rootTag != null) modifier.testTag(rootTag) else modifier)
            .fillMaxSize()
            .then(background)
            // Edge-to-edge: the horizontal system bars are page-wide; the vertical
            // ones are consumed by the bar and by the content box below.
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        SettingsNavBar(
            title = title,
            onBack = onBack,
            backTag = backTag,
            leading = leading,
            trailing = trailing,
        )
        if (largeTitle != null) {
            SettingsLargeTitle(largeTitle)
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .navigationBarsPadding(),
        ) {
            content()
        }
    }
}

/**
 * The catalog: one list. The empty block, the rows and the 需要处理 section are
 * rows of the same scroll container, exactly as iOS nests them in one `List`.
 */
@Composable
private fun AutomationCatalogContent(
    state: AutomationScreenState,
    onOpenDetail: (String) -> Unit,
    onNewSchedule: (() -> Unit)?,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        when (state.status) {
            AutomationStatus.EMPTY -> item(key = "automation.empty") {
                AutomationEmptyBlock(onNewSchedule = onNewSchedule)
            }

            AutomationStatus.UNKNOWN -> {
                item(key = "automation.unknown") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_UNKNOWN_STATE,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_UNKNOWN_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNKNOWN),
                    )
                }
                item(key = "automation.unknown.detail") {
                    InfoRow(
                        title = UiStrings.UNKNOWN,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_UNKNOWN_DETAIL,
                        tone = PageTone.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNKNOWN_DETAIL),
                    )
                }
            }

            AutomationStatus.READY -> {
                if (state.hasUnmeasuredValues) {
                    item(key = "automation.unmeasured") {
                        InfoRow(
                            title = UiStrings.UNKNOWN,
                            value = null,
                            subtitle = UiStrings.AUTOMATION_UNMEASURED_HINT,
                            tone = PageTone.UNKNOWN,
                            modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNMEASURED),
                        )
                    }
                }
                items(count = state.schedules.size, key = { index -> state.schedules[index].id }) { index ->
                    val schedule = state.schedules[index]
                    AutomationScheduleRow(
                        schedule = schedule,
                        onClick = { onOpenDetail(schedule.id) },
                    )
                }
            }
        }
        state.failure?.let { failure ->
            item(key = "automation.failure") {
                AutomationFailureSection(
                    failure = failure,
                    header = {
                        SettingsSectionLabel(
                            title = UiStrings.AUTOMATION_ATTENTION,
                            tag = UiPageTags.AUTOMATION_ATTENTION,
                        )
                    },
                )
            }
        }
    }
}

/**
 * The reported empty catalog: the sentence pair and the one write action the
 * host owns.
 *
 * iOS: `VStack(spacing: 8)` with a 17/600 line, a 13 pt secondary line, and the
 * CTA 8 pt below them; the block itself carries 24 pt above and below
 * (`NativeAutomationPage.swift:19-41`). The CTA is full width inside the page
 * margin *plus* its own 16 pt inset (measured x 32.0..369.7 pt on a 402 pt page),
 * 50 pt tall and radius 12.
 */
@Composable
private fun AutomationEmptyBlock(onNewSchedule: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AUTOMATION_EMPTY)
            .padding(vertical = ShellFilesMetrics.EMPTY_STATE_PADDING_V_PT.dp)
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(ShellFilesMetrics.EMPTY_STATE_GAP_PT.dp),
    ) {
        BasicText(
            text = UiStrings.AUTOMATION_EMPTY,
            style = type.headline.copy(color = tokens.colors.primary, textAlign = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
        BasicText(
            text = UiStrings.AUTOMATION_EMPTY_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary, textAlign = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
        if (onNewSchedule != null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    // Two 16 pt insets, not one: iOS' `.listRowInsets` clear this
                    // row's *inner* margin, so the list's own 16 pt page margin
                    // stays, and the button adds `.padding(.horizontal, 16)` on top
                    // of it. Measured: the box starts at 32.0 pt on a 402 pt page.
                    .padding(horizontal = tokens.geometry.pageOuterMarginH * 2)
                    // iOS `.padding(.top, 8)` on the button, on top of the stack's 8.
                    .padding(top = ShellFilesMetrics.EMPTY_STATE_GAP_PT.dp)
                    .testTag(UiPageTags.AUTOMATION_CTA)
                    .clip(RoundedCornerShape(tokens.radius.card))
                    // ios-sessions-schedules.png 新建任务 = #2F5BFF (page blue).
                    .background(tokens.colors.pageAccent)
                    .defaultMinSize(minHeight = SessionsMetrics.ctaHeight)
                    .clickable(role = Role.Button, onClick = onNewSchedule)
                    .padding(
                        // The button's own inset: 16 (row) + 16 (button) = the
                        // measured 32.0 pt on both sides.
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.badgeInsetV,
                    )
                    .semantics { contentDescription = UiStrings.AUTOMATION_NEW },
                contentAlignment = Alignment.Center,
            ) {
                BasicText(
                    text = UiStrings.AUTOMATION_NEW,
                    style = type.headline.copy(color = tokens.colors.onAccent, textAlign = TextAlign.Center),
                )
            }
        }
    }
}

/** One schedule row: name and status, prompt, then session, rule and next run. */
@Composable
private fun AutomationScheduleRow(
    schedule: AutomationScheduleView,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AUTOMATION_ROW_PREFIX + schedule.id)
            .clickable(role = Role.Button, onClick = onClick)
            // Page-level geometry: a schedule is a compact list row.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = schedule.title,
                // `NativeAutomationPage.swift:52`: `.font(.body.weight(.medium))`.
                style = type.body.copy(
                    color = tokens.colors.primary,
                    fontWeight = FontWeight.Medium,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = schedule.statusText,
                style = type.caption.copy(color = schedule.statusTone.ink(tokens)),
                maxLines = 1,
            )
        }
        // iOS `.font(.subheadline)` (15 pt) for the prompt, two lines.
        BasicText(
            text = schedule.prompt,
            style = type.subheadline.copy(color = tokens.colors.secondary),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        // iOS `.font(.caption)` in secondary ink: "会话 · 规则 · 下次计划".
        BasicText(
            text = scheduleMeta(schedule),
            style = type.caption.copy(color = tokens.colors.secondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The detail page's iOS toolbar Menu (`NativeAutomationPage.swift:155-159`). */
@Composable
private fun AutomationDetailMenu(
    scheduleID: String?,
    onEdit: ((String) -> Unit)?,
    onDelete: ((String) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(
            modifier = Modifier
                .size(AUTOMATION_DETAIL_MENU_TARGET.dp)
                .clickable(role = Role.Button, onClick = { expanded = true })
                .semantics { contentDescription = AUTOMATION_DETAIL_MENU_LABEL }
                .testTag(AUTOMATION_DETAIL_MENU_TAG),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.size(AUTOMATION_DETAIL_MENU_GLYPH.dp)) {
                val center = Offset(size.width / 2f, size.height / 2f)
                drawCircle(
                    color = tokens.colors.secondary,
                    radius = size.minDimension * 0.47f,
                    center = center,
                    style = Stroke(width = size.minDimension * 0.08f),
                )
                val radius = size.minDimension * 0.055f
                repeat(3) { index ->
                    drawCircle(
                        color = tokens.colors.secondary,
                        radius = radius,
                        center = Offset(size.width * (0.31f + index * 0.19f), center.y),
                    )
                }
            }
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.testTag(AUTOMATION_DETAIL_ACTIONS_MENU_TAG),
        ) {
            DropdownMenuItem(
                text = {
                    BasicText(
                        text = UiStrings.AUTOMATION_EDIT_SHORT,
                        style = LocalUiType.current.body.copy(color = tokens.colors.primary),
                    )
                },
                enabled = scheduleID != null && onEdit != null,
                onClick = {
                    expanded = false
                    scheduleID?.let { onEdit?.invoke(it) }
                },
                modifier = Modifier.testTag(AUTOMATION_DETAIL_MENU_EDIT_TAG),
            )
            DropdownMenuItem(
                text = {
                    BasicText(
                        text = UiStrings.AUTOMATION_DELETE,
                        style = LocalUiType.current.body.copy(color = tokens.colors.danger),
                    )
                },
                enabled = scheduleID != null && onDelete != null,
                onClick = {
                    expanded = false
                    scheduleID?.let { onDelete?.invoke(it) }
                },
                modifier = Modifier.testTag(AUTOMATION_DETAIL_MENU_DELETE_TAG),
            )
        }
    }
}

/** One schedule's detail, including the route into its delivery history. */
@Composable
private fun AutomationDetailContent(
    state: AutomationScreenState,
    onOpenHistory: (String) -> Unit,
    onEditSchedule: ((String) -> Unit)?,
    onRequestDelete: ((String) -> Unit)?,
) {
    val detail = state.detail
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_DETAIL),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.detailMissing || detail == null) {
            item(key = "automation.detail.missing") {
                // `ContentUnavailableView("任务不存在", systemImage: "clock.badge.xmark")`
                // (`NativeAutomationPage.swift:148`): the baseline draws the title and
                // a glyph, no second sentence, so the Android-only hint is gone.
                InfoRow(
                    title = UiStrings.AUTOMATION_NOT_FOUND,
                    value = null,
                    tone = PageTone.DEGRADED,
                )
            }
            state.failure?.let { failure ->
                item(key = "automation.detail.failure") {
                    // iOS wraps this page's error in its own 错误 section (:150).
                    AutomationFailureSection(
                        failure = failure,
                        tag = UiPageTags.AUTOMATION_FAILURE,
                        header = {
                            SettingsSectionLabel(
                                title = UiStrings.AUTOMATION_ERROR,
                                tag = UiPageTags.AUTOMATION_FAILURE,
                            )
                        },
                    )
                }
            }
            return@LazyColumn
        }
        // Section("提醒") (`NativeAutomationPage.swift:129`): 名称 / 规则 / 下次计划 /
        // 状态 in that order, then the prompt as one selectable paragraph (`:134`).
        // The 名称 row and the section header were missing on Android, and 会话 /
        // 最近投递 were two rows the baseline does not draw in this section.
        item(key = "automation.detail.reminder.label") {
            SettingsSectionLabel(title = UiStrings.AUTOMATION_SECTION_REMINDER)
        }
        item(key = "automation.detail.name") {
            InfoRow(
                title = UiStrings.AUTOMATION_NAME,
                value = detail.title,
            )
        }
        item(key = "automation.detail.rule") {
            InfoRow(
                title = UiStrings.AUTOMATION_RULE,
                value = detail.ruleText,
                tone = if (detail.ruleText == UiStrings.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            )
        }
        item(key = "automation.detail.next") {
            InfoRow(
                title = UiStrings.AUTOMATION_NEXT_RUN,
                value = detail.nextRunText,
                tone = if (detail.nextRunText == UiStrings.UNKNOWN) PageTone.UNKNOWN else PageTone.NORMAL,
            )
        }
        item(key = "automation.detail.status") {
            InfoRow(
                title = UiStrings.AUTOMATION_STATUS,
                value = detail.statusText,
                tone = detail.statusTone,
                subtitle = if (detail.statusTone == PageTone.UNKNOWN) {
                    UiStrings.AUTOMATION_STATUS_UNKNOWN
                } else {
                    null
                },
            )
        }
        item(key = "automation.detail.prompt") {
            AutomationParagraph(text = detail.prompt)
        }
        // Section("投递记录") (`:136`): the route into the saved deliveries, then the
        // baseline's own `最近投递：…` sentence (`:142`–`:145`).
        item(key = "automation.detail.history.label") {
            SettingsSectionLabel(title = UiStrings.AUTOMATION_SECTION_HISTORY)
        }
        item(key = "automation.detail.history") {
            InfoRow(
                title = UiStrings.AUTOMATION_HISTORY_OPEN,
                value = null,
                onClick = { onOpenHistory(detail.id) },
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_OPEN),
            )
        }
        detail.latestDeliveryAt?.let { latest ->
            item(key = "automation.detail.latest") {
                // `Text("最近投递：\(latestDeliveryAt)").font(.caption)
                // .foregroundStyle(.secondary)` (`NativeAutomationPage.swift:143`).
                val tokens = LocalUiTokens.current
                BasicText(
                    text = UiStrings.AUTOMATION_LATEST_DELIVERY_FORMAT.format(latest),
                    style = LocalUiType.current.caption.copy(color = tokens.colors.secondary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = tokens.geometry.pageOuterMarginH,
                            vertical = tokens.spacing.badgeInsetV,
                        ),
                )
            }
        }
        if (detail.hasUnmeasuredValues) {
            item(key = "automation.detail.unmeasured") {
                InfoRow(
                    title = UiStrings.UNKNOWN,
                    value = null,
                    subtitle = UiStrings.AUTOMATION_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_UNMEASURED),
                )
            }
        }
        // Android-only explanatory row (iOS has no equivalent): the page does not
        // own the schedule store, so an editor is a host handoff.
        item(key = "automation.detail.read-only") {
            AutomationNoteRow(text = UiStrings.AUTOMATION_READ_ONLY)
        }
        state.failure?.let { failure ->
            item(key = "automation.detail.failure") {
                AutomationFailureSection(
                    failure = failure,
                    tag = UiPageTags.AUTOMATION_FAILURE,
                    header = {
                        SettingsSectionLabel(
                            title = UiStrings.AUTOMATION_ERROR,
                            tag = UiPageTags.AUTOMATION_FAILURE,
                        )
                    },
                )
            }
        }
    }
}

/** One schedule's delivery history, with the empty/unknown/failed split. */
@Composable
private fun AutomationHistoryContent(
    state: AutomationScreenState,
    onLoadMore: ((String, String?) -> Unit)?,
) {
    val historyScheduleID = state.detail?.id
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.AUTOMATION_HISTORY_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        if (state.detailMissing || state.detail == null) {
            item(key = "automation.history.missing") {
                // `ContentUnavailableView("任务不存在", systemImage: "clock.badge.xmark")`
                // (`NativeAutomationPage.swift:148`): the baseline draws the title and
                // a glyph, no second sentence, so the Android-only hint is gone.
                InfoRow(
                    title = UiStrings.AUTOMATION_NOT_FOUND,
                    value = null,
                    tone = PageTone.DEGRADED,
                )
            }
            return@LazyColumn
        }
        state.historyNotice?.let { notice ->
            // `Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }`
            // (`NativeAutomationPage.swift:184`–`:186`): the group is untitled on the
            // baseline, so the notice is one 13 pt secondary line and not a 投递记录
            // row.
            item(key = "automation.history.notice") {
                AutomationSecondaryNote(text = notice)
            }
        }
        when (state.historyStatus) {
            AutomationHistoryStatus.UNKNOWN -> {
                item(key = "automation.history.unknown") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_UNKNOWN,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_UNKNOWN_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN),
                    )
                }
                item(key = "automation.history.unknown.detail") {
                    InfoRow(
                        title = UiStrings.UNKNOWN,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_UNKNOWN_DETAIL,
                        tone = PageTone.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_UNKNOWN_DETAIL),
                    )
                }
            }

            AutomationHistoryStatus.FAILED -> {
                item(key = "automation.history.failure") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_FAILED,
                        value = null,
                        subtitle = state.historyFailure,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_FAILURE),
                    )
                }
            }

            AutomationHistoryStatus.EMPTY -> {
                item(key = "automation.history.empty") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_HISTORY_EMPTY,
                        value = null,
                        subtitle = UiStrings.AUTOMATION_HISTORY_EMPTY_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_EMPTY),
                    )
                }
            }

            AutomationHistoryStatus.READY -> {
                items(
                    count = state.deliveries.size,
                    key = { index -> state.deliveries[index].id },
                ) { index ->
                    AutomationDeliveryRow(delivery = state.deliveries[index])
                }
                if (state.historyHasMore && onLoadMore != null && historyScheduleID != null) {
                    item(key = "automation.history.more") {
                        InfoRow(
                            title = UiStrings.AUTOMATION_HISTORY_MORE,
                            value = null,
                            onClick = { onLoadMore(historyScheduleID, state.historyCursor) },
                            modifier = Modifier.testTag(UiPageTags.AUTOMATION_HISTORY_MORE),
                        )
                    }
                }
            }
        }
        state.failure?.let { failure ->
            item(key = "automation.history.failure.section") {
                // iOS wraps this page's error in its own 错误 section (:203).
                AutomationFailureSection(
                    failure = failure,
                    tag = UiPageTags.AUTOMATION_FAILURE,
                    header = {
                        SettingsSectionLabel(
                            title = UiStrings.AUTOMATION_ERROR,
                            tag = UiPageTags.AUTOMATION_FAILURE,
                        )
                    },
                )
            }
        }
    }
}

/** One delivery row: delivered time, planned time and the retained prompt. */
@Composable
private fun AutomationDeliveryRow(delivery: AutomationDeliveryView) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.AUTOMATION_HISTORY_ROW)
            // Page-level geometry: a delivery is a compact list row.
            .defaultMinSize(minHeight = tokens.geometry.pageListRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = delivery.deliveredAt,
            // `NativeAutomationPage.swift:192`: `.font(.subheadline.weight(.medium))`
            // (15 pt medium) for the delivered time.
            style = type.subheadline.copy(
                color = tokens.colors.primary,
                fontWeight = FontWeight.Medium,
            ),
        )
        BasicText(
            text = UiStrings.AUTOMATION_PLANNED_AT_FORMAT.format(delivery.scheduledAt),
            // `NativeAutomationPage.swift:193`: `.font(.caption)` in secondary ink.
            style = type.caption.copy(color = tokens.colors.secondary),
        )
        delivery.prompt?.let { prompt ->
            BasicText(
                text = prompt,
                style = type.caption.copy(color = tokens.colors.secondary),
            )
        }
    }
}

/**
 * The host's failure, under the section header iOS uses.
 *
 * `Section("需要处理") { Text(error).font(.footnote).foregroundStyle(.red) }`
 * (`NativeAutomationPage.swift:70`): a secondary-ink group header, then the
 * host's own sentence in 13 pt red, both starting at the measured 32.7 pt — the
 * same `SettingsSectionLabelIndent` the settings sub-pages measured. There is no
 * retry or dismiss control here on either platform: the 刷新 control in the bar
 * is the retry, and a successful read is what clears the section.
 *
 * @param header the section header; 需要处理 on the catalog, 错误 on the children.
 *   It is a slot because the header's words belong to the route that draws them.
 * @param failure the host's sentence, verbatim: the page never translates a host
 *   error into its own words.
 * @param tag the stable test tag of the failure sentence.
 */
@Composable
private fun AutomationFailureSection(
    header: @Composable () -> Unit,
    failure: String,
    tag: String = UiPageTags.AUTOMATION_FAILURE,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // The list's section gap above the header. The empty block already ends
            // its 24 pt tail below the CTA and the header adds its own 12 pt; this
            // 8 pt is what reproduces the measured 54.6 pt CTA -> header gap
            // (`spec/ui/v1/tokens.json` has no section-gap token, so the page uses
            // the 8 pt spacing token it already reads).
            .padding(top = tokens.spacing.codeToolbar),
    ) {
        header()
        BasicText(
            text = failure,
            style = type.secondary.copy(color = tokens.colors.danger),
            modifier = Modifier
                .fillMaxWidth()
                .testTag(tag)
                .padding(
                    start = SettingsSectionLabelIndent,
                    end = SettingsSectionLabelIndent,
                    top = tokens.geometry.pageOuterMarginH,
                    bottom = tokens.spacing.iconText,
                ),
        )
    }
}

/**
 * A bar text control whose label the page writes.
 *
 * `SettingsNavAction` takes the same copy as `text`, which leaves the label only
 * in the caller's argument. Drawing the `BasicText` here keeps the measured
 * settings bar style (`settingsLabelStyle`, accent ink, icon-text padding) and
 * keeps the page's own words next to the page.
 *
 * @param label the visible verb.
 * @param onClick the control's action.
 * @param tag the stable test tag.
 * @param enabled `false` dims the verb and drops the click; the control keeps its
 *   place in the bar because the baseline draws it unconditionally.
 */
@Composable
private fun AutomationBarAction(
    label: String,
    onClick: () -> Unit,
    tag: String,
    enabled: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = label,
        style = settingsLabelStyle().copy(
            color = if (enabled) tokens.colors.accent else tokens.colors.tertiary,
        ),
        modifier = Modifier
            .testTag(tag)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(vertical = tokens.spacing.iconText, horizontal = tokens.spacing.iconText),
    )
}

// ---------------------------------------------------------------------------
// ScheduleEditorPage: the embedded form
// ---------------------------------------------------------------------------

/**
 * The editor the catalog presents (`NativeAutomationPage.swift:212`–`:420`).
 *
 * iOS puts this form in a `.sheet` (`:92` new, `:99` edit) under its own
 * `NavigationStack`, with an inline title (`:278`), 取消 in the cancellation slot
 * (`:281`) and 保存 in the confirmation slot (`:283`). The port keeps that shape
 * inside the page's own frame: the same two slots, the same three groups, the
 * same field order.
 *
 * The sheet stays open while the host writes. It dismisses only after a matching
 * successful write receipt contains the schedule record the host reread.
 *
 * @param state the page state; [AutomationScreenState.editor] carries the draft.
 * @param onCancel 取消 (`:281`).
 * @param onSubmit 保存 (`:283`).
 * @param onDraftChange one field changed. `null` renders a read-only form, which
 *   is what a host that cannot edit at all passes.
 */
@Composable
private fun ScheduleEditorPage(
    state: AutomationScreenState,
    onCancel: () -> Unit,
    onSubmit: (AutomationScheduleDraft, String) -> Unit,
    onDraftChange: ((AutomationScheduleDraft) -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val editor = state.editor ?: return
    val draft = editor.draft
    val tokens = LocalUiTokens.current
    val update: (AutomationScheduleDraft) -> Unit = { next -> onDraftChange?.invoke(next) }
    // The 规则 chooser is pure local UI state (no ScreenState node): it closes on
    // choose or dismiss and changes nothing on its own.
    var choosingRule by remember { mutableStateOf(false) }

    AutomationFrame(
        // `navigationTitle(schedule == nil ? "新建自动化" : "编辑自动化")` (`:278`).
        title = if (draft.isNew) {
            UiStrings.AUTOMATION_EDITOR_NEW_TITLE
        } else {
            UiStrings.AUTOMATION_EDITOR_EDIT_TITLE
        },
        leading = {
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onCancel,
                tone = SessionActionTone.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_CANCEL),
            )
        },
        trailing = {
            SessionTextAction(
                label = if (editor.saving) AUTOMATION_EDITOR_SAVING_LABEL else UiStrings.AUTOMATION_EDITOR_SAVE,
                onClick = { onSubmit(draft, UUID.randomUUID().toString()) },
                tone = SessionActionTone.ACCENT,
                enabled = editor.canSubmit,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_SAVE),
            )
        },
        rootTag = UiPageTags.AUTOMATION_EDITOR_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                // The timing fields (本地时间 / 时区 / 星期 / Cron) are the last rows
                // of this form. Measured on the L50 emulator: with 每周 selected the
                // 星期 field's bottom sits under the keyboard and the list has no
                // room left to scroll, so the IME inset must shrink the viewport
                // (spec §5 row `insets`).
                .imePadding()
                .testTag(UiPageTags.AUTOMATION_EDITOR_LIST),
            verticalArrangement = Arrangement.spacedBy(pageListGap),
        ) {
            // 任务内容 (`:252`).
            item(key = "editor.content.label") {
                SessionSectionLabel(
                    text = UiStrings.AUTOMATION_EDITOR_CONTENT_SECTION,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_CONTENT_SECTION),
                )
            }
            item(key = "editor.name") {
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_NAME_FIELD,
                    value = draft.title,
                    onValueChange = { value -> update(draft.copy(title = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_NAME,
                )
            }
            item(key = "editor.prompt") {
                AutomationField(
                    label = UiStrings.AUTOMATION_PROMPT,
                    value = draft.prompt,
                    onValueChange = { value -> update(draft.copy(prompt = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_PROMPT,
                    minLines = PROMPT_FIELD_LINES,
                )
            }
            // 计划时间 (`:258`).
            item(key = "editor.timing.label") {
                SessionSectionLabel(
                    text = UiStrings.AUTOMATION_EDITOR_TIMING_SECTION,
                    modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_TIMING_SECTION),
                )
            }
            if (!draft.isNew) {
                // `Toggle("修改计划时间", isOn: $changeTiming)` (`:260`): only an
                // existing schedule offers the choice, and the row is the target.
                item(key = "editor.change-timing") {
                    // `Toggle("修改计划时间", isOn: $changeTiming)`
                    // (`NativeAutomationPage.swift:260`) is a switch on the baseline,
                    // not a word: the row keeps the label on the left and the control
                    // on the right, and the two words above are the switch's own
                    // state description instead of a replacement for it.
                    val on = draft.changeTiming
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.AUTOMATION_EDITOR_CHANGE_TIMING)
                            .heightIn(min = tokens.geometry.pageRowMinHeight)
                            .toggleable(
                                value = on,
                                role = Role.Switch,
                                onValueChange = { next -> update(draft.copy(changeTiming = next)) },
                            )
                            .semantics(mergeDescendants = true) {
                                stateDescription = if (on) {
                                    UiStrings.AUTOMATION_EDITOR_TOGGLE_ON
                                } else {
                                    UiStrings.AUTOMATION_EDITOR_TOGGLE_OFF
                                }
                            }
                            .padding(
                                horizontal = tokens.geometry.pageOuterMarginH,
                                vertical = tokens.spacing.badgeInsetV,
                            ),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BasicText(
                            text = UiStrings.AUTOMATION_EDITOR_CHANGE_TIMING,
                            style = LocalUiType.current.body.copy(color = tokens.colors.primary),
                            modifier = Modifier.weight(1f),
                        )
                        // The row owns the gesture (`toggleable` above), so the
                        // switch is the visual half of one control, not a second one.
                        Switch(checked = on, onCheckedChange = null)
                    }
                }
            }
            if (draft.editsTiming) {
                // `Picker("规则", selection: $rule)` (`:263`): one row that opens the
                // six options.
                item(key = "editor.rule") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_RULE,
                        value = draft.rule.optionLabel,
                        onClick = { choosingRule = true },
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_RULE),
                    )
                }
                item(key = "editor.rule.fields") {
                    AutomationRuleFields(draft = draft, onDraftChange = update)
                }
            } else {
                // `LabeledContent("当前规则", value: schedule.scheduledAt)` (`:274`):
                // the value is the host's own time string, or 未知.
                item(key = "editor.current-rule") {
                    InfoRow(
                        title = UiStrings.AUTOMATION_EDITOR_CURRENT_RULE,
                        value = state.detail?.nextRunText ?: UiStrings.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_CURRENT_RULE),
                    )
                }
            }
            // `Section("错误")` (`:276`): the rule's sentence, and only after 保存.
            editor.error?.let { message ->
                item(key = "editor.error.label") {
                    SessionSectionLabel(text = UiStrings.AUTOMATION_ERROR)
                }
                item(key = "editor.error") {
                    BasicText(
                        text = message,
                        style = LocalUiType.current.caption.copy(color = tokens.colors.danger),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.AUTOMATION_EDITOR_ERROR)
                            .padding(
                                start = SettingsSectionLabelIndent,
                                end = SettingsSectionLabelIndent,
                                top = tokens.spacing.iconText,
                                bottom = tokens.spacing.iconText,
                            ),
                    )
                }
            }
            state.failure?.let { failure ->
                item(key = "editor.failure") {
                    // The host's own read failure, in the same 错误 group.
                    AutomationFailureSection(
                        failure = failure,
                        header = { SessionSectionLabel(text = UiStrings.AUTOMATION_ERROR) },
                    )
                }
            }
            if (state.writable == FactState.NO) {
                item(key = "editor.handoff") {
                    SettingsSubPageFootnote(
                        text = UiStrings.AUTOMATION_EDITOR_HANDOFF_HINT,
                        modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_HANDOFF),
                    )
                }
            }
        }
    }
    if (choosingRule) {
        AutomationRuleDialog(
            selected = draft.rule,
            onSelect = { rule ->
                choosingRule = false
                update(draft.copy(rule = rule))
            },
            onDismiss = { choosingRule = false },
        )
    }
}

/**
 * The rule's own fields (`NativeAutomationPage.swift:290`–`:314`).
 *
 * One field set per rule, in the baseline's order: 延迟秒数 / ISO-8601 日期时间 /
 * 间隔秒数 / 本地时间 + IANA 时区 (+ 星期, + 五段 Cron). The `指定时间` field is
 * preceded by the baseline's own hint (`:296`) because this page cannot fill it
 * with `now + 1h` — it never reads a clock.
 */
@Composable
private fun AutomationRuleFields(
    draft: AutomationScheduleDraft,
    onDraftChange: (AutomationScheduleDraft) -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        when (draft.rule) {
            AutomationRule.AFTER -> AutomationField(
                // `schedule == nil ? "延迟秒数" : "延迟到期秒数"` (`:294`).
                label = if (draft.isNew) {
                    UiStrings.AUTOMATION_EDITOR_DELAY_FIELD
                } else {
                    UiStrings.AUTOMATION_EDITOR_DELAY_EDIT_FIELD
                },
                value = draft.afterSeconds,
                onValueChange = { value -> onDraftChange(draft.copy(afterSeconds = value)) },
                tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + AutomationRule.AFTER.wire,
                keyboardType = KeyboardType.Number,
            )

            AutomationRule.AT -> {
                BasicText(
                    text = UiStrings.AUTOMATION_EDITOR_AT_HINT,
                    style = LocalUiType.current.caption.copy(color = tokens.colors.tertiary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = tokens.geometry.pageOuterMarginH),
                )
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_AT_FIELD,
                    value = draft.at,
                    onValueChange = { value -> onDraftChange(draft.copy(at = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + AutomationRule.AT.wire,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
            }

            AutomationRule.EVERY -> AutomationField(
                label = UiStrings.AUTOMATION_EDITOR_EVERY_FIELD,
                value = draft.everySeconds,
                onValueChange = { value -> onDraftChange(draft.copy(everySeconds = value)) },
                tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + AutomationRule.EVERY.wire,
                keyboardType = KeyboardType.Number,
            )

            AutomationRule.DAILY -> {
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_TIME_FIELD,
                    value = draft.localTime,
                    onValueChange = { value -> onDraftChange(draft.copy(localTime = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + TIME_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_TIME_ZONE_FIELD,
                    value = draft.timeZone,
                    onValueChange = { value -> onDraftChange(draft.copy(timeZone = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + ZONE_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
            }

            AutomationRule.WEEKLY -> {
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_TIME_FIELD,
                    value = draft.localTime,
                    onValueChange = { value -> onDraftChange(draft.copy(localTime = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + TIME_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_TIME_ZONE_FIELD,
                    value = draft.timeZone,
                    onValueChange = { value -> onDraftChange(draft.copy(timeZone = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + ZONE_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_WEEKDAYS_FIELD,
                    value = draft.weekdays,
                    onValueChange = { value -> onDraftChange(draft.copy(weekdays = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + WEEKDAYS_FIELD_SUFFIX,
                    // iOS uses numbersAndPunctuation because weekdays are a
                    // comma-separated list (1,2,3...), not one numeric value.
                    keyboardType = KeyboardType.Text,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
            }

            AutomationRule.CRON -> {
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_CRON_FIELD,
                    value = draft.cron,
                    onValueChange = { value -> onDraftChange(draft.copy(cron = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + CRON_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
                AutomationField(
                    label = UiStrings.AUTOMATION_EDITOR_TIME_ZONE_FIELD,
                    value = draft.timeZone,
                    onValueChange = { value -> onDraftChange(draft.copy(timeZone = value)) },
                    tag = UiPageTags.AUTOMATION_EDITOR_FIELD_PREFIX + ZONE_FIELD_SUFFIX,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                )
            }
        }
    }
}

/**
 * One labelled form field.
 *
 * The label is visible text and the field is one `BasicTextField`, exactly like the
 * MCP editor's field block: same ink roles, same row floor, same placeholder idiom.
 *
 * @param label the field's own visible name.
 * @param value the current text.
 * @param onValueChange one edit.
 * @param tag the stable test tag.
 * @param minLines the field's floor; 提醒内容 uses the baseline's 3…6 lines (`:255`).
 * @param keyboardType the keyboard the field asks for.
 */
@Composable
private fun AutomationField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    minLines: Int = 1,
    keyboardType: KeyboardType = KeyboardType.Text,
    capitalization: KeyboardCapitalization = KeyboardCapitalization.Sentences,
    autoCorrectEnabled: Boolean = true,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        BasicText(
            text = label,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = type.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            minLines = minLines,
            maxLines = if (minLines > 1) PROMPT_FIELD_MAX_LINES else 1,
            keyboardOptions = KeyboardOptions(
                capitalization = capitalization,
                autoCorrectEnabled = autoCorrectEnabled,
                keyboardType = keyboardType,
                imeAction = ImeAction.Done,
            ),
            modifier = Modifier
                .fillMaxWidth()
                // Page-level geometry: an editor field is a page row.
                .heightIn(min = tokens.geometry.pageRowMinHeight)
                .testTag(tag)
                .semantics { contentDescription = label },
        )
    }
}

private const val PROMPT_FIELD_MAX_LINES = 6

/**
 * The 规则 chooser (`Picker("规则", selection: $rule)`, `:263`–`:270`).
 *
 * Six explicit option rows, not a loop over [AutomationRule]'s values: an option
 * the user can tap is visible copy, and the page-source gate only resolves a label
 * where the source names it. The current selection is printed above them
 * (`当前规则`), so the dialog says what is selected without a second glyph.
 *
 * @param selected the rule the draft currently uses.
 * @param onSelect the chosen rule.
 * @param onDismiss close without choosing.
 */
@Composable
private fun AutomationRuleDialog(
    selected: AutomationRule,
    onSelect: (AutomationRule) -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag(UiPageTags.AUTOMATION_EDITOR_RULE_DIALOG),
        title = {
            BasicText(
                text = UiStrings.AUTOMATION_RULE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV)) {
                InfoRow(
                    title = UiStrings.AUTOMATION_EDITOR_CURRENT_RULE,
                    value = selected.optionLabel,
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_AFTER,
                    onClick = { onSelect(AutomationRule.AFTER) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.AFTER.wire,
                    ),
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_AT,
                    onClick = { onSelect(AutomationRule.AT) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.AT.wire,
                    ),
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_EVERY,
                    onClick = { onSelect(AutomationRule.EVERY) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.EVERY.wire,
                    ),
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_DAILY,
                    onClick = { onSelect(AutomationRule.DAILY) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.DAILY.wire,
                    ),
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_WEEKLY,
                    onClick = { onSelect(AutomationRule.WEEKLY) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.WEEKLY.wire,
                    ),
                )
                SessionTextAction(
                    label = UiStrings.AUTOMATION_EDITOR_RULE_CRON,
                    onClick = { onSelect(AutomationRule.CRON) },
                    tone = SessionActionTone.ACCENT,
                    modifier = Modifier.testTag(
                        UiPageTags.AUTOMATION_EDITOR_RULE_OPTION_PREFIX + AutomationRule.CRON.wire,
                    ),
                )
            }
        },
        confirmButton = {},
        dismissButton = {
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onDismiss,
                tone = SessionActionTone.SECONDARY,
            )
        },
        shape = RoundedCornerShape(tokens.radius.card),
        containerColor = tokens.colors.input,
        titleContentColor = tokens.colors.primary,
        textContentColor = tokens.colors.secondary,
    )
}

/**
 * `删除此自动化任务？` with 删除任务 and 取消.
 *
 * `NativeAutomationPage.swift:102`–`:109`: the destructive verb and a cancel, with
 * the sentence about the saved history as the message. The caller checks that the
 * host can perform the delete before it opens.
 *
 * @param onConfirm delete the schedule.
 * @param onCancel close without deleting.
 */
@Composable
private fun AutomationDeleteDialog(onConfirm: () -> Unit, onCancel: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onCancel,
        modifier = Modifier.testTag(UiPageTags.AUTOMATION_DELETE_DIALOG),
        title = {
            BasicText(
                text = UiStrings.AUTOMATION_CONFIRM_DELETE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            BasicText(
                text = UiStrings.AUTOMATION_CONFIRM_DELETE_MESSAGE,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        },
        confirmButton = {
            SessionTextAction(
                label = UiStrings.AUTOMATION_DELETE_TASK,
                onClick = onConfirm,
                tone = SessionActionTone.DANGER,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_DELETE_CONFIRM),
            )
        },
        dismissButton = {
            SessionTextAction(
                label = UiStrings.CANCEL,
                onClick = onCancel,
                tone = SessionActionTone.SECONDARY,
                modifier = Modifier.testTag(UiPageTags.AUTOMATION_DELETE_CANCEL),
            )
        },
        shape = RoundedCornerShape(tokens.radius.card),
        containerColor = tokens.colors.input,
        titleContentColor = tokens.colors.primary,
        textContentColor = tokens.colors.secondary,
    )
}

/** One explanatory line; the ink is a token, never a second colour source. */
@Composable
private fun AutomationNoteRow(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/**
 * The schedule's prompt as the baseline draws it on the detail page:
 * `Text(schedule.prompt).textSelection(.enabled)` (`NativeAutomationPage.swift:134`),
 * body size, no row label.
 */
@Composable
private fun AutomationParagraph(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SelectionContainer {
        BasicText(
            text = text,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
        )
    }
}

/**
 * A 13 pt secondary sentence: the baseline's `.font(.footnote)` line under an
 * untitled group (`NativeAutomationPage.swift:185`, the history's notice).
 */
@Composable
private fun AutomationSecondaryNote(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.secondary.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/**
 * The catalog row's one-line meta.
 *
 * iOS renders `"\(sessionTitle) · \(schedule.detail)"` where `detail` is itself
 * `"\(kind) · \(scheduledAt)"` (`DSHManagementModel.swift:69`), so the visible
 * line is 会话 · 规则 · 下次计划 in that order.
 */
private fun scheduleMeta(schedule: AutomationScheduleView): String =
    UiStrings.AUTOMATION_META_FORMAT.format(
        schedule.sessionText,
        UiStrings.AUTOMATION_META_FORMAT.format(schedule.ruleText, schedule.nextRunText),
    )

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object NativeAutomationPageTokens {
    val refs: List<String> = listOf(
        "colors.accent",
        "colors.background",
        "colors.pageAccent",
        "colors.danger",
        "colors.input",
        "colors.onAccent",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageListRowMinHeight",
        "geometry.pageOuterMarginH",
        "geometry.pageRowMinHeight",
        "radius.card",
        "spacing.badgeInsetV",
        "spacing.codeToolbar",
        "spacing.iconText",
        "typography.caption",
        "typography.headline",
        "typography.secondary",
        "typography.subheadline",
        "typography.body",
    )
}

// ---------------------------------------------------------------------------
// Editor constants
// ---------------------------------------------------------------------------

/**
 * The five rule defaults the baseline's `init` declares (`:221`–`:227`).
 *
 * Every one is the string the baseline's own `@State` starts with, so a new form
 * opens on the same rule, the same 3600-second delay and the same weekday set.
 */
private const val DEFAULT_AFTER_SECONDS: String = "3600"
private const val DEFAULT_EVERY_SECONDS: String = "3600"
private const val DEFAULT_LOCAL_TIME: String = "09:00:00"
private const val DEFAULT_WEEKDAYS: String = "1,2,3,4,5"
private const val DEFAULT_CRON: String = "0 9 * * 1-5"

/** `guard let seconds = Int(intervalSeconds), seconds >= 60` (`:361`). */
private const val MINIMUM_INTERVAL_SECONDS: Int = 60

/** A Vixie cron expression has exactly five fields (`:377`). */
private const val CRON_FIELD_COUNT: Int = 5

/** ISO-8601 weekday numbers (`:370`). */
private const val ISO_MIN_WEEKDAY: Int = 1
private const val ISO_MAX_WEEKDAY: Int = 7

/** The 提醒内容 field's floor: the baseline's `lineLimit(3...6)` (`:255`). */
private const val PROMPT_FIELD_LINES: Int = 3

/** The rule fields that more than one rule shares, as tag suffixes. */
private const val TIME_FIELD_SUFFIX: String = "time"
private const val ZONE_FIELD_SUFFIX: String = "time-zone"
private const val WEEKDAYS_FIELD_SUFFIX: String = "weekdays"
private const val CRON_FIELD_SUFFIX: String = "cron"

/** Source: `ScheduleDetailPage`'s unlabelled `ellipsis.circle` toolbar Menu. */
private const val AUTOMATION_DETAIL_MENU_LABEL: String = "更多操作"
private const val AUTOMATION_DETAIL_MENU_TAG: String = "automation.detail.menu"
private const val AUTOMATION_DETAIL_ACTIONS_MENU_TAG: String = "automation.detail.actions"
private const val AUTOMATION_DETAIL_MENU_EDIT_TAG: String = "automation.detail.menu.edit"
private const val AUTOMATION_DETAIL_MENU_DELETE_TAG: String = "automation.detail.menu.delete"
private const val AUTOMATION_DETAIL_MENU_TARGET: Float = 44f
private const val AUTOMATION_DETAIL_MENU_GLYPH: Float = 22f
private const val AUTOMATION_EDITOR_SHEET_HEIGHT_RATIO: Float = 0.92f
private const val AUTOMATION_EDITOR_SAVING_LABEL: String = "保存中…"

private val WHITESPACE: Regex = Regex("\\s+")

/** The baseline's local-time grammar, verbatim (`:387`). */
private val LOCAL_TIME_PATTERN: Regex =
    Regex("""^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,3})?)?$""")

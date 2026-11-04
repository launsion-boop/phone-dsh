// Phone permissions: the 23-capability matrix, capability for capability.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/PhonePermissionsPage.swift` at iOS
// HEAD 86a39aac (274 lines) and the vocabulary it renders from,
// `examples/probe-app/ProbeKit/Permissions/PhoneCapability.swift` +
// `CapabilityStatus.swift`. Contract: `spec/ui/v1/pages/phone-permissions.json`.
//
// What this page is
// -----------------
// The *capability face*: which phone capabilities the agent may use, what the
// operating system currently allows, and what the phone has actually used. It is
// not decoration, so accuracy is structural rather than cosmetic:
//
//   * a capability is 已允许 **only** when the host reports [PhoneCapabilityStatus.Authorized].
//     There is no default, no inference and no fallback that turns an unread
//     permission into a granted one: `statuses == null` means the host did not
//     read permissions at all, and every row then says 未知 with its controls
//     disabled (the row's status is `null`, not a plausible stand-in);
//   * 未知 and 未请求 are different statements: `null` is "not read", while a
//     capability missing from a *reported* map is iOS's own `.notDetermined`
//     fallback (`PhonePermissionsPage.swift:178`);
//   * the 最近使用审计 section shows the last 20 calls; an audit the host did not
//     report says so instead of claiming 暂无使用记录.
//
// Three dimensions per capability — PR #13's "per-capability status/request/audit"
// -------------------------------------------------------------------------------
//   status  [PhoneCapabilityStatus] — what the OS reports: exactly the seven iOS
//           cases, plus the four special labels the baseline prints instead of the
//           case text (常开 / 未验证 · 点击测试 / 可能已拒绝 / 已允许 · 写操作前确认).
//           `null` on a row is 未知: no read, no claim.
//   request [PhoneCapabilityAction] — what a tap does *right now*: ask the system,
//           enable the app's own use, open system settings (a denied capability
//           never asks again), one biometric confirmation, or nothing (blocked /
//           always on).
//   audit   [PhoneCapabilityAuditRecord] — tool, capability, time, egress and
//           outcome of a real use.
//
// 请求 is a promise, not a decoration
// -----------------------------------
// The request dimension used to be derived from the status alone, which is exact on
// iOS (`.notDetermined` ⇒ the system will prompt) and wrong on Android, where a
// capability can have *no* request path at all: no such permission, no such
// framework, or a grant only the settings app can change. The host now states that
// per row as [PhoneGrantRoute]; a host that says nothing keeps the baseline's own
// rule, so this AAR still renders an iOS-shaped snapshot exactly as before. The rule
// the page enforces for a host that does answer: **a row with no raisable system
// request never offers one** — it is either 去系统设置 (the settings app can change
// it) or BLOCKED (nothing can), and a row that says 去系统设置 renders that one
// control and nothing else.
//
// Section shape (contract: 2 sections, 3 rows)
// --------------------------------------------
// Five group sections whose titles come from the enum — the baseline renders
// `Section(group.title)` (`PhonePermissionsPage.swift:72`), so the caption is data,
// not a literal — followed by the one titled section, 最近使用审计. The five groups
// keep the baseline's membership order, including its own quirk that 后台定位 sits
// in 文件与数据 (`PhoneCapability.swift:60`).
//
// Chrome: there is **no** debug close X and **no** redundant intro row — PR #13
// removed both. The only chrome is the sheet's 完成
// (`PhonePermissionsPage.swift:33`): this is a capability surface, not a dialog.
//
// Copy: the 23 titles and purposes are the baseline's. Four purposes name an
// iOS-only mechanism (Face ID/Touch ID, ActivityKit, MusicKit, FocusStatus) and
// are re-worded for the platform whose page this is; every other purpose is kept
// verbatim. The iOS 18 `ContactAccessButton` for a limited contacts grant has no
// Android counterpart, so that row renders no extra control rather than a fake one.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`,
// `geometry.pageRowMinHeight`, `geometry.cardOuterMarginV`) plus the card shell's
// `radius.card` / `stroke.hairline` / `spacing.cardInset`, which are the tokens the
// baseline's `PageSection` uses. Nothing here re-types a dp, an sp or a colour.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.materialDialogColors
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiTokens
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.util.Locale
import kotlin.math.max

// ---------------------------------------------------------------------------
// Vocabulary: the 23 capabilities and their five groups
// ---------------------------------------------------------------------------

/**
 * One group of capabilities, in the baseline's declaration order.
 *
 * @param id the wire id (`PhoneCapabilityGroup.allCases` raw value), used in test
 *   tags only.
 * @param title the group caption the baseline prints (`PhoneCapability.swift:14`).
 */
public enum class PhoneCapabilityGroup(public val id: String, public val title: String) {
    PERSONAL("personal", "个人信息"),
    DEVICE_SENSORS("deviceSensors", "设备与传感器"),
    SYSTEM_NOTIFICATIONS("systemNotifications", "系统与通知"),
    FILES_DATA("filesData", "文件与数据"),
    HOME_MEDIA("homeMedia", "家庭与媒体"),
}

/**
 * One phone capability the agent can ask for — the 23 `PhoneCapability` cases.
 *
 * @param id the wire id (`PhoneCapability.allCases` raw value).
 * @param title the capability's name (`PhoneCapability.swift:67`).
 * @param purpose what the app does with it (`PhoneCapability.swift:95`); the
 *   confirmation alert shows exactly this sentence.
 * @param group the section it belongs to (`PhoneCapability.swift:56`).
 */
public enum class PhoneCapability(
    public val id: String,
    public val title: String,
    public val purpose: String,
    public val group: PhoneCapabilityGroup,
) {
    CONTACTS(
        "contacts", "通讯录", "仅在你查询时读取联系人；电话和邮箱默认脱敏。", PhoneCapabilityGroup.PERSONAL,
    ),
    CALENDAR(
        "calendar", "日历", "读取你选择时间范围内的日程，并在确认后创建日程。", PhoneCapabilityGroup.PERSONAL,
    ),
    REMINDERS(
        "reminders", "提醒事项", "读取提醒事项，并在确认后创建或完成提醒。", PhoneCapabilityGroup.PERSONAL,
    ),
    HEALTH(
        "health",
        "健康",
        "将读取：步数、睡眠、心率、静息心率、HRV、训练、体重、正念；不写入健康数据。",
        PhoneCapabilityGroup.PERSONAL,
    ),
    PHOTOS(
        "photos", "照片", "读取照片元数据，用于查找最近或指定日期的照片。", PhoneCapabilityGroup.PERSONAL,
    ),
    CAMERA(
        "camera", "相机", "仅在你发起拍摄时采集照片或扫描文稿。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    MICROPHONE(
        "microphone", "麦克风", "仅在你发起录音时采集音频。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    SPEECH(
        "speech", "语音识别", "将你选择的录音转换为文字。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    LOCATION(
        "location", "定位", "仅在你查询时获取一次当前位置。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    MOTION(
        "motion", "运动与健身", "读取你指定时间内的活动与步数。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    BLUETOOTH(
        "bluetooth", "蓝牙", "仅在你发起扫描时发现附近蓝牙设备。", PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    LOCAL_NETWORK(
        "localNetwork",
        "本地网络",
        "点击后通过系统网络浏览器实测局域网发现能力。",
        PhoneCapabilityGroup.DEVICE_SENSORS,
    ),
    NOTIFICATIONS(
        "notifications",
        "通知",
        "仅在你确认后发送本地通知，不接收远程推送。",
        PhoneCapabilityGroup.SYSTEM_NOTIFICATIONS,
    ),
    BIOMETRICS(
        "biometrics",
        "面容确认",
        // iOS says "Face ID 或 Touch ID"; this platform has one system biometric
        // prompt and no Face ID, so the sentence names the mechanism, not a brand.
        "启用后，敏感写操作前需要系统生物识别确认；这不是单独系统授权。",
        PhoneCapabilityGroup.SYSTEM_NOTIFICATIONS,
    ),
    FOCUS(
        "focus",
        "专注模式",
        // iOS reads FocusStatus; Android reads the system interruption filter.
        "读取系统当前是否处于专注（勿扰）状态。",
        PhoneCapabilityGroup.SYSTEM_NOTIFICATIONS,
    ),
    LIVE_ACTIVITY(
        "liveActivity",
        "实时活动",
        // iOS uses ActivityKit; Android's counterpart is the system live-update
        // surface, so the sentence names neither framework.
        "通过系统的实时活动机制创建和更新进行中的活动。",
        PhoneCapabilityGroup.SYSTEM_NOTIFICATIONS,
    ),
    SHORTCUTS(
        "shortcuts",
        "快捷指令",
        "打开指定的快捷指令；跨 App 执行结果无法观测，不承诺已完成。",
        PhoneCapabilityGroup.SYSTEM_NOTIFICATIONS,
    ),
    FILES_FOLDER(
        "filesFolder",
        "文件与文件夹",
        "通过系统选择器授权你选择的文件夹，不读取其它 App 容器。",
        PhoneCapabilityGroup.FILES_DATA,
    ),
    CLIPBOARD(
        "clipboard", "剪贴板", "仅在你明确调用时读取或写入系统剪贴板。", PhoneCapabilityGroup.FILES_DATA,
    ),
    DEVICE(
        "device",
        "设备状态",
        "只读显示设备型号、系统版本和当前时间，始终启用。",
        PhoneCapabilityGroup.FILES_DATA,
    ),
    // The baseline's own grouping (`PhoneCapability.swift:60`): 后台定位 sits in
    // 文件与数据, not in 设备与传感器. Mirrored, not corrected.
    LOCATION_ALWAYS(
        "locationAlways",
        "后台定位",
        "仅在明确创建地理围栏时注册区域监测，不伪造后台事件。",
        PhoneCapabilityGroup.FILES_DATA,
    ),
    HOMEKIT(
        "homekit", "家庭", "读取你授权的家庭与配件，并在确认后写入指定特征。", PhoneCapabilityGroup.HOME_MEDIA,
    ),
    MUSIC(
        "music",
        "音乐",
        // iOS plays through MusicKit; the sentence keeps the promise, not the
        // framework name.
        "通过系统音乐目录播放你指定的真实曲目。",
        PhoneCapabilityGroup.HOME_MEDIA,
    ),
    ;

    /** 设备状态 is the one capability that is always on and cannot be switched off. */
    public val readOnlyAlwaysOn: Boolean get() = this == DEVICE

    public companion object {
        /** The five groups in declaration order. */
        public val groupOrder: List<PhoneCapabilityGroup> get() = PhoneCapabilityGroup.entries.toList()

        /** The capabilities of one group, in declaration order. */
        public fun inGroup(group: PhoneCapabilityGroup): List<PhoneCapability> =
            entries.filter { it.group == group }

        /** The 23 capabilities in declaration order (the page's full matrix). */
        public val matrix: List<PhoneCapability> get() = entries.toList()
    }
}

// ---------------------------------------------------------------------------
// status: what the operating system reports
// ---------------------------------------------------------------------------

/**
 * One authorization state — exactly the seven cases of `CapabilityStatus.swift`,
 * with the baseline's wording and its four behaviours.
 *
 * A row whose status is `null` is 未知 (the host read nothing); there is
 * deliberately no `Unknown` case here, because the enum mirrors iOS and turning
 * "unread" into any of the seven would be a claim.
 */
public sealed interface PhoneCapabilityStatus {
    /** The line the baseline prints for this state (`CapabilityStatus.text`). */
    public val text: String

    /** True when the app may use the capability (its toggle can be on). */
    public val permitsUse: Boolean

    /** True when the system refuses the capability outright on this device. */
    public val blocksInteraction: Boolean

    /** True when a system permission request can still be made. */
    public val canRequest: Boolean

    /** 未请求: nothing asked yet — the one state a fresh request starts from. */
    public data object NotDetermined : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_NOT_DETERMINED
        override val permitsUse: Boolean get() = false
        override val blocksInteraction: Boolean get() = false
        override val canRequest: Boolean get() = true
    }

    /** 已允许. */
    public data object Authorized : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_AUTHORIZED
        override val permitsUse: Boolean get() = true
        override val blocksInteraction: Boolean get() = false
        override val canRequest: Boolean get() = false
    }

    /** 部分允许（N）: the user granted N items only. */
    public data class Limited(public val count: Int) : PhoneCapabilityStatus {
        override val text: String
            get() = String.format(
                Locale.ROOT,
                UiStrings.PHONE_PERMISSIONS_STATUS_LIMITED,
                max(0, count),
            )
        override val permitsUse: Boolean get() = true
        override val blocksInteraction: Boolean get() = false
        override val canRequest: Boolean get() = false
    }

    /** 已拒绝: only the system settings app can change it back. */
    public data object Denied : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_DENIED
        override val permitsUse: Boolean get() = false
        override val blocksInteraction: Boolean get() = false
        override val canRequest: Boolean get() = false
    }

    /** 受系统限制: parental controls / device management; the app cannot fix it. */
    public data object Restricted : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_RESTRICTED
        override val permitsUse: Boolean get() = false
        override val blocksInteraction: Boolean get() = true
        override val canRequest: Boolean get() = false
    }

    /** 已请求: the API does not tell the app whether the user said yes. */
    public data object Requested : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_REQUESTED
        override val permitsUse: Boolean get() = true
        override val blocksInteraction: Boolean get() = false
        override val canRequest: Boolean get() = false
    }

    /** 当前设备不可用: the hardware or the OS version has no such capability. */
    public data object Unavailable : PhoneCapabilityStatus {
        override val text: String get() = UiStrings.PHONE_PERMISSIONS_STATUS_UNAVAILABLE
        override val permitsUse: Boolean get() = false
        override val blocksInteraction: Boolean get() = true
        override val canRequest: Boolean get() = false
    }
}

/** The status line's ink — the baseline's `statusColor` (`PhonePermissionsPage.swift:192`). */
public enum class PhoneStatusTone {
    /** 已允许. */
    AUTHORIZED,

    /** 部分允许 / 未请求 / 已请求: permitted in part, or not yet decided. */
    WARNING,

    /** 已拒绝: the user said no, and only the system settings app can undo it. */
    DANGER,

    /** 受系统限制 / 不可用 / 未知 / 常开: a fact, not a failure. */
    SECONDARY,
}

// ---------------------------------------------------------------------------
// request: what a tap does right now
// ---------------------------------------------------------------------------

/** The next thing a tap on a capability row can do (`PhonePermissionsPage.swift:201`). */
public enum class PhoneCapabilityAction {
    /** 设备状态 is always on: nothing to request and nothing to enable. */
    ALWAYS_ON,

    /** 受系统限制 / 不可用 / 未知, or a request already in flight: controls disabled. */
    BLOCKED,

    /** Already permitted: the tap switches the app's own use on. */
    ENABLE,

    /** 未请求: confirm the purpose, then ask the system. */
    REQUEST,

    /** 已拒绝: the only way back is the system settings app. */
    OPEN_SETTINGS,

    /** 面容确认: one biometric check before the app enables it. */
    CONFIRM_BIOMETRIC,
}

/**
 * How a grant for this capability can be obtained **on this host**, if at all.
 *
 * `status.canRequest` alone cannot answer that on Android: the page's seven statuses
 * are iOS's, and a capability the host reads no status for falls back to
 * [PhoneCapabilityStatus.NotDetermined] — whose `canRequest` is `true` — so a row
 * with *no* request path at all would still be armed as 请求 and a tap would open the
 * confirmation for a system dialog that can never appear. That is the fake control this enum
 * removes: the host states, per capability, which of the three routes exists.
 *
 * Absent from [PhonePermissionsFacts.grantRoutes] means the host did not say, and the
 * page then keeps the baseline's own rule (`status.canRequest` → 请求), which is what
 * an iOS-shaped host needs and what this AAR did before the routes existed.
 */
public enum class PhoneGrantRoute {
    /** A system permission dialog can be raised for this row right now. */
    REQUEST,

    /**
     * The grant is only changed in the system settings app: a special-access page
     * (DND access, background location) has no `requestPermissions` dialog at all,
     * and a revoked or 不再询问 permission is repaired there too.
     */
    SYSTEM_SETTINGS,

    /** No grant exists, or this host has no system page that would grant one. */
    NONE,
}

// ---------------------------------------------------------------------------
// audit: what the phone actually used
// ---------------------------------------------------------------------------

/**
 * One record of a tool actually using a capability.
 *
 * @param tool the tool that used it.
 * @param capability which capability it used.
 * @param at the host's display timestamp; the page never reads or formats a clock.
 * @param egress whether the call left the device.
 * @param outcome the runner's outcome word; [SUCCESS] is the one that reads green.
 */
@Immutable
public data class PhoneCapabilityAuditRecord(
    public val tool: String,
    public val capability: PhoneCapability,
    public val at: String,
    public val egress: Boolean,
    public val outcome: String,
) {
    /** True when the tool call succeeded (`record.outcome == "success"`). */
    public val succeeded: Boolean get() = outcome == SUCCESS

    public companion object {
        /** The outcome word the baseline compares (`PhonePermissionsPage.swift:261`). */
        public const val SUCCESS: String = "success"
    }
}

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The page's read-only input.
 *
 * @param statuses the OS authorization per capability; **`null` means the host did
 *   not read permissions at all** (every row then says 未知), while a missing entry
 *   in a reported map is the baseline's own `.notDetermined` fallback.
 * @param enabled the capabilities this app has switched on (its own store, not the
 *   OS grant); a status that stopped permitting use clears the toggle.
 * @param requesting the capability whose system request is in flight, if any.
 * @param audit the recent uses; `null` means the host reported none, which is not
 *   the same statement as "there were no uses".
 * @param grantRoutes per capability, the one route by which a grant can be obtained
 *   on this host ([PhoneGrantRoute]); a capability absent from the map is "the host
 *   did not say" and keeps the baseline's `status.canRequest` rule.
 */
@Immutable
public data class PhonePermissionsFacts(
    public val statuses: Map<PhoneCapability, PhoneCapabilityStatus>? = null,
    public val enabled: Set<PhoneCapability> = emptySet(),
    public val requesting: PhoneCapability? = null,
    public val audit: List<PhoneCapabilityAuditRecord>? = null,
    public val grantRoutes: Map<PhoneCapability, PhoneGrantRoute> = emptyMap(),
)

// ---------------------------------------------------------------------------
// Local state
// ---------------------------------------------------------------------------

/**
 * The two things this page owns locally: the confirmation the user is looking at
 * and the notice after switching a capability off.
 *
 * @param confirmation the capability awaiting 继续.
 * @param disableNotice the capability that was just switched off.
 */
@Immutable
public data class PhonePermissionsLocalState(
    public val confirmation: PhoneCapability? = null,
    public val disableNotice: PhoneCapability? = null,
)

/** The four local events a permission row can raise. */
public sealed interface PhonePermissionsUiEvent {
    /** The row asked to request this capability: show the purpose first. */
    public data class Confirm(public val capability: PhoneCapability) : PhonePermissionsUiEvent

    /** 取消: drop the confirmation without asking the system. */
    public data object CancelConfirmation : PhonePermissionsUiEvent

    /** The app switched a capability off: say what that did and did not do. */
    public data class NotifyDisabled(public val capability: PhoneCapability) : PhonePermissionsUiEvent

    /** 知道了: drop the disable notice. */
    public data object AcknowledgeDisable : PhonePermissionsUiEvent
}

/** Folds one local event; pure, so a JVM test can replay the sequence. */
public fun PhonePermissionsLocalState.apply(
    event: PhonePermissionsUiEvent,
): PhonePermissionsLocalState = when (event) {
    is PhonePermissionsUiEvent.Confirm -> copy(confirmation = event.capability)
    PhonePermissionsUiEvent.CancelConfirmation -> copy(confirmation = null)
    is PhonePermissionsUiEvent.NotifyDisabled -> copy(disableNotice = event.capability)
    PhonePermissionsUiEvent.AcknowledgeDisable -> copy(disableNotice = null)
}

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** One capability row, projected from (status, app switch, request in flight). */
@Immutable
public data class PhoneCapabilityRowState(
    public val capability: PhoneCapability,
    /** `null` = 未知: the host did not report this capability's permission. */
    public val status: PhoneCapabilityStatus?,
    /** The status line; `null` means the baseline prints no line for this row. */
    public val statusLabel: String?,
    public val tone: PhoneStatusTone,
    public val action: PhoneCapabilityAction,
    /** The toggle position: the app uses it **and** the status permits use. */
    public val enabled: Boolean,
    public val requesting: Boolean,
    public val blocked: Boolean,
    public val showsOpenSettings: Boolean,
    public val showsLimitedPhotos: Boolean,
) {
    /** The a11y label of this row's switch (never the row's own title). */
    public val toggleDescription: String get() = "启用${capability.title}"
}

/** One group section: caption plus its rows. */
@Immutable
public data class PhoneCapabilityGroupView(
    public val group: PhoneCapabilityGroup,
    public val rows: List<PhoneCapabilityRowState> = emptyList(),
) {
    public val id: String get() = group.id
    public val title: String get() = group.title
}

/** One audit row, display-ready. */
@Immutable
public data class PhoneCapabilityAuditRowState(
    public val key: String,
    public val tool: String,
    public val outcome: String,
    public val succeeded: Boolean,
    /** 通讯录 · <when> · egress true — the baseline's one line. */
    public val detail: String,
)

/** The complete phone-permissions screen state. */
@Immutable
public data class PhonePermissionsScreenState(
    public val groups: List<PhoneCapabilityGroupView> = emptyList(),
    /** False when the host reported no statuses at all: every row says 未知. */
    public val statusesKnown: Boolean = false,
    public val confirmation: PhoneCapability? = null,
    public val confirmationPurpose: String? = null,
    public val disableNotice: PhoneCapability? = null,
    public val disableNoticeBody: String? = null,
    /** The audit rows, or `null` when the host did not report an audit. */
    public val audit: List<PhoneCapabilityAuditRowState>? = null,
) {
    public companion object {
        /** The baseline shows the last 20 records (`PhonePermissionsPage.swift:91`). */
        public const val AUDIT_LIMIT: Int = 20

        /**
         * Projects the facts into the two-section page; pure, no clock and no I/O.
         *
         * @param facts the host's read-only snapshot.
         * @param local the two local dialogs.
         */
        public fun from(
            facts: PhonePermissionsFacts,
            local: PhonePermissionsLocalState = PhonePermissionsLocalState(),
        ): PhonePermissionsScreenState {
            val statuses = facts.statuses
            val notice = local.disableNotice
            return PhonePermissionsScreenState(
                groups = PhoneCapability.groupOrder.map { group ->
                    PhoneCapabilityGroupView(
                        group = group,
                        rows = PhoneCapability.inGroup(group).map { capability ->
                            rowState(capability, statuses, facts)
                        },
                    )
                },
                statusesKnown = statuses != null,
                confirmation = local.confirmation,
                confirmationPurpose = local.confirmation?.purpose,
                disableNotice = notice,
                disableNoticeBody = notice?.let(::disableNoticeBody),
                audit = facts.audit
                    ?.take(AUDIT_LIMIT)
                    ?.mapIndexed { index, record ->
                        PhoneCapabilityAuditRowState(
                            key = "${record.capability.id}#$index",
                            tool = record.tool,
                            outcome = record.outcome,
                            succeeded = record.succeeded,
                            detail = "${record.capability.title} · ${record.at} · " +
                                "egress ${record.egress}",
                        )
                    },
            )
        }

        private fun rowState(
            capability: PhoneCapability,
            statuses: Map<PhoneCapability, PhoneCapabilityStatus>?,
            facts: PhonePermissionsFacts,
        ): PhoneCapabilityRowState {
            // A reported map without this capability is the baseline's own
            // `.notDetermined` fallback (`PhonePermissionsPage.swift:178`); a host
            // that reported nothing keeps `null`, which is 未知 and not a guess.
            val status = statuses?.let { it[capability] ?: PhoneCapabilityStatus.NotDetermined }
            val requesting = facts.requesting == capability
            val grantRoute = facts.grantRoutes[capability]
            val action = actionFor(capability, status, requesting, grantRoute)
            return PhoneCapabilityRowState(
                capability = capability,
                status = status,
                statusLabel = statusLabel(capability, status),
                tone = tone(capability, status),
                action = action,
                enabled = capability in facts.enabled && status?.permitsUse == true,
                requesting = requesting,
                // Dimming follows the baseline's `.opacity(blocksInteraction ? 0.4 : 1)`
                // exactly: only 受系统限制 / 当前设备不可用 dim a row. An unread status
                // keeps its ink — the row already says 未知 and its controls are
                // disabled, so dimming it would fade a page that is merely unread
                // instead of refused (and 设备状态, always on, is never dimmed).
                blocked = status?.blocksInteraction == true,
                // The visible repair verb is 去系统设置 exactly when that is what a
                // tap does: a 已拒绝 row, and a row whose grant only exists in the
                // settings app (no request dialog for it at all). Printing it for a
                // row whose action is requested instead would be a second, dead
                // control on the same row.
                showsOpenSettings = action == PhoneCapabilityAction.OPEN_SETTINGS,
                showsLimitedPhotos = status is PhoneCapabilityStatus.Limited &&
                    capability == PhoneCapability.PHOTOS,
            )
        }

        /**
         * The status line, exactly as the baseline composes it
         * (`PhonePermissionsPage.swift:181`).
         *
         * `null` means "print no line": an untouched capability needs no label, the
         * title and the purpose copy already say it is available.
         */
        public fun statusLabel(
            capability: PhoneCapability,
            status: PhoneCapabilityStatus?,
        ): String? = when {
            capability == PhoneCapability.DEVICE ->
                UiStrings.PHONE_PERMISSIONS_STATUS_ALWAYS_ON
            // No read: the row says so instead of borrowing any of the seven cases.
            status == null -> UiStrings.UNKNOWN
            capability == PhoneCapability.LOCAL_NETWORK &&
                status == PhoneCapabilityStatus.NotDetermined ->
                UiStrings.PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_UNVERIFIED
            capability == PhoneCapability.LOCAL_NETWORK &&
                status == PhoneCapabilityStatus.Denied ->
                UiStrings.PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_DENIED
            capability == PhoneCapability.BIOMETRICS &&
                status == PhoneCapabilityStatus.Authorized ->
                UiStrings.PHONE_PERMISSIONS_STATUS_BIOMETRIC_CONFIRM
            status == PhoneCapabilityStatus.NotDetermined -> null
            else -> status.text
        }

        /** The status line's ink (`PhonePermissionsPage.swift:192`). */
        public fun tone(
            capability: PhoneCapability,
            status: PhoneCapabilityStatus?,
        ): PhoneStatusTone = when {
            // 设备状态 is always on; it is never an approval the user gave.
            capability == PhoneCapability.DEVICE -> PhoneStatusTone.SECONDARY
            status == null -> PhoneStatusTone.SECONDARY
            status == PhoneCapabilityStatus.Authorized -> PhoneStatusTone.AUTHORIZED
            status is PhoneCapabilityStatus.Limited ||
                status == PhoneCapabilityStatus.NotDetermined ||
                status == PhoneCapabilityStatus.Requested -> PhoneStatusTone.WARNING
            status == PhoneCapabilityStatus.Denied -> PhoneStatusTone.DANGER
            else -> PhoneStatusTone.SECONDARY
        }

        /**
         * What the next tap does (`PhonePermissionsPage.swift:201`), narrowed by the
         * host's own answer about how a grant can be obtained.
         *
         * @param grantRoute [PhoneGrantRoute] for this row, or `null` when the host
         *   did not say (the baseline's rule then applies: 未请求 → 请求).
         */
        public fun actionFor(
            capability: PhoneCapability,
            status: PhoneCapabilityStatus?,
            requesting: Boolean,
            grantRoute: PhoneGrantRoute? = null,
        ): PhoneCapabilityAction = when {
            capability.readOnlyAlwaysOn -> PhoneCapabilityAction.ALWAYS_ON
            requesting || status == null -> PhoneCapabilityAction.BLOCKED
            status.blocksInteraction -> PhoneCapabilityAction.BLOCKED
            status == PhoneCapabilityStatus.Denied -> PhoneCapabilityAction.OPEN_SETTINGS
            capability == PhoneCapability.BIOMETRICS -> PhoneCapabilityAction.CONFIRM_BIOMETRIC
            status.permitsUse -> PhoneCapabilityAction.ENABLE
            // 请求 only where the host said a system dialog can be raised. Without a
            // route the page keeps the baseline's own rule, because an iOS-shaped
            // host reports `notDetermined` for a row it really can ask about.
            status.canRequest &&
                (grantRoute == null || grantRoute == PhoneGrantRoute.REQUEST) ->
                PhoneCapabilityAction.REQUEST
            grantRoute == PhoneGrantRoute.SYSTEM_SETTINGS -> PhoneCapabilityAction.OPEN_SETTINGS
            else -> PhoneCapabilityAction.BLOCKED
        }

        /** The disable notice's sentence (`PhonePermissionsPage.swift:56`). */
        public fun disableNoticeBody(capability: PhoneCapability): String =
            String.format(
                Locale.ROOT,
                UiStrings.PHONE_PERMISSIONS_DISABLE_BODY,
                capability.title,
            )
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The phone-permissions page.
 *
 * @param state the pure screen state (`PhonePermissionsScreenState.from`).
 * @param onDone the sheet's 完成.
 * @param embedded render inside the settings sheet's tab slot: no page header and
 *   no 完成 of its own, because the shell already draws both.
 * @param onTapCapability the row (not its switch) was tapped; the host performs
 *   [PhoneCapabilityRowState.action].
 * @param onToggleCapability the switch was flipped: `true` asks for the same
 *   activation as a tap, `false` only switches the app's own use off.
 * @param onOpenSettings 去系统设置: open the system page that can change **this
 *   capability's** grant. It carries the capability because the page has two rows
 *   that lead to two different pages (一个已拒绝的运行时权限 opens the app's own
 *   settings; 专注模式 opens the DND-access page, which is not under app settings).
 * @param onManagePhotos 管理可访问照片: open the limited-library picker.
 * @param onConfirmRequest 继续 in the confirmation: perform the row's request.
 * @param onCancelConfirmation 取消 in the confirmation.
 * @param onAcknowledgeDisable 知道了 in the disable notice.
 * @param onDismissDisable the disable notice was dismissed without a button.
 */
@Composable
public fun PhonePermissionsPage(
    state: PhonePermissionsScreenState,
    onDone: () -> Unit = {},
    modifier: Modifier = Modifier,
    embedded: Boolean = false,
    onTapCapability: (PhoneCapability) -> Unit = {},
    onToggleCapability: (PhoneCapability, Boolean) -> Unit = { _, _ -> },
    onOpenSettings: (PhoneCapability) -> Unit = {},
    onManagePhotos: () -> Unit = {},
    onConfirmRequest: () -> Unit = {},
    onCancelConfirmation: () -> Unit = {},
    onAcknowledgeDisable: () -> Unit = {},
    onDismissDisable: () -> Unit = {},
) {
    if (embedded) {
        // The settings shell owns the bar and the segmented picker, so the tab body
        // consumes the horizontal insets and the navigation bar only.
        Box(
            modifier = modifier
                .fillMaxSize()
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(
                        WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                    ),
                ),
        ) {
            PhonePermissionsBody(
                state = state,
                onTapCapability = onTapCapability,
                onToggleCapability = onToggleCapability,
                onOpenSettings = onOpenSettings,
                onManagePhotos = onManagePhotos,
            )
        }
    } else {
        PageFrame(
            title = UiStrings.PHONE_PERMISSIONS_TITLE,
            onBack = onDone,
            modifier = modifier,
            actions = {
                SessionTextAction(
                    label = UiStrings.SETTINGS_DONE,
                    onClick = onDone,
                    tone = SessionActionTone.ACCENT,
                )
            },
        ) {
            PhonePermissionsBody(
                state = state,
                onTapCapability = onTapCapability,
                onToggleCapability = onToggleCapability,
                onOpenSettings = onOpenSettings,
                onManagePhotos = onManagePhotos,
            )
        }
    }
    // Both dialogs live above the page: the settings tab and the pushed route show
    // the same two confirmations.
    state.confirmationPurpose?.let { purpose ->
        ConfirmationDialog(
            purpose = purpose,
            onCancel = onCancelConfirmation,
            onContinue = onConfirmRequest,
        )
    }
    state.disableNoticeBody?.let { notice ->
        val capability = state.disableNotice
        DisableNoticeDialog(
            body = notice,
            onAcknowledge = onAcknowledgeDisable,
            // The notice's 去系统设置 is about the capability it just switched off,
            // so it opens that capability's page, not a generic app-settings one.
            onOpenSettings = { if (capability != null) onOpenSettings(capability) },
            onDismiss = onDismissDisable,
        )
    }
}

/** The list: five capability groups in the baseline's order, then the audit. */
@Composable
private fun PhonePermissionsBody(
    state: PhonePermissionsScreenState,
    onTapCapability: (PhoneCapability) -> Unit,
    onToggleCapability: (PhoneCapability, Boolean) -> Unit,
    onOpenSettings: (PhoneCapability) -> Unit,
    onManagePhotos: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PHONE_PERMISSIONS_LIST)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        // unverified geometry: `spec/ui/v1/tokens.json` declares no page-level card
        // gap, so the approval card's outer vertical margin carries the gap between
        // this page's cards (and the list's own top/bottom inset).
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.cardOuterMarginV),
        contentPadding = PaddingValues(vertical = tokens.geometry.cardOuterMarginV),
    ) {
        state.groups.forEach { group ->
            item(key = "group-${group.id}") {
                SessionSectionLabel(group.title)
            }
            item(key = "card-${group.id}") {
                CapabilityGroupCard(
                    rows = group.rows,
                    onTapCapability = onTapCapability,
                    onToggleCapability = onToggleCapability,
                    onOpenSettings = onOpenSettings,
                    onManagePhotos = onManagePhotos,
                )
            }
        }
        item(key = "audit-header") {
            SessionSectionLabel(UiStrings.PHONE_PERMISSIONS_AUDIT_SECTION)
        }
        item(key = "audit") {
            AuditCard(state.audit)
        }
    }
}

/** One group's card: a hairline-bordered block of capability rows. */
@Composable
private fun CapabilityGroupCard(
    rows: List<PhoneCapabilityRowState>,
    onTapCapability: (PhoneCapability) -> Unit,
    onToggleCapability: (PhoneCapability, Boolean) -> Unit,
    onOpenSettings: (PhoneCapability) -> Unit,
    onManagePhotos: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
    ) {
        rows.forEachIndexed { index, row ->
            if (index > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(tokens.stroke.hairline)
                        .background(tokens.colors.border),
                )
            }
            CapabilityRow(
                row = row,
                onTapCapability = onTapCapability,
                onToggleCapability = onToggleCapability,
                onOpenSettings = onOpenSettings,
                onManagePhotos = onManagePhotos,
            )
        }
    }
}

/**
 * One capability: name, purpose, status, its switch, and — only where the status
 * earns it — the one repair action (去系统设置 for 已拒绝, 管理可访问照片 for a
 * limited photo library).
 */
@Composable
private fun CapabilityRow(
    row: PhoneCapabilityRowState,
    onTapCapability: (PhoneCapability) -> Unit,
    onToggleCapability: (PhoneCapability, Boolean) -> Unit,
    onOpenSettings: (PhoneCapability) -> Unit,
    onManagePhotos: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PHONE_PERMISSIONS_ROW_PREFIX + row.capability.id)
            // The baseline dims a capability the system refuses
            // (`PhonePermissionsPage.swift:75`, `.opacity(0.4)`).
            .graphicsLayer { alpha = if (row.blocked) BLOCKED_ALPHA else 1f },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            // The tap target is the whole text block, never the switch: a tap asks
            // for the capability, the switch is the app's own on/off.
            Column(
                modifier = Modifier
                    .weight(1f)
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .clickable(
                        enabled = row.action != PhoneCapabilityAction.BLOCKED &&
                            row.action != PhoneCapabilityAction.ALWAYS_ON,
                        role = Role.Button,
                        onClick = { onTapCapability(row.capability) },
                    )
                    .semantics(mergeDescendants = true) {},
                verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
            ) {
                BasicText(
                    text = row.capability.title,
                    style = type.subheadline.copy(color = tokens.colors.primary),
                )
                BasicText(
                    text = row.capability.purpose,
                    style = type.caption.copy(color = tokens.colors.secondary),
                )
                row.statusLabel?.let { label ->
                    BasicText(
                        text = label,
                        style = type.caption.copy(color = row.tone.ink(tokens)),
                    )
                }
            }
            CapabilitySwitch(row = row, onToggleCapability = onToggleCapability)
        }
        if (row.showsOpenSettings) {
            SessionTextAction(
                label = UiStrings.PHONE_PERMISSIONS_OPEN_SETTINGS,
                onClick = { onOpenSettings(row.capability) },
                tone = SessionActionTone.ACCENT,
            )
        }
        if (row.showsLimitedPhotos) {
            SessionTextAction(
                label = UiStrings.PHONE_PERMISSIONS_MANAGE_PHOTOS,
                onClick = onManagePhotos,
                tone = SessionActionTone.ACCENT,
            )
        }
    }
}

/**
 * One capability's switch.
 *
 * Its own composable so the row's *text* never becomes the switch's accessible
 * label: the baseline labels the toggle 启用{capability.title}
 * (`PhonePermissionsPage.swift:133`), and the switch keeps that name while the
 * row's tap target stays a different control.
 */
@Composable
private fun CapabilitySwitch(
    row: PhoneCapabilityRowState,
    onToggleCapability: (PhoneCapability, Boolean) -> Unit,
) {
    Box {
        Switch(
            checked = row.enabled,
            onCheckedChange = { value -> onToggleCapability(row.capability, value) },
            enabled = row.action != PhoneCapabilityAction.BLOCKED &&
                row.action != PhoneCapabilityAction.ALWAYS_ON &&
                !row.requesting,
            modifier = Modifier
                .testTag(UiPageTags.PHONE_PERMISSIONS_TOGGLE_PREFIX + row.capability.id)
                .semantics { contentDescription = row.toggleDescription },
        )
    }
}

/** The 最近使用审计 card: the last 20 uses, plus an honest unknown state. */
@Composable
private fun AuditCard(audit: List<PhoneCapabilityAuditRowState>?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.PHONE_PERMISSIONS_AUDIT)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.card),
            )
            .padding(tokens.spacing.cardInset),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
    ) {
        when {
            // The host did not report an audit: say so instead of claiming "none".
            audit == null -> BasicText(
                text = UiStrings.PHONE_PERMISSIONS_AUDIT_UNKNOWN,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )

            audit.isEmpty() -> BasicText(
                text = UiStrings.PHONE_PERMISSIONS_AUDIT_EMPTY,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier.testTag(UiPageTags.PHONE_PERMISSIONS_AUDIT_EMPTY),
            )

            else -> audit.forEach { record -> AuditRow(record) }
        }
    }
}

/** One audit record: the tool and its outcome, then the capability and the time. */
@Composable
private fun AuditRow(record: PhoneCapabilityAuditRowState) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            BasicText(
                text = record.tool,
                style = type.code.copy(color = tokens.colors.primary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = record.outcome,
                style = type.caption.copy(
                    color = if (record.succeeded) tokens.colors.success else tokens.colors.warning,
                ),
            )
        }
        BasicText(
            text = record.detail,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
    }
}

/** 允许使用这项能力？ — the purpose first, then 取消 / 继续. */
@Composable
private fun ConfirmationDialog(
    purpose: String,
    onCancel: () -> Unit,
    onContinue: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val palette = materialDialogColors(tokens)
    AlertDialog(
        onDismissRequest = onCancel,
        title = {
            BasicText(
                text = UiStrings.PHONE_PERMISSIONS_CONFIRM_TITLE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            BasicText(
                text = purpose,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        },
        confirmButton = {
            DialogAction(
                label = UiStrings.PHONE_PERMISSIONS_CONTINUE,
                onClick = onContinue,
                tag = UiPageTags.PHONE_PERMISSIONS_CONFIRM_CONTINUE,
            )
        },
        dismissButton = {
            DialogAction(
                label = UiStrings.CANCEL,
                onClick = onCancel,
                tag = UiPageTags.PHONE_PERMISSIONS_CONFIRM_CANCEL,
            )
        },
        containerColor = palette.container,
        textContentColor = palette.content,
    )
}

/** 已停用应用内使用 — 知道了 / 去系统设置. */
@Composable
private fun DisableNoticeDialog(
    body: String,
    onAcknowledge: () -> Unit,
    onOpenSettings: () -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val palette = materialDialogColors(tokens)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            BasicText(
                text = UiStrings.PHONE_PERMISSIONS_DISABLE_TITLE,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            BasicText(
                text = body,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        },
        confirmButton = {
            DialogAction(
                label = UiStrings.PHONE_PERMISSIONS_DISABLE_ACK,
                onClick = onAcknowledge,
                tag = UiPageTags.PHONE_PERMISSIONS_DISABLE_ACK,
            )
        },
        dismissButton = {
            DialogAction(
                label = UiStrings.PHONE_PERMISSIONS_OPEN_SETTINGS,
                onClick = onOpenSettings,
                tag = UiPageTags.PHONE_PERMISSIONS_DISABLE_SETTINGS,
            )
        },
        containerColor = palette.container,
        textContentColor = palette.content,
    )
}

/** One dialog button; the label is a parameter, the call sites stay readable. */
@Composable
private fun DialogAction(label: String, onClick: () -> Unit, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    TextButton(
        onClick = onClick,
        colors = ButtonDefaults.textButtonColors(contentColor = tokens.colors.secondary),
        modifier = Modifier.testTag(tag),
    ) {
        BasicText(text = label, style = type.body.copy(color = tokens.colors.secondary))
    }
}

// ---------------------------------------------------------------------------
// Constants and the token inventory
// ---------------------------------------------------------------------------

/**
 * The dimming of a capability the system refuses — the baseline's
 * `.opacity(status.blocksInteraction ? 0.4 : 1)`.
 *
 * Not a token: the token table declares no opacity, and this is the baseline's own
 * number rather than a second design source.
 */
private const val BLOCKED_ALPHA: Float = 0.4f

/** The ink for a status tone; every branch is a colour token. */
private fun PhoneStatusTone.ink(tokens: UiTokens): Color = when (this) {
    PhoneStatusTone.AUTHORIZED -> tokens.colors.success
    PhoneStatusTone.WARNING -> tokens.colors.warning
    PhoneStatusTone.DANGER -> tokens.colors.danger
    PhoneStatusTone.SECONDARY -> tokens.colors.secondary
}

/**
 * The token inventory of this page.
 *
 * `PageTokenReferenceTest` asserts that this list equals the tokens the source
 * reads, so an unlisted use and a stale entry both fail.
 */
internal object PhonePermissionsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.COLORS_SUCCESS,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_SUBHEADLINE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
    )
}

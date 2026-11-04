// The phone-permissions matrix's host half: Android readings in, page statuses out.
// SPDX-License-Identifier: MIT
//
// The page's 23 capabilities are iOS's vocabulary (`PhoneCapability`), and Android's
// permission model is not iOS's. This file is the whole translation, one row per
// capability, and its rule is: a status is reported only when something on this
// device actually reports it. Everything else is left out of the map, because a
// reported map entry is a claim (`PhonePermissionsPage.kt:15`).
//
// The read arrives as `:domain`'s `HostPermissionReadings` (see
// `AndroidHostPermissions`), which is the measured half of the device capability
// layer: the merged manifest's permissions, the grant state the platform reports,
// device-admin denials, the notification app-op, DND access, and hardware/service
// presence. Nothing here re-reads the platform, and nothing here invents a value.
//
// Row by row
// ----------
//  * 通讯录 / 日历 / 相机 / 麦克风 / 语音识别 / 定位 / 运动与健身 / 蓝牙 / 后台定位:
//    a declared runtime permission, read through `permissionStatus` below. Declared
//    and granted → 已允许; declared, policy-denied → 受系统限制; declared, not granted
//    and never asked → 未请求; declared, not granted and already asked (the user
//    answered with a refusal) → 已拒绝 — see the caveat on that function and
//    `PhonePermissionAsks`; *not* declared → no status, because Android reports no
//    grant state for a permission the app never declares, and "当前设备不可用" would be
//    a lie about the hardware.
//  * 照片: the media permission of this API level (READ_MEDIA_IMAGES from 33,
//    READ_EXTERNAL_STORAGE below). Android 14's partial grant
//    (READ_MEDIA_VISUAL_USER_SELECTED) is deliberately *not* mapped to
//    `Limited(N)`: the platform hands out no count, and 部分允许（N） with an invented
//    N would be worse than no line at all (reported as an open question).
//  * 通知: the POST_NOTIFICATIONS permission (33+) *and* the notification app-op,
//    which exists on every level. A granted permission with the app-op off is the
//    user's 已拒绝; a not-yet-granted permission is 未请求 until this app has asked,
//    and 已拒绝 afterwards (the same ask log as the rows above).
//  * 专注模式: notification-policy (DND) access, the grant behind reading the
//    interruption filter. Granted → 已允许; not granted → 未请求.
//  * 面容确认: not a system authorization on either platform (the page's own purpose
//    says so). The measurable half is whether a confirmation *can* run — biometric
//    hardware plus a secure lock screen — and that is all this row reports; with
//    both present it reports nothing rather than borrowing a grant.
//  * 提醒事项 / 实时活动 / 快捷指令 / 家庭: no Android framework provides the
//    capability (Reminders and HomeKit have no Android counterpart; ActivityKit's
//    live activity has no public API at this API level; there is no system-wide
//    shortcut runner). 当前设备不可用 is exactly true for these four and is reported
//    on every Android device, not just this one.
//  * 健康: no status. This app declares none of Health Connect's per-type permissions,
//    and the module's presence cannot be read from an app without a `<queries>`
//    element (package visibility). The row stays unread rather than claiming the
//    device lacks Health Connect.
//  * 本地网络 / 文件与文件夹 / 剪贴板 / 音乐: Android has no authorization to read
//    for these. Local-network access is ungated (no permission exists), a folder is
//    granted per-URI by the system picker, the clipboard is a foreground-only app
//    policy with no grant, and the closest thing to a system music catalog is
//    MediaStore plus a third-party player. A status here would describe a platform
//    policy, not this device's state, so the rows stay unread (the page prints no
//    line for them) instead of being filled with a plausible-looking 已允许.
//  * 设备状态: the one capability that needs no permission and that this host really
//    reads (model, API level, time). 已允许 records "nothing gates it"; the page
//    prints 常开 for this row regardless (`PhonePermissionsPage.kt:637`).
//
// What is *not* in this file: the audit, and the request itself.
//
//  * the audit: this host has no capability-use audit — the engine's tool calls are
//    not capability uses (no tool reports which device permission it exercised) and
//    the device connector's transcript is demo data — so `PhonePermissionsFacts.audit`
//    stays `null` and the page says 宿主没有报告使用审计 instead of claiming
//    暂无使用记录;
//  * the request: `requestPermissions` belongs to the Activity, so the decision table
//    ("can this row raise a dialog, and which permission?") is
//    `PhonePermissionRequests.kt` and the launchers are `MainActivity`'s. This file
//    consumes both — the routes it reports are what stops the page arming a 请求 for
//    a row no prompt can be raised for.
package com.phonedsh.probe

import com.phonedsh.domain.device.AndroidHostPermissions
import com.phonedsh.domain.device.HostPermissionReadings
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneCapabilityStatus
import com.phonedsh.ui.page.PhonePermissionsFacts

/**
 * Projects one host read into the page's facts.
 *
 * @param readings this host's permission/hardware snapshot.
 * @param asked the permissions this app has already sent to the platform (see
 *   `PhonePermissionAsks`): the only record that can tell 未请求 from 已拒绝, because
 *   Android answers the same DENIED for both.
 * @param inFlight the capability whose system prompt is on screen, or `null`.
 */
internal fun phonePermissionsFacts(
    readings: HostPermissionReadings,
    asked: Set<String> = emptySet(),
    inFlight: PhoneCapability? = null,
): PhonePermissionsFacts =
    PhonePermissionsFacts(
        statuses = phonePermissionStatuses(readings, asked),
        // This host has no capability-enable store: the page's switch is the app's
        // own on/off and nothing turns one on, so an empty set here means "nothing is
        // enabled", not "nothing was read". A status that stops permitting use clears
        // the toggle in the page's own projection.
        enabled = emptySet(),
        // The one real request this host can have in flight: `null` except between a
        // 继续 and the platform's answer, which is exactly what the page's
        // `requesting` means — and what disarms the row while the dialog is up.
        requesting = inFlight,
        // No capability-use audit on this host; see the file comment. `null` is the
        // page's 宿主没有报告使用审计, which is a different statement from an empty
        // list's 暂无使用记录.
        audit = null,
        // The request half: for which of the 23 rows a system dialog can be raised at
        // all. Reported for every capability (`PhonePermissionRequests.kt`), so a row
        // with no request path can never render 请求.
        grantRoutes = phoneGrantRoutes(readings),
    )

/**
 * The statuses this host can actually report, in the matrix's declaration order.
 *
 * A capability whose status cannot be read is **absent** from the map. That is the
 * only way this host can say "no status": the facts' map cannot hold a null value,
 * and the page's own projection turns a missing entry into `NotDetermined`
 * (`PhonePermissionsPage.kt:604`) — for which it prints *no* status line
 * (`:650`), rather than the word 未知 that a `statuses == null` facts value would
 * print on every row. Both are "no claim"; only the whole-map `null` can produce
 * literal 未知, and it would also erase the rows this host did read.
 */
internal fun phonePermissionStatuses(
    readings: HostPermissionReadings,
    asked: Set<String> = emptySet(),
): Map<PhoneCapability, PhoneCapabilityStatus> {
    val statuses = LinkedHashMap<PhoneCapability, PhoneCapabilityStatus>()
    PhoneCapability.matrix.forEach { capability ->
        statusOf(capability, readings, asked)?.let { statuses[capability] = it }
    }
    return statuses
}

/** One row's decision; `null` means "this host reports no status for it". */
private fun statusOf(
    capability: PhoneCapability,
    readings: HostPermissionReadings,
    asked: Set<String>,
): PhoneCapabilityStatus? = when (capability) {
    PhoneCapability.CONTACTS ->
        permissionStatus(readings, asked, AndroidHostPermissions.READ_CONTACTS)
    PhoneCapability.CALENDAR ->
        permissionStatus(readings, asked, AndroidHostPermissions.READ_CALENDAR)
    PhoneCapability.REMINDERS -> PhoneCapabilityStatus.Unavailable
    // 健康: this app declares none of Health Connect's per-type permissions, and the
    // module's *presence* is not readable from an app without a `<queries>` element
    // (package visibility filters both `getPackageInfo` and `getPermissionInfo` —
    // measured on the android-35 emulator, which has Health Connect installed and
    // answers NameNotFound from the app). So this row reports nothing: 未知 rather than
    // a 当前设备不可用 the host cannot prove.
    PhoneCapability.HEALTH -> null
    PhoneCapability.PHOTOS -> permissionStatus(
        readings,
        asked,
        // The photo permission is the media permission from API 33 and the storage
        // permission below it; neither is declared by this app, but the row must not
        // silently ignore a grant on a build that does declare one.
        if (readings.sdkInt >= 33) {
            AndroidHostPermissions.READ_MEDIA_IMAGES
        } else {
            AndroidHostPermissions.READ_EXTERNAL_STORAGE
        },
    )

    PhoneCapability.CAMERA -> hardware(
        readings.cameraPresent,
        permissionStatus(readings, asked, AndroidHostPermissions.CAMERA),
    )

    PhoneCapability.MICROPHONE -> hardware(
        readings.microphonePresent,
        permissionStatus(readings, asked, AndroidHostPermissions.RECORD_AUDIO),
    )

    // 语音识别 needs the same microphone grant the recognizer reads through; the
    // recognizer's own presence is the part Android can answer separately.
    PhoneCapability.SPEECH -> hardware(
        readings.speechRecognitionAvailable,
        permissionStatus(readings, asked, AndroidHostPermissions.RECORD_AUDIO),
    )

    PhoneCapability.LOCATION -> hardware(
        readings.locationPresent,
        permissionStatus(
            readings,
            asked,
            AndroidHostPermissions.ACCESS_FINE_LOCATION,
            AndroidHostPermissions.ACCESS_COARSE_LOCATION,
        ),
    )

    PhoneCapability.MOTION -> hardware(
        readings.stepCounterPresent,
        permissionStatus(readings, asked, AndroidHostPermissions.ACTIVITY_RECOGNITION),
    )

    PhoneCapability.BLUETOOTH -> hardware(
        readings.bluetoothPresent,
        permissionStatus(
            readings,
            asked,
            if (readings.sdkInt >= 31) {
                AndroidHostPermissions.BLUETOOTH_SCAN
            } else {
                AndroidHostPermissions.BLUETOOTH
            },
        ),
    )

    PhoneCapability.LOCAL_NETWORK -> null
    PhoneCapability.NOTIFICATIONS -> notificationsStatus(readings, asked)
    PhoneCapability.BIOMETRICS -> when {
        !readings.biometricHardwarePresent -> PhoneCapabilityStatus.Unavailable
        readings.deviceSecure == false -> PhoneCapabilityStatus.Unavailable
        else -> null
    }

    PhoneCapability.FOCUS -> if (readings.notificationPolicyAccessGranted) {
        PhoneCapabilityStatus.Authorized
    } else {
        PhoneCapabilityStatus.NotDetermined
    }

    PhoneCapability.LIVE_ACTIVITY -> PhoneCapabilityStatus.Unavailable
    PhoneCapability.SHORTCUTS -> PhoneCapabilityStatus.Unavailable
    PhoneCapability.FILES_FOLDER -> null
    PhoneCapability.CLIPBOARD -> null
    PhoneCapability.DEVICE -> PhoneCapabilityStatus.Authorized
    PhoneCapability.LOCATION_ALWAYS -> hardware(
        readings.locationPresent,
        permissionStatus(readings, asked, AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION),
    )

    PhoneCapability.HOMEKIT -> PhoneCapabilityStatus.Unavailable
    PhoneCapability.MUSIC -> null
}

/**
 * A `false` device reading of a capability's prerequisite is `Unavailable` — the
 * page's own words for "the hardware or the OS version has no such capability"
 * (`PhonePermissionsPage.kt:347`). A `null` reading (the platform service was
 * missing) is *not* evidence of absence, so it reports nothing; and when the device
 * does support the capability, the permission rule decides.
 */
private fun hardware(
    present: Boolean?,
    status: PhoneCapabilityStatus?,
): PhoneCapabilityStatus? = when (present) {
    false -> PhoneCapabilityStatus.Unavailable
    true -> status
    null -> null
}

/**
 * The status of a runtime-permission-backed capability.
 *
 * * policy-denied → 受系统限制 (Android's device-admin restriction; the app cannot
 *   fix it, which is exactly what the page's `Restricted` means);
 * * granted → 已允许;
 * * declared, not granted, never asked → 未请求;
 * * declared, not granted, **already asked** → 已拒绝;
 * * not declared → **no status**. This app's merged manifest declares none of these
 *   permissions today, so the platform answers PERMISSION_DENIED for a request the
 *   app never made — that is the absence of a declaration, not a user decision.
 *   The row's hardware half (where it has one) still reports 当前设备不可用 when the
 *   device really lacks the capability, and otherwise the row stays unread.
 *
 * The 已拒绝 branch is the request lane's one input: Android answers the same DENIED
 * for "never asked" and "asked and refused", so the only record of the difference is
 * this app's own ask log ([asked], `PhonePermissionAsks`). Once the user has answered
 * a request with a refusal — with 不再询问, or with the second denial after which the
 * platform stops drawing the dialog — a second `requestPermissions` returns DENIED
 * without showing anything, so the row must say 已拒绝 and offer 去系统设置 instead of
 * arming a 请求 the platform would swallow. That is what [asked] decides.
 */
private fun permissionStatus(
    readings: HostPermissionReadings,
    asked: Set<String>,
    vararg permissions: String,
): PhoneCapabilityStatus? {
    val declared = permissions.filter(readings::declares)
    if (declared.isEmpty()) return null
    if (declared.any(readings::policyDenied)) return PhoneCapabilityStatus.Restricted
    return when {
        declared.any(readings::granted) -> PhoneCapabilityStatus.Authorized
        declared.any(asked::contains) -> PhoneCapabilityStatus.Denied
        else -> PhoneCapabilityStatus.NotDetermined
    }
}

/**
 * 通知: the runtime permission (API 33+) and the notification app-op.
 *
 * The permission answers "did the platform grant the manifest's request"; the
 * app-op answers "may this app notify right now". A granted permission with the
 * app-op off is the user's own 已拒绝 (only the system settings app turns it back
 * on), and an app-op that could not be read is no claim. Below API 33 there is no
 * runtime permission at all, so the app-op is the whole story.
 */
private fun notificationsStatus(
    readings: HostPermissionReadings,
    asked: Set<String>,
): PhoneCapabilityStatus? {
    if (readings.sdkInt >= 33) {
        if (readings.policyDenied(AndroidHostPermissions.POST_NOTIFICATIONS)) {
            return PhoneCapabilityStatus.Restricted
        }
        // An app that does not declare the permission has no grant state and no
        // prompt: reporting 未请求 would arm a request the platform refuses.
        if (!readings.declares(AndroidHostPermissions.POST_NOTIFICATIONS)) return null
        if (!readings.granted(AndroidHostPermissions.POST_NOTIFICATIONS)) {
            // Already answered with a refusal ⇒ 已拒绝, exactly as the runtime rows
            // above decide it from the same ask log.
            return if (asked.contains(AndroidHostPermissions.POST_NOTIFICATIONS)) {
                PhoneCapabilityStatus.Denied
            } else {
                PhoneCapabilityStatus.NotDetermined
            }
        }
    }
    return when (readings.notificationsEnabled) {
        true -> PhoneCapabilityStatus.Authorized
        false -> PhoneCapabilityStatus.Denied
        null -> null
    }
}

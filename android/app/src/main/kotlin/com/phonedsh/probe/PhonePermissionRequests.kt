// The request half of the phone-permissions matrix: what can actually be asked.
// SPDX-License-Identifier: MIT
//
// `HostPhonePermissions.kt` answers "what does the platform currently allow?"; this
// file answers the other half of the same page — "for which of these 23 rows can a
// system request be raised at all, and how?" The page renders the answer
// (`PhoneGrantRoute`) and refuses to arm a 请求 for a row this file calls
// `SYSTEM_SETTINGS` or `NONE`.
//
// Why the answer is not a constant
// -------------------------------
// Three different Android facts decide it, and only the first is a property of the
// capability itself:
//
//  1. **the capability's mechanism** — a runtime (`dangerous`) permission can be
//     requested with `requestPermissions`; a *special access* (notification-policy
//     access behind 专注模式, background location, an app-op) has no prompt at all and
//     is only changed in the system settings app; several of the page's 23 rows have
//     no Android mechanism whatsoever;
//  2. **this build's merged manifest** — `requestPermissions` on a permission the
//     manifest never declares returns DENIED immediately and shows no dialog, so a
//     request path for an undeclared permission is a button that does nothing. The
//     declared set is read from the platform by `AndroidHostPermissions` (it walks
//     `GET_PERMISSIONS` on the *merged* artifact), never assumed here;
//  3. **the API level** — `POST_NOTIFICATIONS`/`BLUETOOTH_SCAN`/`READ_MEDIA_IMAGES`
//     are runtime permissions only from 33/31/33; below those the same row is a
//     normal permission granted at install (`BLUETOOTH`) or an app-op (`通知`).
//
// Consequences worth stating out loud, because they are the honest reading of this
// build rather than a target state:
//
//  * this app declares exactly one runtime permission that the page maps — the
//    `POST_NOTIFICATIONS` that `:dsh` needs for its progress notification — so 通知
//    is the only row that can raise a dialog today. Every other runtime row is
//    `NONE`, not because the platform lacks the permission but because this APK asks
//    for none of them: a row that offered 请求 would open a dialog the platform would
//    never show. If the manifest ever declares `READ_CONTACTS`, the 通讯录 row turns
//    into `REQUEST` with no change here — the table reads the merged manifest;
//  * `ACCESS_BACKGROUND_LOCATION` (后台定位) is the two-step case: from targetSdk 30
//    on, `requestPermissions` for it raises **no dialog at all** (Android 11 removed
//    the "allow all the time" option from the prompt), so the only honest route is
//    the settings page. On API 29 the request exists, and then only *after* a
//    foreground location grant — before that the platform refuses it outright;
//  * 专注模式 (DND) is special access: the grant behind reading the interruption
//    filter is `NotificationManager.isNotificationPolicyAccessGranted`, changed on
//    `ACTION_NOTIFICATION_POLICY_ACCESS_DETAIL_SETTINGS`. `requestPermissions` has no
//    bearing on it at all;
//  * `READ_MEDIA_VISUAL_USER_SELECTED` (Android 14's partial photo grant) is
//    deliberately absent: L36's decision stands — the platform reports no count, so
//    nothing here maps a partial grant to 部分允许（N）, and the request set is the
//    full-library permission only. Requesting `READ_MEDIA_IMAGES` on 34+ is how the
//    system itself offers the partial ("selected photos") choice; the answer this
//    file records is whatever the platform reports afterwards.
//
// What is *not* here: the request itself. `MainActivity` owns the two
// `registerForActivityResult` launchers (the same shape as its
// `POST_NOTIFICATIONS` one) because a `ActivityResultLauncher` must be registered
// before the Activity is STARTED. This file is the pure decision table it asks, and
// `PhonePermissionAsks` is the one durable piece of state the answer leaves behind.
package com.phonedsh.probe

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.provider.Settings
import com.phonedsh.domain.device.AndroidHostPermissions
import com.phonedsh.domain.device.HostPermissionReadings
import com.phonedsh.ui.page.PhoneCapability
import com.phonedsh.ui.page.PhoneGrantRoute

/**
 * The permissions a request for [capability] must ask for, in one `requestPermissions`
 * call, or an empty list when this build cannot raise a dialog for it at all.
 *
 * The list is empty when the capability has no runtime permission, when the API level
 * has none for it, or when this app's merged manifest does not declare it — the three
 * cases in which the platform answers without ever showing the user anything.
 *
 * @param readings the host's snapshot: the declared/granted sets and the API level.
 */
internal fun requestablePermissions(
    capability: PhoneCapability,
    readings: HostPermissionReadings,
): List<String> {
    val sdkInt = readings.sdkInt
    return when (capability) {
        PhoneCapability.CONTACTS -> declared(readings, AndroidHostPermissions.READ_CONTACTS)
        PhoneCapability.CALENDAR -> declared(readings, AndroidHostPermissions.READ_CALENDAR)
        PhoneCapability.PHOTOS -> declared(
            readings,
            // From 33 the photo library is gated by the media permission; below it by
            // storage access. Requesting both would only add a prompt the platform
            // ignores at this level.
            if (sdkInt >= 33) {
                AndroidHostPermissions.READ_MEDIA_IMAGES
            } else {
                AndroidHostPermissions.READ_EXTERNAL_STORAGE
            },
        )

        PhoneCapability.CAMERA -> declared(readings, AndroidHostPermissions.CAMERA)
        // One microphone grant serves both rows: 语音识别 is a recognizer over the
        // same RECORD_AUDIO permission.
        PhoneCapability.MICROPHONE,
        PhoneCapability.SPEECH,
        -> declared(readings, AndroidHostPermissions.RECORD_AUDIO)

        // Android 12 (31) requires precise+approximate to be requested together;
        // asking for one alone is dropped by the platform. Below 31 either one is a
        // complete request on its own.
        PhoneCapability.LOCATION -> {
            val both = listOf(
                AndroidHostPermissions.ACCESS_FINE_LOCATION,
                AndroidHostPermissions.ACCESS_COARSE_LOCATION,
            )
            val declaredOnes = both.filter(readings::declares)
            if (sdkInt >= 31) {
                if (declaredOnes.size == both.size) both else emptyList()
            } else {
                declaredOnes
            }
        }

        // ACTIVITY_RECOGNITION is a runtime permission from 29; before that the row
        // is either install-granted or absent, and neither has a dialog.
        PhoneCapability.MOTION ->
            if (sdkInt >= 29) declared(readings, AndroidHostPermissions.ACTIVITY_RECOGNITION)
            else emptyList()

        // BLUETOOTH is a normal permission below 31 (granted at install, no prompt)
        // and BLUETOOTH_SCAN is a runtime one from 31.
        PhoneCapability.BLUETOOTH ->
            if (sdkInt >= 31) declared(readings, AndroidHostPermissions.BLUETOOTH_SCAN)
            else emptyList()

        // POST_NOTIFICATIONS exists from 33. Below that the app-op is the whole
        // story and only the settings app changes it.
        PhoneCapability.NOTIFICATIONS ->
            if (sdkInt >= 33) declared(readings, AndroidHostPermissions.POST_NOTIFICATIONS)
            else emptyList()

        // Two-step: the background grant is requestable on API 29 only, and only
        // once a foreground location grant exists. From 30 the platform shows no
        // dialog for it at all, so the route is the settings page (see `grantRoutes`).
        PhoneCapability.LOCATION_ALWAYS ->
            if (sdkInt == 29 &&
                readings.declares(AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION) &&
                (readings.granted(AndroidHostPermissions.ACCESS_FINE_LOCATION) ||
                    readings.granted(AndroidHostPermissions.ACCESS_COARSE_LOCATION))
            ) {
                listOf(AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION)
            } else {
                emptyList()
            }

        // No Android mechanism, no grant, or no declaration this host can name:
        // 提醒事项/家庭/实时活动/快捷指令 have no framework, 本地网络/剪贴板/音乐 have no
        // authorization, 设备状态 needs none, 面容确认 is a per-use prompt (the page's
        // CONFIRM_BIOMETRIC) rather than a grant, 文件与文件夹 is a per-URI SAF picker,
        // and 健康/专注模式 are read-only here (Health Connect per-type permissions are
        // not declared by this app; DND access is special access, below).
        PhoneCapability.REMINDERS,
        PhoneCapability.HEALTH,
        PhoneCapability.LOCAL_NETWORK,
        PhoneCapability.BIOMETRICS,
        PhoneCapability.FOCUS,
        PhoneCapability.LIVE_ACTIVITY,
        PhoneCapability.SHORTCUTS,
        PhoneCapability.FILES_FOLDER,
        PhoneCapability.CLIPBOARD,
        PhoneCapability.DEVICE,
        PhoneCapability.HOMEKIT,
        PhoneCapability.MUSIC,
        -> emptyList()
    }
}

/**
 * The one route a grant can be obtained by, per capability — the page's
 * [PhoneGrantRoute] map, complete for all 23 rows.
 *
 * A row is `REQUEST` only when a dialog can really be raised (declared runtime
 * permission, right API level); `SYSTEM_SETTINGS` when the settings app is the only
 * place that can change it; `NONE` when nothing can.
 */
internal fun phoneGrantRoutes(
    readings: HostPermissionReadings,
): Map<PhoneCapability, PhoneGrantRoute> =
    PhoneCapability.matrix.associateWith { capability ->
        when {
            requestablePermissions(capability, readings).isNotEmpty() ->
                PhoneGrantRoute.REQUEST
            settingsCanChange(capability, readings) -> PhoneGrantRoute.SYSTEM_SETTINGS
            else -> PhoneGrantRoute.NONE
        }
    }

/**
 * True when the system settings app holds the switch for [capability] at all.
 *
 * Only three rows do: 专注模式 (Notification Policy Access is a special access with
 * no prompt), 通知 (the app-op is always in the app's own settings, and below API 33
 * it is the *only* switch), and 后台定位 once it is declared on 30+ (the "Allow all
 * the time" radio only exists on the permission page when the manifest asks for it).
 * A runtime permission the manifest does not declare has no toggle on that page, so
 * it stays `NONE` rather than sending the user to a page with nothing to switch.
 */
private fun settingsCanChange(
    capability: PhoneCapability,
    readings: HostPermissionReadings,
): Boolean = when (capability) {
    PhoneCapability.FOCUS -> true
    PhoneCapability.NOTIFICATIONS -> true
    PhoneCapability.LOCATION_ALWAYS ->
        readings.sdkInt >= 30 &&
            readings.declares(AndroidHostPermissions.ACCESS_BACKGROUND_LOCATION)
    else -> false
}

/**
 * The system page that can change [capability]'s grant, or `null` when the platform
 * has no activity for it (the caller then logs instead of pretending it opened).
 *
 * 专注模式 goes to the DND-access page — the list of apps that may read/change the
 * interruption filter, where this app's own switch is — because app settings does not
 * contain it. That page is `ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS`, the only
 * *public* action for the grant: the per-app detail page some builds also have is a
 * hidden platform constant, and depending on a hidden string would make this control
 * work on some OS versions and throw on others. Everything else goes to this app's
 * own details page, which is where runtime permissions and the notification app-op
 * live.
 */
internal fun phonePermissionSettingsIntent(
    context: Context,
    capability: PhoneCapability,
): Intent? {
    val packageUri = Uri.fromParts("package", context.packageName, null)
    val intent = Intent(phonePermissionSettingsAction(capability)).apply {
        if (action == Settings.ACTION_APPLICATION_DETAILS_SETTINGS) data = packageUri
    }
    return intent.takeIf { it.resolveActivity(context.packageManager) != null }
}

/**
 * The settings page that can change [capability]'s grant, as an intent action.
 *
 * Split from [phonePermissionSettingsIntent] so the two-page decision is a pure
 * function: 专注模式's DND access lives on the notification-policy page, everything
 * else on this app's own details page. The package URI is only meaningful for the
 * details page, and only that one gets it.
 */
internal fun phonePermissionSettingsAction(capability: PhoneCapability): String = when (capability) {
    PhoneCapability.FOCUS -> Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS
    else -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
}

/** The declared subset of [permission], as a one-element list or an empty one. */
private fun declared(
    readings: HostPermissionReadings,
    permission: String,
): List<String> = if (readings.declares(permission)) listOf(permission) else emptyList()

// ---------------------------------------------------------------------------
// The one durable answer
// ---------------------------------------------------------------------------

/**
 * What this app has already asked the platform, and what it is asking right now.
 *
 * **Why the app has to remember.** Android exposes no flag that separates "never
 * asked" from "asked and refused". `shouldShowRequestPermissionRationale` is false in
 * *both* states (and true again only after a single, still-retryable denial), so the
 * only reliable way to know that the user has answered — and that a second
 * `requestPermissions` may return DENIED without drawing a dialog — is to record the
 * ask when it is made. That record is what turns a row from 未请求 into 已拒绝, which
 * is what stops the page from arming a 请求 the platform will silently swallow.
 *
 * It is a private `SharedPreferences` file, not a database: one string set of
 * permission names, written only after an answer. Surviving process death is the
 * point — a fresh process that forgot the ask would show 请求 for a permission the
 * platform has already closed (the 不再询问 case).
 */
internal object PhonePermissionAsks {
    private const val PREFS_NAME = "pdsh.phone.permission.asks"
    private const val KEY_ASKED = "asked"

    @Volatile
    private var prefs: SharedPreferences? = null

    @Volatile
    private var askedPermissions: Set<String> = emptySet()

    /** The capability whose dialog is on screen, or `null`. */
    @Volatile
    var inFlight: PhoneCapability? = null
        private set

    @Volatile
    private var inFlightPermissions: List<String> = emptyList()

    /**
     * Reads the durable record once, at activity creation.
     *
     * @param context any context; only the application context is retained.
     */
    fun install(context: Context) {
        val store = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs = store
        askedPermissions = store.getStringSet(KEY_ASKED, emptySet())?.toSet() ?: emptySet()
    }

    /** The permissions this app has already sent to the platform. */
    fun asked(): Set<String> = askedPermissions

    /** The permissions the in-flight prompt asks for (empty when none is). */
    fun inFlightPermissions(): List<String> = inFlightPermissions

    /** A prompt is about to be launched for [capability]. */
    fun started(capability: PhoneCapability, permissions: List<String>) {
        inFlight = capability
        inFlightPermissions = permissions
    }

    /**
     * The platform answered: record the ask **before** clearing the in-flight marker,
     * so a projection that runs on the same frame still sees the row as 已拒绝 rather
     * than briefly as 未请求.
     */
    fun answered(permissions: Collection<String>) {
        record(permissions)
        inFlight = null
        inFlightPermissions = emptyList()
    }

    /**
     * Records permissions this app asked for through another entry point (the
     * `POST_NOTIFICATIONS` prompt the 跑一轮 tap raises, which is not this page's).
     */
    fun record(permissions: Collection<String>) {
        if (permissions.isEmpty()) return
        val merged = askedPermissions + permissions
        if (merged == askedPermissions) return
        askedPermissions = merged
        prefs?.edit()?.putStringSet(KEY_ASKED, merged)?.apply()
    }
}

// phone-dsh — :app: the background lane's composition root and its facts.
// SPDX-License-Identifier: MIT
//
// `:dsh` ships the machinery (UIDT on API 34+, the dataSync foreground service
// below it, the WorkManager tombstone, the boot guidance receiver) and declares
// its four components in its own library manifest. What was missing is the
// composition root: nothing in `:app` ever called `TurnBackground.start`, so the
// app could not open a window and `HostNavFacts` hard-coded
// `foregroundService = NO` with the comment "this app declares no service".
//
// That comment was wrong in the direction that matters. The manifest merger
// brings `:dsh`'s `<service>`/`<receiver>` elements into the APK, so the surface
// exists and only the call site was missing. This file is the call site, and it
// also turns the fact into a read instead of a constant:
//
//   * [declaration] asks PackageManager what actually landed in the APK, so a
//     dependency that stopped exporting its manifest shows up as `false`;
//   * [backgroundWindowFact] answers "can a background turn window open *here*"
//     from the platform's own preconditions, and names the one that failed;
//   * [startTurn] returns `TurnStartResult`, which is the platform's answer and
//     not an assumption; [endTurn] closes whichever window exists.
//
// Honesty rule this file is built around: a fact is YES only when every
// precondition it claims was measured true. When a window cannot open, the fact
// is NO with the measured reason, and the turn still runs — foreground-only.
package com.phonedsh.probe

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Process
import android.util.Log
import com.phonedsh.dsh.background.BootReceiver
import com.phonedsh.dsh.background.InterruptedTurnStore
import com.phonedsh.dsh.background.NotificationCapability
import com.phonedsh.dsh.background.TurnBackground
import com.phonedsh.dsh.background.TurnChannel
import com.phonedsh.dsh.background.TurnForegroundService
import com.phonedsh.dsh.background.TurnJobService
import com.phonedsh.dsh.background.TurnRequest
import com.phonedsh.dsh.background.TurnRuntime
import com.phonedsh.dsh.background.TurnStartResult
import com.phonedsh.dsh.background.TurnStopReceiver
import com.phonedsh.ui.page.FactState

/**
 * What the *installed* package declares for the background lane.
 *
 * Every field is a [PackageManager] reading of the merged APK manifest, not a
 * constant and not a list of what `:dsh`'s source says: the merger is the step
 * that can silently drop a component, so the read is done on its output.
 *
 * @param foregroundService the `TurnForegroundService` element exists.
 * @param dataSyncType that element carries `foregroundServiceType="dataSync"`.
 *   Below API 29 the attribute does not exist, so it reads `true`.
 * @param dataSyncPermission `FOREGROUND_SERVICE_DATA_SYNC` is granted (a normal
 *   permission, so install grants it unless the manifest never declared it).
 * @param jobService the `TurnJobService` element exists.
 * @param userInitiatedPermission `RUN_USER_INITIATED_JOBS` is granted.
 * @param stopReceiver the notification's stop action has a receiver.
 * @param bootReceiver the `BOOT_COMPLETED` guidance receiver exists.
 */
internal data class BackgroundDeclaration(
    val foregroundService: Boolean = false,
    val dataSyncType: Boolean = false,
    val dataSyncPermission: Boolean = false,
    val jobService: Boolean = false,
    val userInitiatedPermission: Boolean = false,
    val stopReceiver: Boolean = false,
    val bootReceiver: Boolean = false,
) {
    /** The dataSync channel's three preconditions, all of which the platform checks. */
    val foregroundServiceUsable: Boolean
        get() = foregroundService && dataSyncType && dataSyncPermission

    /** The UIDT channel's two declaration-level preconditions. */
    val userInitiatedJobUsable: Boolean
        get() = jobService && userInitiatedPermission
}

/**
 * One fact and the measurement behind it.
 *
 * @param state the fact the page renders.
 * @param detail the measured reason, rendered only when [state] is not YES. It
 *   names the precondition that failed instead of restating the page's own
 *   "unavailable" wording.
 */
internal data class BackgroundFact(
    val state: FactState,
    val detail: String? = null,
)

/**
 * The `foregroundService` fact: can a turn keep running after the user leaves?
 *
 * The page's row says 前台服务可用性 / 可用 / 应用退到后台时仍能继续回合, so the
 * fact is about the *window*, not about one API: on Android 14+ the window is a
 * UIDT job and the foreground service is its fallback, below 14 the service is
 * the only channel. Either one being usable makes the promise true; neither
 * being usable makes it false, and the detail names what is missing.
 *
 * Scope, stated here so the row is not read as more than it measures: YES means
 * the OS window can open and was measured to open (device evidence: the job
 * enters its execution slot, the notification is attached, the process is held
 * at `oom adj 201`). It does **not** mean the turn survives the user leaving:
 * the host's D14 drain still parks the turn on `scenePhase(background)`, and
 * that is a `:dsh` host/controller gap, not a fact this app can read. The
 * commitment table (`docs/design/android-background-commitment-tiers-2026-11-01.md`)
 * records that row as "partial" for exactly this reason.
 *
 * [sdkInt] is a parameter so the decision can be exercised on the JVM for every
 * release without pretending to be another SDK.
 *
 * @param declaration what the APK declares.
 * @param capability the notification link's measured state.
 * @param sdkInt the device's API level.
 */
internal fun backgroundWindowFact(
    declaration: BackgroundDeclaration,
    capability: NotificationCapability,
    sdkInt: Int,
): BackgroundFact {
    // The notification comes first: without a visible progress notification UIDT's
    // contract does not hold and the service's window would be invisible, which is
    // exactly the degradation `:dsh` refuses. Reporting the components as "usable"
    // while this is false would promise a window the layer will not open.
    if (!capability.progressVisible) {
        return BackgroundFact(FactState.NO, notificationDetail(capability))
    }
    val uidtUsable = sdkInt >= TurnChannel.USER_INITIATED_JOB_MIN_SDK &&
        declaration.userInitiatedJobUsable
    if (!declaration.foregroundServiceUsable && !uidtUsable) {
        return BackgroundFact(FactState.NO, missingComponentDetail(declaration, sdkInt))
    }
    return BackgroundFact(FactState.YES)
}

/**
 * The settings page's `notifications` row: does this app's notification link work?
 *
 * `progressVisible` is the same predicate `:dsh` uses to decide whether a
 * background channel may open at all, so the row and the promise cannot drift.
 */
internal fun notificationFact(capability: NotificationCapability): FactState =
    if (capability.progressVisible) FactState.YES else FactState.NO

/** The measured reason a notification is not visible, in the page's voice. */
internal fun notificationDetail(capability: NotificationCapability): String =
    when (capability.degradedReason) {
        NotificationCapability.DegradedReason.RUNTIME_PERMISSION_DENIED ->
            "通知权限未授予（POST_NOTIFICATIONS）：后台通道要求进度通知可见，回合降级为仅前台"

        NotificationCapability.DegradedReason.NOTIFICATIONS_DISABLED ->
            "应用通知被关闭：后台通道要求进度通知可见，回合降级为仅前台"

        NotificationCapability.DegradedReason.CHANNEL_BLOCKED ->
            "回合通知频道被关闭：后台通道要求进度通知可见，回合降级为仅前台"

        null -> "通知不可见：后台通道要求进度通知可见，回合降级为仅前台"
    }

/** Names the components the APK is missing, so the fact is actionable. */
private fun missingComponentDetail(declaration: BackgroundDeclaration, sdkInt: Int): String {
    val missing = buildList {
        if (!declaration.foregroundService) {
            add("前台服务")
        } else if (!declaration.dataSyncType) {
            add("dataSync 前台服务类型")
        }
        if (!declaration.dataSyncPermission) add("FOREGROUND_SERVICE_DATA_SYNC 权限")
        if (sdkInt >= TurnChannel.USER_INITIATED_JOB_MIN_SDK) {
            if (!declaration.jobService) add("UIDT job 服务")
            if (!declaration.userInitiatedPermission) add("RUN_USER_INITIATED_JOBS 权限")
        }
    }
    return "APK 缺少后台组件：" + missing.joinToString("、") + "；回合降级为仅前台"
}

/**
 * The one-line form of a [TurnStartResult] for the log.
 *
 * `foreground_only` is the honest answer the app must not mistake for success:
 * no window opened, so the turn ends when the user leaves.
 */
internal fun describeStartResult(result: TurnStartResult): String = when (result) {
    is TurnStartResult.UserInitiatedJobScheduled -> "uidt_scheduled:${result.jobId}"
    TurnStartResult.DataSyncForegroundServiceStarted -> "data_sync_foreground_service"
    is TurnStartResult.ForegroundOnly -> "foreground_only:${result.reason.name}"
}

/**
 * Everything the navigation facts need to answer the background questions.
 *
 * The declaration is cached by the caller (it cannot change without a reinstall);
 * [capability] is re-probed every time because the user can revoke the
 * notification permission between two reads.
 */
internal data class HostBackgroundReadings(
    val declaration: BackgroundDeclaration,
    val capability: NotificationCapability,
    val sdkInt: Int,
) {
    /** The runtime page's `foregroundService` fact and its measured reason. */
    val window: BackgroundFact
        get() = backgroundWindowFact(declaration, capability, sdkInt)
}

/**
 * The background lane's app-side entry points.
 *
 * Every method takes a `Context` so the ViewModel can call it without holding
 * one: `TurnBackground` already stores the application context.
 */
internal object HostBackground {
    const val TAG: String = "PDSHHostBg"

    /**
     * Reads the merged manifest.
     *
     * The components belong to `:dsh`; `:app` reads them back rather than
     * redeclaring them. A duplicated `<service>` in `:app`'s manifest would merge
     * cleanly today and become two sources of truth tomorrow.
     */
    fun declaration(context: Context): BackgroundDeclaration {
        val packageManager = context.packageManager
        val packageName = context.packageName
        val foreground = serviceInfo(
            packageManager,
            ComponentName(packageName, TurnForegroundService::class.java.name),
        )
        return BackgroundDeclaration(
            foregroundService = foreground != null,
            dataSyncType = foreground.hasDataSyncType(),
            dataSyncPermission = context.holds("android.permission.FOREGROUND_SERVICE_DATA_SYNC"),
            jobService = serviceInfo(
                packageManager,
                ComponentName(packageName, TurnJobService::class.java.name),
            ) != null,
            userInitiatedPermission = context.holds(
                "android.permission.RUN_USER_INITIATED_JOBS",
            ),
            stopReceiver = receiverDeclared(
                packageManager,
                ComponentName(packageName, TurnStopReceiver::class.java.name),
            ),
            bootReceiver = receiverDeclared(
                packageManager,
                ComponentName(packageName, BootReceiver::class.java.name),
            ),
        )
    }

    /** One measurement of the two facts' inputs. */
    fun readings(context: Context, declaration: BackgroundDeclaration): HostBackgroundReadings =
        HostBackgroundReadings(
            declaration = declaration,
            capability = TurnBackground.capability(context),
            sdkInt = Build.VERSION.SDK_INT,
        )

    /**
     * Whether this process is visible to the user right now.
     *
     * UIDT may only be scheduled from a visible app (plan §7.10-B2), and the
     * caller is the only party that can answer. The read is the platform's own
     * importance ranking for *our* process; `false` is the conservative answer
     * when the system refuses to say, because claiming visibility would ask for
     * a job the platform rejects.
     */
    fun appVisible(context: Context): Boolean {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return false
        val self = manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }
            ?: return false
        return self.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    /**
     * Opens the best available window for [epoch] and reports what the platform
     * actually did.
     *
     * Called while the turn's button gesture is still fresh, before the first
     * `await`: a window opened after the app is already in the background cannot
     * be opened at all on Android 12+. [declaration] is the caller's cached read
     * of the merged manifest; it is only logged here, so the one line that says
     * which window opened also says what the app had to open it with.
     */
    fun startTurn(
        context: Context,
        epoch: Long,
        declaration: BackgroundDeclaration,
    ): TurnStartResult {
        val appContext = context.applicationContext
        val visible = appVisible(appContext)
        val channel = TurnChannel.current(TurnBackground.capability(appContext))
        val result = TurnBackground.start(
            appContext,
            TurnRequest(epoch = epoch),
            visible,
        )
        Log.i(
            TAG,
            "BG_TURN_START channel=$channel app_visible=$visible epoch=$epoch " +
                "declared=$declaration result=${describeStartResult(result)}",
        )
        return result
    }

    /**
     * Closes the window and drops the durable marker.
     *
     * The turn ended through an explicit path (completed or failed), so the
     * marker must not survive into the next launch as a fake interruption. Two
     * paths exist because the facade's `complete()` returns early when no window
     * ever ran: a turn that failed before `onStartJob`/`onStartCommand` must still
     * cancel the queued job and clear the marker, or the next launch would report
     * a process death that never happened.
     */
    fun endTurn(context: Context) {
        val appContext = context.applicationContext
        val snapshot = TurnRuntime.snapshot()
        Log.i(
            TAG,
            "BG_TURN_END backend=${snapshot.backend} running=${snapshot.isRunning} " +
                "stop_reason=${snapshot.stopReason}",
        )
        if (snapshot.isRunning) {
            TurnBackground.complete(appContext)
        } else {
            // `stop` is the facade's cancel path for a window that was scheduled but
            // never started. With nothing running it touches no marker, so the
            // explicit clear below is the one that runs.
            TurnBackground.stop(appContext, TurnRuntime.StopReason.USER_STOPPED)
        }
        InterruptedTurnStore(appContext).complete()
    }

    private fun serviceInfo(packageManager: PackageManager, name: ComponentName): ServiceInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                packageManager.getServiceInfo(name, PackageManager.ComponentInfoFlags.of(0L))
            }.getOrNull()
        } else {
            @Suppress("DEPRECATION")
            runCatching { packageManager.getServiceInfo(name, 0) }.getOrNull()
        }

    private fun receiverDeclared(packageManager: PackageManager, name: ComponentName): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                packageManager.getReceiverInfo(name, PackageManager.ComponentInfoFlags.of(0L))
            }.isSuccess
        } else {
            @Suppress("DEPRECATION")
            runCatching { packageManager.getReceiverInfo(name, 0) }.isSuccess
        }

    private fun ServiceInfo?.hasDataSyncType(): Boolean {
        // The attribute only exists from API 29; below it the service had no type
        // and the permission model was different, so there is nothing to check.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        val service = this ?: return false
        return service.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC != 0
    }

    private fun Context.holds(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}

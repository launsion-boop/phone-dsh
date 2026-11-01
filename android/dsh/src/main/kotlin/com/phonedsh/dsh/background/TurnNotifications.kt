// phone-dsh — :dsh / com.phonedsh.dsh.background: the one place notification text lives.
// SPDX-License-Identifier: MIT
//
// Whitelist `platform.fgs-turn-notification` (device-gate): the foreground service
// must carry a persistent notification that shows the turn and its progress and
// offers a graceful stop — the only UI that survives the Task Manager's zero-
// callback Stop. Plan §9.4: this notification is the Android form of "a turn is
// running", not a new feature.
//
// Honesty rules enforced here:
//   * say what is true ("回合执行中", the last recorded step). Never "正在保护你的
//     数据" — durability comes from the WAL write path, not from this notification;
//   * never show a percentage the caller did not supply: no total => indeterminate
//     bar, never a fabricated number;
//   * the running notification always has exactly one action: 停止本轮.

package com.phonedsh.dsh.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.phonedsh.dsh.R

object TurnNotifications {
    const val PROGRESS_CHANNEL_ID = "pdsh_turn_progress"
    const val REPORT_CHANNEL_ID = "pdsh_turn_report"

    const val PROGRESS_NOTIFICATION_ID = 7301
    const val TOMBSTONE_NOTIFICATION_ID = 7302
    const val BOOT_NOTIFICATION_ID = 7303

    const val ACTION_STOP_TURN = "com.phonedsh.dsh.background.action.STOP_TURN"
    const val STOP_ACTION_LABEL = "停止本轮"

    private const val REQUEST_STOP = 7310
    private const val REQUEST_OPEN = 7311
    private const val ACCENT_COLOR = 0xFF2563EB.toInt()

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                PROGRESS_CHANNEL_ID,
                "回合执行",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "回合在后台执行时显示；带停止按钮"
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                REPORT_CHANNEL_ID,
                "回合中断报告",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "进程被系统结束或设备重启后，引导打开应用查看检查点"
            },
        )
    }

    /**
     * The running-turn notification. Indeterminate progress unless the caller gave
     * a real total; the step is the last boundary the caller reported, nothing more.
     */
    fun progress(context: Context, snapshot: TurnRuntime.Snapshot): Notification {
        val builder = base(context, PROGRESS_CHANNEL_ID)
            .setContentTitle("回合执行中")
            .setContentText("PDSH 在后台继续本轮任务。点「停止本轮」结束；已写入磁盘的内容保留。")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, STOP_ACTION_LABEL, stopIntent(context))
            .setProgress(0, 0, true)
        if (snapshot.totalSteps > 0) {
            builder.setProgress(snapshot.totalSteps, snapshot.step, false)
        }
        if (snapshot.step > 0) {
            builder.setSubText("最后检查点：第 ${snapshot.step} 步")
        }
        contentIntent(context)?.let(builder::setContentIntent)
        return builder.build()
    }

    /**
     * Posted after `onTimeout` has already closed admission. It tells the user the
     * system limit was hit; it does not pretend the epoch was closed.
     */
    fun timedOut(context: Context, snapshot: TurnRuntime.Snapshot): Notification {
        val builder = base(context, PROGRESS_CHANNEL_ID)
            .setContentTitle("回合已停止：系统时限")
            .setContentText(
                "前台服务时间上限已到，本轮不再接收新工作。" +
                    "已写入磁盘的进度保留，下次打开应用时报告。",
            )
            .setOngoing(false)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
        if (snapshot.step > 0) builder.setSubText("最后检查点：第 ${snapshot.step} 步")
        contentIntent(context)?.let(builder::setContentIntent)
        return builder.build()
    }

    /** Tombstone: the process died, WorkManager (or boot) found the durable marker. */
    fun tombstone(context: Context, turn: InterruptedTurnStore.InterruptedTurn): Notification {
        val builder = base(context, REPORT_CHANNEL_ID)
            .setContentTitle("上一轮回合被中断")
            .setContentText("${describe(turn)} 打开 PDSH 查看检查点；不会自动续跑。")
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
        contentIntent(context)?.let(builder::setContentIntent)
        return builder.build()
    }

    /** Boot: guidance only. No foreground service, no automatic resume (plan §7.4-3). */
    fun bootGuide(context: Context, turn: InterruptedTurnStore.InterruptedTurn): Notification {
        val builder = base(context, REPORT_CHANNEL_ID)
            .setContentTitle("设备已重启")
            .setContentText("${describe(turn)} 打开 PDSH 查看检查点；不会自动续跑。")
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
        contentIntent(context)?.let(builder::setContentIntent)
        return builder.build()
    }

    fun postProgress(context: Context, snapshot: TurnRuntime.Snapshot): Boolean =
        post(context, PROGRESS_NOTIFICATION_ID, progress(context, snapshot))

    fun postTimedOut(context: Context, snapshot: TurnRuntime.Snapshot): Boolean =
        post(context, PROGRESS_NOTIFICATION_ID, timedOut(context, snapshot))

    fun postTombstone(
        context: Context,
        turn: InterruptedTurnStore.InterruptedTurn,
    ): Boolean = post(context, TOMBSTONE_NOTIFICATION_ID, tombstone(context, turn))

    fun postBootGuide(
        context: Context,
        turn: InterruptedTurnStore.InterruptedTurn,
    ): Boolean = post(context, BOOT_NOTIFICATION_ID, bootGuide(context, turn))

    fun cancelProgress(context: Context) {
        NotificationManagerCompat.from(context).cancel(PROGRESS_NOTIFICATION_ID)
    }

    fun cancel(context: Context, notificationId: Int) {
        NotificationManagerCompat.from(context).cancel(notificationId)
    }

    /**
     * The single stop entry point reached from the notification. A broadcast (not
     * `PendingIntent.getService`) so the same action works for both channels: the
     * receiver asks the facade to stop whichever backend is running.
     */
    fun stopIntent(context: Context): PendingIntent {
        val intent = Intent(context, TurnStopReceiver::class.java).setAction(ACTION_STOP_TURN)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_STOP,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun base(context: Context, channelId: String): NotificationCompat.Builder =
        NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_pdsh_turn)
            .setColor(ACCENT_COLOR)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

    private fun contentIntent(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun describe(turn: InterruptedTurnStore.InterruptedTurn): String {
        val step = if (turn.step > 0) {
            "第 ${turn.step} 步之后进程被系统结束。"
        } else {
            "进程在记录到步骤之前被系统结束。"
        }
        val reason = when (turn.reason) {
            null -> "系统没有给出停止回调。"
            TurnRuntime.StopReason.TASK_REMOVED -> "任务被从最近任务中移除。"
            TurnRuntime.StopReason.SYSTEM_TIMEOUT -> "前台服务时间上限已到。"
            TurnRuntime.StopReason.JOB_STOPPED -> "系统暂停了本轮的后台任务。"
            TurnRuntime.StopReason.SERVICE_STOPPED -> "后台服务被系统停止。"
            TurnRuntime.StopReason.USER_STOPPED -> "本轮由用户停止。"
            TurnRuntime.StopReason.COMPLETED -> "本轮已结束。"
        }
        return "$step$reason"
    }

    private fun post(context: Context, id: Int, notification: Notification): Boolean = try {
        NotificationManagerCompat.from(context).notify(id, notification)
        true
    } catch (error: SecurityException) {
        // POST_NOTIFICATIONS revoked between the capability probe and the post:
        // report the failure so the caller can fall back to the next-open report.
        false
    }
}

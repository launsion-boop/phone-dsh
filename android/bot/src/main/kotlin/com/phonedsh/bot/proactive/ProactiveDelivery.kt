// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.bot.routines.RoutineScheduledNotification

/**
 * Host seam for a proactive result notification. P08's Android Notifier
 * implements this; `:bot` only owns the admission decision and the frozen
 * notification shape. A thrown exception is recorded as `delivery-failed`
 * with its message as `delivery.error`.
 */
public fun interface ProactiveDelivering {
    public fun deliver(notification: ProactiveNotification): ProactiveDeliveryResult
}

/** Delivery failures the platform adapter can report with stable text. */
public class ProactiveDeliveryException(message: String) : Exception(message) {
    public companion object {
        public const val MISSING_DEDUPE_KEY: String = "missingDedupeKey"
        public const val MISSING_DEEP_LINK: String = "missingDeepLink"
    }
}

/**
 * The two preconditions Swift `UNUserNotificationProactiveDelivery` checks.
 * The platform adapter must reject a null [ProactiveNotification.deepLink]
 * (CCR-5); the engine itself does not invent a row for a reminder.
 */
public object ProactiveDeliveryRequirements {
    public fun rejection(notification: ProactiveNotification): String? = when {
        notification.dedupeKey.isEmpty() -> ProactiveDeliveryException.MISSING_DEDUPE_KEY
        notification.deepLink.isNullOrEmpty() -> ProactiveDeliveryException.MISSING_DEEP_LINK
        else -> null
    }
}

/**
 * Host seam for the §3.1 routine-due local notification. The scheduled data
 * type stays `RoutineScheduledNotification` (the existing frozen shape); this
 * port only lets P08 schedule/cancel/reconcile it without `:bot` importing
 * Android's notification APIs.
 */
public interface LocalNotificationScheduling {
    public fun schedule(notification: RoutineScheduledNotification)

    public fun pendingIdentifiers(prefix: String): List<String>

    public fun cancel(identifiers: List<String>)
}

/**
 * Routine-due data is not proactive and consumes no fuse. It reuses the
 * frozen `RoutineScheduledNotification` builder rather than defining a second
 * notification shape.
 */
public object ProactiveRoutineDue {
    public fun notification(
        botId: String,
        routineId: String,
        routineTitle: String,
        fireAt: Long,
    ): RoutineScheduledNotification =
        RoutineScheduledNotification.forRoutine(botId, routineId, routineTitle, fireAt)

    public fun schedule(
        port: LocalNotificationScheduling,
        botId: String,
        routineId: String,
        routineTitle: String,
        fireAt: Long,
    ): RoutineScheduledNotification {
        val notification = notification(botId, routineId, routineTitle, fireAt)
        port.schedule(notification)
        return notification
    }
}

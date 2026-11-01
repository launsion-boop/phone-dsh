// The FGS notification surface, including the graceful-stop button.
// SPDX-License-Identifier: MIT
//
// plan §9.4-1: Android foreground services must show a notification; that is
// the platform form of "a turn is running", not a new feature. plan §7.4-4:
// denying notification permission may degrade the presentation chain but must
// stay visible to the user, and must not silently turn "background can run"
// into a promise. The SPI therefore carries a notification, an optional action
// (the graceful stop of plan §9.4) and the availability of the presentation
// path itself.

package com.phonedsh.platform

/**
 * User-visible host progress (foreground-service notification or equivalent).
 *
 * [notify] and [cancel] are keyed by a caller-chosen stable id; a notification
 * is not a log line and must never carry a token, a full URL or model output
 * that has not been admitted for display.
 */
interface Notifier {
    /**
     * Whether notifications can currently be shown.
     *
     * `DISABLED` is a degradation the caller must surface (plan §7.4-4); it is
     * never permission to pretend that background progress is visible.
     */
    val availability: NotifierAvailability

    /**
     * Shows or updates the notification [id].
     *
     * @param ongoing `true` pins the notification for a running turn (a
     * foreground-service notification); `false` is a terminal update.
     * @param action optional single button; for a running turn this is the
     * graceful-stop action, never a hard kill.
     */
    fun notify(
        id: Int,
        title: String,
        body: String,
        ongoing: Boolean,
        action: NotificationAction?,
    )

    /** Removes notification [id]; succeeds when it is already absent. */
    fun cancel(id: Int)
}

/** Whether the notification channel is usable right now. */
enum class NotifierAvailability {
    ENABLED,
    DISABLED,
}

/**
 * One user-visible notification action.
 *
 * [onClick] runs when the user presses the button while the posting process is
 * alive. It must start the graceful stop path (D14 drain) and be safe to invoke
 * more than once. A cold-start delivery path (process recreated before the
 * click) would need a stable action id; the current SPI deliberately keeps the
 * callback and leaves that path to the Android adapter.
 */
class NotificationAction(
    val label: String,
    val onClick: () -> Unit,
)

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

    /**
     * Shows or updates the notification [id] with the Bot deep link [deepLink].
     *
     * The link is carried, not parsed: P09 owns its grammar
     * (`spec/ui/v1/bot/ui-state.md` §4.13, `schema/deep-link.schema.json`).
     * The default implementation delegates to the five-argument [notify] and
     * therefore drops the link; an adapter that can open a deep link (Android
     * `PendingIntent`, including the cold-start path) overrides this method.
     * Dropping the link is a presentation degradation, not a delivery result.
     */
    fun notify(
        id: Int,
        title: String,
        body: String,
        ongoing: Boolean,
        action: NotificationAction?,
        deepLink: NotificationDeepLink?,
    ) {
        notify(id, title, body, ongoing, action)
    }

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

/**
 * A host deep link attached to one notification (P08 carriage, P09 grammar).
 *
 * The accepted form is the Bot form frozen by
 * `spec/ui/v1/bot/schema/deep-link.schema.json`:
 * `phonedsh://bot/<botID>/<row|routine>/<id>`. This class does not resolve the
 * destination — P09's parser does that when the page handles the link — it only
 * keeps a malformed or non-Bot URI from being placed in a notification.
 */
class NotificationDeepLink(
    /** The complete `phonedsh://bot/...` URI. */
    val uri: String,
) {
    init {
        require(uri.startsWith(PREFIX)) {
            "a Bot notification deep link must start with '$PREFIX'"
        }
        require(uri.length <= MAXIMUM_URI_LENGTH) {
            "a Bot notification deep link must be at most $MAXIMUM_URI_LENGTH characters"
        }
        require(uri.none { it.isWhitespace() || it.isISOControl() }) {
            "a Bot notification deep link must not contain whitespace or control characters"
        }
    }

    override fun toString(): String = "NotificationDeepLink($uri)"

    companion object {
        /** The Bot URI prefix; P09 owns the remaining path grammar. */
        const val PREFIX: String = "phonedsh://bot/"

        /** A notification payload is not an unbounded transport. */
        const val MAXIMUM_URI_LENGTH: Int = 2_048
    }
}

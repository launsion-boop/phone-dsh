// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.state.PendingAnswer

/** Raised when legacy callable access reaches an operation with no real host callback. */
public class PdshActionUnavailableException(
    public val reason: PdshUnavailableReason,
) : IllegalStateException("Host action unavailable: $reason")

/**
 * Chat host operations with a source-compatible callable adapter.
 *
 * The nullable constructor callbacks are the pre-migration API. Their matching
 * `*Availability` properties are authoritative: missing callbacks are
 * `Unavailable`, and invoking a compatibility adapter throws with that reason.
 * New UI should query availability before binding an enabled control.
 */
public class ChatInteractionActions(
    /** Legacy callback to expand/collapse a streamed chat row. */
    toggleRow: ((String) -> Unit)? = null,
    /** Legacy callback to approve the exact pending permission request. */
    approve: ((PendingAnswer) -> Unit)? = null,
    /** Legacy callback to deny the exact pending permission request. */
    deny: ((PendingAnswer) -> Unit)? = null,
    /** Legacy callback to submit an answer to the exact pending question. */
    answer: ((PendingAnswer, String) -> Unit)? = null,
    /** Legacy callback to dismiss the exact pending question. */
    dismissQuestion: ((PendingAnswer) -> Unit)? = null,
    /** Legacy callback to run a goal command such as pause, resume, or clear. */
    goalCommand: ((String) -> Unit)? = null,
    /** Legacy callback to select a permission mode. */
    selectAccessMode: ((String) -> Unit)? = null,
    /** Legacy callback to refresh model and permission-mode catalogs. */
    refreshCatalogs: (() -> Unit)? = null,
    /** Legacy callback reporting IME visibility to the host. */
    imeChanged: ((Boolean) -> Unit)? = null,
    /** Legacy callback to expand the pending work area. */
    expandPending: (() -> Unit)? = null,
    /** Legacy callback to start the stopped engine. */
    startEngine: (() -> Unit)? = null,
    /** Legacy callback to execute a command through the host. */
    executeCommand: ((String) -> Unit)? = null,
    /** Legacy callback to select a provider model and optional reasoning effort. */
    selectModel: ((String, String?) -> Unit)? = null,
    /** Legacy callback to restart the engine through the host. */
    restartEngine: (() -> Unit)? = null,
) {
    /** Authoritative availability for [toggleRow]. */
    public val toggleRowAvailability = availability(toggleRow)
    /** Authoritative availability for [approve]. */
    public val approveAvailability = availability(approve)
    /** Authoritative availability for [deny]. */
    public val denyAvailability = availability(deny)
    /** Authoritative availability for [answer]. */
    public val answerAvailability = availability(answer)
    /** Authoritative availability for [dismissQuestion]. */
    public val dismissQuestionAvailability = availability(dismissQuestion)
    /** Authoritative availability for [goalCommand]. */
    public val goalCommandAvailability = availability(goalCommand)
    /** Authoritative availability for [selectAccessMode]. */
    public val selectAccessModeAvailability = availability(selectAccessMode)
    /** Authoritative availability for [refreshCatalogs]. */
    public val refreshCatalogsAvailability = availability(refreshCatalogs)
    /** Authoritative availability for [imeChanged]. */
    public val imeChangedAvailability = availability(imeChanged)
    /** Authoritative availability for [expandPending]. */
    public val expandPendingAvailability = availability(expandPending)
    /** Authoritative availability for [startEngine]. */
    public val startEngineAvailability = availability(startEngine)
    /** Authoritative availability for [executeCommand]. */
    public val executeCommandAvailability = availability(executeCommand)
    /** Authoritative availability for [selectModel]. */
    public val selectModelAvailability = availability(selectModel)
    /** Authoritative availability for [restartEngine]. */
    public val restartEngineAvailability = availability(restartEngine)

    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val toggleRow: (String) -> Unit = toggleRowAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val approve: (PendingAnswer) -> Unit = approveAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val deny: (PendingAnswer) -> Unit = denyAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val answer: (PendingAnswer, String) -> Unit = answerAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val dismissQuestion: (PendingAnswer) -> Unit = dismissQuestionAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val goalCommand: ((String) -> Unit)? = goalCommandAvailability.legacyOrNull()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val selectAccessMode: (String) -> Unit = selectAccessModeAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val refreshCatalogs: () -> Unit = refreshCatalogsAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val imeChanged: ((Boolean) -> Unit)? = imeChangedAvailability.legacyOrNull()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val expandPending: () -> Unit = expandPendingAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val startEngine: () -> Unit = startEngineAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val executeCommand: ((String) -> Unit)? = executeCommandAvailability.legacyOrNull()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val selectModel: (String, String?) -> Unit = selectModelAvailability.legacy()
    /** Callable compatibility adapter; unavailable access fails with a typed reason. */
    public val restartEngine: () -> Unit = restartEngineAvailability.legacy()

    private companion object {
        fun <C> availability(callback: C?): PdshActionAvailability<C> = callback?.let {
            PdshActionAvailability.Available(it)
        } ?: PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED)

        fun <A> PdshActionAvailability<(A) -> Unit>.legacy(): (A) -> Unit = when (this) {
            is PdshActionAvailability.Available -> callback
            is PdshActionAvailability.Unavailable -> { _ -> throw PdshActionUnavailableException(reason) }
        }

        fun <A, B> PdshActionAvailability<(A, B) -> Unit>.legacy(): (A, B) -> Unit = when (this) {
            is PdshActionAvailability.Available -> callback
            is PdshActionAvailability.Unavailable -> { _, _ -> throw PdshActionUnavailableException(reason) }
        }

        fun PdshActionAvailability<() -> Unit>.legacy(): () -> Unit = when (this) {
            is PdshActionAvailability.Available -> callback
            is PdshActionAvailability.Unavailable -> ({ throw PdshActionUnavailableException(reason) })
        }

        fun <A> PdshActionAvailability<(A) -> Unit>.legacyOrNull(): ((A) -> Unit)? = when (this) {
            is PdshActionAvailability.Available -> callback
            is PdshActionAvailability.Unavailable -> null
        }
    }
}

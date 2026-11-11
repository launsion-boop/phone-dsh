// Send/stop key rules from spec/ui/v1/interaction.md §5.
// SPDX-License-Identifier: MIT
//
// This file deliberately has no Compose runtime dependency: the JVM contract
// test drives the same truth table as the composables. Every number comes from
// the generated `interaction.composerSend` table or an existing reviewed
// Android metric; no value is re-typed here.
package com.phonedsh.ui.composer

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Which keys the composer's trailing action corner shows (rule 1).
 *
 * [SEND] is the idle case, [STOP] is the running case where the draft cannot be
 * submitted, and [BOTH] is the running case that still accepts the draft:
 * the stop key comes first, then the send key, [ComposerSendRule.STOP_SEND_GAP] apart.
 */
public enum class ComposerSendLayout {
    SEND,
    STOP,
    BOTH;

    /** Rule 1: the send key occupies the slot in [SEND] and [BOTH]. */
    public val sendVisible: Boolean get() = this != STOP

    /** Rule 1: the stop key is visible whenever a turn is running. */
    public val stopVisible: Boolean get() = this != SEND

    /** True only when the stop key replaces the send key (the golden's `showsStop`). */
    public val stopOnly: Boolean get() = this == STOP
}

/**
 * The pure §5 truth table shared by the send/stop composables and their tests.
 *
 * The token group is `interaction.composerSend`; [STOP_SEND_GAP] has no
 * `tokens.json` member (reported to the contract owner) and therefore reuses
 * the existing Android dual-button spacing metric, sourced from
 * `ChatPage.swift`'s `HStack(spacing: 8)`.
 */
public object ComposerSendRule {
    /**
     * Rule 1: gap between the stop and send keys when both are visible.
     *
     * `interaction.composerSend` has no gap member, so this is not a token: the
     * value is [ChatMetrics.COMPOSER_ACTION_GAP_PT], the existing reviewed
     * Android projection of the iOS `HStack(spacing: 8)` action cluster.
     */
    public val STOP_SEND_GAP: Dp = ChatMetrics.COMPOSER_ACTION_GAP_PT.dp

    /**
     * Rule 2: the send key is enabled exactly when the draft can be submitted.
     *
     * `composerEnabled && (steer ? hasText && !hasAttachments
     *                        : (turnRunning ? hasText : hasText || hasAttachments))`
     *
     * `composerEnabled` is the screen's resolved capability: pending questions
     * and permissions, recovery and `canSend` / `canSteer` are already folded
     * into it by the host.
     */
    public fun canSubmit(
        composerEnabled: Boolean,
        steer: Boolean,
        hasText: Boolean,
        hasAttachments: Boolean,
        turnRunning: Boolean,
    ): Boolean {
        if (!composerEnabled) return false
        return if (steer) {
            hasText && !hasAttachments
        } else if (turnRunning) {
            hasText
        } else {
            hasText || hasAttachments
        }
    }

    /**
     * Rule 1: [ComposerSendLayout.BOTH] while a turn runs and can still receive
     * the draft; otherwise the stop key replaces the send key.
     */
    public fun layout(turnRunning: Boolean, canSubmit: Boolean): ComposerSendLayout = when {
        !turnRunning -> ComposerSendLayout.SEND
        canSubmit -> ComposerSendLayout.BOTH
        else -> ComposerSendLayout.STOP
    }

    /**
     * Rule 7: the send key's verbatim label.
     *
     * The three strings are the existing Android resources from `UiStrings`,
     * which already carry the iOS `sendButtonLabel` text.
     */
    public fun sendLabel(turnRunning: Boolean, steer: Boolean): String = when {
        !turnRunning -> UiStrings.COMPOSER_SEND_LABEL
        steer -> UiStrings.COMPOSER_SEND_LABEL_STEER
        else -> UiStrings.COMPOSER_SEND_LABEL_QUEUE
    }

    /** Rule 7: the stop key's verbatim label, including the stopping state. */
    public fun stopLabel(stopping: Boolean): String =
        if (stopping) UiStrings.COMPOSER_STOPPING else UiStrings.COMPOSER_STOP_LABEL

    /**
     * Rule 4: the send key's scale at transition [progress], where 0 is the
     * entering appearance (`transitionScale`, 0.8) and 1 is settled.
     */
    public fun transitionScale(progress: Float): Float {
        val value = progress.coerceIn(0f, 1f)
        val entering = UiTokenData.composerSend.transitionScale
        return entering + (1f - entering) * value
    }

    /**
     * Rule 4: the send key's opacity at transition [progress], from
     * `transitionOpacity` (0) to 1.
     */
    public fun transitionAlpha(progress: Float): Float {
        val value = progress.coerceIn(0f, 1f)
        val entering = UiTokenData.composerSend.transitionOpacity
        return entering + (1f - entering) * value
    }
}

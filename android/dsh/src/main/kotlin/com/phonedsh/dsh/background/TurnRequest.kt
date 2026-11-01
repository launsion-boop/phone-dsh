// phone-dsh — :dsh / com.phonedsh.dsh.background: one turn's background contract.
// SPDX-License-Identifier: MIT
//
// A background window is only honest if it carries what the platform needs to
// describe it: the WAL epoch it belongs to, the last known step, and a payload
// estimate (UIDT uses the estimate to decide how long the job may run, plan
// §7.2). None of these values are invented here — :controller owns the epoch and
// the tool-call step; this module only transports them.

package com.phonedsh.dsh.background

import android.content.Intent

/**
 * The inputs the background layer needs to open a window for one turn.
 *
 * @property epoch the WAL epoch the turn belongs to (owned by `:controller`).
 * @property step the last tool-call boundary the caller observed; `0` means
 *   "before the first boundary", never "step one".
 * @property totalSteps total boundaries when the caller knows them; `0` keeps the
 *   progress bar indeterminate. A fabricated total is worse than no bar.
 * @property estimatedDownloadBytes / [estimatedUploadBytes] the payload estimate
 *   UIDT asks for. Callers replace the default with the real estimate as soon as
 *   they have one ([TurnBackground.progress] cannot update it: the system only
 *   accepts `JobService.updateEstimatedNetworkBytes` from the running job).
 * @property requiresNetwork whether the turn needs the network. UIDT is a network
 *   job: without a network constraint the layer falls back to the foreground
 *   service instead of pretending (see [TurnJobScheduler]).
 */
data class TurnRequest(
    val epoch: Long,
    val step: Int = 0,
    val totalSteps: Int = 0,
    val estimatedDownloadBytes: Long = DEFAULT_ESTIMATED_BYTES,
    val estimatedUploadBytes: Long = DEFAULT_ESTIMATED_BYTES,
    val requiresNetwork: Boolean = true,
) {
    init {
        require(epoch != TurnRuntime.UNKNOWN_EPOCH) { "a turn must carry its WAL epoch" }
        require(step >= 0) { "step is a tool-call boundary index, not a countdown" }
        require(totalSteps >= 0) { "totalSteps must be 0 (unknown) or positive" }
        require(estimatedDownloadBytes >= 0 && estimatedUploadBytes >= 0) {
            "payload estimates are byte counts"
        }
    }

    fun into(intent: Intent): Intent = intent
        .putExtra(EXTRA_EPOCH, epoch)
        .putExtra(EXTRA_STEP, step)
        .putExtra(EXTRA_TOTAL_STEPS, totalSteps)
        .putExtra(EXTRA_ESTIMATED_DOWNLOAD_BYTES, estimatedDownloadBytes)
        .putExtra(EXTRA_ESTIMATED_UPLOAD_BYTES, estimatedUploadBytes)
        .putExtra(EXTRA_REQUIRES_NETWORK, requiresNetwork)

    companion object {
        /**
         * 8 MiB: one plan/answer round trip with a modest tool result. This is a
         * placeholder the caller is expected to replace, not a measurement.
         */
        const val DEFAULT_ESTIMATED_BYTES: Long = 8L * 1024L * 1024L

        const val EXTRA_EPOCH = "com.phonedsh.dsh.background.extra.EPOCH"
        const val EXTRA_STEP = "com.phonedsh.dsh.background.extra.STEP"
        const val EXTRA_TOTAL_STEPS = "com.phonedsh.dsh.background.extra.TOTAL_STEPS"
        const val EXTRA_ESTIMATED_DOWNLOAD_BYTES =
            "com.phonedsh.dsh.background.extra.ESTIMATED_DOWNLOAD_BYTES"
        const val EXTRA_ESTIMATED_UPLOAD_BYTES =
            "com.phonedsh.dsh.background.extra.ESTIMATED_UPLOAD_BYTES"
        const val EXTRA_REQUIRES_NETWORK = "com.phonedsh.dsh.background.extra.REQUIRES_NETWORK"

        fun fromIntent(intent: Intent?): TurnRequest? {
            if (intent == null) return null
            val epoch = intent.getLongExtra(EXTRA_EPOCH, TurnRuntime.UNKNOWN_EPOCH)
            if (epoch == TurnRuntime.UNKNOWN_EPOCH) return null
            return TurnRequest(
                epoch = epoch,
                step = intent.getIntExtra(EXTRA_STEP, 0),
                totalSteps = intent.getIntExtra(EXTRA_TOTAL_STEPS, 0),
                estimatedDownloadBytes = intent.getLongExtra(
                    EXTRA_ESTIMATED_DOWNLOAD_BYTES,
                    DEFAULT_ESTIMATED_BYTES,
                ),
                estimatedUploadBytes = intent.getLongExtra(
                    EXTRA_ESTIMATED_UPLOAD_BYTES,
                    DEFAULT_ESTIMATED_BYTES,
                ),
                requiresNetwork = intent.getBooleanExtra(EXTRA_REQUIRES_NETWORK, true),
            )
        }
    }
}

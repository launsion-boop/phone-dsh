// SPDX-License-Identifier: MIT
// Queued-delivery preparation (spec/host/v1/README.md section 10.1;
// docs/protocol-changes/PC-20261114-ios-queued-engine-readiness.md).
//
// Kotlin port of `examples/probe-app/ProbeKit/Lifecycle/ChatDeliveryPreparation.swift`.
// Preparation only: queue admission and delivery receipts stay with SendOutbox.
// A decision is never a delivery receipt and never changes an entry.
package com.phonedsh.probe.outbox

internal enum class ChatDeliveryPreparation {
    /** The engine can take the queued work now. */
    READY,

    /** No engine: start it through the existing start transition. */
    START,

    /** The engine is parked: bring it back through the existing transition. */
    RESUME,

    /** A lifecycle transition or another operation is in flight; look again shortly. */
    WAIT,

    /** Not eligible to run the engine now. Nothing boots; the entries stay queued. */
    DEFERRED,

    /** Manual recovery is required, or the person stopped the engine. */
    NEEDS_ATTENTION,
    ;

    companion object {
        /**
         * The single execution-eligibility answer. On Android the App may run the
         * engine while it is in the foreground, or while the existing turn
         * window (the user-initiated job or its dataSync foreground service,
         * `platform.bgtask-drain-window` / `platform.audio-keepalive`) is held.
         */
        fun executionEligible(foreground: Boolean, keepingAlive: Boolean): Boolean = foreground || keepingAlive

        fun decide(
            foreground: Boolean,
            keepingAlive: Boolean,
            hostPresent: Boolean,
            parked: Boolean,
            transitioning: Boolean,
            busy: Boolean,
            transportReady: Boolean,
            requiresRecovery: Boolean,
            userPaused: Boolean = false,
        ): ChatDeliveryPreparation {
            if (requiresRecovery || userPaused) return NEEDS_ATTENTION
            // A background callback alone is not permission to boot or resume the engine.
            if (!executionEligible(foreground, keepingAlive)) return DEFERRED
            if (transitioning || busy) return WAIT
            if (!hostPresent) return START
            if (parked) return RESUME
            return if (transportReady) READY else WAIT
        }
    }
}

/** The host facts one preparation decision reads, sampled at one instant. */
internal data class ChatDeliveryFacts(
    val foreground: Boolean,
    val keepingAlive: Boolean,
    val hostPresent: Boolean,
    val parked: Boolean,
    val transitioning: Boolean,
    val busy: Boolean,
    val transportReady: Boolean,
    val requiresRecovery: Boolean,
) {
    val executionEligible: Boolean
        get() = ChatDeliveryPreparation.executionEligible(foreground, keepingAlive)

    fun decide(userPaused: Boolean): ChatDeliveryPreparation = ChatDeliveryPreparation.decide(
        foreground = foreground,
        keepingAlive = keepingAlive,
        hostPresent = hostPresent,
        parked = parked,
        transitioning = transitioning,
        busy = busy,
        transportReady = transportReady,
        requiresRecovery = requiresRecovery,
        userPaused = userPaused,
    )
}

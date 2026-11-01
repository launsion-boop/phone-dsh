// Host contract 1 — what a harness backend supports (schema/harness-capabilities).
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * What a harness backend supports.
 *
 * The host must not offer an action the backend cannot honour. A session may
 * narrow this set, never widen it ([HarnessSession.capabilities]).
 *
 * The member set and the three-valued enums are closed by
 * `spec/host/v1/schema/harness-capabilities.schema.json`; every member is
 * required on the wire. The constructor defaults mirror the reference
 * implementation for programmatic construction, but [HarnessJson] still
 * requires all seven members when decoding.
 *
 * One default deliberately does **not** mirror the reference: see
 * [runsWhileAppSuspended].
 */
public data class HarnessCapabilities(
    /** The backend can cancel a running turn. */
    public val cancel: Boolean = true,
    /** The backend accepts [HarnessCommand.Steer] while a turn runs. */
    public val steer: Boolean = false,
    /** How the host resumes an existing session. */
    public val resume: Resume = Resume.NATIVE,
    /** How risky tool calls are approved. */
    public val permission: Permission = Permission.NONE,
    /** How host-provided MCP tool servers reach the backend. */
    public val clientTools: ClientTools = ClientTools.NONE,
    /** Whether the backend emits [HarnessKind.ToolCall] / [HarnessKind.ToolResult]. */
    public val toolVisibility: Boolean = true,
    /**
     * Whether the harness may keep running while the app is suspended
     * (`true` for a remote harness, `false` for an embedded one).
     *
     * **The default is `false` on purpose.** A `true` here is a claim that a
     * turn keeps making progress with no visible Activity; the platform layer
     * uses it to admit device- or connector-initiated turns into the background
     * channel. On Android that claim is conditional (an FGS type the app may
     * actually start, user-initiated data transfer, POST_NOTIFICATIONS), so a
     * backend that can outlive the app still has to *earn* it on this host:
     * [BackgroundExecutionFacts] and [narrowedTo] compute it from the real
     * signals instead of hard-coding it. Decoding still honours the wire value
     * verbatim; only construction without facts is conservative.
     */
    public val runsWhileAppSuspended: Boolean = false,
) {
    /** Resume negotiation; hard-coded in host README §2.5. */
    public enum class Resume(public val wire: String) {
        /** The backend replays durable events after a cursor; resubscribe with `events(afterSeq)`. */
        NATIVE("native"),

        /** The client re-reads a transcript and reconstructs state client-side. */
        REPLAY("replay"),

        /** Start over; nothing is replayed. */
        NONE("none"),
        ;

        public companion object {
            /** Returns the value for a wire label, or `null` for a value this contract version does not know. */
            public fun fromWire(wire: String): Resume? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** How a permission request reaches the user. */
    public enum class Permission(public val wire: String) {
        /** The harness asks before risky tools and waits for [HarnessCommand.PermissionResponse]. */
        NATIVE("native"),

        /** Approvals are relayed through another channel (for example the phone's own tool gate). */
        RELAY("relay"),

        /** The harness never asks; the phone-side gate is the only control. */
        NONE("none"),
        ;

        public companion object {
            public fun fromWire(wire: String): Permission? = entries.firstOrNull { it.wire == wire }
        }
    }

    /** How the host's MCP tool servers reach the harness. */
    public enum class ClientTools(public val wire: String) {
        /** The harness accepts MCP servers at session creation. */
        NATIVE("native"),

        /** Tools reach the harness through a bridge (relay or proxy). */
        BRIDGE("bridge"),

        /** No client tools. */
        NONE("none"),
        ;

        public companion object {
            public fun fromWire(wire: String): ClientTools? = entries.firstOrNull { it.wire == wire }
        }
    }
}

/**
 * The Android facts that decide whether this host can honour
 * `runs_while_app_suspended` (plan §7.10, P6 acceptance "能力位诚实").
 *
 * The flag is not a property of the backend alone. A remote DSH harness may keep
 * a turn running with no visible Activity, but the *phone* still has to deliver
 * its events, answer permission prompts and serve the host's own MCP tools. Each
 * of those needs a foreground service that Android lets the app start, a
 * user-initiated data-transfer grant on Android 14+, and a granted
 * POST_NOTIFICATIONS so the FGS progress is actually user-visible (the plan's
 * "UIDT 进度可见" contract). If any is missing, the honest answer is `false`.
 *
 * Every field is a platform reading, never a preference: the caller passes what
 * `JobScheduler`/`NotificationManager`/`PackageManager` answered. A field left
 * `false` because nobody measured it produces the conservative answer, which is
 * the intended failure mode.
 */
public data class BackgroundExecutionFacts(
    /** The backend itself keeps the turn alive with no Activity (a remote harness, not the embedded engine). */
    public val backendOutlivesApp: Boolean,
    /** A foreground service of a type this app may start is running or startable, and is not stopped by the OS. */
    public val foregroundServiceUsable: Boolean,
    /** User-initiated data transfer is granted (Android 14+ `RUN_USER_INITIATED_JOBS`; not required below 14). */
    public val userInitiatedDataTransferGranted: Boolean,
    /** POST_NOTIFICATIONS is granted, so the FGS progress notification is visible to the user. */
    public val notificationsGranted: Boolean,
) {
    /** The honest value of the capability bit under these facts. */
    public val runsWhileAppSuspended: Boolean
        get() = backendOutlivesApp &&
            foregroundServiceUsable &&
            userInitiatedDataTransferGranted &&
            notificationsGranted

    /** The signals that are missing, in a stable order; empty when the claim holds. */
    public val missingSignals: List<Signal>
        get() = Signal.entries.filter { !it.isMetBy(this) }

    /**
     * One line for the log / runtime details: why the claim does or does not hold.
     *
     * Deliberately says what the *platform* answered, not what the backend wished
     * for, so a bug report can tell "no notification permission" from "embedded
     * engine".
     */
    public fun explain(): String {
        if (runsWhileAppSuspended) {
            return "runs_while_app_suspended=true: remote backend + foreground service + " +
                "user-initiated data transfer + notifications"
        }
        if (!backendOutlivesApp) {
            return "runs_while_app_suspended=false: the backend is embedded and stops with the app"
        }
        return "runs_while_app_suspended=false: backend outlives the app, but this host is missing " +
            missingSignals.joinToString(", ") { it.label }
    }

    /** The four platform readings, named so a failure says which one. */
    public enum class Signal(public val label: String) {
        BACKEND_OUTLIVES_APP("backend outlives the app"),
        FOREGROUND_SERVICE("foreground service"),
        USER_INITIATED_DATA_TRANSFER("user-initiated data transfer"),
        NOTIFICATIONS("POST_NOTIFICATIONS"),
        ;

        public fun isMetBy(facts: BackgroundExecutionFacts): Boolean = when (this) {
            BACKEND_OUTLIVES_APP -> facts.backendOutlivesApp
            FOREGROUND_SERVICE -> facts.foregroundServiceUsable
            USER_INITIATED_DATA_TRANSFER -> facts.userInitiatedDataTransferGranted
            NOTIFICATIONS -> facts.notificationsGranted
        }
    }
}

/**
 * Narrows [runsWhileAppSuspended] to what this host can honour, leaving every
 * other member untouched.
 *
 * A session may narrow capabilities, never widen them; this is the narrowing step
 * for the one member whose truth depends on the platform layer, not the backend.
 * The other direction is intentional: facts cannot turn a `false` into a `true`,
 * because the backend's own claim is a precondition.
 */
public fun HarnessCapabilities.narrowedTo(facts: BackgroundExecutionFacts): HarnessCapabilities =
    if (facts.runsWhileAppSuspended) {
        this
    } else {
        copy(runsWhileAppSuspended = false)
    }

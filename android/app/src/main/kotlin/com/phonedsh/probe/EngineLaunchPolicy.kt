// SPDX-License-Identifier: MIT
package com.phonedsh.probe

internal enum class LaunchHostState { absent, running, parked, failed }

internal enum class LaunchDecision(val wireValue: String) {
    BOOT("boot"),
    RESUME("resume"),
    READY("ready"),
    NATIVE_ONLY("nativeOnly"),
    DEFER("defer"),
    NEEDS_ATTENTION("needsAttention"),
}

internal object EngineLaunchPolicy {
    const val MIN_COLD_BOOT_MS = 20_000L
    const val MIN_RESUME_MS = 8_000L

    fun decide(
        foreground: Boolean,
        residentAudio: Boolean,
        hostState: LaunchHostState,
        leaseRemainingMs: Long?,
        userStopped: Boolean,
        needsReset: Boolean,
    ): LaunchDecision {
        require(leaseRemainingMs == null || leaseRemainingMs >= 0)
        if (needsReset) return LaunchDecision.NEEDS_ATTENTION
        if (userStopped) return LaunchDecision.DEFER
        if (hostState == LaunchHostState.running) return LaunchDecision.READY
        val required = if (hostState == LaunchHostState.parked) MIN_RESUME_MS else MIN_COLD_BOOT_MS
        if (!foreground && !residentAudio && (leaseRemainingMs ?: 0L) < required) {
            return LaunchDecision.NATIVE_ONLY
        }
        return if (hostState == LaunchHostState.parked) LaunchDecision.RESUME else LaunchDecision.BOOT
    }
}

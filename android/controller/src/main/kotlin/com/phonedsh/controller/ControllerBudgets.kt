// phone-dsh Android — :controller budgets (budgets.md §4), pure constants and tier selection.
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

import kotlin.math.min

private const val GIB_BYTES: Long = 1024L * 1024L * 1024L

/**
 * Device tiers of budgets.md §4. A tier is selected once per boot from the
 * physical memory ceiling: the 12 GiB row only applies at or above 12 GiB, the
 * 8 GiB row is the default for [8, 12) GiB, and every lower row applies below
 * the next threshold. `<= 3 GiB` catches every remaining value, including an
 * unknown `0`.
 */
enum class MemoryTier(val displayName: String, val minimumTotalMemoryBytes: Long) {
    GIB_12("12 GiB", 12L * GIB_BYTES),
    GIB_8("8 GiB", 8L * GIB_BYTES),
    GIB_6("6 GiB", 6L * GIB_BYTES),
    GIB_4("4 GiB", 4L * GIB_BYTES),
    AT_MOST_3("<= 3 GiB", 0L),
    ;

    companion object {
        /** Pure selection by the physical memory ceiling. */
        fun forTotalMemory(totalMemBytes: Long): MemoryTier {
            require(totalMemBytes >= 0) { "totalMemBytes must be non-negative, was $totalMemBytes" }
            // Entries are ordered by descending minimum, so the first match wins.
            return entries.first { totalMemBytes >= it.minimumTotalMemoryBytes }
        }
    }
}

/**
 * The budgets.md §4 tier table as constants plus the cross-cutting policy
 * constants of §3–§4. Every value in this class is a constant the controller
 * checks, never a measurement.
 *
 * `MB`/`MiB` are 1 048 576 bytes (budgets.md §4), so the binary units are used
 * literally for both.
 */
data class ControllerBudgets(
    val tier: MemoryTier,
    /** Nominal ceiling of the row: 12 / 8 / 6 / 4 / 3 GiB. */
    val nominalCeilingBytes: Long,
    val engineHeapBytes: Long,
    val vfsLogicalBytes: Long,
    val workspaceBytes: Long,
    val sessionsBytes: Long,
    val tmpBytes: Long,
    val singleFileBytes: Long,
    val singleFileHostMaxBytes: Long,
    val wasiHotInstanceBytes: Long,
    val appProcessBytes: Long,
    /** `workspace = 2 * single_file_limit + headroom` (budgets.md §4). */
    val workspaceHeadroomBytes: Long,
    val maxSubAgents: Int,
    val maxSubAgentsThermalFair: Int,
    val loopbackP95Millis: Int,
    val drainDeadlineMillis: Long,
    val recoveryBaseMaxMillis: Long,
    val recoveryMillisPerMb: Long,
    /** Planned restart after engine heap > 75 % for 3 samples. */
    val engineHeapRestartFraction: Double,
    val engineHeapRestartSamples: Int,
    /** Planned restart after 24 h of continuous running. */
    val continuousRunRestartMillis: Long,
    /** Drain and restart anyway when no tool-call boundary arrives within 60 s. */
    val restartBoundaryDeadlineMillis: Long,
) {
    init {
        require(vfsLogicalBytes >= workspaceBytes + sessionsBytes + tmpBytes) {
            "VFS logical bytes must cover workspace + sessions + tmp"
        }
        require(engineHeapBytes >= vfsLogicalBytes) {
            "engine heap must be at least the VFS logical cap"
        }
        require(workspaceBytes >= 2 * singleFileBytes + workspaceHeadroomBytes) {
            "workspace must hold two largest files plus its headroom"
        }
        require(singleFileBytes in MIN_SINGLE_FILE_BYTES..singleFileHostMaxBytes) {
            "single file limit must be inside [16 MiB, host maximum]"
        }
        require(maxSubAgents >= 1 && maxSubAgentsThermalFair == 1) {
            "sub-agent caps of budgets.md §4 are 2/2/2/1/1 and 1 under thermal fair"
        }
    }

    /** `Peak` row: at most 50 % of the row's nominal ceiling. */
    val peakBytes: Long get() = nominalCeilingBytes / 2

    /** Recovery target `a + k * MB`, with `MB` the materialized tree in MiB rounded up. */
    fun recoveryTargetMillis(materializedBytes: Long): Long {
        require(materializedBytes >= 0) { "materializedBytes must be non-negative" }
        val materializedMib = (materializedBytes + MIB - 1) / MIB
        return recoveryBaseMaxMillis + materializedMib * recoveryMillisPerMb
    }

    /**
     * The single-file limit clamped into `16 MiB ... single_file_host_max`
     * (budgets.md §4). A value outside the range is clamped, never a start
     * failure.
     */
    fun singleFileLimitClamped(requestedBytes: Long): Long =
        requestedBytes.coerceIn(MIN_SINGLE_FILE_BYTES, singleFileHostMaxBytes)

    /**
     * Apply a host `single_file_limit` and raise workspace, VFS and heap in
     * step ("a configuration never lowers a bucket").
     *
     * Note: on the 6 GiB row the host maximum of 128 MiB forces a 280 MB
     * workspace, a 360 MB VFS and a 360 MB heap, above that row's published
     * 120/200/256 MB values. The table is internally inconsistent there; this
     * function follows the "raise in step" rule and never lowers a bucket.
     */
    fun withSingleFileLimit(requestedBytes: Long): ControllerBudgets {
        val limit = singleFileLimitClamped(requestedBytes)
        val workspace = maxOf(workspaceBytes, 2 * limit + workspaceHeadroomBytes)
        val vfs = maxOf(vfsLogicalBytes, workspace + sessionsBytes + tmpBytes)
        val heap = maxOf(engineHeapBytes, vfs)
        return copy(
            singleFileBytes = limit,
            workspaceBytes = workspace,
            vfsLogicalBytes = vfs,
            engineHeapBytes = heap,
        )
    }

    /**
     * Sub-agent cap after the thermal and battery signals of budgets.md §3:
     * `fair` caps at one, `serious`/`critical` allow no new sub-agents, and a
     * low battery or Low Power Mode caps at one. Budgets are never raised.
     */
    fun maxSubAgentsFor(
        thermal: ThermalPressure,
        battery: BatterySnapshot? = null,
    ): Int {
        if (thermal == ThermalPressure.SERIOUS || thermal == ThermalPressure.CRITICAL) return 0
        var cap = if (thermal == ThermalPressure.FAIR) maxSubAgentsThermalFair else maxSubAgents
        if (battery?.constrained == true) cap = min(cap, 1)
        return cap
    }

    companion object {
        const val MIB: Long = 1_048_576L
        const val GIB: Long = 1024L * MIB
        const val MIN_SINGLE_FILE_BYTES: Long = 16L * MIB

        /** budgets.md §1: the drain deadline is 20 s. */
        const val DRAIN_DEADLINE_MILLIS: Long = 20_000L

        /** informational loopback target, never a state change by itself. */
        const val LOOPBACK_P95_MILLIS: Int = 5

        /** Recovery target `a <= 3 s`, `k <= 0.05 s/MB`. */
        const val RECOVERY_BASE_MAX_MILLIS: Long = 3_000L
        const val RECOVERY_MILLIS_PER_MB: Long = 50L

        const val ENGINE_HEAP_RESTART_FRACTION: Double = 0.75
        const val ENGINE_HEAP_RESTART_SAMPLES: Int = 3
        const val CONTINUOUS_RUN_RESTART_MILLIS: Long = 24L * 60L * 60L * 1_000L
        const val RESTART_BOUNDARY_DEADLINE_MILLIS: Long = 60_000L

        /** "The 8 GB row is the default" (budgets.md §4). */
        val DEFAULT_TIER: MemoryTier = MemoryTier.GIB_8

        private fun budgets(
            tier: MemoryTier,
            ceilingGiB: Long,
            heapMiB: Long,
            vfsMiB: Long,
            workspaceMiB: Long,
            sessionsMiB: Long,
            tmpMiB: Long,
            singleFileMiB: Long,
            singleFileHostMaxMiB: Long,
            wasiMiB: Long,
            appMiB: Long,
            headroomMiB: Long,
            subAgents: Int,
        ): ControllerBudgets = ControllerBudgets(
            tier = tier,
            nominalCeilingBytes = ceilingGiB * GIB,
            engineHeapBytes = heapMiB * MIB,
            vfsLogicalBytes = vfsMiB * MIB,
            workspaceBytes = workspaceMiB * MIB,
            sessionsBytes = sessionsMiB * MIB,
            tmpBytes = tmpMiB * MIB,
            singleFileBytes = singleFileMiB * MIB,
            singleFileHostMaxBytes = singleFileHostMaxMiB * MIB,
            wasiHotInstanceBytes = wasiMiB * MIB,
            appProcessBytes = appMiB * MIB,
            workspaceHeadroomBytes = headroomMiB * MIB,
            maxSubAgents = subAgents,
            maxSubAgentsThermalFair = 1,
            loopbackP95Millis = LOOPBACK_P95_MILLIS,
            drainDeadlineMillis = DRAIN_DEADLINE_MILLIS,
            recoveryBaseMaxMillis = RECOVERY_BASE_MAX_MILLIS,
            recoveryMillisPerMb = RECOVERY_MILLIS_PER_MB,
            engineHeapRestartFraction = ENGINE_HEAP_RESTART_FRACTION,
            engineHeapRestartSamples = ENGINE_HEAP_RESTART_SAMPLES,
            continuousRunRestartMillis = CONTINUOUS_RUN_RESTART_MILLIS,
            restartBoundaryDeadlineMillis = RESTART_BOUNDARY_DEADLINE_MILLIS,
        )

        private val TIERS: Map<MemoryTier, ControllerBudgets> = listOf(
            //               tier             ceil  heap  vfs   ws   ses  tmp  file  max  wasi  app  head  sub
            budgets(MemoryTier.GIB_12, 12L, 832L, 768L, 576L, 96L, 96L, 256L, 256L, 640L, 540L, 64L, 2),
            budgets(MemoryTier.GIB_8, 8L, 448L, 388L, 288L, 50L, 50L, 128L, 128L, 260L, 230L, 32L, 2),
            budgets(MemoryTier.GIB_6, 6L, 256L, 200L, 120L, 40L, 40L, 48L, 128L, 200L, 140L, 24L, 2),
            budgets(MemoryTier.GIB_4, 4L, 192L, 144L, 80L, 32L, 32L, 32L, 32L, 144L, 120L, 16L, 1),
            budgets(MemoryTier.AT_MOST_3, 3L, 144L, 96L, 48L, 24L, 24L, 16L, 16L, 96L, 100L, 16L, 1),
        ).associateBy { it.tier }

        /** The constants of one tier. */
        fun forTier(tier: MemoryTier): ControllerBudgets = TIERS.getValue(tier)

        /** Pure tier selection from the physical memory ceiling. */
        fun forTotalMemory(totalMemBytes: Long): ControllerBudgets =
            forTier(MemoryTier.forTotalMemory(totalMemBytes))
    }
}

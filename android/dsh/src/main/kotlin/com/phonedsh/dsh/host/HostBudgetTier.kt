// phone-dsh — :dsh / com.phonedsh.dsh.host: the boot budget tier of budgets.md §4.
// SPDX-License-Identifier: MIT
//
// ---- the contract sentence this file implements ----------------------------
// budgets.md:95-97: "Device tiers are selected once per boot from the physical
// memory ceiling. The 8 GB row is the default; a lower row applies when the
// ceiling is below 8 GiB, and the 12 GiB row applies only when the ceiling is at
// least 12 GiB." The rows themselves are budgets.md:99-115 (heap, VFS logical
// bytes, the workspace/sessions/tmp split, single file, WASI hot instance, app
// process, peak, sub-agents).
//
// Until this file existed the Android port never made that selection. The
// `single_file_limit` of budgets.md:104/120-123 and the `VFS_REFUSED` refusal of
// channel.md:236/§8 were listed as "not-implemented" in HostChannel.kt and
// HostExec.kt, no caller ever read `ActivityManager.MemoryInfo.totalMem`, and
// the Worker kept its own 8 GiB default of 128 MiB
// (`plugins/wasi-toolbox/src/limits.ts:46` DEFAULT_SINGLE_FILE_LIMIT,
// `plugins/worker-entry/src/entry.ts`). A 2 GiB device — the `≤ 3 GiB` row, whose
// single-file limit is 16 MiB — could therefore accept a 128 MiB file, publish
// it through the WAL and only fail later during recovery. The tier table is not
// an optimisation: a device that is handed a row it is not in has a budget the
// contract says it does not have.
//
// ---- where the selected limit goes ----------------------------------------
// Two surfaces, both owned by this port:
//
//   1. `PDSH_SINGLE_FILE_LIMIT_BYTES` in the Worker environment. channel.md §4.1
//      defines HELLO without a file-limit member and reserves every capability
//      string outside `channel/1`, `wal/1`, `exec/1` and `accelerator:<name>`
//      ("Other capability strings are reserved"), so a capability cannot carry
//      this value either. The environment is the contract's publication
//      channel: `plugins/wasi-toolbox/src/limits.ts:43-44` names this variable
//      as "Environment name the host uses to publish its `single_file_limit`
//      (D4)", the Worker entry clamps it into 16 MiB…256 MiB (budgets.md:120-123
//      says an out-of-range value is clamped, never a start failure) and
//      `configureSingleFileLimit` applies it before the VFS boots. The Worker's
//      own write surfaces then refuse an over-limit write with `EFBIG`
//      (channel.md:264-268) *before* any mutation is published.
//   2. The host [VfsSink], which answers a structurally valid mutation that
//      would grow a file past the limit with one `VFS_REFUSED` and consumes no
//      mseq (channel.md:236, :298, :362; budgets.md §4 "enforced at write time").
//      That is the backstop for a Worker that either never received the
//      environment or ignored it.
//
// ---- why the ceiling, and what "unknown" means -----------------------------
// `MemoryInfo.totalMem` is the physical memory ceiling budgets.md:95 names (the
// same value `:domain`'s `AndroidDeviceCapabilities` reports as
// `totalMemoryBytes`). It is read once per boot; §4 says the tier is selected
// once per boot, so a later memory-pressure reading must not re-tier the host.
//
// A missing reading (`totalMem == 0`, which Android documents as a failed
// reading) is *not* the 8 GiB default: it is mapped to the `≤ 3 GiB` row through
// `ControllerBudgets.forTotalMemory(0)`, the same value that type's own test
// pins (`BudgetTierTest`). An unmeasured device must not be granted a quota the
// contract has no evidence for; every real device reports a positive totalMem.
//
// `UNMEASURED` is the other, deliberately *identical* case: a caller that never
// measured anything at all (a unit test, a host with no Context) gets the same
// `≤ 3 GiB` row, not the §4 8 GiB row. budgets.md:95-97 says "The 8 GB row is
// the default" while it is defining the mapping from a **known** ceiling (a
// ceiling below 8 GiB takes a lower row, a ceiling at or above 12 GiB takes the
// 12 GiB row); nothing in §4 of budgets.md, and nothing else in `spec/v1`,
// says which row applies when the memory ceiling is **unknown** — the word
// "unknown"/"unmeasured" does not occur in budgets.md at all. An earlier
// revision of this file answered that unstated case with the 8 GiB row
// (128 MiB), which contradicted the read-failure path two paragraphs above and
// re-opened exactly the bug this lane exists to close: a `≤ 3 GiB` device
// carrying an 8× larger file quota. One question gets one answer now, and it is
// the answer that can only ever make a quota smaller.

package com.phonedsh.dsh.host

import android.app.ActivityManager
import android.content.Context
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.MemoryTier

/** The budgets.md §4 device tier, selected from `MemoryInfo.totalMem`. */
object HostBudgetTier {
    /**
     * Environment variable through which a host publishes its
     * `single_file_limit` to the Worker (D4;
     * `plugins/wasi-toolbox/src/limits.ts:43`).
     *
     * The name is the Worker's, not this port's invention: the Worker entry
     * reads exactly this key (`normalizeSinkLimits` →
     * `singleFileLimitFromEnvironment`), clamps it to 16 MiB…256 MiB and applies
     * it to every write surface before the VFS boots.
     */
    const val SINGLE_FILE_LIMIT_ENV: String = "PDSH_SINGLE_FILE_LIMIT_BYTES"

    /**
     * The row for a caller that has **no** memory measurement: `≤ 3 GiB`.
     *
     * This is the same row [readTotalMemoryBytes] failure produces, on purpose.
     * "Unmeasured" and "a reading of 0" are the same fact — the host does not
     * know this device's ceiling — and one fact may not have two answers. The
     * contract does not state the unknown case (budgets.md:95-97 only maps a
     * known ceiling, and budgets.md never uses the word "unknown"), so the
     * implementation takes the side that cannot widen a quota: the smallest row
     * of budgets.md:104, whose `single_file_limit` is 16 MiB — the same floor
     * budgets.md:120-123 sets for any configured value.
     *
     * The cost of guessing low is a quota a device could have had; the cost of
     * guessing high is a `≤ 3 GiB` device accepting an 8× file, which is the
     * failure (file accepted, recovery OOM) this lane was opened for.
     */
    val UNMEASURED: ControllerBudgets = ControllerBudgets.forTier(MemoryTier.AT_MOST_3)

    /**
     * The §4 row for one physical memory ceiling.
     *
     * Pure: the thresholds live in `ControllerBudgets` (`MemoryTier`), the one
     * owner of the table, so this port cannot drift from the constants the
     * controller enforces. `0` is "no reading" and selects `≤ 3 GiB`; a
     * negative value is a programming error there and is rejected by it.
     */
    fun forTotalMemory(totalMemoryBytes: Long): ControllerBudgets =
        ControllerBudgets.forTotalMemory(totalMemoryBytes)

    /**
     * `ActivityManager.MemoryInfo.totalMem` for this device, or `null` when the
     * service or the reading is unavailable.
     *
     * `totalMem` is 0 on a failed reading, which is the one non-positive value
     * the framework produces; it is reported as `null` rather than as a device
     * with zero bytes so the caller can tell "unknown" from a real ceiling.
     */
    fun readTotalMemoryBytes(context: Context): Long? {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null
        val info = ActivityManager.MemoryInfo()
        return try {
            manager.getMemoryInfo(info)
            if (info.totalMem > 0L) info.totalMem else null
        } catch (_: RuntimeException) {
            // A SecurityException or a vendor service that is not there: the
            // caller then takes the ≤ 3 GiB row, never a larger one.
            null
        }
    }

    /**
     * The §4 row for this device, read once per boot.
     *
     * @param context any context; only the ActivityManager is read.
     */
    fun forDevice(context: Context): ControllerBudgets =
        forTotalMemory(readTotalMemoryBytes(context) ?: 0L)

    /** The `single_file_limit` of [forTotalMemory] in bytes (budgets.md:104). */
    fun singleFileLimitBytes(totalMemoryBytes: Long): Long =
        forTotalMemory(totalMemoryBytes).singleFileBytes

    /**
     * The Worker environment entries this tier publishes.
     *
     * One entry today: the `single_file_limit`. The Worker also accepts
     * `PDSH_VFS_LOGICAL_BYTES`, `PDSH_VFS_WORKSPACE_BYTES`,
     * `PDSH_VFS_SESSIONS_BYTES`, `PDSH_VFS_TMP_BYTES` and
     * `PDSH_WASI_HOT_INSTANCE_BYTES`, and §4 does budget those per row, but this
     * lane only makes the single-file limit true end to end; publishing a quota
     * the host does not enforce on its own sink would be a second, half-wired
     * budget. Reported as an open question rather than half done.
     */
    fun workerEnvironment(totalMemoryBytes: Long): Map<String, String> = mapOf(
        SINGLE_FILE_LIMIT_ENV to singleFileLimitBytes(totalMemoryBytes).toString(),
    )

    /** `true` when [totalMemoryBytes] is a real reading (not 0 / negative). */
    fun isMeasured(totalMemoryBytes: Long): Boolean = totalMemoryBytes > 0L
}

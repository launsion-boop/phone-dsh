// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the mock environment's host runtime.
// SPDX-License-Identifier: MIT
//
// ---- what this file is ----
// The wiring half of the L47 mock: it builds the `ubuntu.exec` lane over
// [MockUbuntuAdapter] so the Agent-facing `ubuntu` command has a host tool to
// call. It is deliberately NOT the real environment (no proot, no rootfs, no
// real command); everything it stands in for is named "mock" here and rendered
// as `backend=mock` in the answer, so a synthetic exit 0 can never be read as a
// real compile.
//
// ---- the seal is injected, and defaults to the mock -------------------------
// The real `BuildSeal` lives in `:platform-android` and `:dsh` does not depend on
// it, so the seal arrives as an [UbuntuSeal] from the composition root (`:app`
// passes `BuildSealUbuntu`). The default here is still [MockUbuntuSeal], because
// this class *is* the mock environment and its unit suite builds it with no
// device; `HostExec.defaultTools` — the one production construction point —
// defaults to `UbuntuSeal.unwired` instead, so a host that forgets to inject one
// fails closed (`seal_unavailable`) rather than claiming a sealed window it never
// opened.
//
// [MockUbuntuSeal] opens and closes nothing; its tripwire observes nothing. It
// reports `isMock = true`, and the host tool copies that into `sealMock` instead
// of writing `true` as a literal, so a real seal is rendered as a real one.
//
// ---- why the job store lives under a temp directory ----
// The mock adapter dies with the process, so a job persisted anywhere else could
// never be resumed: §12.3's `remote` row would have no adapter to resume with.
// A per-process temp directory is the honest store for an in-process mock; the
// record format and the atomic replace are the production ones, so the lane's
// durability path is still exercised.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/**
 * The `Durability` SPI over real files, for the mock's job store.
 *
 * `atomicReplace` is the production order the WAL and `HostStateStore` use:
 * write a temp sibling, fsync it, rename over the target, fsync the directory.
 * The mock has no power-loss promise to keep, but a half-written record would
 * still break `ubuntu.status`, so the order is not simplified away.
 */
class MockRecordDurability : Durability {
    override suspend fun fsyncPath(path: Path) {
        if (Files.isDirectory(path)) {
            fsyncDirectory(path)
            return
        }
        FileChannel.open(path, StandardOpenOption.READ).use { channel ->
            channel.force(true)
        }
    }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        Files.createDirectories(target.parent)
        val temporary = target.resolveSibling("${target.fileName}.tmp")
        try {
            write(temporary)
            fsyncPath(temporary)
            Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING)
            fsyncDirectory(target.parent)
        } catch (failure: IOException) {
            Files.deleteIfExists(temporary)
            throw failure
        }
    }

    override fun level(): DurabilityLevel = DurabilityLevel.LEVEL_1_PROCESS_KILL

    private fun fsyncDirectory(directory: Path) {
        // Directory fsync is not portable to every Android filesystem; a
        // refusal here must not fail a save that the rename already completed.
        try {
            FileChannel.open(directory, StandardOpenOption.READ).use { channel ->
                channel.force(true)
            }
        } catch (ignored: IOException) {
            // Best effort; the record itself is already fsynced.
        }
    }
}

/**
 * The mock's seal: it opens nothing and observes nothing.
 *
 * Never use this for a real environment — [UbuntuSeal.unwired] is the
 * fail-closed seam for that case, and this class exists only because the mock
 * adapter reads no workspace byte, so there is no window to protect. The host
 * tool renders `sealMock` from [isMock], so an answer produced through this seam
 * says so.
 */
class MockUbuntuSeal : UbuntuSeal {
    override suspend fun seal(jobId: String): UbuntuSealResult = UbuntuSealResult.Sealed

    override suspend fun restore(jobId: String): UbuntuSealResult = UbuntuSealResult.Sealed

    override fun observed(jobId: String): Boolean = false

    override suspend fun repair(): Boolean = true

    /** This seam protects nothing, and every answer it produces says so. */
    override val isMock: Boolean = true
}

/**
 * One mock environment session: the same lane wiring as [HostUbuntuSession],
 * with the mock adapter, seal, volatile store and backend name.
 *
 * @param clock wall time for the lane and the adapter's delay.
 * @param budgets the tier numbers the JobRef publishes; the host passes its own
 *   tier when it has one, and the default row otherwise.
 * @param logger token-free host log.
 * @param adapter the environment; a fresh mock is built when this is omitted so
 *   a session that outlives one job still has an adapter.
 * @param seal the seal the lane runs inside. The composition root injects the
 *   real one (`BuildSealUbuntu` in `:platform-android`); the default is the mock
 *   because this class is the mock environment. `HostExec.defaultTools` never
 *   relies on this default — it passes its own seam, whose default is the
 *   fail-closed `UbuntuSeal.unwired`.
 * @param admissionOpen the host's admission state, read at job start.
 * @param storeRoot the job store; a per-process temp directory when omitted.
 */
class MockUbuntuSession(
    clock: Clock,
    budgets: ControllerBudgets = ControllerBudgets.forTier(ControllerBudgets.DEFAULT_TIER),
    logger: HostLog = HostLog.None,
    // The mock's own manifest sits on both sides of the 15 MiB mutation bound
    // by design (`tiny.txt`, `mid.bin`, `huge.bin`). The Agent-facing session
    // declares a 20 MiB artifact limit so the ordinary answer is `succeeded`
    // with the manifest visible; the ingest-refusal path stays covered by the
    // lane's own tests, which build their own adapter.
    adapter: UbuntuAdapter = MockUbuntuAdapter(
        clock = clock,
        fileLimitBytes = MockUbuntuAdapter.HUGE_BYTES,
    ),
    seal: UbuntuSeal = MockUbuntuSeal(),
    admissionOpen: () -> Boolean = { true },
    storeRoot: Path? = null,
) : HostUbuntuSession(
    clock = clock,
    budgets = budgets,
    logger = logger,
    adapter = adapter,
    seal = seal,
    backend = BACKEND,
    admissionOpen = admissionOpen,
    storeRoot = storeRoot ?: Files.createTempDirectory("pdsh-ubuntu-jobs"),
    durability = MockRecordDurability(),
) {
    companion object {
        /** The backend name reported in every answer. */
        const val BACKEND: String = "mock"
    }
}

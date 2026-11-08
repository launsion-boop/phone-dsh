// phone-dsh — :dsh / com.phonedsh.dsh.host: the exec lane's host-side wiring.
// SPDX-License-Identifier: MIT
//
// `com.phonedsh.dsh.exec` owns the protocol (ExecRequest/ExecEvent/ExecBridge);
// this file is the only place that builds it from a `:dsh` host. The bridge's
// constructor demands an `ExecCapability.Available`, so an empty tool registry
// cannot produce a bridge — and therefore cannot advertise `exec/1`.
//
// The first tool is `phone`; its only command is `phone info`, implemented in
// PhoneInfoTool.kt. The other tools are the Rust accelerators (`rg`, `jaq`)
// exposed by `:shell`: this file registers exactly the subset
// `ShellAccelerators.detect(shellMounts)` reports as executable, so the HELLO's
// `accelerator:*` set can never contain a command the host cannot run. Both are
// host-side, read-only accelerators (exec.md §3): they run in this process and
// return bytes, not a process handle.
//
// ---- exec gaps this wiring does not close (J2's list) ----------------------
// * not-implemented: **in-flight duplicate `idem_key`**. ExecBridge refuses a
//   duplicate while the first call is running with a terminal `in_flight` error;
//   it does not join or wait for the first result. A live store would be needed.
// * not-implemented: **live store**. There is no store of in-flight
//   executions/events for reconnect replay or API streaming; the bridge emits the
//   recorded result's events once.
//
// `EXEC_CTL` (`0x22`) is not a gap of this file: HostChannel dispatches it and
// `ExecBridge.onControl` applies it. This object only builds the bridge.
//
// ---- the D10 dedup ledger is injected, never chosen here --------------------
// ExecBridge keeps its replay answers in one `RequestLedger`. The default below
// is `InMemoryRequestLedger`, which is honest only for a caller with no
// workspace (the unit suite): a restart loses the answers. The composition root
// owns the durable backend — `:app` passes
// `FileRequestLedger(workspaceRoot, durability, clock)` over the same workspace
// root the WAL and the journal use — so there is one dedup table (`exec/` under
// that root), not a second in-memory policy beside it.
//
// ---- VFS policy gaps (separate from the wal/1 persistence promise) ----------
// * host `single_file_limit` / `VFS_REFUSED` budget refusal is no longer a gap:
//   [HostBudgetTier] selects the §4 row and [VfsSink] answers the refusal;
// * not-implemented: inbound `seq` enforcement;
// * not-implemented: 32 MiB flow control;
// * not-implemented: 2 ms group commit (per-mutation level-1 ACK is legal and is
//   what the sink does today).

package com.phonedsh.dsh.host

import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.AdmissionGate
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.dsh.exec.ExecWorkspace
import com.phonedsh.dsh.localexec.MockUbuntuSession
import com.phonedsh.dsh.localexec.UbuntuHostTool
import com.phonedsh.dsh.localexec.UbuntuPhoneCatalog
import com.phonedsh.dsh.localexec.UbuntuSeal
import com.phonedsh.dsh.localexec.UbuntuSessionFactory
import com.phonedsh.dsh.tools.InMemoryRequestLedger
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.dsh.tools.RequestLedger
import com.phonedsh.platform.Clock
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.shell.ShellAccelerators

/** The host-side constructors for an `ExecBridge`; not a registry of its own. */
object HostExec {
    /**
     * The `exec/1` bridge with `phone info` plus the mounted Rust accelerators.
     *
     * Admission is read from the D14 machine at call time (the same authority the
     * rest of the host uses), and the applied watermark comes from the recovered
     * WAL. A `null` [wal] is legal: `phone info` has `requires_mseq = 0`, so it
     * does not need a VFS view; a request that does need one waits and times out
     * rather than reading a missing view.
     *
     * `rg` / `jaq` are registered only when [shellMounts] is non-empty and the
     * linked library advertises them — the two conditions `pdsh-ffi` itself
     * enforces for every run. An empty [shellMounts] therefore advertises only
     * `phone`, which is honest rather than a degraded `rg` that cannot read
     * anything.
     *
     * @param clock wall time for `deadline`, monotonic time for the readiness
     *   bound, exactly the `ExecBridge` contract.
     * @param controller the D14 machine; its `admission` is the one gate.
     * @param wal the WAL seam, or `null` when no workspace is attached.
     * @param logger the token-free host log.
     * @param ledger the one D10 dedup table. Production injects the durable
     *   `FileRequestLedger` built over the workspace root (exec.md §2); the
     *   in-memory default is for a caller with no workspace, where a restart
     *   loses replay answers and there is nowhere honest to persist them.
     * @param shellMounts guest-to-host mounts for the Rust accelerators, normally
     *   the WAL's materialized `workspace/` and `home/` directories. Empty means
     *   "this host has no workspace the accelerators may read".
     * @param seal the seal the `ubuntu` lane runs each job inside. `:dsh` links
     *   no platform adapter, so the real one (`BuildSealUbuntu` over
     *   `BuildSeal`, in `:platform-android`) is injected here by the composition
     *   root (`:app`). The default is [UbuntuSeal.unwired] — **not** the mock —
     *   so a host built without one refuses every `ubuntu run` with
     *   `seal_unavailable` instead of reporting a sealed window that never
     *   existed. That default is the audit's fix: the previous wiring answered
     *   `sealed` from a seam that opened nothing, on the production path, for
     *   every job.
     * @param ubuntuSessionFactory the environment behind the `ubuntu` tool. The
     *   default is the mock session, built over the injected seal; `:app` passes
     *   a factory over `ProotUbuntuSession`, which is the only place the real
     *   adapter is selected. `:dsh` never names the real backend.
     *
     * @param nativeTools tools the composition root implements outside `:dsh`
     *   (the native `ssh` / `scp` accelerators of `docs/native-ssh.md`). Each
     *   name must be one of exec.md §3; an empty list advertises none of them.
     *
     * Historical note: this function was named `phoneOnly` while `phone info`
     * was the only registered accelerator. The old name is kept here so code
     * search and older reports still find the call site.
     */
    fun defaultTools(
        clock: Clock,
        controller: ControllerStateMachine,
        wal: HostWal?,
        logger: HostLog,
        ledger: RequestLedger = InMemoryRequestLedger(),
        shellMounts: List<AcceleratorMount> = emptyList(),
        seal: UbuntuSeal = UbuntuSeal.unwired,
        nativeTools: List<RegisteredTool> = emptyList(),
        ubuntuSessionFactory: UbuntuSessionFactory = UbuntuSessionFactory(
            backend = MockUbuntuSession.BACKEND,
        ) {
            MockUbuntuSession(
                clock = clock,
                logger = logger,
                seal = seal,
                admissionOpen = { controller.admission == Admission.OPEN },
            )
        },
    ): ExecBridge {
        val tools = ArrayList<RegisteredTool>(1 + shellMounts.size)
        // `phone` is one tool with a small catalog: `info` (the device facts,
        // unchanged) and `ubuntu` (the local Linux environment, L51). The
        // environment is a host tool, not an accelerator — it writes, so it
        // stays out of the read-only name set — and the Worker discovers it by
        // probing `phone ubuntu probe` at boot. A host without this wiring
        // answers the probe with `unsupported`, so the Agent's `ubuntu` command
        // does not exist there (127).
        tools.add(
            RegisteredTool(
                PhoneInfoTool.NAME,
                UbuntuPhoneCatalog(
                    info = PhoneInfoTool(),
                    ubuntu = UbuntuHostTool(
                        clock = clock,
                        logger = logger,
                        admissionOpen = { controller.admission == Admission.OPEN },
                        seal = seal,
                        sessionFactory = ubuntuSessionFactory,
                    ),
                ),
            ),
        )
        for (accelerator in ShellAccelerators.detect(shellMounts)) {
            tools.add(
                RegisteredTool(
                    accelerator.name,
                    ShellAcceleratorTool(accelerator, shellMounts, clock),
                ),
            )
        }
        // Native accelerators the composition root owns (`ssh` / `scp`): they
        // are registered only when the host really has an implementation, so
        // the HELLO never advertises a command this process cannot run.
        tools.addAll(nativeTools)
        // `phone` always exists, so the non-empty factory is the right one; the
        // advertised names are exactly the tools registered above.
        val capability = ExecCapability.of(tools.first(), *tools.drop(1).toTypedArray())
        return ExecBridge(
            capability = capability,
            admission = AdmissionGate { controller.admission == Admission.OPEN },
            workspace = ExecWorkspace { wal?.appliedMseq() ?: 0L },
            clock = clock,
            logger = logger,
            ledger = ledger,
        )
    }
}

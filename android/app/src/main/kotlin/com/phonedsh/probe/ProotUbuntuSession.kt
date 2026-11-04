// phone-dsh — :app / com.phonedsh.probe: the real session's composition.
// SPDX-License-Identifier: MIT
//
// `HostUbuntuSession` owns the lane wiring; this class is the real backend's
// name and availability fact. It exists as its own type (rather than an inline
// factory) so no caller can accidentally pass the proot adapter while the
// answers still say `backend=mock`: [BACKEND] is the only name this session
// can produce.
//
// Construction opens no file, downloads nothing and starts no process: the
// rootfs is guaranteed inside `ProotUbuntuAdapter.start`, after the approval
// gate and after the lane sealed the workspace.

package com.phonedsh.probe

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.localexec.HostUbuntuSession
import com.phonedsh.dsh.localexec.UbuntuSeal
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import java.nio.file.Path

/** The real local environment's session. */
class ProotUbuntuSession(
    clock: Clock,
    adapter: ProotUbuntuAdapter,
    seal: UbuntuSeal,
    storeRoot: Path,
    durability: Durability,
    admissionOpen: () -> Boolean = { true },
    budgets: ControllerBudgets = ControllerBudgets.forTier(ControllerBudgets.DEFAULT_TIER),
    logger: HostLog = HostLog.None,
) : HostUbuntuSession(
    clock = clock,
    budgets = budgets,
    logger = logger,
    adapter = adapter,
    seal = seal,
    backend = BACKEND,
    admissionOpen = admissionOpen,
    storeRoot = storeRoot,
    durability = durability,
    available = adapter.available,
    unavailableReason = adapter.unavailableReason,
) {
    companion object {
        /** The backend name every answer from this session carries. */
        const val BACKEND: String = "proot"
    }
}

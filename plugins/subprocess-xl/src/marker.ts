// SPDX-License-Identifier: MIT
/**
 * argv[0] the guest sandbox provider puts in front of a confined command:
 * `[CONFINE_MARKER, mode, workspaceRoot, '--', ...argv]`. The subprocess
 * provider strips it into the exec request's `confine` field, the same way a
 * local runner (bwrap, sandbox-exec) wraps argv.
 * @module @phone-dsh/dsh-subprocess-xl/marker
 */
export const CONFINE_MARKER = 'pdsh-guest-confine'

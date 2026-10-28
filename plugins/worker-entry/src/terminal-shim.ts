// SPDX-License-Identifier: MIT
/**
 * Phone Worker refusal for the official persistent-terminal service.
 *
 * The Worker has no OS PTY. `subprocess-xl.spawnTerminal` rejects by design,
 * and the official xterm surface row is disabled rather than showing a
 * permanently failing terminal. The service class itself would still mount
 * (and then fail only when the first terminal opens), which makes the `minimal`
 * preset look healthy even though its persistent-shell rows cannot work here.
 * This module fails that mount loudly and names the missing primitive, so the
 * preset registry reports the real limitation instead of a misleading green
 * health row. It is not a terminal implementation.
 * @module @phone-dsh/dsh-worker-entry/terminal-shim
 */

/** Cordis plugin name; mirrors the official service row. */
export const name = 'terminal'

/** No services are required: the refusal is the platform fact. */
export const inject: readonly string[] = []

/** Fail the mount with the actual missing capability. */
export function apply(): never {
  throw new Error(
    'the phone Worker has no terminal (PTY) primitive: persistent terminals are unavailable '
    + 'and the phone-shell command console is the supported surface',
  )
}

/** Module namespace the Cordis loader accepts. */
export default { name, inject, apply }

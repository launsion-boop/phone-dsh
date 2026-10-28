// SPDX-License-Identifier: MIT
/**
 * Convenience location for the `just-bash` corpus runner.
 *
 * `tools/shell-corpus/runners.mjs` resolves external runners next to
 * `shell-ext/` (`shell-ext/coverage/<name>.mjs`), which is where the
 * implementation lives; this file keeps the runner reachable at the location
 * named by the W5 work package without editing the tool that loads it.
 * @module tools/shell-corpus/runners/just-bash
 */

export { JustBashRunner, commandPrograms, createRunner, seedWorkspace } from '../../../shell-ext/coverage/just-bash.mjs'
export { default } from '../../../shell-ext/coverage/just-bash.mjs'

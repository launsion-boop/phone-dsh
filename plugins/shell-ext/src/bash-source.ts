// SPDX-License-Identifier: MIT
/**
 * `BASH_SOURCE` for a script file run by the Worker shell.
 *
 * just-bash 3.6.0 parses `${BASH_SOURCE[0]}`, `$BASH_SOURCE`,
 * `${BASH_SOURCE[@]}` and `${BASH_SOURCE[*]}` as ordinary parameter
 * expansions, but never defines the variable. GNU bash sets it to the source
 * file of the current execution: for a script started as `./script.sh`,
 * `bash script.sh` or `/bin/bash script.sh`, `${BASH_SOURCE[0]}` is exactly
 * the resolved script path, the same value `$0` carries. Scripts that locate
 * their own directory this way therefore saw an empty string and resolved
 * every relative resource against `/`.
 *
 * `positionalEnvironment` already supplies `$0`; this transform rewrites the
 * four operation-free source forms to `${0}` before the script runs. It is
 * registered only for a file-script execution (`bash script` / `./script`):
 * GNU bash leaves `BASH_SOURCE` unset at the top level of `bash -c`, so the
 * `-c` path deliberately keeps the engine's (empty) value.
 *
 * Deliberate limits, recorded in `docs/p1/shell-invocation-argv-trap.md`:
 * `source`-nested scripts and `BASH_SOURCE[1]`/higher are not modelled (the
 * Worker shell has no source stack); `${BASH_SOURCE[0]:-default}` and other
 * operations are left to the engine, exactly as parsed.
 * @module @phone-dsh/dsh-shell-ext/bash-source
 */

import type { TransformContext, TransformPlugin, TransformResult } from 'just-bash'

/** Transform plugin name registered with `Bash.registerTransformPlugin`. */
export const BASH_SOURCE_PLUGIN = 'pdsh-bash-source'

/** Parameter spellings whose value is the current script file. */
const BASH_SOURCE_PARAMETERS: ReadonlySet<string> = new Set([
  'BASH_SOURCE',
  'BASH_SOURCE[0]',
  'BASH_SOURCE[@]',
  'BASH_SOURCE[*]',
])

/** Minimal structural view of the just-bash AST nodes this plugin edits. */
interface NodeLike {
  type: string
  parameter?: unknown
  operation?: unknown
  [key: string]: unknown
}

/**
 * Rewrite every operation-free `BASH_SOURCE` expansion in the tree to `$0`.
 *
 * The walk covers function bodies and command substitutions alike: both run
 * in the same script file, so GNU bash reports the same source path for them.
 * @param node - AST node, array or primitive to visit.
 */
function rewriteBashSource(node: unknown): void {
  if (Array.isArray(node)) {
    for (const item of node) rewriteBashSource(item)
    return
  }
  if (typeof node !== 'object' || node === null) return
  const typed = node as NodeLike
  if (
    typed.type === 'ParameterExpansion'
    && typeof typed.parameter === 'string'
    && BASH_SOURCE_PARAMETERS.has(typed.parameter)
    && (typed.operation === null || typed.operation === undefined)
  ) {
    // `$0` is provided by `positionalEnvironment`, including for the
    // path-form `./script.sh` dispatch and `bash script.sh`.
    typed.parameter = '0'
  }
  for (const key of Object.keys(typed)) {
    if (key === 'type' || key === 'parameter' || key === 'operation') continue
    rewriteBashSource((typed as Record<string, unknown>)[key])
  }
}

/**
 * Build the transform that resolves `BASH_SOURCE` for one file script.
 * @returns the plugin to register with `Bash.registerTransformPlugin`.
 */
export function createBashSourcePlugin(): TransformPlugin {
  return {
    name: BASH_SOURCE_PLUGIN,
    transform(context: TransformContext): TransformResult {
      rewriteBashSource(context.ast)
      return { ast: context.ast }
    },
  }
}

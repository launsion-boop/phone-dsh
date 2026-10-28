// SPDX-License-Identifier: MIT
/**
 * Locate the pinned DSH checkout at run time.
 *
 * The checkout path is machine-specific, so it is never written into the
 * repository: the tool reads `PDSH_DSH_CHECKOUT` and, when that is unset, the
 * single line in `$HOME/.config/phone-dsh/dsh-checkout`.
 *
 * @module tools/shell-corpus/checkout
 */

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** Package-relative path of the runtime sources inside the checkout. */
const RUNTIME_SOURCE = ['packages', 'experimental', 'webworker-runtime', 'src']

/**
 * Resolve the checkout directory.
 *
 * @param {NodeJS.ProcessEnv} [env] - environment to read (defaults to the process environment).
 * @returns {string} absolute checkout path.
 * @throws {Error} when neither the variable nor the per-machine file names a directory.
 */
export function resolveDshCheckout(env = process.env) {
  const configured = env.PDSH_DSH_CHECKOUT?.trim()
  if (configured !== undefined && configured !== '') return configured
  const home = env.HOME?.trim() || homedir()
  const configFile = join(home, '.config', 'xl', 'dsh-checkout')
  let configuredByFile
  try {
    configuredByFile = readFileSync(configFile, 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line !== '')
  } catch {
    configuredByFile = undefined
  }
  if (configuredByFile !== undefined) return configuredByFile
  throw new Error(
    `DSH checkout not found: set PDSH_DSH_CHECKOUT or write the checkout path to ${configFile}`,
  )
}

/**
 * Absolute path of the runtime's `src` directory inside a checkout.
 *
 * @param {string} checkout - checkout root.
 * @returns {string} runtime source root.
 */
export function runtimeSourceRoot(checkout) {
  return join(checkout, ...RUNTIME_SOURCE)
}

/**
 * Check that a directory looks like the pinned DSH checkout this runner needs.
 *
 * @param {string} checkout - candidate checkout root.
 * @returns {string} the runtime source root.
 * @throws {Error} when the shell interpreter source is absent.
 */
export function requireRuntimeSources(checkout) {
  const sourceRoot = runtimeSourceRoot(checkout)
  const interpreter = join(sourceRoot, 'shell', 'interpret.ts')
  if (!existsSync(interpreter)) {
    throw new Error(
      `DSH checkout at ${checkout} has no runtime shell sources (expected ${interpreter})`,
    )
  }
  return sourceRoot
}

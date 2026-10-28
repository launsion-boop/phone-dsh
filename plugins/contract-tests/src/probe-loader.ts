// SPDX-License-Identifier: MIT
/**
 * Load the probe bundle the contract CLI built for the current checkout.
 * @module @phone-dsh/dsh-contract-tests/probe-loader
 */
import { pathToFileURL } from 'node:url'
import type { ProbeModule } from './probe-types.ts'

let pending: Promise<ProbeModule> | undefined

/**
 * Import the bundled probe once per test file.
 * @returns the checkout-backed probe module.
 * @throws when the suite was not started through the contract CLI.
 */
export function loadProbe(): Promise<ProbeModule> {
  const file = process.env.PDSH_DSH_CONTRACT_PROBE
  if (file === undefined || file === '') {
    throw new Error('PDSH_DSH_CONTRACT_PROBE is unset; run the suite through `npm run contract`')
  }
  pending ??= import(pathToFileURL(file).href).then(module => module as ProbeModule)
  return pending
}

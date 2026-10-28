// SPDX-License-Identifier: MIT
/**
 * Read files from the checkout selected for this contract run.
 * @module @phone-dsh/dsh-contract-tests/checkout-file
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The checkout directory the CLI selected.
 * @returns the absolute directory from the test environment.
 * @throws when the suite was not started through the contract CLI.
 */
export function checkoutDirectory(): string {
  const directory = process.env.PDSH_DSH_CONTRACT_CHECKOUT
  if (directory === undefined || directory === '') {
    throw new Error('PDSH_DSH_CONTRACT_CHECKOUT is unset; run the suite through `npm run contract`')
  }
  return directory
}

/**
 * Read one checkout file as text.
 * @param relativePath - slash-separated path below the checkout root.
 * @returns the file contents.
 */
export function readCheckoutFile(relativePath: string): string {
  return readFileSync(join(checkoutDirectory(), relativePath), 'utf8')
}

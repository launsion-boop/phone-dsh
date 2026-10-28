// SPDX-License-Identifier: MIT
// Structural stub for native or process-spawning packages the phone runtime
// cannot load (node-pty, sharp, koffi, execa, libreoffice-kit). Importing is
// harmless; any call fails loudly with the package name.

const fail = (what) => () => {
  throw new Error(`${what} is not available in the phone bundle (no native addons, no child_process)`)
}

const handler = {
  get(_target, property) {
    if (property === 'then') return undefined
    if (property === '__esModule') return true
    return fail(`native module member ${String(property)}`)
  },
  apply() { return fail('native module')() },
  construct() { return fail('native module')() },
}

const unavailable = new Proxy(function unavailable() {}, handler)
export default unavailable
export const spawn = fail('node-pty spawn')
export const execa = fail('execa')
export const execaNode = fail('execa')
export const execaCommand = fail('execa')
export const load = fail('koffi load')

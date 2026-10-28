// SPDX-License-Identifier: MIT
// Replacement for the `node-addon-require-builtin` native addon. The bundled
// loader resolves plugins from a static table, so Node's internal module
// loader is never needed; callers fall back to their no-internals path.

export function requireBuiltin(id) {
  throw new Error(`node-addon-require-builtin is not available in the phone bundle (requested ${id})`)
}

export default { requireBuiltin }

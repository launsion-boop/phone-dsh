// SPDX-License-Identifier: MIT
/**
 * `node:module` wrapper for the Worker module proxy.
 *
 * The runtime's proxy answers `require.resolve.paths(specifier)` with `null`
 * for every static-module specifier, because that is how it models builtins.
 * DSH's compatibility preflight uses those paths to find a package's
 * `package.json`; a phone override served from the static table (for example
 * the Worker `workflow-ptc` engine) is a package with a real manifest in the
 * image, not a builtin. Returning the image `node_modules` root for a bare,
 * non-builtin specifier lets the preflight read that manifest instead of
 * disabling the row as unverifiable. Resolution and loading still come from
 * the runtime's own require; this wrapper changes only the metadata search
 * paths.
 * @module @phone-dsh/dsh-worker-entry/module-shim
 */
import { requireActiveModuleLoader, type WorkerRequire } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/module-system/module-loader.ts'
import { DEFAULT_ROOT } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/worker-host.ts'

/** The package directory lookup root of the mounted image. */
const IMAGE_MODULES = `${DEFAULT_ROOT.replace(/\/+$/u, '')}/node_modules`

/** Builtin names the Worker runtime proxies (mirrors the runtime's module table). */
export const builtinModules = [
  'assert', 'assert/strict', 'async_hooks', 'buffer', 'child_process', 'crypto', 'events', 'fs', 'http', 'module',
  'net', 'os', 'path', 'process', 'stream', 'tty', 'url', 'util', 'worker_threads',
]

/**
 * Whether a specifier names a proxied Node builtin.
 * @param specifier - module request, with or without the `node:` prefix.
 * @returns true for a builtin name.
 */
export function isBuiltin(specifier: string): boolean {
  return builtinModules.includes(specifier.replace(/^node:/, ''))
}

/**
 * The runtime proxy's `createRequire`, with package metadata search paths
 * widened for static image packages.
 * @param location - directory, file path, or file URL the resolution starts from.
 * @returns the runtime require face.
 */
export function createRequire(location: string | URL): WorkerRequire {
  const require = requireActiveModuleLoader().createRequire(location)
  const originalPaths = require.resolve.paths
  require.resolve.paths = (specifier: string): string[] | null => {
    const paths = originalPaths(specifier)
    if (paths !== null) return paths
    // Builtins have no package directory. A bare specifier served by the
    // static table may still be a real image package (the phone overrides).
    if (specifier.startsWith('node:') || !/^(?:@[^/]+\/)?[^/]+(?:\/|$)/u.test(specifier)) return null
    return [IMAGE_MODULES]
  }
  return require
}

/** Loader hooks have no meaning in the Worker. */
export function register(): never {
  throw new Error('web-preview: node:module.register is not available in the worker host')
}

/** TypeScript stripping has no Worker counterpart. */
export function stripTypeScriptTypes(): never {
  throw new Error('web-preview: node:module.stripTypeScriptTypes is not available in the worker host')
}

/** ESM/CJS export syncing is a no-op in the Worker loader. */
export function syncBuiltinESMExports(): void {
  // The Worker loader materializes CommonJS only; there is no ESM namespace to sync.
}

/** CommonJS interop marker. */
export const __esModule = true

/** Module namespace the Cordis loader and image code receive. */
export default {
  createRequire,
  builtinModules,
  isBuiltin,
  register,
  syncBuiltinESMExports,
  stripTypeScriptTypes,
}

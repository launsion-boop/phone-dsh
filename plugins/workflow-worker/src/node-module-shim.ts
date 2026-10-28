// SPDX-License-Identifier: MIT
/**
 * Minimal `node:module` face for the workflow isolate.
 *
 * Some bundled DSH modules call `createRequire(import.meta.url)('../package.json')`
 * only to read their package version (for an attribution header). A Web
 * Worker has no CommonJS resolver, so this shim answers that metadata read and
 * refuses every other request instead of silently returning a wrong module.
 * It is not a general Node `module` implementation and gives scripts no
 * module-loading capability: workflow code never receives this object.
 * @module @phone-dsh/dsh-workflow-worker/node-module-shim
 */

/** Version metadata the bundled attribution readers expect. */
const VERSION = { version: '0.2.1-rc.2' }

/** The package-json answer for the only supported metadata read. */
interface PackageMetadata {
  readonly version: string
}

/**
 * Create a resolver bound to one URL.
 * @param _url - ignored; the isolate has no filesystem resolver.
 * @returns a function that answers `../package.json` metadata reads.
 */
export function createRequire(_url?: string | URL): (id: string) => PackageMetadata {
  return (id: string) => {
    if (id.endsWith('package.json')) return VERSION
    throw new Error(`workflow isolate: module resolution is unavailable (${id})`)
  }
}

/** No builtin list is exposed to isolate modules. */
export const builtinModules: readonly string[] = Object.freeze([])

/** CommonJS interop marker. */
export const __esModule = true

export default { createRequire, builtinModules }

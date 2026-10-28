// SPDX-License-Identifier: MIT
/**
 * Module-resolution hook that gives the gzip regression probe the browser
 * Worker's stubbed `node:zlib` (see `zlib-unavailable.mjs`).
 */

/** Redirect every `node:zlib` import to the refusing stand-in module. */
export async function resolve(specifier, context, nextResolve) {
  if (specifier === 'node:zlib') {
    return { url: new URL('./zlib-unavailable.mjs', import.meta.url).href, shortCircuit: true }
  }
  return nextResolve(specifier, context)
}

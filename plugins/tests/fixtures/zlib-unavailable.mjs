// SPDX-License-Identifier: MIT
/**
 * The browser Worker's `node:zlib` for the gzip regression probe.
 *
 * The pinned DSH web Worker deliberately replaces the gzip family with
 * `notImplementedFail` stubs: every call logs the refusal and throws an
 * `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM` error. The loader in
 * `zlib-unavailable-hooks.mjs` maps `node:zlib` here so a Node test process
 * sees exactly that host. `constants` stays present because the shell's
 * dependency reads it at module load.
 */

/** The Zstandard/flush constants the Worker host publishes. */
export const constants = Object.freeze({
  Z_BEST_COMPRESSION: 9,
  Z_BEST_SPEED: 1,
  Z_DEFAULT_COMPRESSION: -1,
  Z_NO_FLUSH: 0,
  Z_SYNC_FLUSH: 2,
  Z_FINISH: 4,
})

/** Build the refusing stand-in for one gzip-family symbol. */
function notAvailable(symbol) {
  return function refuse() {
    const message = `web-preview: node:zlib.${symbol} is not available in the worker host`
    console.error(message)
    throw Object.assign(new Error(message), { code: 'ERR_FEATURE_UNAVAILABLE_ON_PLATFORM' })
  }
}

export const gzip = notAvailable('gzip')
export const gzipSync = notAvailable('gzipSync')
export const gunzip = notAvailable('gunzip')
export const gunzipSync = notAvailable('gunzipSync')

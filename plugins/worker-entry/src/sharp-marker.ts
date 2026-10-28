// SPDX-License-Identifier: MIT
/**
 * Identity marker for the Worker-side `sharp` shim.
 *
 * The Worker bundle and the packed image are built by different scripts, so
 * both assert the same marker: `worker-entry/build.mjs` checks it is present
 * in the emitted bundle (proving the shim is reachable from the entry graph)
 * and `scripts/pack-image.mjs` records it beside the image (proving the image
 * was packed against a runtime that still replaces `sharp`). Keep this module
 * dependency-free: build scripts import it directly under Node's type
 * stripping.
 * @module @phone-dsh/dsh-worker-entry/sharp-marker
 */

/** Stable marker string embedded in every Worker bundle that carries the shim. */
export const SHARP_SHIM_MARKER = 'pdsh-sharp-shim/1'

/** Package specifier the shim stands in for. */
export const SHARP_MODULE_SPECIFIER = 'sharp'

/** Worker-entry source that implements the shim. */
export const SHARP_SHIM_MODULE = 'worker-entry/src/sharp-shim.ts'

// SPDX-License-Identifier: MIT
/**
 * Bundle root for the Worker entry.
 *
 * The import order is the contract: the JavaScriptCore compatibility prelude
 * must be installed before any module of the entry graph evaluates, so this
 * root imports it first and only then re-exports the entry. `build.mjs` points
 * esbuild here, which makes the prelude the first code in `worker-entry.js`
 * regardless of what the entry's own import list looks like.
 * @module @phone-dsh/dsh-worker-entry/boot
 */
import './jsc-compat.ts'

export * from './entry.ts'

// SPDX-License-Identifier: MIT
/**
 * Per-stream byte budget shared by the shell's WASI engine commands.
 *
 * The shell's visible output cap (`boundOutput`) runs after a command has
 * already returned, so a guest that never stops writing must be bounded while
 * it streams. This module owns the safety ceiling and the collector used by
 * both the `jq` command (`jq.ts`) and the direct toolbox commands
 * (`toolbox-commands.ts`), so `jq-wasi`/`jaq` cannot bypass the jq path's
 * limit.
 * @module @phone-dsh/dsh-shell-ext/stream-budget
 */

import { DEFAULT_MAX_OUTPUT_BYTES, maxOutputBytesFromEnv } from './output.ts'

/**
 * Safety ceiling for one WASI engine output stream.
 *
 * The shell's display cap is the command result budget; keeping four times
 * that (never below the documented 256 KiB default) leaves room for the head
 * and tail the shell finally keeps while still bounding output no consumer
 * will ever see. It is a memory guard, not a second user-visible truncation
 * policy: the shell's `boundOutput` remains the display owner.
 * @param env - environment that may raise the shell output budget.
 * @returns the cap in bytes.
 */
export function engineStreamLimit(env: Readonly<Record<string, string | undefined>> = process.env): number {
  return Math.max(DEFAULT_MAX_OUTPUT_BYTES, maxOutputBytesFromEnv(env) * 4)
}

/**
 * Capture one output stream without retaining more than its ceiling.
 *
 * `produced` counts every byte the toolbox reported; only the first `limit`
 * bytes are stored. `push` returns true when the chunk crossed the cap so the
 * caller can abort the underlying dispatch.
 */
export class BoundedByteStream {
  readonly limit: number
  readonly chunks: Uint8Array[] = []
  produced = 0
  kept = 0
  truncated = false

  constructor(limit: number) {
    this.limit = Number.isFinite(limit) && limit >= 0 ? Math.floor(limit) : DEFAULT_MAX_OUTPUT_BYTES
  }

  push(chunk: Uint8Array): boolean {
    this.produced += chunk.byteLength
    const remaining = this.limit - this.kept
    if (remaining > 0) {
      const keep = Math.min(remaining, chunk.byteLength)
      this.chunks.push(Uint8Array.from(chunk.subarray(0, keep)))
      this.kept += keep
    }
    if (chunk.byteLength > remaining) this.truncated = true
    return this.truncated
  }
}

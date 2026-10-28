// SPDX-License-Identifier: MIT
/**
 * Output discipline for the Worker shell.
 *
 * A command's output is capped in bytes and kept from both ends: the head
 * carries the first lines a model needs to identify the result and the tail
 * carries the error line or final count. Dropping only the tail (the old
 * collector behaviour) loses exactly the part a failing command explains
 * itself with.
 * @module @phone-dsh/dsh-shell-ext/output
 */

import { decodeUtf8, encodeUtf8 } from './encoding.ts'

/** Default `max_output_bytes` per stream (256 KiB). */
export const DEFAULT_MAX_OUTPUT_BYTES = 256 * 1024

/** Share of the cap reserved for the head of a truncated stream. */
const HEAD_SHARE = 0.6

/**
 * The one truncation marker shared by the top-level output bound and a nested
 * toolbox collector. A marker is data, not a claim by the reader: it names the
 * exact number of bytes dropped and the exact stream size, so a viewer can tell
 * a complete page from a clipped one. Both numbers are produced by the code
 * that dropped the bytes, never by a later re-truncation of the marker text.
 * @param dropped - bytes omitted by the producer.
 * @param total - bytes the producer attempted to write.
 * @returns the marker text (including its surrounding newlines).
 */
export function truncationMarker(dropped: number, total: number): string {
  return `\n…[output truncated: ${String(dropped)} of ${String(total)} bytes elided]…\n`
}

/** The bytes one nested producer dropped from one stream. */
export interface StreamTruncation {
  /** Bytes the producer omitted from the visible stream. */
  readonly dropped: number
  /** UTF-8 bytes the producer's own marker occupies in that stream. */
  readonly markerBytes: number
}

/** Trusted truncation facts reported by producers inside one shell execution. */
export interface OutputAccounting {
  readonly stdout?: StreamTruncation
  readonly stderr?: StreamTruncation
}

/**
 * Symbol the patched engine and the toolbox/interpreter commands use to carry
 * producer-owned truncation facts alongside a command result.
 *
 * This is deliberately a symbol property on the result object, never text in
 * stdout/stderr and never an environment variable: a user command can print
 * any marker-looking text it likes, but it cannot attach this property. The
 * engine only forwards the property along the bytes that really reach the
 * final stream (live stdout/stderr, not a redirected file).
 */
export const OUTPUT_ACCOUNTING_SYMBOL: unique symbol = Symbol.for('@phone-dsh/just-bash/output-truncation/v1')

/** True for a non-negative safe integer. */
function byteCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

/** Validate one stream's producer facts. */
function streamTruncation(value: unknown): StreamTruncation | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const record = value as Record<string, unknown>
  if (!byteCount(record.dropped) || !byteCount(record.markerBytes)) return undefined
  if (record.dropped === 0 && record.markerBytes !== 0) return undefined
  return { dropped: record.dropped, markerBytes: record.markerBytes }
}

/**
 * Read the trusted truncation facts attached to one command result.
 * @param value - an engine/kernel result object.
 * @returns the validated accounting, or undefined when the producer attached none.
 */
export function readOutputAccounting(value: unknown): OutputAccounting | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const raw = (value as Record<symbol, unknown>)[OUTPUT_ACCOUNTING_SYMBOL]
  if (typeof raw !== 'object' || raw === null) return undefined
  const record = raw as Record<string, unknown>
  const stdout = streamTruncation(record.stdout)
  const stderr = streamTruncation(record.stderr)
  if (stdout === undefined && stderr === undefined) return undefined
  return {
    ...stdout === undefined ? {} : { stdout },
    ...stderr === undefined ? {} : { stderr },
  }
}

/** Merge two producers' facts for the same streams. */
export function mergeOutputAccounting(
  left: OutputAccounting | undefined,
  right: OutputAccounting | undefined,
): OutputAccounting | undefined {
  if (left === undefined) return right
  if (right === undefined) return left
  const merge = (
    a: StreamTruncation | undefined,
    b: StreamTruncation | undefined,
  ): StreamTruncation | undefined => {
    if (a === undefined) return b
    if (b === undefined) return a
    return { dropped: a.dropped + b.dropped, markerBytes: a.markerBytes + b.markerBytes }
  }
  const stdout = merge(left.stdout, right.stdout)
  const stderr = merge(left.stderr, right.stderr)
  return {
    ...stdout === undefined ? {} : { stdout },
    ...stderr === undefined ? {} : { stderr },
  }
}

/**
 * Attach producer-owned truncation facts to a command result.
 * @param result - a result object the engine may forward.
 * @param accounting - facts to attach, if any.
 * @returns the same result.
 */
export function withOutputAccounting<T extends object>(result: T, accounting: OutputAccounting | undefined): T {
  if (accounting === undefined) return result
  Object.defineProperty(result, OUTPUT_ACCOUNTING_SYMBOL, {
    value: accounting,
    enumerable: true,
    configurable: true,
    writable: false,
  })
  return result
}

/** One bounded stream. */
export interface BoundedOutput {
  /** The text handed to the caller. */
  readonly text: string
  /** True when bytes were dropped. */
  readonly truncated: boolean
  /** Bytes the command produced before truncation. */
  readonly originalBytes: number
  /** Bytes of the original text kept (head + tail, excluding the marker). */
  readonly keptBytes: number
}

/**
 * Truncate one stream to `maxBytes`, keeping the head and the tail.
 *
 * The marker names the number of dropped bytes so a reader can tell a short
 * result from a clipped one. Invalid UTF-8 created by cutting a multibyte
 * sequence at the head boundary is replaced by U+FFFD by the one shared
 * decoder ({@link decodeUtf8}); no Latin-1 fallback re-encodes the cut bytes.
 * @param text - the complete stream as text.
 * @param maxBytes - positive byte cap; non-finite or non-positive values use the default.
 * @returns the bounded stream.
 */
export function boundOutput(text: string, maxBytes = DEFAULT_MAX_OUTPUT_BYTES): BoundedOutput {
  const source = encodeUtf8(text)
  const limit = Number.isFinite(maxBytes) && maxBytes > 0 ? Math.floor(maxBytes) : DEFAULT_MAX_OUTPUT_BYTES
  if (source.byteLength <= limit) {
    return { text, truncated: false, originalBytes: source.byteLength, keptBytes: source.byteLength }
  }
  const headBytes = Math.max(1, Math.floor(limit * HEAD_SHARE))
  const tailBytes = Math.max(0, limit - headBytes)
  const head = source.subarray(0, headBytes)
  const tail = tailBytes === 0 ? source.subarray(source.byteLength) : source.subarray(source.byteLength - tailBytes)
  const dropped = source.byteLength - head.byteLength - tail.byteLength
  const marker = truncationMarker(dropped, source.byteLength)
  return {
    text: `${decodeUtf8(head)}${marker}${decodeUtf8(tail)}`,
    truncated: true,
    originalBytes: source.byteLength,
    keptBytes: head.byteLength + tail.byteLength,
  }
}

/** Parse a byte cap from the environment, falling back to the default. */
export function maxOutputBytesFromEnv(env: Readonly<Record<string, string | undefined>> = process.env): number {
  const raw = env.PDSH_SHELL_MAX_OUTPUT_BYTES
  if (raw === undefined || raw.trim() === '') return DEFAULT_MAX_OUTPUT_BYTES
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`PDSH_SHELL_MAX_OUTPUT_BYTES must be a positive number of bytes, got ${JSON.stringify(raw)}`)
  }
  return Math.floor(parsed)
}

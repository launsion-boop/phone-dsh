// SPDX-License-Identifier: MIT
/**
 * Cause classification for an aborted execution.
 *
 * The subprocess seam carries a caller-owned `AbortSignal`, never a timeout
 * value: `bash-local` fuses the caller's cancellation with its own deadline
 * into one signal and classifies the result from the abort reason afterwards
 * (`@deepseek-ai/dsh-timeout`'s `TimeoutReason`). Our job account needs the
 * same split — a deadline kill is a `timeout`, a tool-call abort is a `cancel`
 * — so the reason is read structurally instead of adding a dependency edge to
 * the pinned util package. This is a classification of an already-aborted
 * signal, never a re-implementation of the deadline itself.
 * @module @phone-dsh/dsh-subprocess-xl/signal
 */

/**
 * True when an abort reason came from a deadline timer.
 * @param reason - `AbortSignal.reason` of the aborted execution.
 */
export function isTimeoutReason(reason: unknown): boolean {
  if (reason === null || typeof reason !== 'object') return false
  const candidate = reason as { readonly name?: unknown; readonly code?: unknown }
  if (candidate.name === 'TimeoutReason') return true
  return typeof candidate.code === 'string' && /TIMEOUT/.test(candidate.code)
}

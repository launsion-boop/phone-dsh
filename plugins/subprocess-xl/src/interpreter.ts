// SPDX-License-Identifier: MIT
/**
 * External termination of the Worker's WASI interpreter dispatches
 * (G2-FIX-104).
 *
 * A `python3`/WASI command runs inside a warm tool worker (see
 * `@phone-dsh/dsh-wasi-toolbox`). When the interpreter blocks in a proxied
 * syscall, its JavaScript caller never returns, so the command-dispatch layer
 * cannot settle the job by awaiting the engine: the per-workspace execution
 * lane stays held and the deadline/drain settlement waits behind it. The
 * toolbox publishes its hard-stop face on a Worker global — the same
 * cross-package convention as `__PDSH_VFS_FLUSH__` and `__PDSH_CHANNEL__`, so
 * `subprocess-xl` needs no dependency edge on the toolbox package.
 *
 * {@link settleWorkerInterpreter} is called synchronously by the job owner's
 * hard terminator. It terminates every active dispatch, resolves their run
 * promises with a terminal timeout/drain result and marks their partial
 * writes, returning how many dispatches were actually cut off: a non-zero
 * count means the job can settle immediately instead of waiting for an engine
 * that will never return.
 * @module @phone-dsh/dsh-subprocess-xl/interpreter
 */

import type { WorkerJobSettleCause } from './jobs.ts'

/**
 * Name of the Worker global carrying the toolbox.
 *
 * Kept literally in sync with `worker-entry`'s source and the
 * `WORKER_TOOLBOX_GLOBAL` export of `@phone-dsh/dsh-wasi-toolbox`.
 */
export const WORKER_TOOLBOX_GLOBAL = '__PDSH_WASI_TOOLBOX__'

/** The settlement cause the toolbox understands. */
export const INTERPRETER_STOP_CAUSES = ['timeout', 'drain', 'cancel'] as const
export type InterpreterStopCause = typeof INTERPRETER_STOP_CAUSES[number]

/** Structural face of the toolbox's external settlement hook. */
interface WorkerToolboxSettlement {
  terminate?(cause: InterpreterStopCause): number
}

/** Map a job deletion cause onto the toolbox's cause vocabulary. */
export function interpreterStopCause(cause: WorkerJobSettleCause): InterpreterStopCause {
  if (cause === 'timeout') return 'timeout'
  if (cause === 'cancel') return 'cancel'
  // `drain`, `exit` and `failure` all mean "drop the interpreter now": the
  // engine already stopped or the host is taking the Worker away.
  return 'drain'
}

/**
 * Hard-terminate every active WASI dispatch in this Worker.
 *
 * Must never throw: the caller is the job owner's settlement path, and a
 * toolbox that is absent (no python in the image), disposed, or itself broken
 * cannot be allowed to keep the job account non-terminal.
 * @param cause - why the surrounding job is being cut off.
 * @returns the number of active dispatches that were hard-terminated.
 */
export function settleWorkerInterpreter(cause: WorkerJobSettleCause): number {
  const toolbox = (globalThis as Record<string, unknown>)[WORKER_TOOLBOX_GLOBAL] as
    | WorkerToolboxSettlement
    | undefined
  if (toolbox === undefined || typeof toolbox.terminate !== 'function') return 0
  try {
    const stopped = toolbox.terminate(interpreterStopCause(cause))
    return typeof stopped === 'number' && stopped > 0 ? stopped : 0
  } catch (error) {
    console.error('subprocess-xl: the WASI toolbox could not hard-terminate its dispatch', error)
    return 0
  }
}

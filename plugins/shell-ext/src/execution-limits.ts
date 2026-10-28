// SPDX-License-Identifier: MIT
/**
 * The Worker shell's execution ceilings: one owner for the numbers the shell
 * enforces and the capability manifest publishes.
 *
 * just-bash 3.6 defaults these to 100000 when `executionLimits` omits them.
 * That was not phone-dsh's decision and the model could not see it. The shell
 * now spreads {@link WORKER_EXECUTION_LIMITS} into every `Bash` instance and
 * the boot manifest renders the same constants, so the enforced value and the
 * self-report cannot drift.
 *
 * `awk`, `seq`, `for`/`while` and `sed` share these ceilings. A streaming
 * command that crosses one exits non-zero naming the limit; `WorkerShell`
 * attaches the `reason=iterations` contract trailer (G2-FIX-118).
 * @module @phone-dsh/dsh-shell-ext/execution-limits
 */

/** The shared per-command ceilings the Worker shell enforces. */
export interface WorkerExecutionLimits {
  /** Maximum commands executed by one shell invocation. */
  readonly maxCommandCount: number
  /** Maximum `for`/`while`/`until` loop iterations. */
  readonly maxLoopIterations: number
  /** Maximum iterations of an awk `for`/`while` loop. */
  readonly maxAwkIterations: number
  /** Maximum sed branch-loop iterations. */
  readonly maxSedIterations: number
}

/**
 * The frozen ceilings every `Bash` instance receives. The capability manifest
 * reads the same object, so the published numbers are the enforced numbers.
 */
export const WORKER_EXECUTION_LIMITS: WorkerExecutionLimits = Object.freeze({
  maxCommandCount: 100000,
  maxLoopIterations: 100000,
  maxAwkIterations: 100000,
  maxSedIterations: 100000,
})

/** One disclosed fact (same shape as the shell-corpus deviations, new ids). */
export interface WorkerExecutionLimitFact {
  readonly id: string
  readonly note: string
  readonly alternative: string
}

/**
 * The one-line disclosure the manifest renders. Ids are this layer's own; they
 * must not reuse or redefine the shell-corpus `JB-TRAP` / `JB-EPOCHSECONDS`
 * entries, which describe different engine deviations.
 */
export const WORKER_EXECUTION_LIMIT_FACT: WorkerExecutionLimitFact = Object.freeze({
  id: 'WORKER-EXECUTION-LIMITS',
  note: `per command <= ${String(WORKER_EXECUTION_LIMITS.maxCommandCount)} commands and `
    + `${String(WORKER_EXECUTION_LIMITS.maxLoopIterations)} loop / `
    + `${String(WORKER_EXECUTION_LIMITS.maxAwkIterations)} awk / `
    + `${String(WORKER_EXECUTION_LIMITS.maxSedIterations)} sed iterations`,
  alternative: 'streaming awk/seq/for/while/sed work over the limit exits non-zero as `reason=iterations`',
})

/**
 * Render {@link WORKER_EXECUTION_LIMIT_FACT} as the manifest's Limits line.
 * @returns one sentence with the enforced numbers.
 */
export function workerExecutionLimitsSentence(): string {
  return `${WORKER_EXECUTION_LIMIT_FACT.note}; ${WORKER_EXECUTION_LIMIT_FACT.alternative}.`
}

// SPDX-License-Identifier: MIT
/**
 * Stable diagnostic for a genuine guest synchronous/activity budget expiry.
 *
 * The official workflow runtime renders a thrown value by preferring
 * `error.stack`. JavaScriptCore's native stack is only a frame list
 * (`budgetError@<url>`), so it would replace the diagnostic with an engine
 * detail and lose the budget message. The workflow realm and the parent
 * backstop therefore share one controlled, engine-independent line and a
 * machine-routable code; guest errors that merely mention a budget or
 * `interrupted` never acquire it.
 * @module @phone-dsh/dsh-workflow-worker/budget-error
 */

/** Stable machine-routable code for a real synchronous-slice deadline. */
export const WORKFLOW_BUDGET_ERROR_CODE = 'WORKFLOW_SYNC_BUDGET' as const

/** Stable display/type name for a real synchronous-slice deadline. */
export const WORKFLOW_BUDGET_ERROR_NAME = 'WorkflowBudgetError' as const

/**
 * Render the human-readable budget failure without the typed prefix.
 * @param limitMs - the configured synchronous-slice budget.
 * @param suffix - optional terminator detail (`by the isolated realm`).
 * @returns the failure message.
 */
export function budgetMessage(limitMs: number, suffix?: string): string {
  return `workflow script exceeded its ${String(limitMs)}ms synchronous execution budget and was terminated`
    + (suffix === undefined ? '' : ` ${suffix}`)
}

/**
 * Render the complete engine-independent first line.
 * @param limitMs - the configured synchronous-slice budget.
 * @param suffix - optional terminator detail.
 * @returns `<name> [<code>]: <message>`.
 */
export function budgetDiagnostic(limitMs: number, suffix?: string): string {
  return `${WORKFLOW_BUDGET_ERROR_NAME} [${WORKFLOW_BUDGET_ERROR_CODE}]: ${budgetMessage(limitMs, suffix)}`
}

/** A real guest deadline, not an error that merely looks like one. */
export class WorkflowBudgetError extends Error {
  /** Stable machine-routable code, also present in {@link stack}. */
  readonly code = WORKFLOW_BUDGET_ERROR_CODE
  /** The configured synchronous-slice budget. */
  readonly limitMs: number

  /**
   * @param limitMs - the configured synchronous-slice budget.
   * @param suffix - optional terminator detail.
   */
  constructor(limitMs: number, suffix?: string) {
    super(budgetMessage(limitMs, suffix))
    this.name = WORKFLOW_BUDGET_ERROR_NAME
    this.limitMs = limitMs
    // Pin the rendered form. `Error.stack` is writable in both V8 and JSC, but
    // define it defensively so a lazily-installed accessor cannot keep the
    // engine's frame-only form.
    try {
      Object.defineProperty(this, 'stack', {
        value: budgetDiagnostic(limitMs, suffix),
        writable: true,
        configurable: true,
      })
    } catch {
      try {
        this.stack = budgetDiagnostic(limitMs, suffix)
      } catch {
        // A non-writable engine stack would keep its native form; the message
        // and code below still describe the failure.
      }
    }
  }
}

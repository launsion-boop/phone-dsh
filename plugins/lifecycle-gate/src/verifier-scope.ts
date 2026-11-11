// SPDX-License-Identifier: MIT
/**
 * Preset-scope isolation for the read-only verifier (`pdsh-verifier`).
 *
 * The shared mechanism lives in {@link ./restricted-session.ts}; this module
 * only binds the verifier policy to the preset row. On `agent/created` it
 * installs the policy's allow-list on the Agent's own scope, so every
 * inherited tool outside `read`/`grep`/`glob`/`bash` is hidden while the
 * preset's own contract tools stay visible. The execution rule is the same
 * function the global guard uses.
 */
import type { Context } from '@deepseek-ai/cordis'
import { VERIFIER_POLICY, applyRestrictedScope, restrictedGuardReason } from './restricted-session.ts'
import type { ToolExecution } from '@deepseek-ai/dsh-tools'

export const name = 'phone-verifier-isolation'
export const inject = ['tools']

export {
  VERIFIER_AGENT_PRESET,
  VERIFIER_POLICY,
  VERIFIER_SESSION_PREFIX,
  VERIFIER_TOOLS,
  isReadOnlyBashCommand,
} from './restricted-session.ts'

/** Backstop reason for one verifier tool call (same rule as the global guard). */
export function verifyGuardReason(execution: Readonly<ToolExecution>): string | undefined {
  return restrictedGuardReason(execution, VERIFIER_POLICY)
}

export function apply(ctx: Context): void {
  applyRestrictedScope(ctx, VERIFIER_POLICY)
}

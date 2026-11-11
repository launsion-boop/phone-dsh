// SPDX-License-Identifier: MIT
/**
 * Preset-scope isolation for the background memory maintainer
 * (`phone-bot-maintainer`).
 *
 * The shared mechanism lives in {@link ./restricted-session.ts}; this module
 * only binds the maintainer policy to the preset scope. `bash` is registered
 * by the preset before this row, and the memory tools arrive from the global
 * phone MCP client, so the allow-list restriction is installed on the first
 * `tools/change` that sees the complete frozen set.
 */
import type { Context } from '@deepseek-ai/cordis'
import { MAINTAINER_POLICY, applyRestrictedScope, restrictedGuardReason } from './restricted-session.ts'
import type { ToolExecution } from '@deepseek-ai/dsh-tools'

export const name = 'phone-memory-maintainer-scope'
export const inject = ['tools']

export {
  MAINTAINER_AGENT_PRESET,
  MAINTAINER_ALLOWED_TOOLS,
  MAINTAINER_POLICY,
  MAINTAINER_SESSION_PREFIX,
  maintainerBareToolName,
  maintainerBashAllowed,
  maintainerToolAllowed,
  maintainerVisibleAllowList,
} from './restricted-session.ts'

/** Backstop reason for one maintainer tool call (same rule as the global guard). */
export function maintainerGuardReason(execution: Readonly<ToolExecution>): string | undefined {
  return restrictedGuardReason(execution, MAINTAINER_POLICY)
}

export function apply(ctx: Context): void {
  applyRestrictedScope(ctx, MAINTAINER_POLICY)
}

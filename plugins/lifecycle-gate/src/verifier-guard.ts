// SPDX-License-Identifier: MIT
/**
 * Global fail-closed backstop for host-minted verifier sessions.
 *
 * The `pdsh-verifier` preset mounts {@link ./verifier-scope.ts} in its own
 * scope, which hides inherited globals and guards dispatch. This independent
 * row repeats the same rule keyed by the immutable creation header, so a
 * missed or later-changed preset scope still cannot give a verifier a write,
 * egress, message, Task or memory surface.
 */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'
import { verifyGuardReason } from './verifier-scope.ts'

export const name = 'phone-verifier-guard'
export const inject = ['tools']

export function apply(ctx: Context): void {
  ctx.tools.guard(exec => exec.agent?.session?.header?.agentPreset === 'pdsh-verifier'
    ? verifyGuardReason(exec)
    : undefined)
}

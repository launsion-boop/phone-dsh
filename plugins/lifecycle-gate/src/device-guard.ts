// SPDX-License-Identifier: MIT
/** Global fail-closed guard for sessions created for device-originated tasks. */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'

export const name = 'phone-device-task-guard'
export const inject = ['tools']

/** The immutable creation header survives a blank-session preset switch. */
export function apply(ctx: Context): void {
  ctx.tools.guard(exec => exec.agent?.session?.header?.agentPreset === 'pdsh-device-task'
    ? 'Device-originated task sessions have no tool access.'
    : undefined)
}

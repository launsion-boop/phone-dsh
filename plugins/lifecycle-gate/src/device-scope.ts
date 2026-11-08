// SPDX-License-Identifier: MIT
/** Agent-scope isolation for device-originated tasks. */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'

export const name = 'phone-device-task-isolation'
export const inject = ['tools']

/** Hide global tools and deny every scoped dispatch. */
export function apply(ctx: Context): void {
  ctx.tools.restrict({ allow: [] })
  ctx.tools.guard(() => 'Device-originated task sessions have no tool access.')
}

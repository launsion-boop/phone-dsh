// SPDX-License-Identifier: MIT
/**
 * Execution boundary for the memory maintainer (S3, spec/bot/v2 §4.1).
 *
 * The maintainer preset also installs `maintainer-scope`, but a session that
 * was created before that preset was selected (or resumed after an upgrade)
 * can keep running the user-facing surface. The host mints maintainer session
 * ids with a reserved prefix, so this one global row can deny every tool
 * outside the frozen memory + record surface regardless of the composed
 * preset. `tools.restrict` only shapes visibility; this guard is the hard
 * boundary.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-tools'
import {
  MAINTAINER_ALLOWED_TOOLS,
  MAINTAINER_SESSION_PREFIX,
  maintainerBareToolName,
  maintainerBashAllowed,
  maintainerToolAllowed,
} from './maintainer-scope.ts'

export const name = 'phone-memory-maintainer-guard'
export const inject = ['tools']

const DENIAL = 'Maintainer sessions may only read and write memory (and use bash for `phone record`).'
const BASH_DENIAL = 'Maintainer bash is limited to `phone record search` and `phone record read`.'

export function maintainerSessionId(agent: Agent | undefined): string {
  const subject = agent as (Agent & { session?: { id?: unknown } }) | undefined
  const sessionId = subject?.session?.id
  if (typeof sessionId === 'string') return sessionId
  return typeof subject?.id === 'string' ? subject.id : ''
}

export function isMaintainerSession(agent: Agent | undefined): boolean {
  return maintainerSessionId(agent).startsWith(MAINTAINER_SESSION_PREFIX)
}

export function maintainerToolAllowedForSession(
  agent: Agent | undefined,
  name: string,
): boolean {
  return isMaintainerSession(agent) && maintainerToolAllowed(name)
}

function bashCommand(argumentsValue: unknown): string {
  if (typeof argumentsValue !== 'object' || argumentsValue === null) return ''
  const command = (argumentsValue as { command?: unknown }).command
  return typeof command === 'string' ? command : ''
}

export function apply(ctx: Context): void {
  ctx.tools.guard(execution => {
    if (!isMaintainerSession(execution.agent)) return undefined
    if (!MAINTAINER_ALLOWED_TOOLS.has(maintainerBareToolName(execution.name))) return DENIAL
    if (maintainerBareToolName(execution.name) === 'bash'
        && !maintainerBashAllowed(bashCommand(execution.arguments))) {
      return BASH_DENIAL
    }
    return undefined
  })
}

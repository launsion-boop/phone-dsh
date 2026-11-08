// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { UserMessage } from '@deepseek-ai/dsh-session'
import { botHiddenSessions } from './runtime-registry.ts'

export function isHiddenPromptMessage(message: UserMessage): boolean {
  return message.content.some(block => block.type === 'text' && block.text.startsWith('[SAND_HIDDEN_PROMPT]'))
}

export function steerInsertedMessage(
  agent: Agent,
  message: UserMessage,
  rerouting: WeakSet<UserMessage>,
  hiddenSessions: ReadonlySet<string> = new Set(),
): boolean {
  const sessionId = String(agent.id || agent.session?.id || '')
  if (hiddenSessions.has(sessionId) || isHiddenPromptMessage(message)) return false
  if (agent.status !== 'running' || rerouting.has(message)) return false
  if (!agent.inbox.nextTurn.some(pending => pending.id === message.id)) return false
  let removed = false
  rerouting.add(message)
  try {
    removed = agent.inbox.remove(message.id)
    if (!removed) return false
    agent.steer(message)
    return true
  } catch (error) {
    if (removed) {
      try {
        agent.followup(message)
      } catch {}
    }
    const detail = error instanceof Error ? error.message : String(error)
    console.error(`[steering] could not steer ${message.id}: ${detail}`)
    return false
  } finally {
    rerouting.delete(message)
  }
}

export default function dshbotSteering(ctx: Context): void {
  const rerouting = new WeakSet<UserMessage>()
  const hiddenSessions = botHiddenSessions
  ctx.on('agent/inbox/inserted', ({ agent, message }) => {
    steerInsertedMessage(agent, message, rerouting, hiddenSessions)
  })
}

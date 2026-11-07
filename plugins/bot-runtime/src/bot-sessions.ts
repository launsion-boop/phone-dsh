// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'

/**
 * Bot sessions are minted into a reserved `gb-` namespace by the App's Bot
 * runtime, and that runtime claims every session it creates or recovers
 * through `phone/botClaimSession`. Ownership therefore never depends on the
 * Bot MCP catalog being reachable: a Bot session still fails closed for
 * `bash`/`write`/`edit` when the App's MCP tools/list is temporarily
 * unavailable, while a workbench session in the same Worker was never claimed
 * and keeps the ordinary DSH permission chain.
 */
export const BOT_SESSION_PREFIX = 'gb-'

export interface BotOwnedSessions {
  add(sessionId: string): void
  has(sessionId: string): boolean
}

export function isBotSessionId(sessionId: string): boolean {
  return sessionId.startsWith(BOT_SESSION_PREFIX)
}

export function createBotOwnedSessions(): BotOwnedSessions {
  const claimed = new Set<string>()
  return {
    add(sessionId: string): void {
      if (sessionId !== '') claimed.add(sessionId)
    },
    has(sessionId: string): boolean {
      return sessionId !== '' && (isBotSessionId(sessionId) || claimed.has(sessionId))
    },
  }
}

/** Shared Worker-side registry; the channel plugin claims, the gates read. */
export function botOwnedSessions(ctx: Context): BotOwnedSessions {
  const registered = ctx.get('dshbotOwnedSessions') as BotOwnedSessions | undefined
  if (registered !== undefined) return registered
  const created = createBotOwnedSessions()
  ctx.provide('dshbotOwnedSessions', created)
  return created
}

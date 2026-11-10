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
 *
 * The same claim carries the host-issued session token. It is kept only in
 * this Worker plugin's in-memory map; it is never an environment variable, a
 * file, an event, a log line or a URL parameter. A Worker restart creates a new
 * map, so a session has no credential until the App claims it again; identity
 * registration then omits the field and the host rejects it (fail closed).
 */
export const BOT_SESSION_PREFIX = 'gb-'

export interface BotOwnedSessions {
  /**
   * Marks a session as Bot-owned and remembers the host-issued session token.
   * A missing or empty token is never replaced with a fake value; a previous
   * non-empty token is kept until a new one is supplied.
   */
  add(sessionId: string, sessionToken?: string): void
  has(sessionId: string): boolean
  /** The in-memory session token for one claimed session, if any. */
  tokenFor(sessionId: string): string | undefined
}

export function isBotSessionId(sessionId: string): boolean {
  return sessionId.startsWith(BOT_SESSION_PREFIX)
}

export function createBotOwnedSessions(): BotOwnedSessions {
  const claimed = new Set<string>()
  const sessionTokens = new Map<string, string>()
  return {
    add(sessionId: string, sessionToken?: string): void {
      if (sessionId === '') return
      claimed.add(sessionId)
      if (typeof sessionToken === 'string' && sessionToken !== '') {
        sessionTokens.set(sessionId, sessionToken)
      }
    },
    has(sessionId: string): boolean {
      return sessionId !== '' && (isBotSessionId(sessionId) || claimed.has(sessionId))
    },
    tokenFor(sessionId: string): string | undefined {
      if (sessionId === '') return undefined
      return sessionTokens.get(sessionId)
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

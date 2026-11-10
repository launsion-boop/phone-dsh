// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { BotStreamFrame, BotStreamHub } from './channel.ts'
import { botHiddenSessions, botStreamHub } from './runtime-registry.ts'
import { turnOriginOfMessage } from './turn-origin.ts'

export const MAX_STREAM_ATTEMPTS = 512

interface StreamFrame {
  readonly type: 'start' | 'end' | 'chunk'
  readonly turn?: number
  readonly step?: number
  readonly attemptId?: string
  readonly index?: number
  readonly outcome?: { kind?: string; eventType?: string; seq?: number }
  readonly chunk?: { type?: string; text?: string }
}

interface AssistantStreamEvent {
  readonly agent?: Agent
  readonly frame?: StreamFrame
}

interface ToolExecution {
  readonly name: string
  readonly agent?: Agent
}

export interface StreamForwardConfig {
  readonly hub?: BotStreamHub
}

function isHiddenMessage(message: { readonly source?: unknown }): boolean {
  return turnOriginOfMessage(message).hidden
}

export default function dshbotStreamForward(ctx: Context, config: StreamForwardConfig = {}): void {
  const hub = config.hub ?? botStreamHub(ctx)
  if (!hub) throw new Error('[stream-forward] Bot channel is not mounted')
  const attempts = new Map<string, { turn: number | null; step: number | null }>()
  const suppressing = new Set<string>()
  const hidden = botHiddenSessions
  hidden.clear()

  const rememberAttempt = (attemptId: string, turn: number | null, step: number | null): void => {
    attempts.set(attemptId, { turn, step })
    if (attempts.size > MAX_STREAM_ATTEMPTS) attempts.delete(attempts.keys().next().value!)
  }

  ctx.on('agent/inbox/inserted', ({ agent, message }) => {
    const sessionId = String(agent.id || agent.session?.id || '')
    if (sessionId && isHiddenMessage(message)) hidden.add(sessionId)
  })

  ctx.on('tools/post-execute', async (exec: ToolExecution, _result: unknown, next: () => Promise<any>) => {
    const downstream = await next()
    const bare = exec.name.replace(/^mcp__[^_]+__/, '')
    const sessionId = String(exec.agent?.id ?? exec.agent?.session?.id ?? '')
    if (sessionId && (bare === 'ask_user' || bare === 'show_next_steps')) {
      const failed = downstream !== null && typeof downstream === 'object'
        && ((downstream as { isError?: boolean }).isError === true || (downstream as { kind?: string }).kind === 'block')
      if (!failed) suppressing.add(sessionId)
    }
    return downstream
  })

  const listener = ({ agent, frame }: AssistantStreamEvent): void => {
    try {
      const sessionId = String(agent?.session?.id ?? agent?.id ?? '')
      if (!sessionId || !frame) return
      const attemptId = String(frame.attemptId ?? '')
      if (frame.type === 'start') {
        const turn = Number.isFinite(Number(frame.turn)) ? Number(frame.turn) : null
        const step = Number.isFinite(Number(frame.step)) ? Number(frame.step) : null
        rememberAttempt(attemptId, turn, step)
        hub.publish({ v: 1, type: 'start', sessionId, turn, step, attemptId })
        return
      }
      if (frame.type === 'end') {
        const info = attempts.get(attemptId) ?? { turn: null, step: null }
        attempts.delete(attemptId)
        hub.publish({
          v: 1, type: 'end', sessionId, turn: info.turn, step: info.step, attemptId,
          outcome: frame.outcome?.kind ?? null,
          eventType: frame.outcome?.eventType ?? null,
          seq: Number.isFinite(Number(frame.outcome?.seq)) ? Number(frame.outcome?.seq) : null,
        })
        return
      }
      if (frame.type !== 'chunk' || frame.chunk?.type !== 'text-delta' || !frame.chunk.text) return
      if (suppressing.has(sessionId) || hidden.has(sessionId)) return
      const info = attempts.get(attemptId) ?? { turn: null, step: null }
      hub.publish({
        v: 1, type: 'text', sessionId, turn: info.turn, step: info.step, attemptId,
        index: Number.isFinite(Number(frame.index)) ? Number(frame.index) : null,
        text: frame.chunk.text,
      })
    } catch {}
  }
  ctx.on('agent/assistant-stream', listener, { global: true })
  ctx.on('session/event', (session, event) => {
    if (event.type !== 'turn/end') return
    const sessionId = String(session.id ?? '')
    if (!sessionId) return
    suppressing.delete(sessionId)
    hidden.delete(sessionId)
  }, { global: true })
}

dshbotStreamForward.inject = ['dshbotStreamHub']

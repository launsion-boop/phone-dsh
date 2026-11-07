// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import { SessionId } from '@deepseek-ai/dsh-session'
import { botOwnedSessions } from './bot-sessions.ts'
import { registerBotStreamHub } from './runtime-registry.ts'

class AsyncQueue<T> {
  private readonly values: T[] = []
  private readonly waiters: ((result: { done: boolean; value?: T }) => void)[] = []
  private ended = false

  push(value: T): void {
    if (this.ended) return
    const waiter = this.waiters.shift()
    if (waiter) waiter({ done: false, value })
    else this.values.push(value)
  }

  end(): void {
    if (this.ended) return
    this.ended = true
    for (const waiter of this.waiters.splice(0)) waiter({ done: true })
  }

  async next(): Promise<{ done: boolean; value?: T }> {
    const value = this.values.shift()
    if (value !== undefined) return { done: false, value }
    if (this.ended) return { done: true }
    return new Promise(resolve => { this.waiters.push(resolve) })
  }
}

export interface BotStreamFrame {
  readonly v: 1
  readonly type: 'start' | 'text' | 'end'
  readonly sessionId: string
  readonly turn: number | null
  readonly step: number | null
  readonly attemptId: string
  readonly index?: number | null
  readonly text?: string
  readonly outcome?: string | null
  readonly eventType?: string | null
  readonly seq?: number | null
}

export interface BotCancelRequest {
  readonly sessionId: string
}

export interface BotStreamRequest {
  readonly sessionId: string
}

export interface BotClaimSessionRequest {
  readonly sessionId: string
}

export class BotStreamHub {
  private readonly subscribers = new Map<string, Set<AsyncQueue<BotStreamFrame>>>()
  private closed = false

  publish(frame: BotStreamFrame): boolean {
    if (this.closed || frame.sessionId === '') return false
    const queues = this.subscribers.get(frame.sessionId)
    if (!queues || queues.size === 0) return false
    for (const queue of queues) queue.push(frame)
    return true
  }

  subscribe(sessionId: string): AsyncIterable<BotStreamFrame> {
    if (this.closed || sessionId === '') throw new Error('stream channel is closed')
    const queue = new AsyncQueue<BotStreamFrame>()
    const queues = this.subscribers.get(sessionId) ?? new Set<AsyncQueue<BotStreamFrame>>()
    if (queues.size >= 16) {
      const oldest = queues.values().next().value as AsyncQueue<BotStreamFrame>
      oldest.end()
      queues.delete(oldest)
    }
    queues.add(queue)
    this.subscribers.set(sessionId, queues)
    const hub = this
    return (async function* () {
      try {
        while (true) {
          const next = await queue.next()
          if (next.done) return
          if (next.value !== undefined) yield next.value
        }
      } finally {
        queues.delete(queue)
        if (queues.size === 0) hub.subscribers.delete(sessionId)
      }
    })()
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    for (const queues of this.subscribers.values()) {
      for (const queue of queues) queue.end()
    }
    this.subscribers.clear()
  }
}

export class BotRuntimeRemote extends TypertRemoteService {
  static inject = ['typert', 'agents']
  readonly hub: BotStreamHub

  constructor(ctx: Context, hub: BotStreamHub) {
    super(ctx, 'botRuntimeRemote', { namespace: 'phone' })
    this.hub = hub
    ctx.effect(() => () => hub.close(), 'Bot stream channel')
  }

  botStream(request: BotStreamRequest): AsyncIterable<BotStreamFrame> {
    return this.hub.subscribe(request.sessionId)
  }

  botCancel(request: BotCancelRequest): { ok: boolean; sessionId: string; reason?: string } {
    const sessionId = String(request.sessionId ?? '')
    if (!sessionId) return { ok: false, sessionId, reason: 'invalid-session' }
    const agent = this.ctx.agents.get(SessionId(sessionId))
    if (!agent) return { ok: false, sessionId, reason: 'missing-agent' }
    agent.cancel({ kind: 'user' }, { keepInbox: true })
    return { ok: true, sessionId }
  }

  /**
   * Claims an existing session as Bot-owned before its first turn. This is the
   * non-MCP path the Bot runtime uses for the deterministic main session and
   * for legacy/recovered session ids that predate the `gb-` namespace; the
   * identity and approval gates read the same Worker-local registry.
   */
  botClaimSession(request: BotClaimSessionRequest): { ok: boolean; sessionId: string } {
    const sessionId = String(request?.sessionId ?? '')
    if (!sessionId) return { ok: false, sessionId }
    botOwnedSessions(this.ctx).add(sessionId)
    return { ok: true, sessionId }
  }
}

function markRemoteMethod(name: 'botStream' | 'botCancel' | 'botClaimSession'): void {
  const descriptor = Object.getOwnPropertyDescriptor(BotRuntimeRemote.prototype, name)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`Bot Remote method is missing: ${name}`)
  let initializer: ((this: BotRuntimeRemote) => void) | undefined
  const context = {
    name,
    private: false,
    static: false,
    addInitializer(fn: (this: BotRuntimeRemote) => void) { initializer = fn },
  } as ClassMethodDecoratorContext<BotRuntimeRemote, (this: BotRuntimeRemote, ...args: unknown[]) => unknown>
  Remote(descriptor.value as never, context as never)
  if (initializer === undefined) throw new TypeError(`Bot Remote decorator did not initialize: ${name}`)
  initializer.call(Object.create(BotRuntimeRemote.prototype) as BotRuntimeRemote)
}

markRemoteMethod('botStream')
markRemoteMethod('botCancel')
markRemoteMethod('botClaimSession')

export async function dshbotChannel(ctx: Context): Promise<void> {
  const hub = new BotStreamHub()
  registerBotStreamHub(ctx, hub)
  await ctx.plugin(BotRuntimeRemote, hub)
}

dshbotChannel.inject = ['typert', 'agents']

export default dshbotChannel

// SPDX-License-Identifier: MIT
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import type { Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { createUserMessage, LlmAdapter } from '@deepseek-ai/dsh-llm'
import type { GenerateOptions, LlmResolvedModelInfo, StreamChunk } from '@deepseek-ai/dsh-llm'
import LlmRuntime from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'

export type ScriptEntry = StreamChunk[] | 'hang'

export class ScriptAdapter extends LlmAdapter {
  readonly requests: GenerateOptions[] = []
  readonly aborts: unknown[] = []
  hanging = 0
  private readonly waiters: { count: number; resolve: () => void }[] = []
  private readonly hangWaiters: { count: number; resolve: () => void }[] = []
  private readonly script: ScriptEntry[]

  constructor(script: ScriptEntry[]) {
    super()
    this.script = script
  }

  override resolveModel(provider: string, model: string): Promise<LlmResolvedModelInfo> {
    return Promise.resolve({ provider, id: model, name: model })
  }

  waitForRequests(count: number): Promise<void> {
    if (this.requests.length >= count) return Promise.resolve()
    return new Promise(resolve => { this.waiters.push({ count, resolve }) })
  }

  waitForHanging(count: number): Promise<void> {
    if (this.hanging >= count) return Promise.resolve()
    return new Promise(resolve => { this.hangWaiters.push({ count, resolve }) })
  }

  async *stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    this.requests.push(options)
    for (const waiter of this.waiters.splice(0)) {
      if (this.requests.length >= waiter.count) waiter.resolve()
      else this.waiters.push(waiter)
    }
    const entry = this.script.shift()
    if (entry === undefined) throw new Error('ScriptAdapter: script exhausted')
    if (entry === 'hang') {
      yield { type: 'block-start', index: 0, blockType: 'text' }
      yield { type: 'text-delta', index: 0, text: 'partial' }
      await new Promise<void>((_resolve, reject) => {
        const abort = (): void => {
          this.aborts.push(options.signal?.reason)
          reject(new Error('aborted'))
        }
        if (options.signal?.aborted) {
          abort()
          return
        }
        options.signal?.addEventListener('abort', abort, { once: true })
        this.hanging += 1
        for (const waiter of this.hangWaiters.splice(0)) {
          if (this.hanging >= waiter.count) waiter.resolve()
          else this.hangWaiters.push(waiter)
        }
      })
      return
    }
    for (const chunk of entry) {
      if (options.signal?.aborted) throw new Error('aborted')
      yield chunk
    }
  }
}

export function textResponse(text: string): StreamChunk[] {
  return [
    { type: 'block-start', index: 0, blockType: 'text' },
    { type: 'text-delta', index: 0, text },
    { type: 'block-end', index: 0, block: { type: 'text', text } },
    { type: 'usage', usage: { inputTokens: 1, outputTokens: 1 } },
    { type: 'finish', reason: { kind: 'stop' } },
  ]
}

export function userMessage(text: string) {
  return createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })
}

export async function mountRuntime(): Promise<Context> {
  const ctx = new Context()
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(AgentRegistry)
  return ctx
}

export async function createAgent(ctx: Context, id: string): Promise<Agent> {
  if (ctx.get('agentLoop') === undefined) await ctx.plugin(AgentLoop, { agents: [] })
  return ctx.agentLoop.create(SessionId(id), { provider: 'mock', model: 'mock' })
}

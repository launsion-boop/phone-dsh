// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import dshbotVolatileContext from '../bot-runtime/src/volatile-context.ts'
import {
  BOT_VOLATILE_CONTEXT_TOOL,
  validateVolatileContextResponse,
  VOLATILE_TOTAL_TEXT_LIMIT,
} from '../bot-runtime/src/volatile-mcp.ts'

interface MutableResponse {
  schemaVersion: unknown
  sessionId: unknown
  revision: unknown
  blocks?: Record<string, unknown>
}

interface Golden {
  valid: {
    request: { sessionId: string }
    response: MutableResponse & { blocks: Record<string, unknown> }
  }
  invalid: {
    request?: { sessionId: string }
    error?: { isError: boolean; message: string }
    reason: string
  }[]
}

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const golden = JSON.parse(readFileSync(
  join(repository, 'spec/bot/v1/golden/volatile-context.json'), 'utf8',
)) as Golden
const contract = JSON.parse(readFileSync(
  join(repository, 'spec/bot/v1/volatile-context.schema.json'), 'utf8',
)) as { properties: { request: Record<string, unknown>; response: unknown } }

function response(): MutableResponse {
  return structuredClone(golden.valid.response)
}

function invalid(reason: string): Golden['invalid'][number] {
  const entry = golden.invalid.find(candidate => candidate.reason === reason)
  assert.ok(entry !== undefined, `missing shared invalid vector ${reason}`)
  return entry
}

function agent(id: string): Agent {
  return { id, session: { id } } as unknown as Agent
}

async function mountConsumer(): Promise<Context> {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(NativeToolExecutor)
  return ctx
}

function registerVolatileTool(
  ctx: Context,
  handler: (args: Record<string, unknown>) => unknown,
): void {
  ctx.tools.register(createMcpToolDefinition(ctx, {
    name: BOT_VOLATILE_CONTEXT_TOOL,
    rawName: 'BotVolatileContext',
    description: 'Return the current Bot volatile context snapshot.',
    inputSchema: contract.properties.request,
    outputSchema: contract.properties.response,
    call: async args => handler(args),
  }))
}

async function mountPlugin(ctx: Context): Promise<void> {
  await ctx.plugin(dshbotVolatileContext, {
    now: () => new Date('2026-11-06T08:09:59.900Z'),
    lang: () => 'en' as const,
  })
}

async function assemble(ctx: Context, subject: Agent, signal?: AbortSignal) {
  return ctx.systemPrompt.assemble({
    agent: subject,
    scope: subject,
    ...signal === undefined ? {} : { signal },
  })
}

function volatileText(assembly: Awaited<ReturnType<typeof assemble>>): string {
  return assembly.contexts.find(entry => entry.name === 'dshbot:volatile')?.text ?? ''
}

test('the real consumer reads the shared valid golden through the phone MCP discovery name', async () => {
  const ctx = await mountConsumer()
  const calls: Record<string, unknown>[] = []
  try {
    registerVolatileTool(ctx, args => {
      calls.push(args)
      return { content: [], structuredContent: response() }
    })
    await mountPlugin(ctx)
    const text = volatileText(await assemble(ctx, agent(golden.valid.request.sessionId)))
    assert.deepEqual(calls, [golden.valid.request])

    const blocks = golden.valid.response.blocks
    const markers = [blocks.variant, '## Time', blocks.persona, blocks.memory, blocks.automation]
      .map(value => String(value))
    const positions = markers.map(marker => text.indexOf(marker))
    assert.ok(positions.every((position, index) => position >= 0
      && (index === 0 || position > positions[index - 1]!)))
    for (const name of ['variant', 'persona', 'memory', 'automation']) {
      assert.ok(text.includes(String(blocks[name])), `${name} from the shared golden is injected`)
    }
  } finally {
    await ctx.fiber.dispose()
  }
})

test('shared invalid golden cases deny empty/cross-session reads and MCP errors without stale memory', async () => {
  const ctx = await mountConsumer()
  const calls: Record<string, unknown>[] = []
  let mode: 'success' | 'error' = 'success'
  try {
    registerVolatileTool(ctx, args => {
      calls.push(args)
      if (mode === 'error') {
        return {
          isError: true,
          content: [{ type: 'text', text: invalid('no_partial_or_stale_snapshot').error!.message }],
        }
      }
      return { content: [], structuredContent: response() }
    })
    await mountPlugin(ctx)
    const main = agent(golden.valid.request.sessionId)
    assert.match(volatileText(await assemble(ctx, main)), /我喜欢简短回答/)

    const empty = invalid('empty_session_id')
    const emptyText = volatileText(await assemble(ctx, agent(empty.request!.sessionId)))
    assert.doesNotMatch(emptyText, /我喜欢简短回答/)
    assert.equal(calls.length, 1, 'an empty session never reaches the MCP tool')

    const cross = invalid('cross_session_read_denied')
    const crossText = volatileText(await assemble(ctx, agent(cross.request!.sessionId)))
    assert.doesNotMatch(crossText, /我喜欢简短回答/)
    assert.deepEqual(calls.at(-1), cross.request)

    mode = 'error'
    const failed = volatileText(await assemble(ctx, main))
    assert.doesNotMatch(failed, /我喜欢简短回答|variant|大肥鱼/)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('transport failures and invalid MCP responses clear a previously accepted snapshot', async () => {
  const ctx = await mountConsumer()
  const subject = agent(golden.valid.request.sessionId)
  let mode: 'success' | 'throw' | 'invalid' = 'success'
  try {
    registerVolatileTool(ctx, () => {
      if (mode === 'throw') throw new Error('transport unavailable')
      if (mode === 'invalid') {
        return {
          content: [],
          structuredContent: { ...response(), unexpected: 'partial data must not escape' },
        }
      }
      return { content: [], structuredContent: response() }
    })
    await mountPlugin(ctx)
    assert.match(volatileText(await assemble(ctx, subject)), /我喜欢简短回答/)

    mode = 'throw'
    assert.doesNotMatch(volatileText(await assemble(ctx, subject)), /我喜欢简短回答/)

    mode = 'success'
    assert.match(volatileText(await assemble(ctx, subject)), /我喜欢简短回答/)
    mode = 'invalid'
    const invalidText = volatileText(await assemble(ctx, subject))
    assert.doesNotMatch(invalidText, /我喜欢简短回答|partial data must not escape/)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('response validation enforces the schema, session, block and total limits', () => {
  const sessionId = golden.valid.request.sessionId
  assert.deepEqual(validateVolatileContextResponse(response(), sessionId), golden.valid.response.blocks)
  assert.deepEqual(validateVolatileContextResponse([], sessionId), undefined)
  assert.deepEqual(validateVolatileContextResponse(response(), 'x'.repeat(201)), undefined)

  const cases: { name: string; mutate: (candidate: MutableResponse) => void }[] = [
    { name: 'schemaVersion', mutate: candidate => { candidate.schemaVersion = 2 } },
    { name: 'session', mutate: candidate => { candidate.sessionId = 'gb-other' } },
    { name: 'zero revision', mutate: candidate => { candidate.revision = 0 } },
    { name: 'fractional revision', mutate: candidate => { candidate.revision = 1.5 } },
    { name: 'missing blocks', mutate: candidate => { delete candidate.blocks } },
    { name: 'extra response member', mutate: candidate => { Object.assign(candidate, { extra: true }) } },
    { name: 'extra block', mutate: candidate => { candidate.blocks!.extra = 'x' } },
    { name: 'non-string block', mutate: candidate => { candidate.blocks!.memory = 1 } },
    { name: 'variant limit', mutate: candidate => { candidate.blocks!.variant = 'v'.repeat(12_001) } },
    { name: 'persona limit', mutate: candidate => { candidate.blocks!.persona = 'p'.repeat(12_001) } },
    { name: 'memory limit', mutate: candidate => { candidate.blocks!.memory = 'm'.repeat(4_001) } },
    { name: 'automation limit', mutate: candidate => { candidate.blocks!.automation = 'a'.repeat(4_001) } },
    {
      name: 'total limit',
      mutate: candidate => {
        candidate.blocks = { variant: 'v'.repeat(12_000), persona: 'p'.repeat(12_000), memory: 'm' }
        assert.equal(12_000 + 12_000 + 1, VOLATILE_TOTAL_TEXT_LIMIT + 1)
      },
    },
  ]
  for (const { name, mutate } of cases) {
    const candidate = response()
    mutate(candidate)
    assert.deepEqual(validateVolatileContextResponse(candidate, sessionId), undefined, name)
  }

  const empty = response()
  empty.blocks = {}
  assert.deepEqual(validateVolatileContextResponse(empty, sessionId), {})

  const unicodeSession = '😀'.repeat(200)
  const unicodeResponse = response()
  unicodeResponse.sessionId = unicodeSession
  assert.ok(validateVolatileContextResponse(unicodeResponse, unicodeSession) !== undefined)
  assert.deepEqual(validateVolatileContextResponse(unicodeResponse, '😀'.repeat(201)), undefined)
})

test('late, aborted and transport-failed MCP calls cannot overwrite or retain stale memory', async () => {
  const ctx = await mountConsumer()
  const subject = agent(golden.valid.request.sessionId)
  let calls = 0
  let markFirstStarted: () => void = () => {}
  let releaseFirst: (value: unknown) => void = () => {}
  let markThirdStarted: () => void = () => {}
  let releaseThird: (value: unknown) => void = () => {}
  const firstStarted = new Promise<void>(resolve => { markFirstStarted = resolve })
  const thirdStarted = new Promise<void>(resolve => { markThirdStarted = resolve })
  const successful = (memory: string, revision: number) => ({
    content: [],
    structuredContent: { ...response(), revision, blocks: { memory } },
  })

  try {
    registerVolatileTool(ctx, () => {
      calls += 1
      if (calls === 1) {
        return new Promise(resolve => {
          releaseFirst = resolve
          markFirstStarted()
        })
      }
      if (calls === 2) return successful('fresh-memory', 4)
      if (calls === 3) {
        return new Promise(resolve => {
          releaseThird = resolve
          markThirdStarted()
        })
      }
      throw new Error('transport failed')
    })
    await mountPlugin(ctx)

    const slowAssembly = assemble(ctx, subject)
    await firstStarted
    const fresh = volatileText(await assemble(ctx, subject))
    releaseFirst(successful('late-memory', 3))
    const slow = volatileText(await slowAssembly)
    for (const text of [fresh, slow]) {
      assert.match(text, /fresh-memory/)
      assert.doesNotMatch(text, /late-memory/)
    }

    const controller = new AbortController()
    const abortedAssembly = assemble(ctx, subject, controller.signal)
    await thirdStarted
    controller.abort({ kind: 'user' })
    releaseThird(successful('aborted-memory', 5))
    const aborted = volatileText(await abortedAssembly)
    assert.doesNotMatch(aborted, /fresh-memory|aborted-memory/)

    const failed = volatileText(await assemble(ctx, subject))
    assert.doesNotMatch(failed, /fresh-memory|aborted-memory/)
  } finally {
    await ctx.fiber.dispose()
  }
})

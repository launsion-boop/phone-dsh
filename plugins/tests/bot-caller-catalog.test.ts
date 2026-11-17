// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotIdentityBridge from '../bot-runtime/src/identity-bridge.ts'
import {
  CALLER_SESSION_HEADER,
  createCallerCatalogRequest,
  parseCallerCatalogResponse,
  planCallerCatalog,
} from '../bot-runtime/src/caller-catalog.ts'
import type { CallerCatalog } from '../bot-runtime/src/caller-catalog.ts'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { createAgent, mountRuntime } from './bot-runtime-test-kit.ts'

async function assembleFor(ctx: Context, agent: Agent) {
  const toolSet = await ctx.tools.resolve({
    agent,
    modelSelection: { provider: 'mock', model: 'mock' },
    signal: new AbortController().signal,
  })
  try {
    return await ctx.systemPrompt.assemble({ scope: agent, agent, toolSet })
  } finally {
    toolSet.dispose()
  }
}

function registerProbe(ctx: Context, name: string, description: string): void {
  ctx.tools.register(defineTool({
    name,
    description,
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => 'ok',
  }))
}

function registerTeamProbes(ctx: Context): void {
  registerProbe(ctx, 'mcp__phone__SendToAgent', 'static send')
  registerProbe(ctx, 'mcp__phone__CreateTeammate', 'static create')
  registerProbe(ctx, 'mcp__phone__ListRoutines', 'static routines')
}

const nonMainCatalog: CallerCatalog = {
  tools: [
    {
      name: 'SendToAgent',
      description: 'send\nAvailable bots: Alpha (id: bot-a, main Bot); Xray (id: bot-x).',
    },
    { name: 'FishAction', description: 'fish' },
  ],
}

const mainCatalog: CallerCatalog = {
  tools: [
    {
      name: 'SendToAgent',
      description: 'send\nAvailable bots: Bee (id: bot-b); Xray (id: bot-x).',
    },
    {
      name: 'CreateTeammate',
      description: 'create\nAvailable bots: Bee (id: bot-b); Xray (id: bot-x).',
    },
  ],
}

test('only a catalog with the roster marker is treated as identified', () => {
  assert.equal(planCallerCatalog(undefined), undefined)
  assert.equal(planCallerCatalog({
    tools: [
      { name: 'SendToAgent', description: 'static send' },
      { name: 'CreateTeammate', description: 'static create' },
    ],
  }), undefined)

  assert.deepEqual(planCallerCatalog(nonMainCatalog), {
    descriptions: {
      SendToAgent: nonMainCatalog.tools[0]?.description,
    },
    includeCreateTeammate: false,
    deviceAppTools: [],
  })
  assert.deepEqual(planCallerCatalog(mainCatalog), {
    descriptions: {
      SendToAgent: mainCatalog.tools[0]?.description,
      CreateTeammate: mainCatalog.tools[1]?.description,
    },
    includeCreateTeammate: true,
    deviceAppTools: [],
  })
})

test('the per-session catalog request carries the App session and parses tools/list', async () => {
  const calls: { url: string; init: RequestInit }[] = []
  const request = createCallerCatalogRequest({
    url: 'http://127.0.0.1:9/mcp',
    token: 'placeholder',
    fetch: (async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), init: init ?? {} })
      return {
        ok: true,
        async json() {
          return { jsonrpc: '2.0', id: 'dshbot-tools-list', result: { tools: nonMainCatalog.tools } }
        },
      } as unknown as Response
    }) as typeof fetch,
  })
  const catalog = await request('gb-bot-b', { timeoutMs: 1_000 })
  assert.deepEqual(catalog, nonMainCatalog)
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.url, 'http://127.0.0.1:9/mcp')
  const headers = new Headers(calls[0]?.init.headers)
  assert.equal(headers.get(CALLER_SESSION_HEADER), 'gb-bot-b')
  assert.equal(headers.get('authorization'), 'Bearer placeholder')
  assert.deepEqual(JSON.parse(String(calls[0]?.init.body)), {
    jsonrpc: '2.0', id: 'dshbot-tools-list', method: 'tools/list', params: {},
  })

  assert.equal(parseCallerCatalogResponse({ result: {} }), undefined)
  const parsed = parseCallerCatalogResponse({
    result: { tools: [{ name: 'SendToAgent', description: 'ok' }, { name: 'bad' }] },
  })
  assert.deepEqual(parsed, { tools: [{ name: 'SendToAgent', description: 'ok' }] })
})

test('the catalog request carries the host egress credential only when configured', async () => {
  const previous = process.env.PDSH_MCP_EGRESS_TOKEN
  const calls: { headers: Headers }[] = []
  const request = createCallerCatalogRequest({
    url: 'http://127.0.0.1:9/mcp',
    token: 'placeholder',
    fetch: (async (_url: string | URL | Request, init?: RequestInit) => {
      calls.push({ headers: new Headers(init?.headers) })
      return {
        ok: true,
        async json() { return { result: { tools: [] } } },
      } as unknown as Response
    }) as typeof fetch,
  })
  try {
    process.env.PDSH_MCP_EGRESS_TOKEN = 'caller-catalog-fixture-egress'
    await request('gb-bot-b', { timeoutMs: 1_000 })
    assert.equal(calls[0]?.headers.get('x-pdsh-mcp-egress'),
      'caller-catalog-fixture-egress', 'the trusted catalog client sends the egress credential')

    process.env.PDSH_MCP_EGRESS_TOKEN = ''
    await request('gb-bot-b', { timeoutMs: 1_000 })
    assert.equal(calls[1]?.headers.get('x-pdsh-mcp-egress'), null,
      'an empty environment value omits the header and fails closed at the host')

    delete process.env.PDSH_MCP_EGRESS_TOKEN
    await request('gb-bot-b', { timeoutMs: 1_000 })
    assert.equal(calls[2]?.headers.get('x-pdsh-mcp-egress'), null,
      'a missing environment value omits the header and fails closed at the host')
  } finally {
    if (previous === undefined) delete process.env.PDSH_MCP_EGRESS_TOKEN
    else process.env.PDSH_MCP_EGRESS_TOKEN = previous
  }
})

test('the mounted bridge applies the per-caller catalog per Bot session', async () => {
  const ctx = await mountRuntime()
  const requested: string[] = []
  try {
    registerTeamProbes(ctx)
    await ctx.plugin(dshbotIdentityBridge, {
      catalog: {
        cacheTtlMs: 2_000,
        request: async sessionId => {
          requested.push(sessionId)
          return sessionId === 'gb-bot-a' ? mainCatalog : nonMainCatalog
        },
      },
    })

    const teammate = await createAgent(ctx, 'gb-bot-b')
    const teammateAssembly = await assembleFor(ctx, teammate)
    assert.deepEqual(
      teammateAssembly.tools.map(entry => entry.name),
      ['mcp__phone__ListRoutines', 'mcp__phone__SendToAgent'],
    )
    assert.equal(
      teammateAssembly.tools.find(entry => entry.name === 'mcp__phone__SendToAgent')?.description,
      nonMainCatalog.tools[0]?.description,
    )

    const main = await createAgent(ctx, 'gb-bot-a')
    const mainAssembly = await assembleFor(ctx, main)
    assert.deepEqual(
      mainAssembly.tools.map(entry => entry.name),
      ['mcp__phone__CreateTeammate', 'mcp__phone__ListRoutines', 'mcp__phone__SendToAgent'],
    )
    assert.equal(
      mainAssembly.tools.find(entry => entry.name === 'mcp__phone__SendToAgent')?.description,
      mainCatalog.tools[0]?.description,
    )
    assert.equal(
      mainAssembly.tools.find(entry => entry.name === 'mcp__phone__CreateTeammate')?.description,
      mainCatalog.tools[1]?.description,
    )

    const workbench = await createAgent(ctx, 'session-workbench')
    const workbenchAssembly = await assembleFor(ctx, workbench)
    assert.deepEqual(
      workbenchAssembly.tools.map(entry => entry.name),
      ['mcp__phone__CreateTeammate', 'mcp__phone__ListRoutines', 'mcp__phone__SendToAgent'],
    )
    assert.equal(
      workbenchAssembly.tools.find(entry => entry.name === 'mcp__phone__SendToAgent')?.description,
      'static send',
    )
    assert.deepEqual(requested, ['gb-bot-b', 'gb-bot-a'])
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a refresh replaces the scoped surface when the caller becomes the main Bot', async () => {
  const ctx = await mountRuntime()
  let catalog: CallerCatalog = nonMainCatalog
  let requests = 0
  try {
    registerTeamProbes(ctx)
    await ctx.plugin(dshbotIdentityBridge, {
      catalog: {
        cacheTtlMs: 0,
        request: async () => {
          requests += 1
          return catalog
        },
      },
    })

    const subject = await createAgent(ctx, 'gb-bot-b')
    const before = await assembleFor(ctx, subject)
    assert.equal(before.tools.some(entry => entry.name === 'mcp__phone__CreateTeammate'), false)

    catalog = mainCatalog
    ctx.emit('agent/status', { agent: subject, status: 'idle' })
    for (let attempt = 0; attempt < 100 && requests < 2; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 1))
    }
    assert.ok(requests >= 2, 'the status event must re-fetch the catalog')
    // `agent/status` is an emit; let the fire-and-forget refresh apply.
    await new Promise(resolve => setTimeout(resolve, 5))
    const after = await assembleFor(ctx, subject)
    assert.equal(after.tools.some(entry => entry.name === 'mcp__phone__CreateTeammate'), true)
    assert.equal(
      after.tools.find(entry => entry.name === 'mcp__phone__SendToAgent')?.description,
      mainCatalog.tools[0]?.description,
    )
    assert.equal(
      after.tools.find(entry => entry.name === 'mcp__phone__CreateTeammate')?.description,
      mainCatalog.tools[1]?.description,
    )
  } finally {
    await ctx.fiber.dispose()
  }
})

const boundCatalog: CallerCatalog = {
  tools: [
    {
      name: 'SendToAgent',
      description: 'send\nAvailable bots: Alpha (id: bot-a, main Bot); Xray (id: bot-x).',
    },
    { name: 'DeviceAppStage', description: 'stage' },
    { name: 'DeviceAppInstall', description: 'install' },
  ],
}

test('device-app tools are deny-unless-listed per caller', async () => {
  assert.deepEqual(planCallerCatalog(boundCatalog)?.deviceAppTools, ['DeviceAppStage', 'DeviceAppInstall'])
  assert.deepEqual(planCallerCatalog(nonMainCatalog)?.deviceAppTools, [])
  // Only one of the two listed: the other stays hidden (no widening).
  assert.deepEqual(planCallerCatalog({
    tools: [boundCatalog.tools[0]!, boundCatalog.tools[1]!],
  })?.deviceAppTools, ['DeviceAppStage'])
  // A near-name is never treated as a device-app tool.
  assert.deepEqual(planCallerCatalog({
    tools: [boundCatalog.tools[0]!, { name: 'DeviceAppInstallAll', description: 'x' }],
  })?.deviceAppTools, [])

  const ctx = await mountRuntime()
  let catalog: CallerCatalog = nonMainCatalog
  let requests = 0
  const names = async (agent: Agent): Promise<string[]> =>
    (await assembleFor(ctx, agent)).tools.map(entry => entry.name).filter(name => name.includes('DeviceApp'))
  try {
    registerTeamProbes(ctx)
    registerProbe(ctx, 'mcp__phone__DeviceAppStage', 'static stage')
    registerProbe(ctx, 'mcp__phone__DeviceAppInstall', 'static install')
    await ctx.plugin(dshbotIdentityBridge, {
      catalog: {
        cacheTtlMs: 0,
        request: async sessionId => {
          requests += 1
          return sessionId === 'gb-bot-a' ? boundCatalog : catalog
        },
      },
    })

    // Unbound Bot: both tools hidden; its other tools and the team surface stay.
    const unbound = await createAgent(ctx, 'gb-bot-b')
    assert.deepEqual(await names(unbound), [])
    assert.equal((await assembleFor(ctx, unbound)).tools.some(e => e.name === 'mcp__phone__SendToAgent'), true)

    // Bound Bot: both visible.
    const bound = await createAgent(ctx, 'gb-bot-a')
    assert.deepEqual(await names(bound), ['mcp__phone__DeviceAppInstall', 'mcp__phone__DeviceAppStage'])

    // Unidentified caller (workbench): the static surface is untouched.
    const workbench = await createAgent(ctx, 'session-workbench')
    assert.deepEqual(await names(workbench), ['mcp__phone__DeviceAppInstall', 'mcp__phone__DeviceAppStage'])

    // The binding appears later: a refresh reveals the tools; losing it hides them again.
    catalog = boundCatalog
    const before = requests
    ctx.emit('agent/status', { agent: unbound, status: 'idle' })
    for (let attempt = 0; attempt < 100 && requests <= before; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 1))
    }
    await new Promise(resolve => setTimeout(resolve, 5))
    assert.deepEqual(await names(unbound), ['mcp__phone__DeviceAppInstall', 'mcp__phone__DeviceAppStage'])
    catalog = nonMainCatalog
    const again = requests
    ctx.emit('agent/status', { agent: unbound, status: 'idle' })
    for (let attempt = 0; attempt < 100 && requests <= again; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 1))
    }
    await new Promise(resolve => setTimeout(resolve, 5))
    assert.deepEqual(await names(unbound), [])
  } finally {
    await ctx.fiber.dispose()
  }
})

// SPDX-License-Identifier: MIT
/**
 * Background-job identity attribution.
 *
 * DSH registers every `bash` execution with its job registry and keeps the
 * process alive after the tool result for `run_in_background: true` or a
 * timeout promotion. These tests mount the real tool pipeline, the real
 * identity bridge, and a fake job registry (the seam the production
 * `dsh-jobs-local` provides) to prove the bridge does not cancel the
 * registration at the tool-result boundary.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import JobRegistry from '@deepseek-ai/dsh-jobs-local'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import * as NativeToolExecutor from '@deepseek-ai/dsh-tool-executor-native'
import ToolRuntime, { defineTool } from '@deepseek-ai/dsh-tools'
import dshbotIdentityBridge from '../bot-runtime/src/identity-bridge.ts'
import { executeTool } from './bot-runtime-test-kit.ts'

function agent(id = 'gb-main'): Agent {
  return { id, session: { id } } as unknown as Agent
}

interface JobEvent {
  readonly type: string
  readonly job?: { readonly id: string; readonly status: string; readonly owner?: string }
}

/** The subset of `ctx.jobs` the identity bridge consumes. */
class FakeJobs {
  status = 'running'
  readonly owner = 'gb-main'
  readonly jobId = 'bash-background-1'
  private readonly listeners = new Set<{
    readonly owner: string
    readonly listener: (event: JobEvent) => void
  }>()

  readonly events = {
    subscribe: (filter: { owner: string }, listener: (event: JobEvent) => void): (() => void) => {
      const entry = { owner: filter.owner, listener }
      this.listeners.add(entry)
      return () => { this.listeners.delete(entry) }
    },
  }

  get(id: string, caller?: string): { id: string; status: string; owner?: string } {
    return { id, status: this.status, owner: caller ?? this.owner }
  }

  settle(): void {
    this.status = 'completed'
    for (const entry of [...this.listeners]) {
      if (entry.owner !== this.owner) continue
      entry.listener({
        type: 'settled',
        job: { id: this.jobId, status: this.status, owner: this.owner },
      })
    }
  }
}

async function mount(jobs: FakeJobs, result: Record<string, unknown>, options: {
  jobHeartbeatMs?: number
  lifetimeMs?: number
  jobMaxLifetimeMs?: number
} = {}): Promise<{
  ctx: Context
  registrations: Record<string, unknown>[]
  cancellations: string[]
  executed: () => number
}> {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(NativeToolExecutor)
  ctx.provide('jobs' as never, jobs)
  ctx.tools.register(defineTool({
    name: 'mcp__phone__BotVolatileContext',
    description: 'Bot availability probe',
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => '{}',
  }))
  let runs = 0
  ctx.tools.register(defineTool({
    name: 'bash',
    description: 'background bash probe',
    parameters: {},
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: () => [{ type: 'text', text: 'started' }],
    },
    execute: async () => {
      runs += 1
      return result as never
    },
  }))
  const registrations: Record<string, unknown>[] = []
  const cancellations: string[] = []
  await ctx.plugin(dshbotIdentityBridge, {
    request: async payload => {
      registrations.push(payload)
      return { ok: true, id: `registration-${String(registrations.length)}` }
    },
    cancel: async id => { cancellations.push(id) },
    lifetimeMs: options.lifetimeMs ?? 10_000,
    jobHeartbeatMs: options.jobHeartbeatMs ?? 20,
    jobMaxLifetimeMs: options.jobMaxLifetimeMs ?? 5_000,
  })
  return { ctx, registrations, cancellations, executed: () => runs }
}

async function runBash(ctx: Context, callId: string): Promise<void> {
  const result = await executeTool(ctx, {
    callId: ToolCallId(callId),
    name: 'bash',
    arguments: { command: 'sleep 1; curl -X POST http://127.0.0.1:8787/upload' },
    signal: new AbortController().signal,
    agent: agent(),
  })
  assert.equal(result.isError, false, JSON.stringify(result))
}

async function settle(): Promise<void> {
  await new Promise(resolve => setTimeout(resolve, 0))
  await new Promise(resolve => setTimeout(resolve, 20))
}

test('a background bash result keeps the identity registration until the job settles', async () => {
  const jobs = new FakeJobs()
  const harness = await mount(jobs, {
    kind: 'background', jobId: jobs.jobId, cwd: '/dsh/workspace',
  }, { jobHeartbeatMs: 10_000 })
  try {
    await runBash(harness.ctx, 'background-call')
    assert.equal(harness.executed(), 1)
    assert.deepEqual(harness.cancellations, [],
      'the tool-result boundary must not cancel a registration a live job still needs')
    assert.equal(harness.registrations.length, 1)

    jobs.settle()
    await settle()
    assert.deepEqual(harness.cancellations, ['registration-1'],
      'settlement must release the registration exactly once')
  } finally {
    await harness.ctx.fiber.dispose()
  }
})

test('a promoted foreground job keeps the registration and a plain foreground call does not', async () => {
  const promoted = new FakeJobs()
  promoted.status = 'running'
  const promotedHarness = await mount(promoted, {
    kind: 'promoted', jobId: promoted.jobId, timeoutMs: 60_000, output: '',
  })
  try {
    await runBash(promotedHarness.ctx, 'promoted-call')
    assert.deepEqual(promotedHarness.cancellations, [])
    promoted.settle()
    await settle()
    assert.deepEqual(promotedHarness.cancellations, ['registration-1'])
  } finally {
    await promotedHarness.ctx.fiber.dispose()
  }

  const foregroundJobs = new FakeJobs()
  const foreground = await mount(foregroundJobs, {
    kind: 'foreground', cwd: '/dsh/workspace', exitCode: 0, signal: null,
    timedOut: false, aborted: false, timeoutMs: 60_000,
    stdout: { text: '', truncated: false }, stderr: { text: '', truncated: false },
  })
  try {
    await runBash(foreground.ctx, 'foreground-call')
    assert.deepEqual(foreground.cancellations, ['registration-1'],
      'a normal tool result still releases immediately')
  } finally {
    await foreground.ctx.fiber.dispose()
  }
})

test('the job-held registration is heartbeated with the same call and args', async () => {
  const jobs = new FakeJobs()
  const harness = await mount(jobs, {
    kind: 'background', jobId: jobs.jobId, cwd: '/dsh/workspace',
  }, { jobHeartbeatMs: 20 })
  try {
    await runBash(harness.ctx, 'heartbeat-call')
    await new Promise(resolve => setTimeout(resolve, 45))
    assert.ok(harness.registrations.length >= 2,
      `expected at least one heartbeat refresh, got ${String(harness.registrations.length)}`)
    const first = harness.registrations[0]!
    const last = harness.registrations.at(-1)!
    assert.equal(last.callId, first.callId)
    assert.equal(last.name, first.name)
    assert.deepEqual(last.arguments, first.arguments)
    assert.equal(harness.cancellations.length, 0)
    const latestID = `registration-${String(harness.registrations.length)}`
    jobs.settle()
    await settle()
    assert.deepEqual(harness.cancellations, [latestID],
      'cleanup cancels the latest registration id')
  } finally {
    await harness.ctx.fiber.dispose()
  }
})

test('a job that already settled when the tool returned releases immediately', async () => {
  const jobs = new FakeJobs()
  const harness = await mount(jobs, {
    kind: 'background', jobId: jobs.jobId, cwd: '/dsh/workspace',
  })
  try {
    jobs.status = 'completed'
    await runBash(harness.ctx, 'settled-before-return')
    await settle()
    assert.deepEqual(harness.cancellations, ['registration-1'])
  } finally {
    await harness.ctx.fiber.dispose()
  }
})


test('the real dsh-jobs-local settlement releases the job-held registration', async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})
  await ctx.plugin(NativeToolExecutor)
  // Production mounts the same provider from dsh-base's `jobs` row.
  await ctx.plugin(JobRegistry, {})
  const jobs = ctx.get('jobs') as unknown as {
    attachController(name: string): () => void
    start(spec: Record<string, unknown>): string
  }
  const detachController = jobs.attachController('bot-egress-job-attribution-test')
  ctx.tools.register(defineTool({
    name: 'mcp__phone__BotVolatileContext',
    description: 'Bot availability probe',
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    execute: async () => '{}',
  }))
  let finish: (() => void) | undefined
  let issuedJobID = ''
  ctx.tools.register(defineTool({
    name: 'bash',
    description: 'background bash probe',
    parameters: {},
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: () => [{ type: 'text', text: 'started' }],
    },
    execute: async () => {
      const done = Promise.withResolvers<{ status: string; detail: string }>()
      issuedJobID = jobs.start({
        kind: 'bash',
        label: 'sleep 1; curl -X POST http://127.0.0.1:8787/upload',
        run: () => ({ cancel: () => {}, done: done.promise }),
      })
      finish = () => { done.resolve({ status: 'completed', detail: 'exit code: 0' }) }
      return { kind: 'background', jobId: issuedJobID, cwd: '/dsh/workspace' } as never
    },
  }))
  const cancellations: string[] = []
  let registrations = 0
  try {
    await ctx.plugin(dshbotIdentityBridge, {
      request: async () => {
        registrations += 1
        return { ok: true, id: `real-job-registration-${String(registrations)}` }
      },
      cancel: async id => { cancellations.push(id) },
      jobHeartbeatMs: 10_000,
    })
    const result = await executeTool(ctx, {
      callId: ToolCallId('real-job-call'),
      name: 'bash',
      arguments: { command: 'sleep 1; curl -X POST http://127.0.0.1:8787/upload' },
      signal: new AbortController().signal,
      agent: agent(),
    })
    assert.equal(result.isError, false, JSON.stringify(result))
    assert.notEqual(issuedJobID, '')
    assert.deepEqual(cancellations, [])
    assert.equal(typeof finish, 'function')
    finish!()
    await settle()
    assert.deepEqual(cancellations, ['real-job-registration-1'])
  } finally {
    detachController()
    await ctx.fiber.dispose()
  }
})

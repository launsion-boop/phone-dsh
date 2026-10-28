// SPDX-License-Identifier: MIT
// G2-F01: the Worker route that scopes descendant teardown to exact roots.
//
// These tests pin the route contract and the behavior the host relies on:
//   * only the exact live top-level root Agents named by the host are passed to
//     `subagents.drainDescendants`; an unrelated root and a child id are not;
//   * the route awaits the real disposal before answering, so the host can
//     verify DSH's own terminal `turn/end` after the response;
//   * a request deadline returns a typed failure, never a success receipt;
//   * a missing root is reported, not invented, and a child id is refused.
//
// The real pinned-DSH parent/child integration is in `descendant-drain.test.ts`.

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  DESCENDANT_DRAIN_DEFAULT_BUDGET_MS,
  DESCENDANT_DRAIN_MAX_BUDGET_MS,
  DESCENDANT_DRAIN_MAX_ROOTS,
  DESCENDANT_DRAIN_PATH,
  DESCENDANT_DRAIN_PROTOCOL,
  DescendantDrainError,
  drainDescendantSessions,
  registerDescendantDrainRoute,
  validateDescendantDrainRequest,
} from '../surface-phone/src/descendant-drain-controller.js'

interface FakeAgent {
  id: string
}

/** One fake listDescendants row. */
interface FakeDescendant {
  kind?: 'child' | 'diagnostic'
  id: string
  parentId: string
  depth?: number
  activity?: 'running' | 'inactive'
  reason?: string
}

interface FakeContextOptions {
  roots?: FakeAgent[]
  childOwned?: FakeAgent[]
  drain?: (roots: readonly FakeAgent[]) => Promise<void>
  descendants?: FakeDescendant[]
  list?: (rootId: string, signal?: AbortSignal) => Promise<FakeDescendant[]>
}

/** Minimal `ctx.agents` + `ctx.subagents` fake with exact identity. */
function fakeContext(options: FakeContextOptions = {}): {
  agents: {
    get(id: string): FakeAgent | undefined
    roots(): FakeAgent[]
  }
  get(name: string): unknown
  calls: FakeAgent[][]
  listed: string[]
} {
  const roots = options.roots ?? [{ id: 'root-1' }, { id: 'root-2' }]
  const childOwned = options.childOwned ?? [{ id: 'child-1' }]
  const byID = new Map([...roots, ...childOwned].map(agent => [agent.id, agent]))
  const calls: FakeAgent[][] = []
  const listed: string[] = []
  const drain = options.drain ?? (async () => {})
  const descendants = options.descendants ?? []
  return {
    agents: {
      get: (id: string) => byID.get(id),
      roots: () => [...roots],
    },
    get: (name: string) => name === 'subagents'
      ? {
          async listDescendants(rootId: string, signal?: AbortSignal): Promise<FakeDescendant[]> {
            listed.push(rootId)
            signal?.throwIfAborted()
            if (options.list !== undefined) return options.list(rootId, signal)
            // The real `listDescendants` walks reachable parent catalogs
            // recursively; mirror that for the default fixture.
            const reachable = new Set([rootId])
            const rows: FakeDescendant[] = []
            let added = true
            while (added) {
              added = false
              for (const entry of descendants) {
                if (reachable.has(entry.id) || !reachable.has(entry.parentId)) continue
                rows.push({ ...entry, kind: entry.kind ?? 'child' })
                reachable.add(entry.id)
                added = true
              }
            }
            return rows
          },
          async drainDescendants(selected: readonly FakeAgent[]): Promise<void> {
            calls.push([...selected])
            await drain(selected)
          },
        }
      : undefined,
    calls,
    listed,
  }
}

describe('descendant drain request validation', () => {
  test('a complete request keeps root order, de-duplicates and clamps the budget', () => {
    const value = validateDescendantDrainRequest({
      sessionIds: ['root-2', 'root-1', 'root-2'],
      timeoutMs: 1234.9,
    })
    assert.deepEqual(value.rootSessionIds, ['root-2', 'root-1'])
    assert.equal(value.budgetMs, 1234)
    assert.equal(validateDescendantDrainRequest({ sessionIds: ['root-1'] }).budgetMs,
      DESCENDANT_DRAIN_DEFAULT_BUDGET_MS)
    assert.equal(validateDescendantDrainRequest({
      sessionIds: ['root-1'], timeoutMs: DESCENDANT_DRAIN_MAX_BUDGET_MS + 10,
    }).budgetMs, DESCENDANT_DRAIN_MAX_BUDGET_MS)
  })

  test('missing, empty or non-string roots are typed failures', () => {
    for (const body of [{}, { sessionIds: [] }, { sessionIds: [''] }, { sessionIds: [1] }]) {
      assert.throws(() => validateDescendantDrainRequest(body),
        (error: unknown) => error instanceof DescendantDrainError
          && error.status === 400)
    }
    assert.throws(() => validateDescendantDrainRequest({
      sessionIds: Array.from({ length: DESCENDANT_DRAIN_MAX_ROOTS + 1 }, (_, index) => `r${String(index)}`),
    }), (error: unknown) => error instanceof DescendantDrainError
      && error.code === 'descendant-drain/too-many-roots')
  })

  test('a non-positive or non-numeric budget is refused instead of defaulted', () => {
    for (const timeoutMs of [0, -1, Number.NaN, 'soon']) {
      assert.throws(() => validateDescendantDrainRequest({ sessionIds: ['root-1'], timeoutMs }),
        (error: unknown) => error instanceof DescendantDrainError
          && error.code === 'descendant-drain/bad-budget')
    }
  })
})

describe('scoped descendant drain', () => {
  test('passes exactly the named live roots to the public manager and awaits disposal', async () => {
    let release!: () => void
    const blocked = new Promise<void>((resolve) => { release = resolve })
    const ctx = fakeContext({ drain: async () => { await blocked } })
    const running = drainDescendantSessions(ctx, ['root-1'])
    while (ctx.calls.length === 0) await Promise.resolve()
    assert.deepEqual(ctx.calls.map(call => call.map(agent => agent.id)), [['root-1']],
      'only root-1 may reach drainDescendants; root-2 and child-1 must not')
    let settled = false
    void running.then(() => { settled = true })
    await Promise.resolve()
    assert.equal(settled, false, 'the route must await drainDescendants, not release it in the background')
    release()
    const receipt = await running
    assert.equal(receipt.protocol, DESCENDANT_DRAIN_PROTOCOL)
    assert.deepEqual(receipt.roots, ['root-1'])
    assert.deepEqual(receipt.missing, [])
    assert.deepEqual(receipt.descendants, [])
    assert.ok(receipt.durationMs >= 0)
  })

  test('reports the live descendant ids so the host never mistakes an old header for stale', async () => {
    // DSH cold resume reuses the child id and its persisted header, so the
    // child's createdAt still points at the previous incarnation. The route's
    // live set is what keeps that child (and its own descendants) in the
    // host's durable turn/end verification.
    const ctx = fakeContext({
      roots: [{ id: 'root-1' }],
      descendants: [
        { id: 'resumed-child', parentId: 'root-1', depth: 1, activity: 'running' },
        { id: 'idle-child', parentId: 'root-1', depth: 1, activity: 'inactive' },
        { id: 'resumed-grandchild', parentId: 'resumed-child', depth: 2, activity: 'running' },
      ],
    })
    const receipt = await drainDescendantSessions(ctx, ['root-1'])
    assert.deepEqual(receipt.descendants, ['resumed-child', 'resumed-grandchild'],
      'only live descendants may reach the host stale-journal decision')
    assert.deepEqual(ctx.calls.map(call => call.map(agent => agent.id)), [['root-1']])
  })

  test('fails loud when the descendant listing has an unreadable branch', async () => {
    const ctx = fakeContext({
      roots: [{ id: 'root-1' }],
      descendants: [
        { kind: 'diagnostic', id: 'child-1', parentId: 'root-1', reason: 'corrupt' },
      ],
    })
    await assert.rejects(drainDescendantSessions(ctx, ['root-1']),
      (error: unknown) => error instanceof DescendantDrainError
        && error.code === 'descendant-drain/list-incomplete')
    assert.deepEqual(ctx.calls, [], 'an unknown descendant tree must not be drained as success')
  })

  test('reports a missing root but never guesses a descendant for it', async () => {
    const ctx = fakeContext()
    const receipt = await drainDescendantSessions(ctx, ['missing-root', 'root-2'])
    assert.deepEqual(receipt.roots, ['root-2'])
    assert.deepEqual(receipt.missing, ['missing-root'])
    assert.deepEqual(ctx.calls.map(call => call.map(agent => agent.id)), [['root-2']])
  })

  test('refuses a subagent-owned child id instead of cancelling it directly', async () => {
    const ctx = fakeContext()
    await assert.rejects(drainDescendantSessions(ctx, ['child-1']),
      (error: unknown) => error instanceof DescendantDrainError
        && error.code === 'descendant-drain/not-root'
        && error.status === 409)
    assert.deepEqual(ctx.calls, [], 'a rejected child id must never reach the manager')
  })

  test('refuses to claim success when the scoped manager is unavailable', async () => {
    const ctx = fakeContext()
    ctx.get = () => undefined
    await assert.rejects(drainDescendantSessions(ctx, ['root-1']),
      (error: unknown) => error instanceof DescendantDrainError
        && error.code === 'descendant-drain/unavailable')
  })

  test('an aborted caller does not reach the manager and does not answer as success', async () => {
    const ctx = fakeContext()
    const controller = new AbortController()
    controller.abort(new Error('stop'))
    await assert.rejects(drainDescendantSessions(ctx, ['root-1'], controller.signal))
    assert.deepEqual(ctx.calls, [])
  })
})

/** One registered route handler and its disposable. */
function routeFixture(ctx: ReturnType<typeof fakeContext>): {
  call(body: unknown, options?: { contentType?: string, signal?: AbortSignal }): Promise<Response>
  dispose(): void
} {
  let handler: ((request: Request) => Promise<Response>) | undefined
  const connection = {
    fetch: {
      register(options: Record<string, unknown>): () => void {
        assert.equal(options.path, DESCENDANT_DRAIN_PATH)
        handler = options.fetch as (request: Request) => Promise<Response>
        return () => { handler = undefined }
      },
    },
  }
  const effect = (run: () => unknown) => run() as () => void
  const disposable = registerDescendantDrainRoute({ ...ctx, effect }, connection)
  return {
    async call(body, options = {}) {
      assert.ok(handler, 'the route must be registered')
      return await handler(new Request('http://pdsh.test' + DESCENDANT_DRAIN_PATH, {
        method: 'POST',
        headers: { 'content-type': options.contentType ?? 'application/json' },
        body: typeof body === 'string' ? body : JSON.stringify(body),
        signal: options.signal,
      }))
    },
    dispose: () => { disposable() },
  }
}

describe('descendant drain route', () => {
  test('returns the successful receipt envelope after the awaited drain', async () => {
    const ctx = fakeContext()
    const route = routeFixture(ctx)
    try {
      const response = await route.call({ sessionIds: ['root-1'], timeoutMs: 5000 })
      assert.equal(response.status, 200)
      const body = await response.json() as {
        ok?: boolean
        value?: {
          protocol?: string
          roots?: string[]
          missing?: string[]
          descendants?: string[]
          durationMs?: number
        }
      }
      assert.equal(body.ok, true)
      assert.equal(body.value?.protocol, DESCENDANT_DRAIN_PROTOCOL)
      assert.deepEqual(body.value?.roots, ['root-1'])
      assert.deepEqual(body.value?.missing, [])
      assert.deepEqual(body.value?.descendants, [])
      assert.equal(typeof body.value?.durationMs, 'number')
    } finally {
      route.dispose()
    }
  })

  test('a deadline returns 504 with no successful value while disposal is still pending', async () => {
    let release!: () => void
    const blocked = new Promise<void>((resolve) => { release = resolve })
    const ctx = fakeContext({ drain: async () => { await blocked } })
    const route = routeFixture(ctx)
    try {
      const startedAt = Date.now()
      const response = await route.call({ sessionIds: ['root-1'], timeoutMs: 20 })
      const text = await response.text()
      assert.equal(response.status, 504, text)
      assert.ok(Date.now() - startedAt >= 10)
      const body = JSON.parse(text) as { ok?: boolean, value?: unknown, error?: { code?: string } }
      assert.equal(body.ok, false, 'a timeout must not report success')
      assert.equal(body.value, undefined, 'a timeout must not claim a drain receipt')
      assert.equal(body.error?.code, 'descendant-drain/timeout')
    } finally {
      release()
      route.dispose()
    }
  })

  test('a child id is a 409, not a successful no-op', async () => {
    const ctx = fakeContext()
    const route = routeFixture(ctx)
    try {
      const response = await route.call({ sessionIds: ['child-1'] })
      const text = await response.text()
      assert.equal(response.status, 409, text)
      assert.match(text, /descendant-drain\/not-root/)
    } finally {
      route.dispose()
    }
  })

  test('missing roots are reported in a successful receipt without a fabricated drain', async () => {
    const ctx = fakeContext({ roots: [{ id: 'root-1' }] })
    const route = routeFixture(ctx)
    try {
      const response = await route.call({ sessionIds: ['gone-root'] })
      assert.equal(response.status, 200)
      const body = await response.json() as {
        value?: { roots?: string[], missing?: string[], descendants?: string[] }
      }
      assert.deepEqual(body.value?.roots, [])
      assert.deepEqual(body.value?.missing, ['gone-root'])
      assert.deepEqual(body.value?.descendants, [])
      assert.deepEqual(ctx.calls, [])
    } finally {
      route.dispose()
    }
  })

  test('rejects a non-JSON content type and malformed JSON', async () => {
    const ctx = fakeContext()
    const route = routeFixture(ctx)
    try {
      const wrongType = await route.call({ sessionIds: ['root-1'] }, { contentType: 'text/plain' })
      assert.equal(wrongType.status, 415)
      const malformed = await route.call('{not json')
      assert.equal(malformed.status, 400)
      assert.match(await malformed.text(), /descendant-drain\/bad-json/)
    } finally {
      route.dispose()
    }
  })
})

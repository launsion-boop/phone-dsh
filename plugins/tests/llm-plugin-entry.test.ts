// SPDX-License-Identifier: MIT
// P0: the llm-bridge package entry must load in the Worker, whose module table
// has no node:http(s) or node:zlib transport. Every desktop builtin is behind
// `await import()` inside the functions that use it, so importing the plugin
// entry and installing it over the host `/v1/http` route never resolves them.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { IncomingHttpHeaders } from 'node:http'
import { registerHooks } from 'node:module'
import type { AddressInfo } from 'node:net'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'

/** Builtins the Worker module table does not carry (no TLS client, no usable zlib client). */
const WORKER_MISSING = ['node:https', 'node:http', 'node:zlib'] as const
/** Files evaluated when the package entry (`src/index.ts`) is imported. */
const ENTRY_GRAPH = ['index.ts', 'install.ts', 'node-fetch.ts'] as const
/**
 * Every specifier the entry graph must not import statically. `node:stream` is
 * in the Worker module table, but the desktop transport is its only consumer,
 * so the entry keeps it behind the same lazy loader as well.
 */
const FORBIDDEN = [...WORKER_MISSING, 'node:net', 'node:tls', 'node:stream', 'undici'] as const

test('every file reachable from the package entry has no static node transport import', () => {
  for (const file of ENTRY_GRAPH) {
    const source = readFileSync(fileURLToPath(new URL(`../llm-bridge/src/${file}`, import.meta.url)), 'utf8')
    const specifiers = [
      ...source.matchAll(/^\s*(?:import|export)\b(?!\s+type\b)[^\n]*?\bfrom\s+(['"])([^'"]+)\1/gm),
      ...source.matchAll(/^\s*import\s+(['"])([^'"]+)\1/gm),
    ].map(match => match[2])
    for (const specifier of FORBIDDEN) {
      assert.equal(specifiers.includes(specifier), false, `${file} statically imports ${specifier}`)
    }
  }
})

test('the package entry installs over /v1/http while node:https/http/zlib are unresolvable', async () => {
  const seen: IncomingHttpHeaders[] = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      seen.push(req.headers)
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify({ target: req.headers['x-pdsh-target-url'], body: Buffer.concat(chunks).toString() }))
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const token = 'llm-entry-token-0123456789abcdef'
  const previousLocation = Object.getOwnPropertyDescriptor(globalThis, 'location')
  const previous = {
    PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN,
    PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN,
  }
  // Simulate the Worker module table: resolving a missing builtin is a
  // load-time failure, so any static (or mis-scoped dynamic) edge is fatal.
  const hooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if ((WORKER_MISSING as readonly string[]).includes(specifier)) {
        throw new Error(`${specifier} is not in the Worker module table`)
      }
      return nextResolve(specifier, context)
    },
  })
  Object.defineProperty(globalThis, 'location', { value: { origin: base }, configurable: true, writable: true })
  process.env.PDSH_CHANNEL_TOKEN = token
  process.env.PDSH_CHANNEL_ORIGIN = base
  try {
    // Load the plugin the way the Worker does: through its package entry.
    const entry = await import('@phone-dsh/dsh-llm-bridge') as typeof import('../llm-bridge/src/index.ts')
    // The desktop `createNodeFetch` stays a lazy forwarding export: creating it
    // must not resolve the node:http(s)/stream/zlib clients.
    assert.equal(typeof entry.createNodeFetch, 'function')
    assert.equal(typeof entry.createNodeFetch(), 'function')
    const ctx = new Context()
    try {
      await ctx.plugin(entry, {
        mode: 'auto',
        hostProxy: false,
        hostProxyRoutes: 'external',
        tokenEnv: 'PDSH_CHANNEL_TOKEN',
        idempotencyHosts: [],
      })
      assert.equal(entry.nodeFetchInstalled(), true, 'the plugin installs the Worker host route')
      const response = await fetch('https://model.example/v1/messages', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{"prompt":"hi"}',
      })
      assert.equal(response.status, 200)
      assert.equal(response.headers.get('cache-control'), 'no-store')
      const body = await response.json() as Record<string, string>
      assert.equal(body.target, 'https://model.example/v1/messages')
      assert.equal(body.body, '{"prompt":"hi"}')
      assert.equal(seen.length, 1)
      assert.equal(seen[0]?.authorization, `Bearer ${token}`)
    } finally {
      await ctx.fiber.dispose()
    }
    assert.equal(entry.nodeFetchInstalled(), false, 'unload restores the platform fetch')
  } finally {
    hooks.deregister()
    server.closeAllConnections()
    server.close()
    if (previousLocation === undefined) delete (globalThis as { location?: unknown }).location
    else Object.defineProperty(globalThis, 'location', previousLocation)
    for (const key of ['PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN'] as const) {
      const value = previous[key]
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
})

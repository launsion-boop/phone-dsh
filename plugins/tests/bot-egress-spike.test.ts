// SPDX-License-Identifier: MIT
/**
 * WP3 Bot egress security spike (evidence only; no production fix).
 *
 * These tests exercise three Worker-side seams with the real production code:
 * the bash environment scrub, the `curl` shim over `POST /v1/http`, and the
 * structural approval effect classifier. A small loopback pair mimics the two
 * host layers the spike is about (the `/v1/http` route plus the Bot MCP
 * listener) so the real `curl` shim, not a hand-written request, decides what
 * crosses the boundary. Host-side admission and bearer injection are owned by
 * `Tests/PhoneDSHTests/PhoneMCPAccessSettingsTests.swift` and
 * `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift`; those run the real
 * Swift policy and are cited in the report, not duplicated here.
 *
 * Known failures are marked with `todo`: the assertion states the behaviour the
 * security fix should produce, so the run reports them as `todo` instead of a
 * red suite. When the condition is fixed the test still passes as `todo`; the
 * report lists every one so the fix can remove the marker.
 */
import assert from 'node:assert/strict'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { build } from 'esbuild'

import { WorkerShell, VfsFileSystem, createWorkerCommands } from '../shell-ext/src/index.ts'
import { NodeGitFs } from '../wasi-toolbox/git/index.ts'
import { runCurl } from '../shell-ext/src/curl.ts'
import { phoneEffectsForApproval } from '../bot-runtime/src/approval-gate.ts'
import { localEnvironment } from '../subprocess-xl/src/local.ts'
import type { SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')

/** Fixture credentials: never a real device value, and masked in the report. */
const CHANNEL_TOKEN = 'wp3-fixture-channel-token'
const LAUNCH_TOKEN = 'wp3-fixture-launch-token'
const PHONE_MCP_TOKEN = 'wp3-fixture-phone-mcp-token'
const BOT_TOKEN = 'wp3-fixture-bot-bearer'
const MCP_ROUTES = new Set(['/mcp', '/identity/register', '/identity/cancel', '/approval'])

interface Seen {
  readonly route: 'host' | 'bot'
  readonly method: string
  readonly url: string
  readonly path: string
  readonly authorization: string | undefined
  readonly body: string
  readonly target?: string
}

interface LoopbackPair {
  readonly hostOrigin: string
  readonly botOrigin: string
  readonly seen: Seen[]
  close(): Promise<void>
}

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((accept, refuse) => {
    const chunks: Buffer[] = []
    request.on('data', (chunk: Buffer) => chunks.push(chunk))
    request.on('error', refuse)
    request.on('end', () => accept(Buffer.concat(chunks).toString('utf8')))
  })
}

function listen(server: Server): Promise<string> {
  return new Promise((accept, refuse) => {
    server.once('error', refuse)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address() as AddressInfo
      accept(`http://127.0.0.1:${String(address.port)}`)
    })
  })
}

function close(server: Server): Promise<void> {
  return new Promise((accept, refuse) => {
    server.close(error => (error === undefined ? accept() : refuse(error)))
  })
}

function reply(response: ServerResponse, status: number, body: string): void {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(body)
}

/**
 * The host `/v1/http` route and the Bot MCP listener.
 *
 * The host half mirrors the documented production seam this spike must prove:
 * loopback bearer check, exact target path, real Bot bearer injected after the
 * Worker's Authorization is dropped. It is a fixture, not the Swift gateway;
 * the report separates the two pieces.
 */
async function startLoopbackPair(): Promise<LoopbackPair> {
  const seen: Seen[] = []
  const bot: Server = createServer((request, response) => {
    void (async () => {
      const body = await readBody(request)
      const url = request.url ?? '/'
      seen.push({
        route: 'bot', method: request.method ?? 'GET', url, path: url,
        authorization: request.headers.authorization, body,
      })
      if (request.headers.authorization !== `Bearer ${BOT_TOKEN}`) {
        reply(response, 401, '{"error":"unauthorized"}')
        return
      }
      if (url === '/identity/register') {
        let session = ''
        try {
          const parsed = JSON.parse(body) as { sessionId?: unknown }
          if (typeof parsed.sessionId === 'string') session = parsed.sessionId
        } catch {}
        if (session === '') {
          reply(response, 400, '{"ok":false,"error":"sessionId"}')
          return
        }
        reply(response, 200, '{"ok":true,"id":"registration-1"}')
        return
      }
      if (url === '/mcp') {
        reply(response, 200, '{"jsonrpc":"2.0","id":"spike","result":{"structuredContent":{"ok":true}}}')
        return
      }
      if (url === '/identity/cancel' || url === '/approval') {
        reply(response, 200, '{"ok":true,"allowed":false}')
        return
      }
      reply(response, 404, '{"error":"not_found"}')
    })()
  })
  const botOrigin = await listen(bot)
  const host: Server = createServer((request, response) => {
    void (async () => {
      const body = await readBody(request)
      const url = request.url ?? '/'
      const target = String(request.headers['x-pdsh-target-url'] ?? '')
      const method = String(request.headers['x-pdsh-target-method'] ?? request.method ?? 'POST').toUpperCase()
      seen.push({
        route: 'host', method: request.method ?? 'GET', url, path: url,
        authorization: request.headers.authorization, body, target,
      })
      if (request.method !== 'POST' || url !== '/v1/http') {
        reply(response, 404, '{"error":"not_found"}')
        return
      }
      if (request.headers.authorization !== `Bearer ${CHANNEL_TOKEN}`) {
        reply(response, 401, '{"error":"unauthorized"}')
        return
      }
      let parsed: URL
      try {
        parsed = new URL(target)
      } catch {
        reply(response, 400, '{"error":"bad_target"}')
        return
      }
      if (`${parsed.protocol}//${parsed.host}` !== botOrigin || !MCP_ROUTES.has(parsed.pathname)) {
        // The production gateway answers 403 `forbidden`; the shim maps that
        // to exit 22 without reading the body.
        reply(response, 403, '{"error":"forbidden"}')
        return
      }
      const upstream = await fetch(parsed, {
        method,
        headers: {
          authorization: `Bearer ${BOT_TOKEN}`,
          'content-type': 'application/json',
        },
        ...method === 'GET' || method === 'HEAD' ? {} : { body },
      })
      const answer = await upstream.text()
      response.writeHead(upstream.status, { 'content-type': upstream.headers.get('content-type') ?? 'application/json' })
      response.end(answer)
    })()
  })
  const hostOrigin = await listen(host)
  return {
    hostOrigin, botOrigin, seen,
    async close() {
      await Promise.all([close(host), close(bot)])
    },
  }
}

function scratchRoot(): { directory: string; root: string; cleanup(): void } {
  const directory = mkdtempSync(join(tmpdir(), 'wp3-egress-'))
  mkdirSync(join(directory, 'dsh', 'workspace'), { recursive: true })
  mkdirSync(join(directory, 'dsh', 'tmp'), { recursive: true })
  // The VFS root `/` maps to `directory`, so the shell cwd /dsh/workspace is a
  // real materialized directory (the same shape every WorkerShell test uses).
  return { directory, root: directory, cleanup: () => rmSync(directory, { recursive: true, force: true }) }
}

function spawnSpec(argv: readonly string[]): SubprocessSpawnSpec {
  // Only `env` is consulted by localEnvironment; the other members are the
  // production spawn shape.
  return {
    argv: [...argv],
    cwd: '/dsh/workspace',
    stdio: { stdin: 'ignore', stdout: { maxBytes: 65_536 }, stderr: { maxBytes: 65_536 } },
    graceMs: 1_000,
  }
}

async function withTokenEnvironment<T>(body: () => Promise<T>): Promise<T> {
  const previous = {
    PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN,
    PDSH_DSH_LAUNCH_TOKEN: process.env.PDSH_DSH_LAUNCH_TOKEN,
    PDSH_PHONE_MCP_TOKEN: process.env.PDSH_PHONE_MCP_TOKEN,
  }
  process.env.PDSH_CHANNEL_TOKEN = CHANNEL_TOKEN
  process.env.PDSH_DSH_LAUNCH_TOKEN = LAUNCH_TOKEN
  process.env.PDSH_PHONE_MCP_TOKEN = PHONE_MCP_TOKEN
  try {
    return await body()
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
  }
}

// ---------------------------------------------------------------------------
// Q1 — environment credentials
// ---------------------------------------------------------------------------

test('Q1: the bash child environment carries no PDSH token value', async () => {
  await withTokenEnvironment(async () => {
    const scratch = scratchRoot()
    try {
      const spec = spawnSpec(['bash', '-c', 'env'])
      const env = localEnvironment(spec)
      assert.equal(env.PDSH_CHANNEL_TOKEN, undefined,
        'subprocess-xl.localEnvironment must scrub PDSH_CHANNEL_TOKEN')
      assert.equal(env.PDSH_DSH_LAUNCH_TOKEN, undefined,
        'subprocess-xl.localEnvironment must scrub PDSH_DSH_LAUNCH_TOKEN')
      assert.equal(env.PDSH_PHONE_MCP_TOKEN, undefined,
        'subprocess-xl.localEnvironment must scrub PDSH_PHONE_MCP_TOKEN')

      const shell = new WorkerShell({
        fs: new VfsFileSystem({ root: scratch.root }),
        commands: createWorkerCommands({ git: false, curl: false }),
      })
      const result = await shell.run(['bash', '-c',
        'env; printenv PDSH_CHANNEL_TOKEN; printenv PDSH_DSH_LAUNCH_TOKEN; '
        + 'printenv PDSH_PHONE_MCP_TOKEN; echo "$PDSH_CHANNEL_TOKEN"; '
        + 'cat /proc/self/environ 2>&1; cat /proc/1/environ 2>&1; '
        + 'ls -la /dsh/home 2>&1; cat /dsh/home/capabilities.json 2>&1; '
        + 'cat /dsh/home/mcp.json 2>&1; cat /dsh/home/settings.json 2>&1'],
        { cwd: '/dsh/workspace', env })
      assert.match(result.stdout, /PATH=|HOME=|PWD=/u,
        'the env probe itself must have run')
      // The capability manifest is written before the first model request; it
      // publishes the egress allow-list and command surface, never a token.
      assert.equal(result.stdout.includes('PDSH_CHANNEL_TOKEN'), false,
        'no Worker-visible file may publish the token name/value')
      assert.equal(result.aborted, false)
      for (const secret of [CHANNEL_TOKEN, LAUNCH_TOKEN, PHONE_MCP_TOKEN]) {
        assert.equal(result.stdout.includes(secret), false,
          `the bash output leaked a token: ${result.stdout}`)
        assert.equal(result.stderr.includes(secret), false,
          `the bash stderr leaked a token: ${result.stderr}`)
      }
    } finally {
      scratch.cleanup()
    }
  })
})

// ---------------------------------------------------------------------------
// Q2 — the `curl` shim over the host `/v1/http` route
// ---------------------------------------------------------------------------

test('Q2: the host policy still rejects a non-MCP target (regression)', async () => {
  const pair = await startLoopbackPair()
  const scratch = scratchRoot()
  try {
    const result = await runCurl(
      ['-sS', '-X', 'POST', '--data-raw', '{"jsonrpc":"2.0"}', `${pair.botOrigin}/not-a-route`],
      { cwd: '/dsh/workspace', fs: new VfsFileSystem({ root: scratch.root }) },
      { origin: pair.hostOrigin, token: CHANNEL_TOKEN })
    assert.equal(result.exitCode, 22, result.stderr)
    assert.match(result.stderr, /host allow-list rejected/u)
    assert.equal(pair.seen.filter(entry => entry.route === 'bot').length, 0,
      'the Bot listener must not see a rejected target')
  } finally {
    scratch.cleanup()
    await pair.close()
  }
})

test('Q2 known failure: model-written curl reaches the four Bot MCP routes', { todo: 'WP3 Q2: host egress admits the Bot MCP routes with the injected bearer' }, async () => {
  const pair = await startLoopbackPair()
  const scratch = scratchRoot()
  try {
    const bodies: Record<string, string> = {
      '/mcp': '{"jsonrpc":"2.0","id":"wp3","method":"tools/call"}',
      '/identity/register': '{"runtimeId":"phone-worker","sessionId":"gb-main",'
        + '"callId":"wp3","name":"UpdateMemory","argsDigest":"00"}',
      '/identity/cancel': '{"id":"registration-1"}',
      '/approval': '{"callId":"wp3"}',
    }
    const results: { path: string; exitCode: number; stdout: string; stderr: string }[] = []
    for (const path of [...MCP_ROUTES]) {
      const result = await runCurl(
        ['-sS', '-X', 'POST', '--data-raw', bodies[path]!, `${pair.botOrigin}${path}`],
        { cwd: '/dsh/workspace', fs: new VfsFileSystem({ root: scratch.root }) },
        { origin: pair.hostOrigin, token: CHANNEL_TOKEN })
      results.push({ path, ...result })
    }
    // The security contract under test: the host must NOT admit a target that
    // the Worker reached around its Bot MCP client.
    const reached = results.filter(result => result.exitCode === 0).map(result => result.path)
    assert.deepEqual(reached, [], `model-written curl reached ${JSON.stringify(reached)}; `
      + `results=${JSON.stringify(results)}; seen=${JSON.stringify(pair.seen)}`)
  } finally {
    scratch.cleanup()
    await pair.close()
  }
})

// ---------------------------------------------------------------------------
// Approval regex variants
// ---------------------------------------------------------------------------

const DIRECT = 'curl -sS -X POST --data-raw \'{"jsonrpc":"2.0"}\' http://127.0.0.1:1/identity/register'
const SCRIPT = 'printf \'%s\\n\' \'curl -sS -X POST --data-raw "{}" http://127.0.0.1:1/identity/register\' '
  + '> /tmp/wp3-spike.sh; bash /tmp/wp3-spike.sh'
const VARIABLE = 'c=cur; l="${c}l"; "$l" -sS -X POST --data-raw \'{}\' '
  + 'http://127.0.0.1:1/identity/register'

test('approval: a literal curl POST is classified as curl-post (regression)', () => {
  const effects = phoneEffectsForApproval('bash', { command: DIRECT })
  assert.equal(effects.some(effect => effect.operation === 'curl-post'), true,
    JSON.stringify(effects))
})

test('approval known failure: a script-file curl POST is still classified', { todo: 'WP3: the bash approval classifier only sees the outer command' }, () => {
  const effects = phoneEffectsForApproval('bash', { command: SCRIPT })
  assert.equal(effects.some(effect => effect.operation === 'curl-post' || effect.operation === 'network-egress'),
    true, JSON.stringify(effects))
})

test('approval known failure: a concatenated-command curl POST is still classified', { todo: 'WP3: variable concatenation avoids the literal curl regex' }, () => {
  const effects = phoneEffectsForApproval('bash', { command: VARIABLE })
  assert.equal(effects.some(effect => effect.operation === 'curl-post' || effect.operation === 'network-egress'),
    true, JSON.stringify(effects))
})

// ---------------------------------------------------------------------------
// git transport
// ---------------------------------------------------------------------------

test('Q1/Q2: git can reach /v1/http but exact-path admission blocks the Bot MCP routes', async () => {
  const pair = await startLoopbackPair()
  const scratch = scratchRoot()
  try {
    await withTokenEnvironment(async () => {
      const spec = spawnSpec(['git', 'clone', `${pair.botOrigin}/repo`])
      const env = localEnvironment(spec)
      // The model can learn this non-secret origin. The shell environment is
      // scrubbed, yet `HostHttpTransport` falls back to the Worker `process.env`
      // for the bearer when `transportFor` passes an undefined token. This test
      // records that observed fact instead of assuming the scrub is a boundary.
      env.PDSH_CHANNEL_ORIGIN = pair.hostOrigin
      const shell = new WorkerShell({
        fs: new VfsFileSystem({ root: scratch.root }),
        commands: createWorkerCommands({ curl: false, git: { fs: new NodeGitFs(scratch.root) } }),
      })
      const result = await shell.run(['bash', '-c',
        `GIT_TRACE_CURL=1 GIT_CURL_VERBOSE=1 GIT_TRACE=1 git clone ${pair.botOrigin}/repo`],
        { cwd: '/dsh/workspace', env })
      assert.notEqual(result.exitCode, 0, result.stdout)
      // The npm-vendored git client does not implement GIT_TRACE_CURL, so the
      // token is not printed even though the transport used it.
      for (const secret of [CHANNEL_TOKEN, LAUNCH_TOKEN, PHONE_MCP_TOKEN]) {
        assert.equal(`${result.stdout}${result.stderr}`.includes(secret), false,
          'git diagnostics must not print a token')
      }
      const host = pair.seen.filter(entry => entry.route === 'host')
      assert.equal(host.length, 1, JSON.stringify(pair.seen))
      assert.equal(host[0]!.authorization, `Bearer ${CHANNEL_TOKEN}`,
        'the git transport used the real Worker process token')
      assert.equal(host[0]!.target?.includes('/info/refs'), true)
      assert.equal(pair.seen.filter(entry => entry.route === 'bot').length, 0,
        'the exact-path MCP policy must reject the git smart-HTTP path')
      assert.match(result.stderr, /host allow-list rejected/u)
    })
  } finally {
    scratch.cleanup()
    await pair.close()
  }
})

// ---------------------------------------------------------------------------
// Q1/Q2 — WASI python: the guest gets no token; its only network is the
// loopback `/v1/http` bridge.
// ---------------------------------------------------------------------------

test('WASI python: the guest environment never carries the loopback token', async () => {
  const { createLoopbackXhrTransport, PDSH_HTTP_ROUTE } = await import('../wasi-toolbox/src/http-bridge.ts')
  const seen: { url: string; headers: Map<string, string>; body: string | null }[] = []
  class FakeXhr {
    status = 200
    statusText = 'OK'
    responseHeaders = ''
    response: unknown = new ArrayBuffer(0)
    responseType = ''
    private openedUrl = ''
    private readonly headers = new Map<string, string>()
    open(_method: string, url: string, _async: boolean): void { this.openedUrl = url }
    setRequestHeader(name: string, value: string): void { this.headers.set(name.toLowerCase(), value) }
    getAllResponseHeaders(): string { return '' }
    send(body: unknown): void {
      seen.push({ url: this.openedUrl, headers: new Map(this.headers), body: typeof body === 'string' ? body : null })
      this.response = new ArrayBuffer(0)
    }
  }
  const transport = createLoopbackXhrTransport({
    origin: 'http://127.0.0.1:1',
    token: CHANNEL_TOKEN,
    xhrFactory: () => new FakeXhr() as never,
  })
  const response = transport.request({
    method: 'POST',
    url: 'http://127.0.0.1:9/identity/register',
    headers: {},
    body: new TextEncoder().encode('{"jsonrpc":"2.0"}'),
  })
  assert.equal(response.status, 200)
  assert.equal(seen.length, 1)
  assert.equal(seen[0]!.url, `http://127.0.0.1:1${PDSH_HTTP_ROUTE}`)
  assert.equal(seen[0]!.headers.get('authorization'), `Bearer ${CHANNEL_TOKEN}`)
  assert.equal(seen[0]!.headers.get('x-pdsh-target-url'), 'http://127.0.0.1:9/identity/register')
  // The Python guest's own default environment is built by resolvePythonHttpRoute
  // and must not publish the token; the bridge, not the guest, carries it.
  const { resolvePythonHttpRoute } = await import('../worker-entry/src/python-toolbox.ts')
  assert.deepEqual(
    resolvePythonHttpRoute({ PDSH_CHANNEL_ORIGIN: 'http://127.0.0.1:1', PDSH_CHANNEL_TOKEN: CHANNEL_TOKEN }),
    { origin: 'http://127.0.0.1:1', token: CHANNEL_TOKEN })
})

// ---------------------------------------------------------------------------
// web_fetch — the provider's outbound is the DeepSeek Fetch API, not /v1/http.
// ---------------------------------------------------------------------------

test('web_fetch: the DeepSeek fetch provider sends the URL to its own API, not the host route', async () => {
  const pair = await startLoopbackPair()
  const previousFetch = globalThis.fetch
  const requests: { url: string; body: string }[] = []
  try {
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({ url: String(input), body: String(init?.body ?? '') })
      return new Response(JSON.stringify({ content: '# fetched remotely' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    }) as typeof fetch
    const { DeepSeekFetchApiProvider } = await import('@deepseek-ai/dsh-web-deepseek-api')
    const provider = new DeepSeekFetchApiProvider(() => ({
      apiKey: 'wp3-fixture-search-key',
      baseURL: 'https://api.deepseek.test',
    }))
    assert.equal(provider.available(), true)
    const target = `${pair.botOrigin}/mcp`
    const result = await provider.fetch({ url: target }, new AbortController().signal)
    assert.equal(result.statusCode, 200)
    assert.equal(requests.length, 1)
    assert.equal(requests[0]!.url, 'https://api.deepseek.test/fetch')
    assert.deepEqual(JSON.parse(requests[0]!.body), { url: target })
    assert.equal(pair.seen.length, 0,
      'web_fetch must not make a host /v1/http request')
  } finally {
    globalThis.fetch = previousFetch
    await pair.close()
  }
})

// ---------------------------------------------------------------------------
// Q1/Q2 — PTC: the model-written workflow program has no fetch or process.
// ---------------------------------------------------------------------------

test('PTC: the QuickJS workflow guest has no fetch, process or environment', { timeout: 120_000 }, async () => {
  const scratch = mkdtempSync(join(tmpdir(), 'wp3-quickjs-'))
  try {
    const outfile = join(scratch, 'quickjs-vm.mjs')
    await build({
      entryPoints: [join(root, 'workflow-worker/src/quickjs-vm.ts')],
      outfile,
      bundle: true,
      format: 'esm',
      platform: 'browser',
      target: 'es2022',
      loader: { '.wasm': 'binary' },
      nodePaths: [join(root, 'node_modules')],
      absWorkingDir: root,
      logLevel: 'silent',
    })
    const vm = await import(outfile) as {
      runInNewContext(code: string): Promise<unknown>
    }
    const raw = await vm.runInNewContext(`JSON.stringify({
      fetch: typeof fetch,
      process: typeof process,
      require: typeof require,
      worker: typeof Worker,
      env: (() => { try { return typeof globalThis.process.env } catch { return 'blocked' } })(),
      token: (() => { try { return typeof globalThis.process.env.PDSH_CHANNEL_TOKEN } catch { return 'blocked' } })(),
      escape: (() => {
        try { return typeof ({}).constructor.constructor('return process')() }
        catch { return 'blocked' }
      })(),
    })`)
    const value = JSON.parse(String(raw)) as Record<string, string>
    assert.deepEqual(value, {
      fetch: 'undefined',
      process: 'undefined',
      require: 'undefined',
      worker: 'undefined',
      env: 'blocked',
      token: 'blocked',
      escape: 'blocked',
    })
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
})

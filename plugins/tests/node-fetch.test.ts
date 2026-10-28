// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import http from 'node:http'
import { createRequire } from 'node:module'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, before, test } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { gzipSync } from 'node:zlib'
import { toolCallStorage } from '../exec-bridge/src/call-context.ts'
import { installNodeFetch } from '../llm-bridge/src/install.ts'
import { createNodeFetch } from '../llm-bridge/src/node-fetch.ts'

const here = dirname(fileURLToPath(import.meta.url))
let base = ''
const seen: http.IncomingHttpHeaders[] = []
const server = http.createServer((req, res) => {
  seen.push(req.headers)
  const chunks: Buffer[] = []
  req.on('data', (c: Buffer) => chunks.push(c))
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString()
    switch (req.url) {
      case '/sse':
        res.writeHead(200, { 'content-type': 'text/event-stream' })
        res.write('data: one\n\n')
        setTimeout(() => { res.end('data: two\n\n') }, 30)
        return
      case '/gzip':
        res.writeHead(200, { 'content-encoding': 'gzip', 'content-type': 'text/plain' })
        res.end(gzipSync('compressed hello'))
        return
      case '/echo':
        res.writeHead(201, { 'content-type': 'application/json', 'x-multi': 'a' })
        res.end(JSON.stringify({ method: req.method, body }))
        return
      case '/redirect':
        res.writeHead(302, { location: '/echo' })
        res.end()
        return
      case '/hang':
        res.writeHead(200)
        res.write('partial')
        return
      case '/v1/http':
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ proxied: true, target: req.headers['x-pdsh-target-url'], method: req.headers['x-pdsh-target-method'], body }))
        return
      default:
        res.writeHead(404)
        res.end()
    }
  })
})

before(async () => {
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})
after(() => { server.closeAllConnections(); server.close() })

const nodeFetch = createNodeFetch()

test('streams a response body incrementally', async () => {
  const response = await nodeFetch(`${base}/sse`)
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('content-type'), 'text/event-stream')
  const reader = (response.body as ReadableStream<Uint8Array>).getReader()
  const first = await reader.read()
  assert.equal(new TextDecoder().decode(first.value), 'data: one\n\n')
  let rest = ''
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    rest += new TextDecoder().decode(value)
  }
  assert.equal(rest, 'data: two\n\n')
})

test('decodes gzip, posts bodies, follows redirects, keeps status and url', async () => {
  assert.equal(await (await nodeFetch(`${base}/gzip`)).text(), 'compressed hello')
  const posted = await nodeFetch(`${base}/echo`, { method: 'POST', body: '{"x":1}', headers: { 'content-type': 'application/json' } })
  assert.equal(posted.status, 201)
  assert.deepEqual(await posted.json(), { method: 'POST', body: '{"x":1}' })
  const redirected = await nodeFetch(`${base}/redirect`, { method: 'POST', body: 'gone' })
  assert.equal(redirected.redirected, true)
  assert.equal(redirected.url, `${base}/echo`)
  assert.deepEqual(await redirected.json(), { method: 'GET', body: '' })
  await assert.rejects(nodeFetch(`${base}/redirect`, { redirect: 'error' }), /fetch failed/)
})

test('abort before and during the body', async () => {
  const controller = new AbortController()
  const response = await nodeFetch(`${base}/hang`, { signal: controller.signal })
  const reader = (response.body as ReadableStream<Uint8Array>).getReader()
  await reader.read()
  controller.abort(new Error('stop reading'))
  await assert.rejects(reader.read())
  await assert.rejects(nodeFetch(`${base}/echo`, { signal: AbortSignal.abort(new Error('pre-aborted')) }), /pre-aborted/)
})

test('connection failures look like undici\'s "fetch failed"', async () => {
  await assert.rejects(nodeFetch('http://127.0.0.1:1/'), (error: unknown) => error instanceof TypeError && error.message === 'fetch failed')
})

test('host proxy route rewrites the request and moves upstream authorization', async () => {
  const proxied = createNodeFetch({ proxy: { url: base, token: 'bridge-token-0123456789', match: () => true } })
  const response = await proxied('https://model.example/v1/messages', { method: 'POST', body: 'payload', headers: { authorization: 'Bearer upstream' } })
  assert.deepEqual(await response.json(), { proxied: true, target: 'https://model.example/v1/messages', method: 'POST', body: 'payload' })
  const headers = seen.at(-1) as http.IncomingHttpHeaders
  assert.equal(headers.authorization, 'Bearer bridge-token-0123456789')
  assert.equal(headers['x-pdsh-upstream-authorization'], 'Bearer upstream')
})

test('the installed fetch adds the idempotency key inside a tool call, only for loopback / host routes', async () => {
  const restore = installNodeFetch({ mode: 'always' })
  try {
    await (await fetch(`${base}/echo`)).text()
    assert.equal(seen.at(-1)?.['x-pdsh-idempotency-key'], undefined)
    await toolCallStorage().run({ sessionId: 's', callId: 'c', key: 'xl1-test-key', spawns: 0 }, async () => {
      await (await fetch(`${base}/echo`)).text()
    })
    assert.equal(seen.at(-1)?.['x-pdsh-idempotency-key'], 'xl1-test-key')
  } finally {
    restore()
  }
})

test('under --jitless native fetch fails on WebAssembly and the node:http fetch works', async () => {
  // Type stripping itself needs WebAssembly, so the jitless child runs an esbuild bundle of the module.
  const esbuild = await import('esbuild')
  const dir = mkdtempSync(join(tmpdir(), 'pdsh-jitless-'))
  const runJitless = async (file: string, preload?: string): Promise<{ code: number, stdout: string, stderr: string }> => {
    const args = ['--jitless', ...preload === undefined ? [] : ['--import', preload], file]
    try {
      const { stdout, stderr } = await promisify(execFile)(process.execPath, args, { encoding: 'utf8', timeout: 30_000 })
      return { code: 0, stdout, stderr }
    } catch (error) {
      const failure = error as { code?: number | string, stdout?: string, stderr?: string, message?: string }
      return {
        code: typeof failure.code === 'number' ? failure.code : 1,
        stdout: failure.stdout ?? '',
        stderr: failure.stderr ?? failure.message ?? '',
      }
    }
  }
  try {
    const lib = join(dir, 'node-fetch.mjs')
    esbuild.buildSync({ entryPoints: [join(here, '../llm-bridge/src/node-fetch.ts')], bundle: true, platform: 'node', format: 'esm', outfile: lib })

    // Probe 1, native failure only. Node 22's undici parser initializes
    // asynchronously and dies on the missing WebAssembly before the fetch
    // promise settles; Node 25 catches the same cause and rejects instead. No
    // owned-fetch code is imported here, so neither shape can abort probe 2.
    const nativeScript = join(dir, 'native-probe.mjs')
    writeFileSync(nativeScript, `
      console.log(JSON.stringify({ wasm: typeof WebAssembly, probe: 'native' }))
      try {
        const response = await fetch(${JSON.stringify(`${base}/gzip`)})
        console.log(JSON.stringify({ native: 'ok', body: await response.text() }))
      } catch (error) {
        console.log(JSON.stringify({ native: 'error', message: String(error?.cause?.message ?? error?.message ?? error) }))
      }
    `)
    const native = await runJitless(nativeScript)
    const nativeLines = native.stdout.trim().split('\n')
    assert.ok(nativeLines[0], native.stdout)
    const nativeStart = JSON.parse(nativeLines[0])
    assert.equal(nativeStart.wasm, 'undefined')
    assert.equal(nativeStart.probe, 'native')
    if (native.code === 0) {
      // Node 25 rejects with the WebAssembly cause; a future runtime whose
      // native fetch does not need the parser is allowed to succeed.
      assert.ok(nativeLines[1], native.stdout)
      const nativeDone = JSON.parse(nativeLines[1])
      if (nativeDone.native === 'ok') {
        assert.equal(nativeDone.body, 'compressed hello')
      } else {
        assert.equal(nativeDone.native, 'error')
        assert.match(nativeDone.message, /WebAssembly/)
      }
    } else {
      assert.match(native.stderr, /WebAssembly/, 'native fetch must fail on the missing WebAssembly parser')
    }

    // Node 22's built-in WHATWG classes and node:http's lazy WebSocket getters
    // both pull in undici's WASM llhttp parser as a module side effect, even
    // though this transport only uses node:http. The preload installs the
    // WHATWG implementation already present in the lockfile (undici) and
    // defuses those unrelated getters. It does not fake WebAssembly, handle
    // unhandled rejections or exit early: the process stays wasm-less and the
    // HTTP response below is real.
    const undiciUrl = pathToFileURL(createRequire(import.meta.url).resolve('undici')).href
    const preload = join(dir, 'whatwg-preload.mjs')
    writeFileSync(preload, `
      import { createRequire } from 'node:module'
      import undici from ${JSON.stringify(undiciUrl)}
      for (const name of ['Headers', 'Request', 'Response', 'FormData']) {
        if (undici[name] !== undefined) globalThis[name] = undici[name]
      }
      const require = createRequire(import.meta.url)
      for (const id of ['node:http', 'node:https']) {
        const module = require(id)
        for (const name of ['WebSocket', 'CloseEvent', 'MessageEvent']) {
          if (Object.getOwnPropertyDescriptor(module, name)?.get !== undefined) {
            Object.defineProperty(module, name, { value: undefined, configurable: true, enumerable: true, writable: true })
          }
        }
      }
    `)

    // Probe 2, owned transport in its own jitless process: importing the
    // bundle and calling createNodeFetch must not touch native fetch at all.
    const script = join(dir, 'probe.mjs')
    writeFileSync(script, `
      import { createNodeFetch } from ${JSON.stringify(lib)}
      const out = { wasm: typeof WebAssembly, probe: 'owned' }
      try {
        const response = await createNodeFetch()(${JSON.stringify(`${base}/gzip`)})
        out.status = response.status
        out.node = await response.text()
      } catch (error) {
        out.error = String(error?.stack ?? error)
      }
      console.log(JSON.stringify(out))
    `)
    const child = await runJitless(script, preload)
    assert.equal(child.code, 0, `${child.stdout}\n${child.stderr}`)
    const out = JSON.parse(child.stdout)
    assert.equal(out.wasm, 'undefined')
    assert.equal(out.probe, 'owned')
    assert.equal(out.error, undefined)
    assert.equal(out.status, 200)
    assert.equal(out.node, 'compressed hello')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

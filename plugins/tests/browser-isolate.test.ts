// SPDX-License-Identifier: MIT
/**
 * Real-browser Worker gate for the workflow isolate.
 *
 * Node's `worker_threads` harness (and the browser-port fixture) exercise the
 * message protocol, but they are not a browser: a module Worker that kept a
 * `node:` import or a lazy `postMessage` lookup can still pass under Node. This
 * test loads the production `workflow-isolate.js` in Chromium, runs a standard
 * workflow through the real Worker transport, then proves a synchronous loop
 * is stopped by the QuickJS realm and the next workflow still completes.
 *
 * It is skipped unless `PDSH_CHROMIUM` points at a Chrome/Chromium binary:
 * Playwright's browser download is deliberately not part of `npm ci`, and the
 * authoritative iOS/JavaScriptCore gate remains the Mac simulator run.
 *
 *   PDSH_DSH_CHECKOUT=<checkout> PDSH_CHROMIUM=/path/to/chrome \
 *     node --test tests/browser-isolate.test.ts
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const chromiumPath = process.env.PDSH_CHROMIUM
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the isolate must be built from the pinned checkout'
  : chromiumPath === undefined || chromiumPath === ''
    ? 'PDSH_CHROMIUM is unset; install Chrome/Chromium or run the Mac WKWebView gate'
    : false

interface RunOutcome {
  done?: { value?: unknown; stopReason?: string; error?: string }
  fatal?: string
  workerError?: string
  log: string[]
}

interface PageOutcome {
  normal: RunOutcome
  loop: RunOutcome
  after: RunOutcome
}

const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

test('the production isolate runs in a real browser Worker and hard-stops a sync loop', {
  skip,
  timeout: 120_000,
}, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-browser-isolate-'))
  scratch.push(directory)
  const workerOut = join(directory, 'worker')
  const build = spawnSync(process.execPath, [join(root, 'worker-entry', 'build.mjs'), '--out', workerOut], {
    cwd: root,
    env: { ...process.env, PDSH_DSH_CHECKOUT: checkout },
    encoding: 'utf8',
  })
  assert.equal(build.status, 0, `worker-entry build failed:\n${build.stdout}\n${build.stderr}`)

  const page = readFileSync(join(here, 'fixtures', 'browser-isolate-page.html'))
  const isolate = readFileSync(join(workerOut, 'workflow-isolate.js'))
  let isolateMap: Buffer | undefined
  try {
    isolateMap = readFileSync(join(workerOut, 'workflow-isolate.js.map'))
  } catch {
    isolateMap = undefined
  }
  const server = createServer((request, response) => {
    const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
    if (pathname === '/') {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
      response.end(page)
      return
    }
    if (pathname === '/workflow-isolate.js') {
      response.writeHead(200, {
        'content-type': 'text/javascript; charset=utf-8',
        'content-length': String(isolate.byteLength),
      })
      response.end(isolate)
      return
    }
    if (pathname === '/workflow-isolate.js.map' && isolateMap !== undefined) {
      response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
      response.end(isolateMap)
      return
    }
    if (pathname === '/favicon.ico') {
      response.writeHead(204)
      response.end()
      return
    }
    response.writeHead(404)
    response.end()
  })
  await new Promise<void>((resolveListen, rejectListen) => {
    server.once('error', rejectListen)
    server.listen(0, '127.0.0.1', resolveListen)
  })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('browser isolate server has no port')
  try {
    const { chromium } = await import('playwright-core')
    const browser = await chromium.launch({
      executablePath: chromiumPath,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    })
    try {
      const tab = await browser.newPage()
      const failures: string[] = []
      tab.on('pageerror', error => { failures.push(error.stack ?? error.message) })
      tab.on('console', (message) => {
        if (message.type() === 'error') failures.push(message.text())
      })
      await tab.goto(`http://127.0.0.1:${String(address.port)}/`)
      await tab.waitForFunction(() => document.title === 'done', null, { timeout: 60_000 })
      const outcome = await tab.evaluate(() => (window as unknown as { __RESULT__: PageOutcome }).__RESULT__)
      assert.deepEqual(failures, [], `the browser page raised errors:\n${failures.join('\n')}`)
      assert.equal(outcome.normal.done?.stopReason, 'completed', outcome.normal.done?.error ?? outcome.normal.fatal)
      assert.deepEqual(outcome.normal.done?.value, {
        child: 'BROWSER_CHILD_OK',
        fetchType: 'undefined',
        processType: 'undefined',
        eventSourceType: 'undefined',
        webTransportType: 'undefined',
        workerType: 'undefined',
        importBlocked: 'blocked',
        hostSentinel: 'undefined',
      })
      assert.equal(outcome.loop.done?.stopReason, 'error')
      assert.match(outcome.loop.done?.error ?? '', /synchronous execution budget.*isolated realm/u)
      assert.equal(outcome.after.done?.stopReason, 'completed', outcome.after.done?.error ?? outcome.after.fatal)
      assert.equal(outcome.after.done?.value, 'AFTER_LOOP')
      assert.ok(outcome.normal.log.includes('ready'))
      assert.ok(outcome.normal.log.includes('child-start'))
    } finally {
      await browser.close()
    }
  } finally {
    await new Promise<void>(resolveClose => { server.close(() => resolveClose()) })
  }
})

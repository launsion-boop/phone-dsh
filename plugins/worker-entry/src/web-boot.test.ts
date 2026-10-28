// SPDX-License-Identifier: MIT
/**
 * Protocol tests for the full Web page boot.
 *
 * These run the real page-side `WorkerTunnel` and `applyIndexInjections` from
 * the pinned DSH checkout against a postMessage peer that answers the tunnel's
 * `/__boot__` request. The peer is only the wire counterpart: the init frame,
 * the tunnel request, the transport globals and the injection interpreter are
 * the production modules. A missing checkout (or a Node without synchronous
 * module hooks) skips; the built bundle is covered by `build.mjs --check`.
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { test } from 'node:test'
import { promiseWithResolvers } from './promise-compat.ts'

const HERE = dirname(fileURLToPath(import.meta.url))
const CLIENT_EXPORT = '@deepseek-ai/dsh-experimental-webworker-runtime/client'
const CLIENT_INJECTIONS = '@deepseek-ai/dsh-client-web/injections'

interface TestHistory {
  readonly state?: unknown
  replaceState(data: unknown, unused: string, url?: string | URL | null): void
}

interface WebBootModule {
  readBootQuery(search: string, href: string): {
    image: string
    overlays: readonly string[]
    xl: Record<string, unknown>
  }
  bootInitFrame(query: {
    image: string
    overlays: readonly string[]
    xl: Record<string, unknown>
  }): {
    t: 'init'
    image: string
    overlays: readonly string[]
    xl: Record<string, unknown>
  }
  installTunnelTransport(tunnel: unknown): void
  showBootFailure(reason: unknown): void
  stripBootTransportParams(href: string): string | undefined
  scrubBootLocation(options: { href?: string; history?: TestHistory }): boolean
  redactBootFailureDetail(reason: unknown, secrets?: readonly string[]): string
  isEmbeddedAppPage(globals?: Record<string, unknown>): boolean
  installEmbeddedAppPreferences(globals?: Record<string, unknown>): boolean
  connectWebWorker(options: {
    search?: string
    href?: string
    worker?: Worker
    onFailure?: (reason: unknown) => void
    history?: TestHistory
    timeoutMs?: number
  }): Promise<void>
}

interface BootGlobals {
  __DSH_BOOT_READY__?: PromiseWithResolvers<void>
  __DSH_TRANSPORT__?: {
    ownsHost?: boolean
    fetch?: unknown
    openStream?: unknown
    loadBundle?: unknown
  }
  __DSH_FILE_UPLOAD__?: { fetch?: unknown }
  __PDH_TEST_INJECTION__?: unknown
  __PDH_LATE_INJECTION__?: unknown
  location?: { origin: string; href: string }
}

function readCheckout(): string | undefined {
  const fromEnv = process.env.PDSH_DSH_CHECKOUT
  if (fromEnv !== undefined && fromEnv !== '') return fromEnv
  try {
    const line = readFileSync(join(homedir(), '.config/phone-dsh/dsh-checkout'), 'utf8').trim()
    if (line !== '') return line
  } catch {
    // fall through to the designated reference checkout
  }
  return existsSync('/dsh-reference/.git') ? '/dsh-reference' : undefined
}

const checkout = readCheckout()
const runtimeClient = checkout === undefined
  ? undefined
  : join(checkout, 'packages/experimental/webworker-runtime/src/client/index.ts')
const clientInjections = checkout === undefined
  ? undefined
  : join(checkout, 'packages/client/web/src/apply-injections.ts')
const hooksAvailable = typeof registerHooks === 'function'

let webBoot: Promise<WebBootModule> | undefined

function loadWebBoot(): Promise<WebBootModule> {
  if (webBoot !== undefined) return webBoot
  if (!hooksAvailable || runtimeClient === undefined || clientInjections === undefined
      || !existsSync(runtimeClient) || !existsSync(clientInjections)) {
    throw new Error('pinned checkout is not available')
  }
  registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === CLIENT_EXPORT) {
        return { url: pathToFileURL(runtimeClient).href, shortCircuit: true }
      }
      if (specifier === CLIENT_INJECTIONS) {
        return { url: pathToFileURL(clientInjections).href, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    },
  })
  webBoot = import('./web-boot.ts') as Promise<WebBootModule>
  return webBoot
}

/** One postMessage peer that answers the tunnel boot request. */
class TunnelPeer extends EventTarget {
  readonly posted: unknown[] = []
  private readonly boot: { body: string; status: number; message?: string }
  private readonly onBoot: ((peer: TunnelPeer) => void) | undefined

  constructor(
    boot: { body: string; status: number; message?: string },
    onBoot?: (peer: TunnelPeer) => void,
  ) {
    super()
    this.boot = boot
    this.onBoot = onBoot
  }

  /** Deliver one unsolicited Worker frame to the page listeners. */
  emit(data: unknown): void {
    this.dispatchEvent(new MessageEvent('message', { data }))
  }

  postMessage(message: unknown): void {
    this.posted.push(message)
    const frame = message as { t?: unknown; id?: unknown; url?: unknown }
    if (frame.t !== 'req' || typeof frame.id === 'undefined') return
    const url = String(frame.url)
    if (!url.endsWith('/__boot__')) return
    const id = frame.id
    queueMicrotask(() => {
      if (this.onBoot !== undefined) {
        this.onBoot(this)
        return
      }
      const body = new TextEncoder().encode(this.boot.body).buffer
      this.dispatchEvent(new MessageEvent('message', {
        data: {
          t: 'res', id, status: this.boot.status, headers: {}, body,
          ...this.boot.message === undefined ? {} : { message: this.boot.message },
        },
      }))
    })
  }
}

/** Peer that never answers `/__boot__`, modelling a Worker without a host. */
class SilentPeer extends EventTarget {
  readonly posted: unknown[] = []

  postMessage(message: unknown): void {
    this.posted.push(message)
  }

  emit(data: unknown): void {
    this.dispatchEvent(new MessageEvent('message', { data }))
  }
}

function withPageLocation<T>(href: string, run: () => Promise<T>): Promise<T> {
  const globals = globalThis as BootGlobals
  const previous = globals.location
  globals.location = { origin: new URL(href).origin, href }
  return run().finally(() => {
    globals.location = previous
  })
}

function clearBootGlobals(): void {
  const globals = globalThis as BootGlobals
  delete globals.__DSH_BOOT_READY__
  delete globals.__DSH_TRANSPORT__
  delete globals.__DSH_FILE_UPLOAD__
  delete globals.__PDH_TEST_INJECTION__
  delete globals.__PDH_LATE_INJECTION__
}

/**
 * Compile the exact ready regex the native observability bridge installs.
 *
 * The Worker and page are different processes/languages, so the contract is
 * the rendered title text: read the bridge's own regex rather than copying a
 * second copy of the alternatives into this test.
 */
function nativeReadyRegex(): RegExp {
  const source = readFileSync(
    join(HERE, '..', '..', '..', 'Sources', 'PhoneDSHEngine', 'WebEngineScripts.swift'),
    'utf8',
  )
  const marker = /if \(\/(DSH ready\|worker ready\|worker is ready)\/i\.test\(text\)\)/.exec(source)
  assert.notEqual(marker, null, 'WebEngineScripts still has a ready regex the boot signal can satisfy')
  return new RegExp(marker![1]!, 'i')
}

test('readBootQuery carries every init field and resolves the channel scheme', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
  const search = [
    '?image=%2Fimage%2Fbase',
    '&channel=%2Fchannel',
    '&token=launch-token',
    '&overlay=a.tar.gz',
    '&overlay%5B%5D=b.tar.gz',
    '&fence=%7B%22owner%22%3A%22phone%22%2C%22generation%22%3A4%2C%22wal_seq%22%3A9%7D',
    '&env=%7B%22PDSH_SANDBOX_MODE%22%3A%22read-only%22%7D',
    '&egress=%5B%22api.example.invalid%22%5D',
    '&boot_id=0123456789abcdef0123456789abcdef',
    '&session_epoch=4',
  ].join('')
  const query = boot.readBootQuery(search, href)
  assert.equal(query.image, '/image/base')
  assert.deepEqual(query.overlays, ['a.tar.gz', 'b.tar.gz'])
  assert.deepEqual(query.xl, {
    channelURL: 'ws://127.0.0.1:7411/channel',
    token: 'launch-token',
    env: { PDSH_SANDBOX_MODE: 'read-only' },
    fence: { owner: 'phone', generation: 4, wal_seq: 9 },
    bootId: '0123456789abcdef0123456789abcdef',
    sessionEpoch: '4',
    egressAllow: ['api.example.invalid'],
  })
  assert.deepEqual(boot.bootInitFrame(query), { t: 'init', ...query })

  const defaults = boot.readBootQuery('?image=x&channel=https%3A%2F%2F127.0.0.1%2Fchannel', href)
  assert.equal(defaults.xl['channelURL'], 'wss://127.0.0.1/channel')
  assert.equal(defaults.xl['token'], '')
  assert.deepEqual(defaults.xl['fence'], { owner: 'phone', generation: 0, wal_seq: 0 })
  assert.deepEqual(defaults.xl['env'], {})
  assert.equal('bootId' in defaults.xl, false)
  assert.equal('sessionEpoch' in defaults.xl, false)
  assert.equal('egressAllow' in defaults.xl, false)

  assert.throws(() => boot.readBootQuery('?channel=/channel', href), /\?image=/)
  assert.throws(() => boot.readBootQuery('?image=x', href), /\?channel=/)
  assert.throws(() => boot.readBootQuery('?image=x&channel=/c&fence=%7B', href), /fence/)
})

test('stripBootTransportParams keeps business query and hash only', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const transport = [
    ['image', '%2Fimage%2Fbase'],
    ['channel', '%2Fchannel'],
    ['channelURL', '%2Fchannel-alias'],
    ['token', 'launch-token'],
    ['overlay', 'a.tar.gz'],
    ['overlay%5B%5D', 'b.tar.gz'],
    ['fence', '%7B%22owner%22%3A%22phone%22%7D'],
    ['env', '%7B%22PDSH_LAUNCH_TOKEN%22%3A%22secret%22%7D'],
    ['egress', '%5B%22api.example.invalid%22%5D'],
    ['egress_allow', '%5B%22alias.example.invalid%22%5D'],
    ['boot_id', '0123456789abcdef0123456789abcdef'],
    ['session_epoch', '4'],
  ].map(([name, value]) => `${name}=${value}`).join('&')
  const href = `http://127.0.0.1:7411/static/web/index.html?keep=one&${transport}&filter=a+b&empty=#conversation/42`

  const stripped = boot.stripBootTransportParams(href)
  assert.notEqual(stripped, undefined)
  const visible = new URL(stripped!)
  assert.equal(visible.pathname, '/static/web/index.html')
  assert.deepEqual([...visible.searchParams.keys()], ['keep', 'filter', 'empty'])
  assert.equal(visible.searchParams.get('keep'), 'one')
  assert.equal(visible.searchParams.get('filter'), 'a b')
  assert.equal(visible.searchParams.get('empty'), '')
  assert.equal(visible.hash, '#conversation/42')
  assert.match(href, /token=launch-token/, 'the in-memory source URL is what the caller captures')

  assert.equal(boot.stripBootTransportParams('http://127.0.0.1/static/web/index.html?keep=1#x'), undefined)
  assert.equal(boot.stripBootTransportParams('not a url'), undefined)
})

test('scrubBootLocation preserves history state and never stores boot config', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const calls: { data: unknown; unused: string; url: string }[] = []
  const state = { route: 'conversation' }
  const history: TestHistory = {
    state,
    replaceState(data, unused, url) {
      calls.push({ data, unused, url: String(url) })
    },
  }
  const href = 'http://127.0.0.1:7411/static/web/index.html?token=launch-token&image=%2Fimage%2Fbase&keep=one#chat'
  assert.equal(boot.scrubBootLocation({ href, history }), true)
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.data, state, 'the existing history state is kept, not replaced with boot config')
  assert.equal(calls[0]?.unused, '')
  const visible = new URL(calls[0]!.url)
  assert.equal(visible.searchParams.get('keep'), 'one')
  assert.equal(visible.hash, '#chat')
  assert.equal(visible.searchParams.has('token'), false)
  assert.equal(visible.searchParams.has('image'), false)

  const denied: TestHistory = {
    replaceState() { throw new Error('denied') },
  }
  assert.equal(boot.scrubBootLocation({ href, history: denied }), false,
    'a denied replaceState does not throw into the boot path')
})

test('promiseWithResolvers fallback resolves and rejects without the platform method', async () => {
  const resolved = promiseWithResolvers<number>({})
  resolved.resolve(7)
  assert.equal(await resolved.promise, 7)

  const rejected = promiseWithResolvers<number>({})
  const failure = new Error('fallback rejects')
  rejected.reject(failure)
  await assert.rejects(rejected.promise, /fallback rejects/)
})

test('redactBootFailureDetail bounds and redacts transport secrets', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const detail = boot.redactBootFailureDetail(new Error(
    'GET http://127.0.0.1:7411/static/web/index.html'
    + '?token=launch-token&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&overlay=a.tar.gz&fence=%7B%22owner%22%3A%22phone%22%7D'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22secret%22%7D'
    + '&egress=%5B%22api.example.invalid%22%5D&keep=one#chat failed',
  ))
  assert.doesNotMatch(detail, /launch-token|secret|%2Fimage%2Fbase|api\.example\.invalid/)
  assert.match(detail, /\[redacted\]/)
  assert.match(detail, /keep=one/)
  assert.match(detail, /failed/, 'the useful diagnostic survives')

  const json = boot.redactBootFailureDetail(new Error(
    '{"token":"launch-token","env":{"PDSH_LAUNCH_TOKEN":"secret"},"fence":{"owner":"phone"},"keep":1}',
  ))
  assert.doesNotMatch(json, /launch-token|secret/)
  assert.match(json, /\[redacted\]/)

  // A raw (un-encoded) query object must be swallowed whole, not rewritten as
  // `env=[redacted]{"PDSH_LAUNCH_TOKEN":"secret"}` by the generic query rule.
  const rawObject = boot.redactBootFailureDetail(new Error(
    'GET ?env={"PDSH_LAUNCH_TOKEN":"secret"}&fence={"owner":"phone"}'
    + '&egress=["api.example.invalid"]&keep=one failed',
  ))
  assert.doesNotMatch(rawObject, /PDSH_LAUNCH_TOKEN|secret|owner|phone|api\.example\.invalid/)
  assert.equal(rawObject.match(/\[redacted\]/g)?.length, 3)
  assert.match(rawObject, /keep=one/)
  assert.match(rawObject, /failed/)

  const valueOnly = boot.redactBootFailureDetail(
    new Error('handshake body repeated SECRET-TOKEN and SECRET-ENV without a field name'),
    ['SECRET-TOKEN', 'SECRET-ENV'],
  )
  assert.doesNotMatch(valueOnly, /SECRET-TOKEN|SECRET-ENV/)
  assert.match(valueOnly, /\[redacted\]/)
  assert.match(valueOnly, /handshake body repeated/)

  const long = boot.redactBootFailureDetail('x'.repeat(1000))
  assert.ok(long.length <= 321, `detail must be bounded, got ${long.length}`)
  assert.ok(long.endsWith('…'))
  assert.equal(boot.redactBootFailureDetail(Object.create(null)), 'unknown error')
})

test('showBootFailure paints user copy plus a redacted detail, never the raw URL', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const panel = {
    dataset: {} as Record<string, string>,
    style: { cssText: '' },
    textContent: '',
    setAttribute(_name: string, _value: string) {},
  }
  const appended: typeof panel[] = []
  const fakeDocument = {
    title: '',
    querySelector(_selector: string) { return null },
    createElement(_tag: string) { return panel },
    body: { append(node: typeof panel) { appended.push(node) } },
  }
  const globals = globalThis as unknown as { document?: unknown }
  const previous = Object.getOwnPropertyDescriptor(globals, 'document')
  Object.defineProperty(globals, 'document', { value: fakeDocument, configurable: true })
  try {
    boot.showBootFailure(new Error(
      'GET http://127.0.0.1:7411/static/web/index.html?token=launch-token'
      + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22secret%22%7D&keep=one failed',
    ))
    assert.equal(fakeDocument.title, 'DSH boot failed')
    assert.equal(appended.length, 1)
    assert.match(panel.textContent, /DSH boot failed\. Please go back and try again\./)
    assert.match(panel.textContent, /Technical detail:/)
    assert.match(panel.textContent, /\[redacted\]/)
    assert.doesNotMatch(panel.textContent, /launch-token|secret|PDSH_LAUNCH_TOKEN/)
  } finally {
    if (previous === undefined) delete globals.document
    else Object.defineProperty(globals, 'document', previous)
  }
})

test('connectWebWorker installs the tunnel transport and applies injections', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=launch-token&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&fence=%7B%22owner%22%3A%22phone%22%2C%22generation%22%3A4%2C%22wal_seq%22%3A9%7D'
    + '&env=%7B%22PDSH_SANDBOX_MODE%22%3A%22read-only%22%7D'
    + '&keep=business#conversation'
  const historyCalls: { state: unknown; url: string }[] = []
  const history: TestHistory = {
    state: { route: 'conversation' },
    replaceState(state, _unused, url) {
      historyCalls.push({ state, url: String(url) })
    },
  }
  const peer = new TunnelPeer({
    status: 200,
    body: JSON.stringify({
      injections: [{ kind: 'global', name: '__PDH_TEST_INJECTION__', value: 'applied' }],
    }),
  })
  try {
    await withPageLocation(href, () => boot.connectWebWorker({
      href,
      search: new URL(href).search,
      worker: peer as unknown as Worker,
      history,
    }))
    const globals = globalThis as BootGlobals
    const init = peer.posted[0] as {
      t: string
      image: string
      overlays: readonly string[]
      xl: Record<string, unknown>
    }
    assert.equal(init.t, 'init')
    assert.equal(init.image, '/image/base')
    assert.deepEqual(init.overlays, [])
    assert.equal(init.xl['channelURL'], 'ws://127.0.0.1:7411/channel')
    assert.equal(init.xl['token'], 'launch-token')
    assert.deepEqual(init.xl['env'], { PDSH_SANDBOX_MODE: 'read-only' })
    assert.equal(historyCalls.length, 1)
    assert.equal(historyCalls[0]?.state, history.state)
    const visible = new URL(historyCalls[0]!.url)
    assert.equal(visible.searchParams.get('keep'), 'business')
    assert.equal(visible.hash, '#conversation')
    for (const name of ['token', 'image', 'channel', 'fence', 'env']) {
      assert.equal(visible.searchParams.has(name), false, `the visible URL must not keep ${name}`)
    }
    assert.equal(globals.__DSH_TRANSPORT__?.ownsHost, true)
    assert.equal(typeof globals.__DSH_TRANSPORT__?.fetch, 'function')
    assert.equal(typeof globals.__DSH_TRANSPORT__?.openStream, 'function')
    assert.equal(typeof globals.__DSH_TRANSPORT__?.loadBundle, 'function')
    assert.equal(typeof globals.__DSH_FILE_UPLOAD__?.fetch, 'function')
    assert.equal(globals.__PDH_TEST_INJECTION__, 'applied')
    await globals.__DSH_BOOT_READY__?.promise
  } finally {
    clearBootGlobals()
  }
})

test('complete Web boot publishes the title the native ready regex recognizes', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html?image=x&channel=%2Fchannel'
  const peer = new TunnelPeer({
    status: 200,
    body: JSON.stringify({
      injections: [{ kind: 'global', name: '__PDH_TEST_INJECTION__', value: 'applied' }],
    }),
  })
  const fakeDocument = { title: 'DSH Local Build' }
  const globals = globalThis as unknown as { document?: unknown }
  const previous = Object.getOwnPropertyDescriptor(globals, 'document')
  Object.defineProperty(globals, 'document', { value: fakeDocument, configurable: true })
  try {
    await withPageLocation(href, () => boot.connectWebWorker({
      href,
      search: new URL(href).search,
      worker: peer as unknown as Worker,
    }))
    assert.equal(fakeDocument.title, 'DSH ready')
    assert.equal(
      nativeReadyRegex().test(fakeDocument.title),
      true,
      'the native bridge must see the full Web ready state instead of waiting for bootTimeout',
    )
    await (globalThis as BootGlobals).__DSH_BOOT_READY__?.promise
  } finally {
    if (previous === undefined) delete globals.document
    else Object.defineProperty(globals, 'document', previous)
    clearBootGlobals()
  }
})

test('pdsh-ready after /__boot__ never reaches the real WorkerTunnel', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  if (process.hasUncaughtExceptionCaptureCallback()) {
    t.skip('another uncaught-exception capture is installed')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html?image=x&channel=%2Fchannel'
  const peer = new TunnelPeer({
    status: 200,
    body: JSON.stringify({ injections: [] }),
  })
  const uncaught: unknown[] = []
  process.setUncaughtExceptionCaptureCallback((error) => { uncaught.push(error) })
  try {
    await withPageLocation(href, () => boot.connectWebWorker({
      href,
      search: new URL(href).search,
      worker: peer as unknown as Worker,
    }))
    // entry.ts posts this after a successful host boot. The boot listener has
    // already succeeded, so the tunnel's own listener is the only remaining
    // consumer; the control-frame filter must stay ahead of it.
    peer.emit({ t: 'pdsh-ready' })
    await new Promise<void>((resolve) => { setTimeout(resolve, 25) })
    assert.deepEqual(
      uncaught.map(error => String(error)),
      [],
      'pdsh-ready must not reach WorkerTunnel.receive and throw unknown frame',
    )
  } finally {
    process.setUncaughtExceptionCaptureCallback(null)
    clearBootGlobals()
  }
})

test('the boot deadline covers script-src loading and stops later injections', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html?image=x&channel=%2Fchannel'
  const peer = new TunnelPeer({
    status: 200,
    body: JSON.stringify({
      injections: [
        // The peer answers /__boot__ but never answers this bundle request.
        { kind: 'script-src', src: '/never-answers.js' },
        { kind: 'global', name: '__PDH_LATE_INJECTION__', value: 'applied' },
      ],
    }),
  })
  try {
    const result = await withPageLocation(href, () => Promise.race([
      boot.connectWebWorker({
        href,
        search: new URL(href).search,
        worker: peer as unknown as Worker,
        timeoutMs: 100,
      }).then(
        () => ({ state: 'resolved' as const }),
        (error: unknown) => ({ state: 'rejected' as const, error }),
      ),
      new Promise<{ state: 'pending' }>((resolve) => {
        setTimeout(() => { resolve({ state: 'pending' }) }, 1_000)
      }),
    ]))
    assert.equal(result.state, 'rejected', 'a silent bundle cannot leave the ready gate pending')
    if (result.state !== 'rejected') return
    assert.match(String(result.error), /no ready signal after 100 ms/)
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, /no ready signal after 100 ms/)
    assert.equal(
      (globalThis as BootGlobals).__PDH_LATE_INJECTION__,
      undefined,
      'injection rows after the timed-out script-src must not run',
    )
  } finally {
    clearBootGlobals()
  }
})

test('a script-src bundle refusal settles readiness and redacts the console', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=SECRET-TOKEN&image=%2Fimage%2Fbase&channel=%2Fchannel'
  class BundleRefusalPeer extends TunnelPeer {
    override postMessage(message: unknown): void {
      super.postMessage(message)
      const frame = message as { t?: unknown; id?: unknown; url?: unknown }
      if (frame.t !== 'req' || !String(frame.url).endsWith('/bundle.js')) return
      queueMicrotask(() => {
        this.emit({
          t: 'res',
          id: frame.id,
          status: 503,
          headers: {},
          body: new TextEncoder().encode('bundle unavailable').buffer,
          message: 'bundle fetch failed for ?token=SECRET-TOKEN',
        })
      })
    }
  }
  const peer = new BundleRefusalPeer({
    status: 200,
    body: JSON.stringify({
      injections: [{ kind: 'script-src', src: '/bundle.js' }],
    }),
  })
  const warnings: string[] = []
  const originalWarn = console.warn
  console.warn = (...args: unknown[]) => { warnings.push(args.map(value => String(value)).join(' ')) }
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          worker: peer as unknown as Worker,
          timeoutMs: 1_000,
        }),
        (error: unknown) => {
          const message = error instanceof Error ? error.message : String(error)
          assert.match(message, /bundle.*503/)
          assert.doesNotMatch(message, /SECRET-TOKEN/)
          return true
        },
      )
    })
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, /bundle.*503/)
    const warningText = warnings.join('\n')
    assert.match(warningText, /\[redacted\]/)
    assert.doesNotMatch(warningText, /SECRET-TOKEN/)
  } finally {
    console.warn = originalWarn
    clearBootGlobals()
  }
})

test('connectWebWorker rejects the readiness deferred and reports the failure', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html?image=x&channel=%2Fchannel'
  const peer = new TunnelPeer({ status: 503, body: 'tree did not start' })
  let reported: unknown
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          worker: peer as unknown as Worker,
          onFailure(reason) { reported = reason },
        }),
        /HTTP 503/,
      )
    })
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, /HTTP 503/)
    assert.match(String(reported), /HTTP 503/)
    assert.equal((globalThis as BootGlobals).__PDH_TEST_INJECTION__, undefined)
  } finally {
    clearBootGlobals()
  }
})

test('a 503 body cannot leak token/env through the rejected ready Error', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=SECRET-TOKEN&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22SECRET-ENV%22%7D'
  const peer = new TunnelPeer({
    status: 503,
    body: 'tree did not start: image fetch failed with 503 for '
      + 'http://127.0.0.1:7411/image?token=SECRET-TOKEN '
      + 'env={"PDSH_LAUNCH_TOKEN":"SECRET-ENV"}',
  })
  let reported: unknown
  let rejected: unknown
  const assertSafe = (error: unknown): true => {
    const text = error instanceof Error ? error.message : String(error)
    assert.doesNotMatch(text, /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
    assert.match(text, /\[redacted\]/, 'the useful shape survives with the value removed')
    assert.match(text, /HTTP 503|image fetch failed/)
    return true
  }
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          worker: peer as unknown as Worker,
          onFailure(reason) { reported = reason },
        }),
        (error: unknown) => {
          rejected = error
          return assertSafe(error)
        },
      )
    })
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, assertSafe)
    assertSafe(reported)
    // `AppWebEntry.run()` logs the same Error and paints `reason.message`.
    const dshRunFailureText = rejected instanceof Error ? rejected.message : String(rejected)
    assert.doesNotMatch(dshRunFailureText, /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
    assert.equal((rejected as Error).cause, undefined, 'the raw reason is not retained as cause')
    assert.equal((globalThis as BootGlobals).__PDH_TEST_INJECTION__, undefined)
  } finally {
    clearBootGlobals()
  }
})

test('a 503 refusal message is redacted at console.warn before boot rejects', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=SECRET-TOKEN&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22SECRET-ENV%22%7D'
  // The pinned WorkerTunnel prints the raw `res.message` in warnRefusal; the
  // native bridge forwards that line, so it must be safe before the reject.
  const peer = new TunnelPeer({
    status: 503,
    body: 'tree did not start',
    message: 'image fetch failed for http://127.0.0.1:7411/image?token=SECRET-TOKEN '
      + 'env={"PDSH_LAUNCH_TOKEN":"SECRET-ENV"}',
  })
  const warnings: string[] = []
  const originalWarn = console.warn
  console.warn = (...args: unknown[]) => { warnings.push(args.map(value => String(value)).join(' ')) }
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          worker: peer as unknown as Worker,
        }),
        /HTTP 503/,
      )
    })
  } finally {
    console.warn = originalWarn
    clearBootGlobals()
  }
  const text = warnings.join('\n')
  assert.match(text, /HTTP 503/)
  assert.match(text, /image fetch failed/)
  assert.match(text, /\[redacted\]/)
  assert.doesNotMatch(text, /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
})

test('a Worker pdsh-error before /__boot__ rejects boot instead of waiting', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=SECRET-TOKEN&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22SECRET-ENV%22%7D'
  const peer = new SilentPeer()
  let reported: unknown
  let rejected: unknown
  try {
    await withPageLocation(href, async () => {
      const pending = boot.connectWebWorker({
        href,
        search: new URL(href).search,
        worker: peer as unknown as Worker,
        timeoutMs: 1_000,
        onFailure(reason) { reported = reason },
      })
      // The listener is installed synchronously before the first await; this
      // models a Worker that failed before any TunnelServer existed.
      peer.emit({
        t: 'pdsh-error',
        message: 'worker entry: fence.owner is required for '
          + '?token=SECRET-TOKEN env={"PDSH_LAUNCH_TOKEN":"SECRET-ENV"}',
      })
      await assert.rejects(pending, (error: unknown) => {
        rejected = error
        const message = error instanceof Error ? error.message : String(error)
        assert.match(message, /fence\.owner is required/, 'the Worker reason is retained')
        assert.match(message, /\[redacted\]/)
        assert.doesNotMatch(message, /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
        return true
      })
    })
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, /fence\.owner is required/)
    assert.match(String(reported), /fence\.owner is required/)
    assert.doesNotMatch(String(rejected), /SECRET-TOKEN|SECRET-ENV/)
  } finally {
    clearBootGlobals()
  }
})

test('connectWebWorker bounds a silent /__boot__ with a finite timeout', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html?image=x&channel=%2Fchannel'
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          worker: new SilentPeer() as unknown as Worker,
          timeoutMs: 50,
        }),
        /no ready signal after 50 ms/,
      )
    })
    const ready = (globalThis as BootGlobals).__DSH_BOOT_READY__
    assert.notEqual(ready, undefined)
    await assert.rejects(ready!.promise, /no ready signal/)
  } finally {
    clearBootGlobals()
  }
})

test('connectWebWorker scrubs transport secrets even when the boot query is invalid', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  clearBootGlobals()
  const boot = await loadWebBoot()
  const href = 'http://127.0.0.1:7411/static/web/index.html'
    + '?token=launch-token&image=%2Fimage%2Fbase&channel=%2Fchannel&fence=%7B&keep=one#chat'
  const historyCalls: { state: unknown; url: string }[] = []
  const history: TestHistory = {
    state: { route: 'conversation' },
    replaceState(state, _unused, url) {
      historyCalls.push({ state, url: String(url) })
    },
  }
  try {
    await withPageLocation(href, async () => {
      await assert.rejects(
        boot.connectWebWorker({
          href,
          search: new URL(href).search,
          history,
        }),
        /fence/,
      )
    })
    assert.equal(historyCalls.length, 1)
    assert.equal(historyCalls[0]?.state, history.state)
    const visible = new URL(historyCalls[0]!.url)
    assert.equal(visible.searchParams.get('keep'), 'one')
    assert.equal(visible.hash, '#chat')
    assert.equal(visible.searchParams.has('token'), false)
    assert.equal(visible.searchParams.has('image'), false)
    assert.equal(visible.searchParams.has('channel'), false)
    await assert.rejects((globalThis as BootGlobals).__DSH_BOOT_READY__!.promise, /fence/)
  } finally {
    clearBootGlobals()
  }
})

test('embedded app preferences dismiss only the native page PWA promotion', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  const writes: Array<{ key: string; value: string }> = []
  const storage = { setItem(key: string, value: string) { writes.push({ key, value }) } }

  // A normal DSH Web page has no native marker and keeps the complete PWA flow.
  assert.equal(boot.isEmbeddedAppPage({}), false)
  assert.equal(boot.installEmbeddedAppPreferences({ localStorage: storage }), false)
  assert.deepEqual(writes, [])

  // Any object that is not the explicit app display mode is not the App either.
  assert.equal(boot.isEmbeddedAppPage({ __PDSH_EMBEDDED_APP__: { displayMode: 'browser' } }), false)
  assert.deepEqual(writes, [])

  assert.equal(boot.isEmbeddedAppPage({ __PDSH_EMBEDDED_APP__: { version: 1, displayMode: 'app' } }), true)
  assert.equal(boot.installEmbeddedAppPreferences({
    __PDSH_EMBEDDED_APP__: { version: 1, displayMode: 'app' },
    localStorage: storage,
  }), true)
  assert.deepEqual(writes, [{ key: 'dsh-ui-mobile:install-promotion-dismissed', value: '1' }])
})

test('embedded app preferences tolerate a storage-denied WebView', async (t) => {
  if (!hooksAvailable || runtimeClient === undefined || !existsSync(runtimeClient)) {
    t.skip('pinned DSH checkout is not available')
    return
  }
  const boot = await loadWebBoot()
  assert.equal(boot.installEmbeddedAppPreferences({
    __PDSH_EMBEDDED_APP__: { version: 1, displayMode: 'app' },
    localStorage: { setItem() { throw new Error('storage denied') } },
  }), true)
})

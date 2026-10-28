// SPDX-License-Identifier: MIT
// W1-SEAM: channel seam across exec-bridge, worker-entry and llm-bridge. One
// host HELLO drives accelerator routing, the Worker never emits 0x40, and the
// 0x31 high-water marks live only in the channel package's tracker.
import assert from 'node:assert/strict'
import { Context } from '@deepseek-ai/cordis'
import { createServer } from 'node:http'
import type { IncomingHttpHeaders } from 'node:http'
import type { AddressInfo } from 'node:net'
import { test } from 'node:test'
import {
  createMemoryChannelPair, decodeUtf8, encodeUtf8, FrameType, makeHostHello,
  type ChannelClient,
} from '../channel/src/index.ts'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import { ChannelExecTransport, DeferredChannel } from '../exec-bridge/src/transport.ts'
import { defaultHostProxy, installNodeFetch } from '../llm-bridge/src/install.ts'
import { startPhoneWorker } from '../worker-entry/src/entry.ts'
import type { PhoneWorkerHostLike, PhoneWorkerRuntime, WorkerEntryRequestListener, WorkerEntrySynthesize, WorkerEntryVfs } from '../worker-entry/src/entry.ts'
import { MockChannel, eventually } from './test-channel.ts'

const IDEM_KEY = '2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a'

function execRequest(argv: readonly string[]): {
  exec_id: string
  argv: string[]
  cwd: string
  requires_mseq: number
  idem_key: string
} {
  return {
    exec_id: 'xl1-seam-0',
    argv: [...argv],
    cwd: '/dsh/workspace',
    requires_mseq: 47,
    idem_key: IDEM_KEY,
  }
}

test('zero host accelerator caps: hello reports none and exec never sends 0x20', async () => {
  const mock = new MockChannel()
  const transport = new ChannelExecTransport(mock, undefined, { helloTimeoutMs: 1_000 })
  try {
    let helloResolved = false
    const helloPromise = transport.hello().then((hello) => {
      helloResolved = true
      return hello
    })
    await new Promise(resolve => setTimeout(resolve, 5))
    assert.equal(helloResolved, false, 'routing waits for the host HELLO instead of guessing')
    mock.setHostHello(makeHostHello({ caps: [] }))
    const hello = await helloPromise
    assert.deepEqual(hello.capabilities.accelerators, [])
    await assert.rejects(transport.exec(execRequest(['rg', 'needle'])), /not an advertised host accelerator/)
    assert.equal(mock.framesOf(FrameType.EXEC_REQ).length, 0, 'nothing is routed to the host')
  } finally {
    transport.destroy()
  }
})

test('advertised rg goes to 0x20 with requires_mseq and idem_key', async () => {
  const mock = new MockChannel({ caps: ['accelerator:rg'], nextMseq: 48n, ackedMseq: 47n })
  const transport = new ChannelExecTransport(mock, undefined, { helloTimeoutMs: 1_000 })
  try {
    const hello = await transport.hello()
    assert.deepEqual(hello.capabilities.accelerators, ['rg'])
    const stream = await transport.exec(execRequest(['rg', '--json', 'needle']))
    stream.close()
    const frames = mock.framesOf(FrameType.EXEC_REQ)
    assert.equal(frames.length, 1)
    const body = JSON.parse(decodeUtf8(frames[0]!.payload)) as Record<string, unknown>
    assert.deepEqual(body['argv'], ['rg', '--json', 'needle'])
    assert.equal(body['requires_mseq'], 47)
    assert.equal(body['idem_key'], IDEM_KEY)
  } finally {
    transport.destroy()
  }
})

test('an unadvertised command fails locally even when another accelerator is advertised', async () => {
  const mock = new MockChannel({ caps: ['accelerator:rg'] })
  const transport = new ChannelExecTransport(mock, undefined, { helloTimeoutMs: 1_000 })
  try {
    await transport.hello()
    await assert.rejects(transport.exec(execRequest(['jaq', '.x'])), /not an advertised host accelerator/)
    assert.equal(mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    transport.destroy()
  }
})

test('an explicit accelerator config replaces the cap-derived set', async () => {
  const mock = new MockChannel({ caps: ['accelerator:rg'] })
  const transport = new ChannelExecTransport(mock, ['jaq'])
  try {
    const hello = await transport.hello()
    assert.deepEqual(hello.capabilities.accelerators, ['jaq'])
    await assert.rejects(transport.exec(execRequest(['rg', 'x'])), /not an advertised host accelerator/)
    const stream = await transport.exec(execRequest(['jaq', '.x']))
    stream.close()
    assert.equal(mock.framesOf(FrameType.EXEC_REQ).length, 1)
  } finally {
    transport.destroy()
  }
})

test('the exec-bridge service selects the channel and publishes only the host HELLO caps', async () => {
  const mock = new MockChannel({ caps: ['accelerator:rg'] })
  const globals = globalThis as { __PDSH_CHANNEL__?: ChannelClient }
  globals.__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  try {
    await ctx.plugin(XlExecBridge, {
      tokenEnv: 'PDSH_SEAM_UNUSED_TOKEN',
      tokenFileEnv: 'PDSH_SEAM_UNUSED_TOKEN_FILE',
      connectTimeoutMs: 2_000,
    })
    const bridge = ctx.get('xlExecBridge') as XlExecBridge
    await bridge.ready
    assert.equal(bridge.transport.kind, 'channel')
    assert.deepEqual(bridge.hello.capabilities.accelerators, ['rg'])
    // A reconnect HELLO replaces the caps; the service facts used by the
    // executor-inversion check must follow instead of freezing the first set.
    mock.setHostHello(makeHostHello({ caps: ['accelerator:jaq'] }))
    assert.deepEqual(bridge.hello.capabilities.accelerators, ['jaq'])
  } finally {
    await ctx.fiber.dispose()
    delete globals.__PDSH_CHANNEL__
  }
})

test('DeferredChannel forwards hostHello and onHostHello', () => {
  const mock = new MockChannel()
  const globals = globalThis as { __PDSH_CHANNEL__?: ChannelClient }
  globals.__PDSH_CHANNEL__ = mock
  try {
    const deferred = new DeferredChannel()
    const before: unknown = deferred.hostHello
    assert.equal(before, undefined)
    const seen: string[] = []
    const off = deferred.onHostHello(hello => { seen.push(hello.caps.at(-1) as string) })
    mock.setHostHello(makeHostHello({ caps: ['accelerator:rg'] }))
    assert.deepEqual(deferred.hostHello?.caps, ['channel/1', 'wal/1', 'exec/1', 'accelerator:rg'])
    mock.setHostHello(makeHostHello({ caps: ['accelerator:jaq'] }))
    assert.deepEqual(seen, ['accelerator:rg', 'accelerator:jaq'])
    off()
  } finally {
    delete globals.__PDSH_CHANNEL__
  }
})

test('exec-bridge journal waits on the channel 0x31 tracker instead of decoding acks itself', async () => {
  const mock = new MockChannel({ journalAck: 'manual' })
  const transport = new ChannelExecTransport(mock)
  try {
    let settled = false
    const append = transport.journal(1n, 'session.1', encodeUtf8('{"t":"start"}')).then(() => { settled = true })
    await eventually(() => mock.framesOf(FrameType.JOURNAL).length === 1)
    assert.equal(settled, false, 'append waits for the level-1 ack')
    assert.equal(transport.journalAck('session.1'), 0n)
    mock.emitJournalAck(1, 'session.1', 1n)
    await append
    assert.equal(transport.journalAck('session.1'), 1n)
  } finally {
    transport.destroy()
  }
})

test('the installed Worker transport routes /v1/http with the channel bearer', async () => {
  const seen: IncomingHttpHeaders[] = []
  const server = createServer((req, res) => {
    seen.push(req.headers)
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify({
        target: req.headers['x-pdsh-target-url'],
        method: req.headers['x-pdsh-target-method'],
        authorization: req.headers.authorization,
        upstream: req.headers['x-pdsh-upstream-authorization'],
        body: Buffer.concat(chunks).toString(),
      }))
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const token = 'w1-seam-token-0123456789abcdef'
  const previousLocation = Object.getOwnPropertyDescriptor(globalThis, 'location')
  const previous = {
    PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN,
    PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN,
  }
  Object.defineProperty(globalThis, 'location', { value: { origin: base }, configurable: true, writable: true })
  process.env.PDSH_CHANNEL_TOKEN = token
  process.env.PDSH_CHANNEL_ORIGIN = base
  const restore = installNodeFetch({ mode: 'auto' })
  try {
    const response = await fetch('https://model.example/v1/messages', {
      method: 'POST',
      headers: { authorization: 'Bearer upstream-key', 'content-type': 'application/json' },
      body: '{"prompt":"hi"}',
    })
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('cache-control'), 'no-store')
    const body = await response.json() as Record<string, string>
    assert.equal(body.target, 'https://model.example/v1/messages')
    assert.equal(body.method, 'POST')
    assert.equal(body.authorization, `Bearer ${token}`)
    assert.equal(body.upstream, 'Bearer upstream-key')
    assert.equal(body.body, '{"prompt":"hi"}')

    // Inside the Worker even a loopback URL is carried by the host route, so
    // no node:http client is needed in the runtime module table.
    const loopback = await fetch(`${base}/mcp`, { method: 'POST', body: 'mcp-body' })
    const routed = await loopback.json() as Record<string, string>
    assert.equal(routed.target, `${base}/mcp`)
    assert.equal(routed.authorization, `Bearer ${token}`)
    assert.equal(routed.body, 'mcp-body')
    assert.equal(seen.length, 2)
  } finally {
    restore()
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

test('the entry hands PDSH_CHANNEL_URL/TOKEN/ORIGIN to DSH before it boots', async () => {
  const keys = ['PDSH_CHANNEL_URL', 'PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN'] as const
  const previous = new Map(keys.map(key => [key, process.env[key]]))
  const token = 'w1-seam-token-0123456789abcdef'
  const pair = createMemoryChannelPair()
  const vfs: WorkerEntryVfs = { subscribe: () => () => {}, flush: async () => {} }
  const listen: WorkerEntryRequestListener = (_req, res) => {
    (res as { end: (body?: string) => void }).end('ok')
  }
  const synthesize: WorkerEntrySynthesize = (request, sink) => {
    const req = { method: request.method, url: request.path, headers: request.headers }
    const res = {
      writeHead: (status: number, headers: Record<string, string>) => { sink.head(status, headers) },
      end: (body?: string) => { sink.end({ status: 200, headers: {}, body: body === undefined ? undefined : encodeUtf8(body) }) },
    }
    return { req, res, get aborted() { return false }, abort() {} }
  }
  let bootEnv: Record<string, string> | undefined
  let bootProcess: Record<string, string | undefined> | undefined
  const host: PhoneWorkerHostLike = {
    handleMessage: () => {},
    start: async () => {},
    vfs,
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: (options) => {
      bootEnv = options.env as Record<string, string> | undefined
      bootProcess = {
        PDSH_CHANNEL_URL: process.env.PDSH_CHANNEL_URL,
        PDSH_CHANNEL_TOKEN: process.env.PDSH_CHANNEL_TOKEN,
        PDSH_CHANNEL_ORIGIN: process.env.PDSH_CHANNEL_ORIGIN,
      }
      return host
    },
    whenRequestListener: async () => listen,
    createChannel: () => pair.worker,
    synthesize,
  }
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:4567/channel',
    token,
    imageURL: 'image.tar.gz',
    overlayURLs: [],
    fence: { owner: 'phone', generation: 3n, wal_seq: 41n },
    bootId: '00112233445566778899aabbccddeeff',
    sessionEpoch: 7n,
    runtime,
    pagePost: () => {},
  })
  try {
    assert.equal(process.env.PDSH_CHANNEL_URL, 'ws://127.0.0.1:4567/channel')
    assert.equal(process.env.PDSH_CHANNEL_TOKEN, token)
    assert.equal(process.env.PDSH_CHANNEL_ORIGIN, 'http://127.0.0.1:4567')
    assert.equal(bootProcess?.PDSH_CHANNEL_URL, 'ws://127.0.0.1:4567/channel')
    assert.equal(bootEnv?.PDSH_CHANNEL_TOKEN, token)
    // llm-bridge's /v1/http route consumes exactly these env names.
    const proxy = defaultHostProxy()
    assert.equal(proxy?.url, 'http://127.0.0.1:4567')
    assert.equal(proxy?.token, token)
  } finally {
    await handle.stop()
    for (const key of keys) {
      const value = previous.get(key)
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  }
})

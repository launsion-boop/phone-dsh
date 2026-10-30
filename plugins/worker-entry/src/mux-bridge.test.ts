// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  canonicalStringify, createMemoryChannelPair, decodeUtf8, encodeUtf8, MAX_API_BODY_BYTES,
  type ApiRequestHead, type ApiResponseChunk, type MemoryChannelClient, type MemoryChannelPair,
} from '../../channel/src/index.ts'
import {
  CHANNEL_AUTHENTICATED_HEADER, serveApiRequests, withChannelAuthentication,
  type WorkerEntryChannel, type WorkerEntryRequestListener, type WorkerEntrySynthesize,
} from './entry.ts'
import {
  MUX_ERROR_HEADER, MUX_ID_HEADER, MUX_NDJSON_CONTENT_TYPE, MUX_OPERATION_HEADER,
  WorkerEntryMuxBridge, encodeMuxFrameLine, parseMuxClientFrame,
  type WorkerEntryMuxClientFrame, type WorkerEntryMuxServerFrame,
  type WorkerEntryMuxSession, type WorkerEntryMuxSessionFactory,
} from './mux-bridge.ts'
import { createTunnelMuxSessionFactory, createTunnelPort } from './mux-tunnel.ts'

const MUX_A = '0123456789abcdef0123456789abcdef'
const MUX_B = 'fedcba9876543210fedcba9876543210'

interface FakeSession extends WorkerEntryMuxSession {
  readonly muxId: string
  readonly sent: WorkerEntryMuxClientFrame[]
  closedCount: number
  emit(frame: WorkerEntryMuxServerFrame): void
}

interface FakeFactory {
  readonly createSession: WorkerEntryMuxSessionFactory
  readonly sessions: Map<string, FakeSession>
  readonly created: number
}

function createFakeFactory(): FakeFactory {
  const sessions = new Map<string, FakeSession>()
  let created = 0
  return {
    createSession(muxId: string): FakeSession {
      created += 1
      const listeners = new Set<(frame: WorkerEntryMuxServerFrame) => void>()
      const session: FakeSession = {
        muxId,
        sent: [],
        closedCount: 0,
        send(frame) { session.sent.push(frame) },
        onFrame(listener) {
          listeners.add(listener)
          return () => { listeners.delete(listener) }
        },
        close() { session.closedCount += 1 },
        emit(frame) {
          for (const listener of [...listeners]) listener(frame)
        },
      }
      sessions.set(muxId, session)
      return session
    },
    sessions,
    get created() { return created },
  }
}

function connectPair(): MemoryChannelPair {
  return createMemoryChannelPair({ autoConnect: true })
}

async function settle(): Promise<void> {
  for (let index = 0; index < 3; index += 1) {
    await new Promise<void>((resolve) => setTimeout(resolve, 0))
  }
}

const mustNotSynthesize: WorkerEntrySynthesize = () => {
  throw new Error('a mux request must not reach the synthetic HTTP listener')
}

function muxHead(muxId: string, operation: string): ApiRequestHead {
  return {
    method: 'POST',
    path: '/api/remote.mux',
    headers: {
      'content-type': operation === 'receive' ? MUX_NDJSON_CONTENT_TYPE : 'application/json',
      [MUX_ID_HEADER]: muxId,
      [MUX_OPERATION_HEADER]: operation,
    },
  }
}

async function collectRequest(
  pair: MemoryChannelPair,
  head: ApiRequestHead,
  body: Uint8Array = new Uint8Array(0),
): Promise<ApiResponseChunk[]> {
  const chunks: ApiResponseChunk[] = []
  for await (const chunk of pair.host.request(head, body)) chunks.push(chunk)
  return chunks
}

function bodyOf(chunks: readonly ApiResponseChunk[]): Uint8Array {
  let length = 0
  for (const chunk of chunks) length += chunk.body.byteLength
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk.body, offset)
    offset += chunk.body.byteLength
  }
  return out
}

function linesOf(chunks: readonly ApiResponseChunk[]): string[] {
  return decodeUtf8(bodyOf(chunks)).split('\n').filter(line => line !== '')
}

function statusOf(chunks: readonly ApiResponseChunk[]): number | undefined {
  return chunks[0]?.head?.status
}

function errorCodeOf(chunks: readonly ApiResponseChunk[]): string | undefined {
  const body = JSON.parse(decodeUtf8(bodyOf(chunks))) as { error?: { code?: string } }
  return body.error?.code
}

function assertBytesEqual(actual: Uint8Array, expected: Uint8Array, message: string): void {
  assert.equal(actual.byteLength, expected.byteLength, message)
  for (let index = 0; index < expected.byteLength; index += 1) {
    if (actual[index] !== expected[index]) assert.fail(`${message} at byte ${index}`)
  }
}

function sendFrame(frame: WorkerEntryMuxClientFrame): Uint8Array {
  return encodeUtf8(canonicalStringify(frame))
}

test('send then receive round-trips mux frames through one session', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    const open: WorkerEntryMuxClientFrame = {
      type: 'open',
      streamId: 'stream-1',
      endpoint: 'session/follow',
      payload: { args: { sessionId: 's1' } },
    }
    const send = await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame(open))
    assert.equal(statusOf(send), 200)
    assert.equal(factory.created, 1)
    const session = factory.sessions.get(MUX_A)
    assert.ok(session !== undefined)
    assert.deepEqual(session.sent, [open])

    // The frame is emitted before the receive is attached; the bridge queues it.
    session.emit({ type: 'item', streamId: 'stream-1', value: { n: 1 } })
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    session.emit({ type: 'end', streamId: 'stream-1' })
    const close = await collectRequest(pair, muxHead(MUX_A, 'close'))
    assert.equal(statusOf(close), 200)

    const chunks = await receive
    assert.equal(statusOf(chunks), 200)
    assert.equal(chunks[0]?.head?.headers['content-type'], MUX_NDJSON_CONTENT_TYPE)
    assert.deepEqual(linesOf(chunks), [
      '{"streamId":"stream-1","type":"item","value":{"n":1}}',
      '{"streamId":"stream-1","type":"end"}',
    ])
    assert.equal(session.closedCount, 1)
  } finally {
    dispose()
  }
})

test('two mux ids stream independently and close cleanly', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 'a-1', endpoint: 'session/follow', payload: { args: { id: 'a' } },
    }))
    await collectRequest(pair, muxHead(MUX_B, 'send'), sendFrame({
      type: 'open', streamId: 'b-1', endpoint: 'session/follow', payload: { args: { id: 'b' } },
    }))
    const sessionA = factory.sessions.get(MUX_A)
    const sessionB = factory.sessions.get(MUX_B)
    assert.ok(sessionA !== undefined && sessionB !== undefined)
    assert.equal(factory.created, 2)

    const receiveA = collectRequest(pair, muxHead(MUX_A, 'receive'))
    const receiveB = collectRequest(pair, muxHead(MUX_B, 'receive'))
    await settle()
    sessionA.emit({ type: 'item', streamId: 'a-1', value: 'A' })
    sessionB.emit({ type: 'item', streamId: 'b-1', value: 'B' })
    await settle()

    assert.equal(statusOf(await collectRequest(pair, muxHead(MUX_A, 'close'))), 200)
    assert.equal(statusOf(await collectRequest(pair, muxHead(MUX_B, 'close'))), 200)
    const [chunksA, chunksB] = await Promise.all([receiveA, receiveB])
    assert.deepEqual(linesOf(chunksA), ['{"streamId":"a-1","type":"item","value":"A"}'])
    assert.deepEqual(linesOf(chunksB), ['{"streamId":"b-1","type":"item","value":"B"}'])
    assert.equal(sessionA.closedCount, 1)
    assert.equal(sessionB.closedCount, 1)
  } finally {
    dispose()
  }
})

test('receive ends when the mux closes and still delivers queued frames first', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's1', endpoint: 'session/follow', payload: {},
    }))
    const session = factory.sessions.get(MUX_A)!
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    session.emit({ type: 'item', streamId: 's1', value: 1 })
    await settle()
    const close = await collectRequest(pair, muxHead(MUX_A, 'close'))
    const chunks = await receive
    assert.equal(statusOf(close), 200)
    assert.deepEqual(linesOf(chunks), ['{"streamId":"s1","type":"item","value":1}'])
    assert.equal(session.closedCount, 1)
  } finally {
    dispose()
  }
})

test('receive frames are canonical JSON and split at the 4 MiB API_RES bound', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 'big', endpoint: 'session/follow', payload: {},
    }))
    const session = factory.sessions.get(MUX_A)!
    const frame: WorkerEntryMuxServerFrame = {
      type: 'item',
      streamId: 'big',
      value: { blob: 'x'.repeat(MAX_API_BODY_BYTES + 1024) },
    }
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    session.emit(frame)
    await settle()
    await collectRequest(pair, muxHead(MUX_A, 'close'))
    const chunks = await receive
    for (const chunk of chunks) {
      assert.ok(chunk.body.byteLength <= MAX_API_BODY_BYTES, `chunk is ${chunk.body.byteLength} bytes`)
    }
    assertBytesEqual(bodyOf(chunks), encodeMuxFrameLine(frame), 'receive bytes')
    const dataChunks = chunks.filter(chunk => chunk.body.byteLength > 0)
    assert.equal(dataChunks.length, 2, 'one 4 MiB chunk plus the remainder')
  } finally {
    dispose()
  }
})

test('server frames are canonical JSON (sorted keys, no whitespace)', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's1', endpoint: 'session/follow', payload: {},
    }))
    const session = factory.sessions.get(MUX_A)!
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    session.emit({ type: 'item', streamId: 's1', value: { z: 1, a: { d: 4, c: 3 } } })
    await settle()
    await collectRequest(pair, muxHead(MUX_A, 'close'))
    const chunks = await receive
    assert.equal(
      decodeUtf8(bodyOf(chunks)),
      '{"streamId":"s1","type":"item","value":{"a":{"c":3,"d":4},"z":1}}\n',
    )
  } finally {
    dispose()
  }
})

test('mux projection rounds llm retry delayMs without admitting other fractions', () => {
  const encoded = encodeMuxFrameLine({
    type: 'item', streamId: 's1', value: {
      type: 'llm/retry', seq: 18, time: 1793276504702,
      data: { delayMs: 528.0336662194833, policyKey: '[0.1]' },
    },
  })
  assert.equal(
    decodeUtf8(encoded),
    '{"streamId":"s1","type":"item","value":{"data":{"delayMs":528,"policyKey":"[0.1]"},"seq":18,"time":1793276504702,"type":"llm/retry"}}\n',
  )
  for (const value of [
    { type: 'event', event: { type: 'llm/retry', data: { delayMs: 528.0336662194833 } } },
    { type: 'snapshot', records: [{ event: { type: 'llm/retry', data: { delayMs: 528.0336662194833 } } }] },
  ]) {
    assert.match(decodeUtf8(encodeMuxFrameLine({ type: 'item', streamId: 's1', value })), /"delayMs":528/)
  }
  assert.throws(
    () => encodeMuxFrameLine({
      type: 'item', streamId: 's1', value: { type: 'other/event', data: { delayMs: 0.5 } },
    }),
    /integers only/,
  )
})

test('parseMuxClientFrame mirrors the gateway stream-protocol exact-key rules', () => {
  assert.deepEqual(
    parseMuxClientFrame('{"type":"open","streamId":"s","endpoint":"e","payload":{"a":1}}'),
    { type: 'open', streamId: 's', endpoint: 'e', payload: { a: 1 } },
  )
  assert.deepEqual(parseMuxClientFrame('{"type":"item","streamId":"s"}'), { type: 'item', streamId: 's' })
  assert.deepEqual(
    parseMuxClientFrame('{"type":"item","streamId":"s","value":[1,2]}'),
    { type: 'item', streamId: 's', value: [1, 2] },
  )
  assert.deepEqual(parseMuxClientFrame('{"type":"end","streamId":"s"}'), { type: 'end', streamId: 's' })
  assert.deepEqual(parseMuxClientFrame('{"type":"cancel","streamId":"s"}'), { type: 'cancel', streamId: 's' })
  assert.throws(() => parseMuxClientFrame('not json'), /not JSON/)
  assert.throws(() => parseMuxClientFrame('[]'), /JSON object/)
  assert.throws(() => parseMuxClientFrame('{"type":"open","streamId":"s","endpoint":"e"}'), /legal/)
  assert.throws(() => parseMuxClientFrame('{"type":"open","streamId":"","endpoint":"e","payload":null}'), /streamId/)
  assert.throws(() => parseMuxClientFrame('{"type":"item","streamId":"s","extra":1}'), /legal/)
})

test('D22 marker is the only entry-owned value and inbound copies are stripped', async () => {
  let captured: Record<string, string> | undefined
  const synthesize: WorkerEntrySynthesize = (request, sink) => {
    captured = request.headers
    sink.end({ status: 200, headers: { 'content-type': 'text/plain' }, body: encodeUtf8('ok') })
    return { req: {}, res: {}, aborted: false, abort(): void {} }
  }
  const listener: WorkerEntryRequestListener = () => {}
  const pair = connectPair()
  const dispose = serveApiRequests(pair.worker, async () => listener, { synthesize })
  try {
    const chunks = await collectRequest(pair, {
      method: 'POST',
      path: '/api/ping',
      headers: {
        [CHANNEL_AUTHENTICATED_HEADER]: 'spoofed',
        host: 'attacker.example',
        accept: 'application/json',
      },
    }, encodeUtf8('ping'))
    assert.equal(statusOf(chunks), 200)
    assert.ok(captured !== undefined)
    assert.equal(captured[CHANNEL_AUTHENTICATED_HEADER], '1')
    assert.equal(captured['host'], '127.0.0.1')
    assert.equal(captured['accept'], 'application/json')
    assert.equal(
      Object.keys(captured).filter(name => name.toLowerCase() === CHANNEL_AUTHENTICATED_HEADER).length,
      1,
    )
  } finally {
    dispose()
  }
  assert.deepEqual(
    withChannelAuthentication({ 'X-PDSH-Channel-Authenticated': 'spoofed', accept: 'text/plain' }),
    { accept: 'text/plain', [CHANNEL_AUTHENTICATED_HEADER]: '1' },
  )
})

test('unknown operation, malformed id and malformed body answer 400 with the x-xl error header', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    const badOperation = await collectRequest(pair, muxHead(MUX_A, 'bogus'))
    assert.equal(statusOf(badOperation), 400)
    assert.equal(badOperation[0]?.head?.headers[MUX_ERROR_HEADER], 'mux_invalid_operation')
    assert.equal(errorCodeOf(badOperation), 'mux_invalid_operation')

    const badId = await collectRequest(pair, {
      method: 'POST',
      path: '/api/remote.mux',
      headers: { [MUX_ID_HEADER]: 'not-32-hex', [MUX_OPERATION_HEADER]: 'send' },
    })
    assert.equal(statusOf(badId), 400)
    assert.equal(badId[0]?.head?.headers[MUX_ERROR_HEADER], 'mux_invalid_id')

    const badBody = await collectRequest(pair, muxHead(MUX_A, 'send'), encodeUtf8('{"type":'))
    assert.equal(statusOf(badBody), 400)
    assert.equal(badBody[0]?.head?.headers[MUX_ERROR_HEADER], 'mux_invalid_frame')
    assert.equal(factory.created, 0, 'a refused request opens no session')

    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's1', endpoint: 'session/follow', payload: {},
    }))
    assert.equal(factory.created, 1)
  } finally {
    dispose()
  }
})

test('tunnel-backed sessions map mux frames onto the runtime stream lane', () => {
  const posted: unknown[] = []
  const hostMessages: unknown[] = []
  const port = createTunnelPort((message) => { posted.push(message) })
  const session = createTunnelMuxSessionFactory({
    handleHostMessage: (message) => { hostMessages.push(message) },
    tunnel: port,
  })(MUX_A)
  const frames: WorkerEntryMuxServerFrame[] = []
  session.onFrame((frame) => { frames.push(frame) })

  session.send({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: {} } })
  assert.deepEqual(hostMessages, [{
    t: 'stream-open',
    id: `pdsh-mux:${MUX_A}:1:s1`,
    endpoint: 'session/follow',
    payload: { args: {} },
  }])
  session.send({ type: 'item', streamId: 's1', value: { n: 1 } })
  session.send({ type: 'end', streamId: 's1' })
  assert.deepEqual(hostMessages.slice(1), [
    { t: 'stream-uplink-item', id: `pdsh-mux:${MUX_A}:1:s1`, value: { n: 1 } },
    { t: 'stream-uplink-end', id: `pdsh-mux:${MUX_A}:1:s1` },
  ])
  // A frame after the uplink ended is dropped, as the gateway mux server does.
  session.send({ type: 'item', streamId: 's1', value: 2 })
  assert.equal(hostMessages.length, 3)

  session.send({ type: 'open', streamId: 's2', endpoint: 'session/follow', payload: null })
  port.postMessage({ t: 'stream-item', id: `pdsh-mux:${MUX_A}:1:s2`, value: 'hello' })
  port.postMessage({ t: 'stream-end', id: `pdsh-mux:${MUX_A}:1:s2` })
  assert.deepEqual(frames, [
    { type: 'item', streamId: 's2', value: 'hello' },
    { type: 'end', streamId: 's2' },
  ])

  session.send({ type: 'open', streamId: 's3', endpoint: 'session/follow', payload: null })
  port.postMessage({
    t: 'stream-error',
    id: `pdsh-mux:${MUX_A}:1:s3`,
    failure: { kind: 'remote', code: 'gateway/boom', message: 'boom', details: { a: 1 } },
  })
  assert.deepEqual(frames.at(-1), {
    type: 'error',
    streamId: 's3',
    error: { code: 'gateway/boom', message: 'boom', details: { a: 1 } },
  })

  session.send({ type: 'open', streamId: 's4', endpoint: 'session/follow', payload: null })
  session.close()
  assert.deepEqual(hostMessages.at(-1), { t: 'abort', id: `pdsh-mux:${MUX_A}:1:s4` })
  const before = frames.length
  port.postMessage({ t: 'stream-item', id: `pdsh-mux:${MUX_A}:1:s4`, value: 'late' })
  assert.equal(frames.length, before, 'a closed session ignores later tunnel frames')
  assert.ok(posted.length > 0, 'the tunnel port forwards frames to the page')
})

test('worker mux requests drive the tunnel lane end to end', async () => {
  const pair = connectPair()
  const posted: unknown[] = []
  const hostMessages: unknown[] = []
  const port = createTunnelPort((message) => { posted.push(message) })
  // Stand-in for the runtime host: `stream-open` becomes an answer on the
  // outbound tunnel lane, exactly where the gateway's stream opener posts.
  const factory = createTunnelMuxSessionFactory({
    handleHostMessage(message: unknown) {
      hostMessages.push(message)
      const frame = message as { t?: string; id?: string; endpoint?: string }
      if (frame.t !== 'stream-open') return
      setTimeout(() => {
        port.postMessage({ t: 'stream-item', id: frame.id, value: { endpoint: frame.endpoint } })
        port.postMessage({ t: 'stream-end', id: frame.id })
      }, 0)
    },
    tunnel: port,
  })
  const bridge = new WorkerEntryMuxBridge({ createSession: factory })
  const dispose = serveApiRequests(pair.worker, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    const send = await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: {} },
    }))
    assert.equal(statusOf(send), 200)
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'item', streamId: 's1', value: { n: 1 },
    }))
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    const close = await collectRequest(pair, muxHead(MUX_A, 'close'))
    assert.equal(statusOf(close), 200)
    const chunks = await receive
    assert.deepEqual(linesOf(chunks), [
      '{"streamId":"s1","type":"item","value":{"endpoint":"session/follow"}}',
      '{"streamId":"s1","type":"end"}',
    ])
    assert.deepEqual(hostMessages.slice(0, 2), [
      {
        t: 'stream-open',
        id: `pdsh-mux:${MUX_A}:1:s1`,
        endpoint: 'session/follow',
        payload: { args: {} },
      },
      { t: 'stream-uplink-item', id: `pdsh-mux:${MUX_A}:1:s1`, value: { n: 1 } },
    ])
    assert.ok(posted.length > 0)
  } finally {
    dispose()
  }
})

test('a lost channel closes every mux session', async () => {
  const factory = createFakeFactory()
  const pair = connectPair()
  const bridge = new WorkerEntryMuxBridge({ createSession: factory.createSession })
  const loss = channelWithTransportLoss(pair.worker)
  const dispose = serveApiRequests(loss.channel, async () => () => {}, {
    synthesize: mustNotSynthesize,
    mux: bridge,
  })
  try {
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's1', endpoint: 'session/follow', payload: {},
    }))
    const session = factory.sessions.get(MUX_A)!
    const receive = collectRequest(pair, muxHead(MUX_A, 'receive'))
    await settle()
    loss.lose()
    assert.equal(session.closedCount, 1)
    pair.disconnect()
    await assert.rejects(receive, /connection_closed|closed/)
    await pair.reconnect()
    await collectRequest(pair, muxHead(MUX_A, 'send'), sendFrame({
      type: 'open', streamId: 's2', endpoint: 'session/follow', payload: {},
    }))
    assert.equal(factory.created, 2, 'a new send opens a fresh session')
  } finally {
    dispose()
  }
})

function channelWithTransportLoss(client: MemoryChannelClient): {
  readonly channel: WorkerEntryChannel
  lose(): void
} {
  const handlers = new Set<() => void>()
  const channel = new Proxy(client, {
    get(target, property, receiver) {
      if (property === 'onTransportLost') {
        return (handler: () => void): (() => void) => {
          handlers.add(handler)
          return () => { handlers.delete(handler) }
        }
      }
      const value = Reflect.get(target, property, receiver) as unknown
      return typeof value === 'function' ? (value as (...args: unknown[]) => unknown).bind(target) : value
    },
  }) as unknown as WorkerEntryChannel
  return {
    channel,
    lose(): void {
      for (const handler of [...handlers]) handler()
    },
  }
}

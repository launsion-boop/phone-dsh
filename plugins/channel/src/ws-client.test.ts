// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { canonicalStringify } from './canonical-json.ts'
import { decodeUtf8, encodeUtf8 } from './bytes.ts'
import type { ChannelClient } from './client.ts'
import { MAX_UNACKED_VFS_BYTES, RING_TIMEOUT_MS } from './client.ts'
import { FrameDecoder, FrameType, encodeFrame, type Frame } from './frames.ts'
import type { HelloHostPayload, VfsRefusedPayload } from './payloads.ts'
import { VfsRefusedError } from './payloads.ts'
import { decodeJournal, decodeVfsMutation, encodeJournal, encodeJournalAck, encodeVfsAck, encodeVfsMutation, VfsOp } from './vfs-mutation.ts'
import {
  ChannelPeerError, WebSocketChannelClient,
  type WebSocketChannelOptions, type WebSocketLike,
} from './ws-client.ts'

const BOOT_ID = '00112233445566778899aabbccddeeff'
const FENCE = { owner: 'phone', generation: 3n, wal_seq: 41n } as const

class MockWebSocket implements WebSocketLike {
  readonly url: string
  readonly sent: Uint8Array[] = []
  readonly closeCalls: { code: number | undefined; reason: string | undefined }[] = []
  readyState = 0
  binaryType = 'arraybuffer'
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>()

  constructor(url: string) {
    this.url = url
  }

  send(data: ArrayBuffer | ArrayBufferView | string): void {
    if (this.readyState !== 1) throw new Error('mock WebSocket: send() before open')
    if (typeof data === 'string') throw new Error('mock WebSocket: the channel sends binary frames only')
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    this.sent.push(bytes.slice())
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason })
    if (this.readyState === 3) return
    this.readyState = 3
    this.emit('close', {})
  }

  addEventListener(type: string, listener: (event: unknown) => void): void {
    const set = this.listeners.get(type) ?? new Set()
    set.add(listener)
    this.listeners.set(type, set)
  }

  open(): void {
    if (this.readyState !== 0) return
    this.readyState = 1
    this.emit('open', {})
  }

  deliver(frame: Frame): void {
    this.emit('message', { data: frameBytes(frame) })
  }

  deliverText(text: string): void {
    this.emit('message', { data: text })
  }

  deliverBytes(bytes: Uint8Array): void {
    this.emit('message', { data: bytes })
  }

  /** Simulate an unplanned transport loss (no close handshake from the client). */
  drop(): void {
    if (this.readyState === 3) return
    this.readyState = 3
    this.emit('close', {})
  }

  private emit(type: string, event: unknown): void {
    for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event)
  }
}

/** Host-side seq counter and encoder for one mock connection. */
class MockHost {
  private seq = 0n

  frame(type: FrameType, payload: Uint8Array): Frame {
    this.seq += 1n
    return { type, seq: this.seq, payload }
  }

  hello(overrides: Partial<HelloHostPayload> = {}): Frame {
    const payload: Record<string, unknown> = {
      proto: 1,
      role: 'host',
      boot_id: 'ffeeddccbbaa99887766554433221100',
      session_epoch: 7,
      fence: { owner: 'phone', generation: 3, wal_seq: 41 },
      caps: ['channel/1', 'wal/1', 'exec/1', 'accelerator:rg'],
      next_mseq: 42,
      acked_mseq: 41,
      durable_mseq: 40,
      ...overrides,
    }
    return this.frame(FrameType.HELLO, encodeUtf8(canonicalStringify(payload)))
  }
}

function frameBytes(frame: Frame): Uint8Array {
  return encodeFrame(frame)
}

function decodeSent(bytes: Uint8Array): Frame {
  const frames = new FrameDecoder().push(bytes)
  assert.equal(frames.length, 1)
  return frames[0]!
}

function sentFrames(socket: MockWebSocket): Frame[] {
  return socket.sent.map(decodeSent)
}

async function waitFor(condition: () => boolean, message = 'condition', timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${message}`)
    await new Promise<void>((resolve) => setTimeout(resolve, 1))
  }
}

interface ConnectedClient {
  readonly client: WebSocketChannelClient
  readonly sockets: MockWebSocket[]
  readonly host: MockHost
  readonly socket: MockWebSocket
}

async function connectClient(
  overrides: Partial<WebSocketChannelOptions> = {},
  lastMseq = 41n,
): Promise<ConnectedClient> {
  const sockets: MockWebSocket[] = []
  const client = new WebSocketChannelClient({
    url: 'ws://127.0.0.1:1234/channel',
    token: 'test-token',
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
    lastMseq,
    createSocket: (url) => {
      const socket = new MockWebSocket(url)
      sockets.push(socket)
      return socket
    },
    backoffMinMs: 1,
    backoffMaxMs: 4,
    ...overrides,
  })
  const connecting = client.connect()
  await waitFor(() => sockets.length === 1, 'the first socket')
  const socket = sockets[0]!
  socket.open()
  await waitFor(() => socket.sent.length === 1, 'the worker HELLO')
  const host = new MockHost()
  socket.deliver(host.hello({ next_mseq: lastMseq + 1n, acked_mseq: lastMseq, durable_mseq: 0n }))
  await connecting
  return { client, sockets, host, socket }
}

function mutation(mseq: bigint, path: string, data: Uint8Array): Uint8Array {
  return encodeVfsMutation({ mseq, op: VfsOp.WRITE, mode: 0o644, mflags: 0, appendFrom: 0n, path, data })
}

test('handshake sends the worker HELLO first and adopts the host mseq space', async () => {
  const sockets: MockWebSocket[] = []
  const client = new WebSocketChannelClient({
    url: 'ws://127.0.0.1:1234/channel',
    token: 'abc',
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
    lastMseq: 41n,
    createSocket: (url) => {
      const socket = new MockWebSocket(url)
      sockets.push(socket)
      return socket
    },
  })
  const connecting = client.connect()
  await waitFor(() => sockets.length === 1)
  const socket = sockets[0]!
  assert.match(socket.url, /^ws:\/\/127\.0\.0\.1:1234\/channel\?token=abc$/)
  socket.open()
  await waitFor(() => socket.sent.length === 1)
  const hello = decodeSent(socket.sent[0]!)
  assert.equal(hello.type, FrameType.HELLO)
  assert.equal(hello.seq, 1n)
  const fields = JSON.parse(decodeUtf8(hello.payload)) as Record<string, unknown>
  assert.equal(fields['proto'], 1)
  assert.equal(fields['role'], 'worker')
  assert.equal(fields['boot_id'], BOOT_ID)
  assert.equal(fields['session_epoch'], 7)
  assert.deepEqual(fields['fence'], { owner: 'phone', generation: 3, wal_seq: 41 })
  assert.equal(fields['last_mseq'], 41)
  assert.deepEqual(fields['caps'], ['channel/1', 'vfs-sink/1', 'journal/1', 'api/1'])

  const host = new MockHost()
  socket.deliver(host.hello())
  await connecting
  assert.equal(client.nextMseq(), 42n)
  assert.equal(client.ackedMseq(1), 41n)
  assert.equal(client.ackedMseq(2), 40n)
})

test('default construction takes the protocol 32 MiB window and 30 s ring timeout', () => {
  const client = new WebSocketChannelClient({
    url: 'ws://127.0.0.1:1234/channel',
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
  })
  // The effective options are private; this asserts the D3 defaults are wired
  // through, not only that the shared constants have the right value.
  const effective = (client as unknown as {
    options: { maxUnackedVfsBytes: number; ringTimeoutMs: number }
  }).options
  assert.equal(effective.maxUnackedVfsBytes, MAX_UNACKED_VFS_BYTES)
  assert.equal(effective.ringTimeoutMs, RING_TIMEOUT_MS)
})

test('a bad inbound seq answers BAD_SEQ and closes', async () => {
  const { client, host, socket } = await connectClient()
  socket.deliver(host.frame(FrameType.LIFECYCLE, encodeUtf8(canonicalStringify({
    state: 'run', budget: 0, admission: 'open', reason: 'foreground',
  }))))
  // Bypass the host counter: a frame with a deliberately wrong seq.
  socket.deliver({ type: FrameType.LIFECYCLE, seq: 9n, payload: encodeUtf8('{}') })
  await waitFor(() => socket.closeCalls.length > 0, 'the connection to close')
  const errorFrame = sentFrames(socket).find(frame => frame.type === FrameType.ERROR)
  assert.ok(errorFrame !== undefined)
  assert.equal((JSON.parse(decodeUtf8(errorFrame.payload)) as { code: string }).code, 'BAD_SEQ')
  await assert.rejects(client.waitAck(1, 42n), ChannelPeerError)
})

test('VFS flow control waits for level-1 acks before sending more mutations', async () => {
  const { client, host, socket } = await connectClient({
    lastMseq: 0n, maxUnackedVfsBytes: 2_500,
  }, 0n)
  const data = new Uint8Array(1_000).fill(0x61)
  for (let index = 0; index < 3; index++) {
    const mseq = client.nextMseq()
    client.send(FrameType.VFS_MUT, mutation(mseq, `/dsh/workspace/file-${String(index)}`, data))
  }
  const mutationsBefore = sentFrames(socket).filter(frame => frame.type === FrameType.VFS_MUT)
  assert.equal(mutationsBefore.length, 2)
  assert.deepEqual(mutationsBefore.map(frame => frame.seq), [2n, 3n])

  socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 1n })))
  await waitFor(
    () => sentFrames(socket).filter(frame => frame.type === FrameType.VFS_MUT).length === 3,
    'the third mutation after the ack',
  )
  const mseqs = sentFrames(socket)
    .filter(frame => frame.type === FrameType.VFS_MUT)
    .map(frame => decodeVfsMutation(frame.payload).mseq)
  assert.deepEqual(mseqs, [1n, 2n, 3n])
})

test('D3: level-1 ack progress restarts the ring timer for a slow legal publish', async () => {
  const ringTimeoutMs = 150
  const ackEveryMs = 50
  const { client, host, socket } = await connectClient({ maxUnackedVfsBytes: 2_200, ringTimeoutMs }, 0n)
  // Four 1 000-byte mutations keep the 2 000-byte window full for ~200 ms,
  // longer than the ring timeout, while every 50 ms ack makes progress.
  for (let index = 0; index < 4; index++) {
    const mseq = client.nextMseq()
    client.send(FrameType.VFS_MUT, mutation(mseq, `/dsh/workspace/slow-${String(index)}`, new Uint8Array(1_000)))
  }
  assert.equal(sentFrames(socket).filter(frame => frame.type === FrameType.VFS_MUT).length, 2)
  for (let mseq = 1n; mseq <= 4n; mseq++) {
    await new Promise<void>((resolve) => setTimeout(resolve, ackEveryMs))
    socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: mseq })))
  }
  await waitFor(
    () => sentFrames(socket).filter(frame => frame.type === FrameType.VFS_MUT).length === 4,
    'all four slow mutations to be sent',
  )
  assert.equal(socket.closeCalls.length, 0, 'ack progress must not trip RING_TIMEOUT')
  assert.equal(sentFrames(socket).some(frame => frame.type === FrameType.ERROR), false)
  assert.equal(client.admissionOpen, true)
  assert.equal(client.ackedMseq(1), 4n)
})

test('a full window with no ack progress emits RING_TIMEOUT and closes admission', async () => {
  const { client, socket } = await connectClient({ maxUnackedVfsBytes: 1_000, ringTimeoutMs: 5 }, 0n)
  client.send(FrameType.VFS_MUT, mutation(1n, '/dsh/workspace/a', new Uint8Array(700)))
  client.send(FrameType.VFS_MUT, mutation(2n, '/dsh/workspace/b', new Uint8Array(700)))
  await waitFor(() => socket.closeCalls.length > 0, 'the ring timeout close')
  const errorFrame = sentFrames(socket).find(frame => frame.type === FrameType.ERROR)
  assert.ok(errorFrame !== undefined)
  assert.equal((JSON.parse(decodeUtf8(errorFrame.payload)) as { code: string }).code, 'RING_TIMEOUT')
  assert.equal(client.admissionOpen, false)
  await assert.rejects(client.waitAck(1, 2n), ChannelPeerError)
})

test('reconnect resends every unacked VFS_MUT and JOURNAL with original ids', async () => {
  const { client, sockets, host, socket } = await connectClient()
  client.send(FrameType.VFS_MUT, mutation(42n, '/dsh/workspace/a.txt', encodeUtf8('hello')))
  client.send(FrameType.JOURNAL, encodeJournal({
    jseq: 1n, sessionId: 'session.1', record: encodeUtf8('{"event":1}'),
  }))
  assert.equal(sentFrames(socket).filter(frame => frame.type === FrameType.VFS_MUT).length, 1)

  socket.drop()
  await waitFor(() => sockets.length === 2, 'the reconnect socket')
  const second = sockets[1]!
  second.open()
  await waitFor(() => second.sent.length === 1, 'the second HELLO')
  const secondHost = new MockHost()
  second.deliver(secondHost.hello())
  await waitFor(() => second.sent.length >= 3, 'the resends')
  const resent = sentFrames(second)
  assert.equal(resent[0]!.type, FrameType.HELLO)
  assert.equal(resent[1]!.type, FrameType.VFS_MUT)
  assert.equal(resent[1]!.seq, 2n)
  assert.equal(decodeVfsMutation(resent[1]!.payload).mseq, 42n)
  assert.equal(resent[2]!.type, FrameType.JOURNAL)
  assert.equal(resent[2]!.seq, 3n)
  assert.equal(decodeJournal(resent[2]!.payload).jseq, 1n)
})

test('a level-1 ack on the new HELLO drops already durable mutations from the resend', async () => {
  const { client, sockets, socket } = await connectClient()
  client.send(FrameType.VFS_MUT, mutation(42n, '/dsh/workspace/a.txt', encodeUtf8('hello')))
  socket.drop()
  await waitFor(() => sockets.length === 2, 'the reconnect socket')
  const second = sockets[1]!
  second.open()
  await waitFor(() => second.sent.length === 1)
  const secondHost = new MockHost()
  second.deliver(secondHost.hello({ next_mseq: 43n, acked_mseq: 42n }))
  await waitFor(() => second.sent.length >= 1)
  // HELLO only: the host already holds mseq 42.
  assert.equal(second.sent.length, 1)
  assert.equal(client.nextMseq(), 43n)
})

test('a reconnect HELLO resolves waitAck/barrier for the tail it reports', async () => {
  const { client, sockets, socket } = await connectClient()
  let acked = false
  let barriered = false
  const waitingAck = client.waitAck(1, 42n).then(() => { acked = true })
  const waitingBarrier = client.barrier(1, 42n).then(() => { barriered = true })
  socket.drop()
  await waitFor(() => sockets.length === 2, 'the reconnect socket')
  const second = sockets[1]!
  second.open()
  await waitFor(() => second.sent.length === 1, 'the second HELLO')
  const secondHost = new MockHost()
  second.deliver(secondHost.hello({ next_mseq: 43n, acked_mseq: 42n, durable_mseq: 0n }))
  await Promise.all([waitingAck, waitingBarrier])
  assert.equal(acked, true)
  assert.equal(barriered, true)
})

test('reconnect backoff starts at 100 ms, doubles and caps at 5 s', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const sockets: MockWebSocket[] = []
  const client = new WebSocketChannelClient({
    url: 'ws://127.0.0.1:1234/channel',
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
    lastMseq: 0n,
    createSocket: (url) => {
      const socket = new MockWebSocket(url)
      sockets.push(socket)
      return socket
    },
  })
  const connecting = client.connect()
  assert.equal(sockets.length, 1)
  sockets[0]!.open()
  sockets[0]!.deliver(new MockHost().hello({ next_mseq: 1n, acked_mseq: 0n, durable_mseq: 0n }))
  await connecting

  // The default schedule is 100 ms doubling up to a 5 s ceiling.
  const delays = [100, 200, 400, 800, 1_600, 3_200, 5_000, 5_000]
  for (const delay of delays) {
    const socketCount: number = sockets.length
    sockets[socketCount - 1]!.drop()
    t.mock.timers.tick(delay - 1)
    assert.equal(sockets.length, socketCount, `no reconnect before ${String(delay)} ms`)
    t.mock.timers.tick(1)
    assert.equal(sockets.length, socketCount + 1, `reconnect after ${String(delay)} ms`)
  }
  await client.close()
})

test('the ChannelClient contract carries the 0x31 journal ack methods', async () => {
  const { client } = await connectClient()
  const channel: ChannelClient = client
  assert.equal(typeof channel.waitJournalAck, 'function')
  assert.equal(channel.journalAcked('session.1', 1), 0n)
  await client.close()
})

test('barrier sends VFS_BARRIER and resolves on the matching level-1 ack', async () => {
  const { client, host, socket } = await connectClient()
  let resolved = false
  const barrier = client.barrier(1, 42n).then(() => { resolved = true })
  await waitFor(() => sentFrames(socket).some(frame => frame.type === FrameType.VFS_BARRIER), 'the barrier')
  assert.equal(resolved, false)
  socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 42n })))
  await barrier
  assert.equal(resolved, true)
})

test('a barrier requested during a reconnect is sent after the new HELLO', async () => {
  const { client, sockets, socket } = await connectClient()
  socket.drop()
  const barrier = client.barrier(1, 42n)
  await waitFor(() => sockets.length === 2, 'the reconnect socket')
  const second = sockets[1]!
  second.open()
  await waitFor(() => second.sent.length === 1)
  const secondHost = new MockHost()
  second.deliver(secondHost.hello())
  await waitFor(
    () => sentFrames(second).some(frame => frame.type === FrameType.VFS_BARRIER),
    'the barrier after HELLO',
  )
  second.deliver(secondHost.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 42n })))
  await barrier
})

test('the Worker never sends API_REQ: request() and send(0x40) are protocol errors', async () => {
  const { client, socket } = await connectClient()
  assert.throws(
    () => client.request({ method: 'GET', path: '/api/status', headers: {} }, new Uint8Array(0)),
    /host->worker only/,
  )
  assert.throws(() => client.send(FrameType.API_REQ, encodeUtf8('{}')), /not outbound on a worker channel/)
  assert.equal(sentFrames(socket).filter(frame => frame.type === FrameType.API_REQ).length, 0)
  await client.close()
})

test('hostHello exposes the parsed host HELLO and refreshes on reconnect', async () => {
  const { client, sockets, socket } = await connectClient()
  const seen: HelloHostPayload[] = []
  const off = client.onHostHello(hello => { seen.push(hello) })
  try {
    assert.equal(client.hostHello?.role, 'host')
    assert.deepEqual(client.hostHello?.caps, ['channel/1', 'wal/1', 'exec/1', 'accelerator:rg'])
    assert.equal(client.hostHello?.next_mseq, 42n)
    assert.equal(seen.length, 0, 'the pre-listener HELLO is not replayed')

    socket.drop()
    const staleCaps: HelloHostPayload | undefined = client.hostHello
    assert.equal(staleCaps, undefined, 'stale caps do not survive the transport')
    await waitFor(() => sockets.length === 2, 'the reconnect socket')
    const second = sockets[1]!
    second.open()
    await waitFor(() => second.sent.length === 1, 'the second HELLO')
    const secondHost = new MockHost()
    second.deliver(secondHost.hello({
      caps: ['channel/1', 'wal/1', 'exec/1', 'accelerator:jaq'],
      next_mseq: 43n,
      acked_mseq: 41n,
    }))
    await waitFor(() => client.hostHello?.caps.includes('accelerator:jaq') === true, 'the refreshed hostHello')
    assert.deepEqual(client.hostHello?.caps, ['channel/1', 'wal/1', 'exec/1', 'accelerator:jaq'])
    assert.deepEqual(seen.map(hello => hello.caps.at(-1)), ['accelerator:jaq'])
  } finally {
    off()
    await client.close()
  }
})

test('journal acks remove records from the resend buffer', async () => {
  const { client, host, socket } = await connectClient()
  client.send(FrameType.JOURNAL, encodeJournal({ jseq: 1n, sessionId: 'session.1', record: encodeUtf8('a') }))
  await waitFor(() => sentFrames(socket).some(frame => frame.type === FrameType.JOURNAL))
  const waiting = client.waitJournalAck(1, 'session.1', 1n)
  socket.deliver(host.frame(FrameType.JOURNAL_ACK, encodeJournalAck({
    level: 1, sessionId: 'session.1', uptoJseq: 1n,
  })))
  await waiting
  assert.equal(client.journalAcked('session.1', 1), 1n)
})

test('close rejects pending acks', async () => {
  const { client, socket } = await connectClient()
  const waiting = client.waitAck(1, 99n)
  await client.close()
  await assert.rejects(waiting)
  assert.ok(socket.closeCalls.length > 0)
})

test('text WebSocket messages are a protocol error', async () => {
  const { socket } = await connectClient()
  socket.deliverText('not a frame')
  await waitFor(() => socket.closeCalls.length > 0, 'the close')
  const errorFrame = sentFrames(socket).find(frame => frame.type === FrameType.ERROR)
  assert.ok(errorFrame !== undefined)
  assert.equal((JSON.parse(decodeUtf8(errorFrame.payload)) as { code: string }).code, 'BAD_PAYLOAD')
})

test('frames split across WebSocket messages are decoded as a stream', async () => {
  const { client, host, socket } = await connectClient()
  const frame = host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 42n }))
  const bytes = frameBytes(frame)
  socket.deliverBytes(bytes.subarray(0, 7))
  socket.deliverBytes(bytes.subarray(7))
  await client.waitAck(1, 42n)
})

/** One host `ERROR VFS_REFUSED` frame (channel.md §4.8). */
function refusalFrame(
  host: MockHost,
  fields: Partial<Omit<VfsRefusedPayload, 'ref_seq'>> & {
    ref_seq?: number
    mseq?: number
    accepted_bytes?: number
  } = {},
): Frame {
  const payload = {
    code: 'VFS_REFUSED',
    message: 'host refused the mutation: EFBIG',
    path: '/dsh/workspace/big.bin',
    limit: 64 * 1024 * 1024,
    reason: 'file-too-large',
    ...fields,
  }
  return host.frame(FrameType.ERROR, encodeUtf8(canonicalStringify(payload)))
}

test('a host VFS_REFUSED is non-fatal and the next mutation reuses the refused mseq', async () => {
  const { client, host, socket } = await connectClient({}, 0n)
  const refusedSeq = client.send(
    FrameType.VFS_MUT,
    mutation(1n, '/dsh/workspace/big.bin', new Uint8Array(64)),
  )
  assert.equal(refusedSeq, 2n)
  const waiting = client.waitAck(1, 1n)
  socket.deliver(refusalFrame(host, { ref_seq: Number(refusedSeq), mseq: 1, accepted_bytes: 0 }))

  await assert.rejects(waiting, (error: unknown) => {
    assert.ok(error instanceof VfsRefusedError)
    assert.equal(error.code, 'EFBIG')
    assert.equal(error.path, '/dsh/workspace/big.bin')
    assert.equal(error.limit, 64 * 1024 * 1024)
    assert.equal(error.acceptedBytes, 0)
    assert.equal(error.reason, 'file-too-large')
    assert.equal(error.refusedMseq, 1n)
    return true
  })

  // The channel is still the same live connection: no close, no outbound
  // ERROR, and the host's unchanged expected mseq is reused.
  assert.equal(socket.closeCalls.length, 0)
  assert.equal(sentFrames(socket).some(frame => frame.type === FrameType.ERROR), false)
  assert.equal(client.admissionOpen, true)
  assert.equal(client.nextMseq(), 1n)
  assert.equal(client.ackedMseq(1), 0n)

  // The retried write is accepted at mseq 1 (the host never consumed it).
  const retriedSeq = client.send(
    FrameType.VFS_MUT,
    mutation(1n, '/dsh/workspace/next.bin', encodeUtf8('ok')),
  )
  assert.equal(retriedSeq, 3n)
  const mutations = sentFrames(socket)
    .filter(frame => frame.type === FrameType.VFS_MUT)
    .map(frame => decodeVfsMutation(frame.payload))
  assert.deepEqual(mutations.map(item => item.mseq), [1n, 1n])
  assert.equal(mutations[1]?.path, '/dsh/workspace/next.bin')

  socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 1n })))
  await client.waitAck(1, 1n)
  await client.close()
})

test('VFS_REFUSED carries the accepted prefix of an appended refusal', async () => {
  const { client, host, socket } = await connectClient({}, 0n)
  // An appended mutation whose accepted prefix the host reports as 8 MiB.
  const appended = encodeVfsMutation({
    mseq: 1n,
    op: VfsOp.WRITE,
    mode: 0o644,
    mflags: 2,
    appendFrom: 8n * 1024n * 1024n,
    path: '/dsh/workspace/appended.bin',
    data: new Uint8Array(64),
  })
  const refusedSeq = client.send(FrameType.VFS_MUT, appended)
  const waiting = client.waitAck(1, 1n)
  socket.deliver(refusalFrame(host, {
    path: '/dsh/workspace/appended.bin',
    limit: 16 * 1024 * 1024,
    ref_seq: Number(refusedSeq),
    mseq: 1,
    accepted_bytes: 8 * 1024 * 1024,
  }))

  await assert.rejects(waiting, (error: unknown) => {
    assert.ok(error instanceof VfsRefusedError)
    assert.equal(error.path, '/dsh/workspace/appended.bin')
    assert.equal(error.acceptedBytes, 8 * 1024 * 1024)
    assert.equal(error.refusedMseq, 1n)
    return true
  })
  assert.equal(socket.closeCalls.length, 0)
  assert.equal(client.nextMseq(), 1n)
  await client.close()
})

test('VFS_REFUSED without a structured mseq is located by ref_seq', async () => {
  const { client, host, socket } = await connectClient({}, 0n)
  const refusedSeq = client.send(
    FrameType.VFS_MUT,
    mutation(1n, '/dsh/workspace/diagnostic.bin', new Uint8Array(32)),
  )
  const waiting = client.waitAck(1, 1n)
  socket.deliver(refusalFrame(host, {
    path: '/dsh/workspace/diagnostic.bin',
    ref_seq: Number(refusedSeq),
  }))

  await assert.rejects(waiting, (error: unknown) => {
    assert.ok(error instanceof VfsRefusedError)
    assert.equal(error.code, 'EFBIG')
    assert.equal(error.acceptedBytes, 0)
    assert.equal(error.refusedMseq, undefined)
    return true
  })
  assert.equal(socket.closeCalls.length, 0)
  assert.equal(client.admissionOpen, true)
  assert.equal(client.nextMseq(), 1n)
  await client.close()
})

test('a genuine protocol ERROR still closes the channel', async () => {
  const { client, host, socket } = await connectClient({}, 0n)
  client.send(FrameType.VFS_MUT, mutation(1n, '/dsh/workspace/a.bin', encodeUtf8('x')))
  const waiting = client.waitAck(1, 1n)
  socket.deliver(host.frame(FrameType.ERROR, encodeUtf8(canonicalStringify({
    code: 'BAD_MSEQ',
    message: 'expected mseq 1, got 2',
    ref_seq: 2,
  }))))

  await waitFor(() => socket.closeCalls.length > 0, 'the protocol-error close')
  assert.equal(socket.closeCalls[0]?.code, 1002)
  assert.equal(client.admissionOpen, false)
  await assert.rejects(waiting, (error: unknown) => {
    assert.ok(error instanceof ChannelPeerError)
    assert.equal(error.code, 'BAD_MSEQ')
    return true
  })
  assert.throws(
    () => client.send(FrameType.VFS_MUT, mutation(1n, '/dsh/workspace/b.bin', encodeUtf8('y'))),
    ChannelPeerError,
  )
})

test('a malformed VFS_REFUSED is still a BAD_PAYLOAD protocol error', async () => {
  const { client, host, socket } = await connectClient({}, 0n)
  client.send(FrameType.VFS_MUT, mutation(1n, '/dsh/workspace/a.bin', encodeUtf8('x')))
  socket.deliver(host.frame(FrameType.ERROR, encodeUtf8(canonicalStringify({
    code: 'VFS_REFUSED',
    message: 'missing limit',
    path: '/dsh/workspace/a.bin',
    reason: 'file-too-large',
  }))))
  await waitFor(() => socket.closeCalls.length > 0, 'the malformed-refusal close')
  const errorFrame = sentFrames(socket).find(frame => frame.type === FrameType.ERROR)
  assert.ok(errorFrame !== undefined)
  assert.equal((JSON.parse(decodeUtf8(errorFrame.payload)) as { code: string }).code, 'BAD_PAYLOAD')
  await assert.rejects(client.waitAck(1, 1n), ChannelPeerError)
})

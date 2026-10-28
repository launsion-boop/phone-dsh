// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'
import {
  ChannelRequestError, decodeApiRequest, decodeUtf8, encodeApiAbort, encodeApiEnd, encodeApiResponse,
  encodeJournal, encodeJournalAck, encodeUtf8, encodeVfsMutation, FrameType, MAX_UNACKED_VFS_BYTES,
  makeHostHello, readU64be, RING_TIMEOUT_MS, VfsOp, type Frame, type HelloHostPayload,
} from './index.ts'
import { createMemoryChannelPair } from './memory-channel.ts'

function tick(): Promise<void> {
  return new Promise(resolve => setImmediate(resolve))
}

function mutation(mseq: bigint, text = 'hello\n'): Uint8Array {
  return encodeVfsMutation({
    mseq,
    op: VfsOp.WRITE,
    mode: 0o644,
    mflags: 1,
    appendFrom: 0n,
    path: '/dsh/workspace/notes.txt',
    data: encodeUtf8(text),
  })
}

function mseqOf(frame: Frame): bigint {
  return readU64be(frame.payload, 0)
}

test('flow-control constants match D3', () => {
  assert.equal(MAX_UNACKED_VFS_BYTES, 32 * 1024 * 1024)
  assert.equal(RING_TIMEOUT_MS, 30_000)
})

test('send assigns consecutive seq values and level-1 acks advance ackedMseq', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 42n })
  await pair.host.connect()
  await pair.worker.connect()
  const received: Frame[] = []
  pair.host.onFrame(frame => received.push(frame))

  assert.equal(pair.worker.nextMseq(), 42n)
  assert.equal(pair.worker.send(FrameType.VFS_MUT, mutation(42n)), 1n)
  assert.equal(pair.worker.nextMseq(), 43n)
  assert.equal(pair.worker.send(FrameType.VFS_MUT, mutation(43n)), 2n)
  assert.equal(pair.worker.nextMseq(), 44n)
  await tick()

  assert.deepEqual(received.map(mseqOf), [42n, 43n])
  assert.equal(pair.worker.ackedMseq(1), 43n)
  assert.equal(pair.worker.ackedMseq(2), 0n)
})

test('a barrier gets a matching ack without blocking the next frame', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 42n })
  await pair.host.connect()
  await pair.worker.connect()
  pair.worker.send(FrameType.VFS_MUT, mutation(42n))
  await pair.worker.barrier(1, 42n)
  assert.equal(pair.worker.ackedMseq(1), 42n)
  await pair.worker.barrier(2, 42n)
  assert.equal(pair.worker.ackedMseq(2), 42n)
})

test('reconnect resends only unacked VFS_MUT with their original mseq', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 42n })
  await pair.host.connect()
  await pair.worker.connect()
  const received: bigint[] = []
  pair.host.onFrame(frame => {
    if (frame.type === FrameType.VFS_MUT) received.push(mseqOf(frame))
  })

  // The third mutation is lost in transit; the host accepted 42 and 43.
  pair.setDrop((direction, frame) =>
    direction === 'worker->host' && frame.type === FrameType.VFS_MUT && mseqOf(frame) === 44n)
  pair.worker.send(FrameType.VFS_MUT, mutation(42n))
  pair.worker.send(FrameType.VFS_MUT, mutation(43n))
  pair.worker.send(FrameType.VFS_MUT, mutation(44n))
  await tick()
  assert.deepEqual(received, [42n, 43n])
  assert.equal(pair.worker.ackedMseq(1), 43n)

  pair.disconnect()
  pair.setDrop(undefined)
  await pair.reconnect()
  await tick()

  assert.deepEqual(received, [42n, 43n, 44n], 'only mseq 44 is re-sent, preserving its number')
  assert.equal(pair.worker.ackedMseq(1), 44n)
  assert.equal(pair.host.expectedInboundMseq, 45n)
})

test('the host accepts only the expected mseq and reports BAD_MSEQ', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 42n })
  await pair.host.connect()
  await pair.worker.connect()
  pair.worker.send(FrameType.VFS_MUT, mutation(42n))
  await tick()

  const errors: Frame[] = []
  pair.worker.onFrame(frame => {
    if (frame.type === FrameType.ERROR) errors.push(frame)
  })
  pair.worker.send(FrameType.VFS_MUT, mutation(42n))
  await tick()

  assert.equal(errors.length, 1)
  const payload = JSON.parse(decodeUtf8(errors[0]!.payload)) as { code: string }
  assert.equal(payload.code, 'BAD_MSEQ')
  assert.equal(pair.host.expectedInboundMseq, 43n, 'the rejected mutation does not advance the host')
})

test('request streams API_RES chunks until API_END', async () => {
  const pair = createMemoryChannelPair()
  await pair.host.connect()
  await pair.worker.connect()
  pair.worker.onFrame(frame => {
    if (frame.type !== FrameType.API_REQ) return
    const request = decodeApiRequest(frame.payload)
    pair.worker.send(FrameType.API_RES, encodeApiResponse({
      reqId: request.reqId,
      head: { status: 200, headers: { 'content-type': 'text/plain' } },
      body: encodeUtf8('hello '),
    }))
    pair.worker.send(FrameType.API_RES, encodeApiResponse({
      reqId: request.reqId,
      head: undefined,
      body: encodeUtf8('world'),
    }))
    pair.worker.send(FrameType.API_END, encodeApiEnd(request.reqId))
  })

  const chunks: { head: unknown; body: string }[] = []
  for await (const chunk of pair.host.request(
    { method: 'POST', path: '/api/session/message', headers: { 'content-type': 'application/json' } },
    encodeUtf8('{"text":"hi"}'),
  )) {
    chunks.push({ head: chunk.head, body: decodeUtf8(chunk.body) })
  }
  assert.deepEqual(chunks, [
    { head: { status: 200, headers: { 'content-type': 'text/plain' } }, body: 'hello ' },
    { head: undefined, body: 'world' },
  ])
})

test('request rejects when the peer aborts it', async () => {
  const pair = createMemoryChannelPair()
  await pair.host.connect()
  await pair.worker.connect()
  pair.worker.onFrame(frame => {
    if (frame.type !== FrameType.API_REQ) return
    const request = decodeApiRequest(frame.payload)
    pair.worker.send(FrameType.API_ABORT, encodeApiAbort(request.reqId, 'client_cancelled'))
  })

  const consume = async (): Promise<void> => {
    for await (const chunk of pair.host.request(
      { method: 'GET', path: '/api/x', headers: {} },
      new Uint8Array(0),
    )) {
      void chunk
    }
  }
  await assert.rejects(consume, (error: unknown) =>
    error instanceof ChannelRequestError && error.reason === 'client_cancelled')
})

test('delayed delivery preserves order and waitAck observes it', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 1n, delayMs: 5 })
  await pair.host.connect()
  await pair.worker.connect()
  const received: bigint[] = []
  pair.host.onFrame(frame => {
    if (frame.type === FrameType.VFS_MUT) received.push(mseqOf(frame))
  })
  pair.worker.send(FrameType.VFS_MUT, mutation(1n))
  pair.worker.send(FrameType.VFS_MUT, mutation(2n))
  assert.deepEqual(received, [])
  await pair.worker.waitAck(1, 2n)
  assert.deepEqual(received, [1n, 2n])
  assert.equal(pair.worker.ackedMseq(1), 2n)
})

test('waitAck rejects when the connection drops', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 1n, autoAck: false })
  await pair.host.connect()
  await pair.worker.connect()
  pair.worker.send(FrameType.VFS_MUT, mutation(1n))
  const waiting = pair.worker.waitAck(1, 1n)
  pair.disconnect()
  await assert.rejects(waiting, /disconnected/)
})

test('a delayed drop of an ack keeps the mutation buffered for the reconnect', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 7n })
  await pair.host.connect()
  await pair.worker.connect()
  // Drop the level-1 ack for mseq 7 only.
  pair.setDrop((direction, frame) => direction === 'host->worker' && frame.type === FrameType.VFS_ACK)
  pair.worker.send(FrameType.VFS_MUT, mutation(7n))
  await sleep(5)
  assert.equal(pair.worker.ackedMseq(1), 6n)
  pair.disconnect()
  pair.setDrop(undefined)
  await pair.reconnect()
  await sleep(5)
  assert.equal(pair.worker.ackedMseq(1), 7n)
})

test('the pair is connected on creation', async () => {
  const pair = createMemoryChannelPair({ nextMseq: 1n })
  assert.equal(pair.worker.send(FrameType.VFS_MUT, mutation(1n)), 1n)
  await tick()
  assert.equal(pair.worker.ackedMseq(1), 1n)
})

test('disconnect aborts in-flight requests with connection_closed', async () => {
  const pair = createMemoryChannelPair()
  const consume = async (): Promise<void> => {
    for await (const chunk of pair.host.request(
      { method: 'GET', path: '/api/stream', headers: {} },
      new Uint8Array(0),
    )) {
      void chunk
    }
  }
  const running = consume()
  await tick()
  pair.disconnect()
  await assert.rejects(running, (error: unknown) =>
    error instanceof ChannelRequestError && error.reason === 'connection_closed')
})

test('hostHello is exposed to the worker and refreshed on reconnect', async () => {
  const first = makeHostHello({ caps: ['accelerator:rg'], ackedMseq: 5n, nextMseq: 6n, durableMseq: 4n })
  const pair = createMemoryChannelPair({ hostHello: first })
  await tick()
  const seen: HelloHostPayload[] = []
  const off = pair.worker.onHostHello(hello => { seen.push(hello) })
  try {
    assert.deepEqual(pair.worker.hostHello?.caps, first.caps)
    assert.equal(pair.worker.ackedMseq(1), 5n)
    assert.equal(pair.worker.ackedMseq(2), 4n)

    const second = makeHostHello({ caps: ['accelerator:jaq'], ackedMseq: 5n, nextMseq: 6n })
    pair.setHostHello(second)
    pair.disconnect()
    const stale: HelloHostPayload | undefined = pair.worker.hostHello
    assert.equal(stale, undefined)
    await pair.reconnect()
    assert.deepEqual(pair.worker.hostHello?.caps, second.caps)
    assert.deepEqual(seen.map(hello => hello.caps.at(-1)), ['accelerator:jaq'])
  } finally {
    off()
  }
})

test('a Worker-side memory channel cannot send API_REQ', () => {
  const pair = createMemoryChannelPair()
  assert.throws(
    () => pair.worker.request({ method: 'GET', path: '/api/x', headers: {} }, new Uint8Array(0)),
    /host->worker only/,
  )
})

test('JOURNAL_ACK updates the one tracker and the worker never decodes it twice', async () => {
  const pair = createMemoryChannelPair()
  pair.worker.send(FrameType.JOURNAL, encodeJournal({
    jseq: 1n, sessionId: 'session.1', record: encodeUtf8('{"t":"start"}'),
  }))
  await tick()
  const waiting = pair.worker.waitJournalAck(1, 'session.1', 1n)
  pair.host.send(FrameType.JOURNAL_ACK, encodeJournalAck({ level: 1, sessionId: 'session.1', uptoJseq: 1n }))
  await waiting
  assert.equal(pair.worker.journalAcked('session.1', 1), 1n)
})

test('the global injection points are declared and unset in tests', () => {
  assert.equal(globalThis.__PDSH_CHANNEL__, undefined)
  assert.equal(globalThis.__PDSH_LIFECYCLE__, undefined)
  assert.equal(globalThis.__PDSH_FENCE__, undefined)
})

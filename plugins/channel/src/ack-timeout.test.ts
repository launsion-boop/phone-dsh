// SPDX-License-Identifier: MIT
// G2-FIX-10 regression: a lost durability ack must never park a caller. The
// pre-fix AckTracker.wait() only rejected on abort/rejectAll and the WebSocket
// client had no fail-loud path, so this test hung until the runner timeout.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  AckTimeoutError, AckTracker, DEFAULT_DURABILITY_ACK_TIMEOUT_MS, VFS_ACK_KEY,
  resolveDurabilityAckTimeoutMs,
} from './ack-tracker.ts'
import { canonicalStringify } from './canonical-json.ts'
import { decodeUtf8, encodeUtf8 } from './bytes.ts'
import { FrameDecoder, FrameType, encodeFrame, type Frame } from './frames.ts'
import type { HelloHostPayload } from './payloads.ts'
import { decodeJournal, decodeVfsMutation, encodeJournal, encodeVfsMutation, VfsOp } from './vfs-mutation.ts'
import { WebSocketChannelClient, type WebSocketLike } from './ws-client.ts'

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
    this.emit('message', { data: encodeFrame(frame) })
  }

  private emit(type: string, event: unknown): void {
    for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event)
  }
}

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
      caps: ['channel/1', 'wal/1', 'exec/1'],
      next_mseq: 42,
      acked_mseq: 41,
      durable_mseq: 40,
      ...overrides,
    }
    return this.frame(FrameType.HELLO, encodeUtf8(canonicalStringify(payload)))
  }
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

test('the durability wait window is a validated named constant with an env override', () => {
  assert.equal(DEFAULT_DURABILITY_ACK_TIMEOUT_MS, 30_000)
  assert.equal(resolveDurabilityAckTimeoutMs(), 30_000)
  assert.equal(resolveDurabilityAckTimeoutMs(5), 5)
  assert.throws(() => resolveDurabilityAckTimeoutMs(0), RangeError)
  assert.throws(() => resolveDurabilityAckTimeoutMs(-1), RangeError)
  assert.throws(() => resolveDurabilityAckTimeoutMs(1.5), RangeError)
  const previous = process.env.PDSH_DURABILITY_ACK_TIMEOUT_MS
  try {
    process.env.PDSH_DURABILITY_ACK_TIMEOUT_MS = '1234'
    assert.equal(resolveDurabilityAckTimeoutMs(), 1234)
    process.env.PDSH_DURABILITY_ACK_TIMEOUT_MS = 'not-a-number'
    assert.throws(() => resolveDurabilityAckTimeoutMs(), RangeError)
  } finally {
    if (previous === undefined) delete process.env.PDSH_DURABILITY_ACK_TIMEOUT_MS
    else process.env.PDSH_DURABILITY_ACK_TIMEOUT_MS = previous
  }
})

test('AckTracker.wait rejects with ACK_TIMEOUT when the ack never arrives', async () => {
  const tracker = new AckTracker({ timeoutMs: 10 })
  const started = Date.now()
  await assert.rejects(
    tracker.wait(VFS_ACK_KEY, 1, 3n),
    (error: unknown) => error instanceof AckTimeoutError
      && error.code === 'ACK_TIMEOUT'
      && error.timeoutMs === 10,
  )
  assert.equal(tracker.pending, 0)
  assert.ok(Date.now() - started < 1_000, 'the wait must be bounded by the configured window')
})

test('ack timeout sends ERROR, reconnects and replays the original jseq/mseq', async () => {
  const sockets: MockWebSocket[] = []
  const client = new WebSocketChannelClient({
    url: 'ws://127.0.0.1:1234/channel',
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
    lastMseq: 41n,
    ackTimeoutMs: 10,
    backoffMinMs: 1,
    backoffMaxMs: 4,
    createSocket: (url) => {
      const socket = new MockWebSocket(url)
      sockets.push(socket)
      return socket
    },
  })
  try {
    const connecting = client.connect()
    await waitFor(() => sockets.length === 1, 'the first socket')
    const socket = sockets[0]!
    socket.open()
    await waitFor(() => socket.sent.length === 1, 'the worker HELLO')
    socket.deliver(new MockHost().hello())
    await connecting

    client.send(FrameType.VFS_MUT, encodeVfsMutation({
      mseq: 42n, op: VfsOp.WRITE, mode: 0o644, mflags: 0, appendFrom: 0n,
      path: '/dsh/workspace/a.txt', data: encodeUtf8('hello'),
    }))
    client.send(FrameType.JOURNAL, encodeJournal({
      jseq: 7n, sessionId: 'session.1', record: encodeUtf8('{"event":7}'),
    }))
    // The host swallows both acks: the callers must reject, not hang.
    const journalWait = client.waitJournalAck(1, 'session.1', 7n)
    const vfsWait = client.waitAck(1, 42n)
    await assert.rejects(journalWait, (error: unknown) => error instanceof AckTimeoutError)
    await assert.rejects(vfsWait, (error: unknown) => error instanceof AckTimeoutError)
    await waitFor(() => socket.closeCalls.length > 0, 'the fail-loud close')
    const errorFrame = sentFrames(socket).find(frame => frame.type === FrameType.ERROR)
    assert.ok(errorFrame !== undefined, 'an ERROR frame must precede the close')
    assert.equal((JSON.parse(decodeUtf8(errorFrame.payload)) as { code: string }).code, 'RING_TIMEOUT')

    // The existing reconnect path replays the unacked buffers with their
    // original application-level keys (D2/D3).
    await waitFor(() => sockets.length === 2, 'the reconnect socket')
    const second = sockets[1]!
    second.open()
    await waitFor(() => second.sent.length === 1, 'the second HELLO')
    second.deliver(new MockHost().hello())
    await waitFor(
      () => sentFrames(second).filter(frame => frame.type === FrameType.JOURNAL).length === 1,
      'the JOURNAL replay',
    )
    const replayed = sentFrames(second).filter(
      frame => frame.type === FrameType.VFS_MUT || frame.type === FrameType.JOURNAL,
    )
    assert.equal(replayed.length, 2)
    assert.equal(replayed[0]!.type, FrameType.VFS_MUT)
    assert.equal(decodeVfsMutation(replayed[0]!.payload).mseq, 42n)
    assert.equal(replayed[1]!.type, FrameType.JOURNAL)
    const journal = decodeJournal(replayed[1]!.payload)
    assert.equal(journal.sessionId, 'session.1')
    assert.equal(journal.jseq, 7n)
  } finally {
    await client.close()
  }
})

// SPDX-License-Identifier: MIT
/**
 * G2-FIX-103 repair: one host `ERROR VFS_REFUSED` diagnostic reaches the
 * write-outcome tracker twice — the sink's `onFrame` hook observes the frame
 * while the command-boundary `flush()` parked on the same mseq has its
 * `waitAck()` rejected by it. Both call sites deliver the refusal to
 * `VfsWriteOutcomes.noteRefusal`, and pre-fix the second delivery renumbers
 * every later in-flight write a second time and then rejects the write that
 * moved into the freed slot even though the host never refused it.
 *
 * This drives the real `WebSocketChannelClient`, the real sink and a scripted
 * host over a real frame path: three proxied writes are published, the command
 * flush parks on the last mseq, and the host refuses the first one. After the
 * refusal each surviving write must settle on its own ack, on the same
 * connection, with no channel teardown.
 *
 * The last vector refuses the write the channel renumbered into the freed slot:
 * that is a different mutation at the same reused slot and must be applied, not
 * dropped as a duplicate of the previous occupant's refusal.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  canonicalStringify, decodeVfsMutation, encodeFrame, encodeUtf8, encodeVfsAck,
  FrameDecoder, FrameType, makeHostHello, WebSocketChannelClient,
  type Frame, type WebSocketLike,
} from '../channel/src/index.ts'
import { installSink, VfsRefusalError, type WorkerEntryMutation } from '../worker-entry/src/entry.ts'
import { VfsProxyError, VfsWriteOutcomes, type VfsWriteTicket } from '../wasi-toolbox/src/index.ts'

const BOOT_ID = '00112233445566778899aabbccddeeff'
const FENCE = { owner: 'phone', generation: 0n, wal_seq: 0n } as const
const REFUSED_PATH = '/dsh/workspace/refused.bin'
const LATER_PATH = '/dsh/workspace/later.bin'
const THIRD_PATH = '/dsh/workspace/third.bin'
const HOST_LIMIT = 1024

/** Fail with a clear message instead of letting a hung test stall the suite. */
function withWatchdog<T>(promise: Promise<T>, what: string, ms = 5_000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`watchdog: ${what} did not settle in ${ms} ms`)), ms)
    promise.then(
      (value) => { clearTimeout(timer); resolve(value) },
      (error: unknown) => { clearTimeout(timer); reject(error) },
    )
  })
}

/** Minimal `WebSocket` face with a synchronous scripted host behind `send()`. */
class MockSocket implements WebSocketLike {
  readonly sent: Uint8Array[] = []
  readonly closeCalls: { code: number | undefined; reason: string | undefined }[] = []
  readonly url: string
  readyState = 0
  binaryType = 'arraybuffer'
  onFrame: ((frame: Frame) => void) | undefined
  private readonly listeners = new Map<string, Set<(event: unknown) => void>>()

  constructor(url: string) {
    this.url = url
  }

  send(data: ArrayBuffer | ArrayBufferView | string): void {
    if (this.readyState !== 1) throw new Error('mock socket: send() before open')
    if (typeof data === 'string') throw new Error('the channel sends binary frames only')
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    this.sent.push(bytes.slice())
    for (const frame of new FrameDecoder().push(bytes)) this.onFrame?.(frame)
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

/** Host-side connection seq counter; every mutation is withheld unless refused. */
class MockHost {
  private seq = 0n
  readonly received: Frame[] = []

  frame(type: FrameType, payload: Uint8Array): Frame {
    this.seq += 1n
    return { type, seq: this.seq, payload }
  }

  hello(): Frame {
    return this.frame(FrameType.HELLO, encodeUtf8(canonicalStringify(makeHostHello({
      bootId: 'ffeeddccbbaa99887766554433221100',
      sessionEpoch: 7n,
      fence: FENCE,
      caps: ['channel/1', 'wal/1', 'exec/1'],
      ackedMseq: 0n,
      nextMseq: 1n,
      durableMseq: 0n,
    }))))
  }

  refusal(mutation: { mseq: bigint; path: string }, refSeq: bigint): Frame {
    return this.frame(FrameType.ERROR, encodeUtf8(canonicalStringify({
      code: 'VFS_REFUSED',
      message: `host refused mseq ${String(mutation.mseq)}: ${mutation.path} would grow past ${String(HOST_LIMIT)} bytes`,
      path: mutation.path,
      limit: HOST_LIMIT,
      reason: 'file-too-large',
      mseq: mutation.mseq,
      accepted_bytes: 0,
      ref_seq: refSeq,
    })))
  }

  mutations(): ReturnType<typeof decodeVfsMutation>[] {
    return this.received.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
  }
}

/** The runtime's synchronous publish contract: observers run during the write. */
class MemoryVfs {
  private readonly listeners = new Set<(mutation: WorkerEntryMutation) => void>()

  subscribe(listener: (mutation: WorkerEntryMutation) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  async flush(): Promise<void> {}

  write(path: string, bytes: Uint8Array): void {
    this.publish({ kind: 'write', path, bytes: new Uint8Array(bytes), mode: 0o644, entryChanged: true })
  }

  private publish(mutation: WorkerEntryMutation): void {
    for (const listener of [...this.listeners]) listener(mutation)
  }
}

interface Fixture {
  readonly client: WebSocketChannelClient
  readonly socket: MockSocket
  readonly host: MockHost
  readonly vfs: MemoryVfs
  readonly outcomes: VfsWriteOutcomes
  readonly dispose: () => void
}

async function fixture(): Promise<Fixture> {
  const socket = new MockSocket('ws://127.0.0.1:1234/channel')
  const host = new MockHost()
  const client = new WebSocketChannelClient({
    url: socket.url,
    bootId: BOOT_ID,
    sessionEpoch: 7n,
    fence: FENCE,
    lastMseq: 0n,
    createSocket: () => socket,
    backoffMinMs: 1,
    backoffMaxMs: 2,
  })
  // Acks are withheld: the test delivers the refusal and each ack explicitly,
  // so the parked flush is genuinely waiting when the diagnostic arrives.
  socket.onFrame = (frame) => { host.received.push(frame) }
  const connecting = client.connect()
  socket.open()
  socket.deliver(host.hello())
  await connecting
  const vfs = new MemoryVfs()
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 5_000 })
  const dispose = installSink(vfs, client, { writeOutcomes: outcomes })
  return { client, socket, host, vfs, outcomes, dispose }
}

/** Begin a ticket, publish one write through the sink, and close its window. */
function publishWrite(outcomes: VfsWriteOutcomes, vfs: MemoryVfs, path: string, size = 8): VfsWriteTicket {
  const ticket = outcomes.begin(path)
  vfs.write(path, new Uint8Array(size))
  outcomes.endPublishing(ticket)
  return ticket
}

/** The most recent VFS_MUT frame the host saw for one mutation slot and path. */
function latestMutationFrame(host: MockHost, mseq: bigint, path: string): Frame {
  const found = [...host.received].reverse().find((frame) => {
    if (frame.type !== FrameType.VFS_MUT) return false
    const mutation = decodeVfsMutation(frame.payload)
    return mutation.mseq === mseq && mutation.path === path
  })
  assert.notEqual(found, undefined, `no VFS_MUT for mseq ${String(mseq)} ${path}`)
  return found as Frame
}

test('G2-FIX-103: a refusal delivered to a parked flush settles the write and keeps the channel', {
  timeout: 30_000,
}, async () => {
  const { client, socket, host, vfs, outcomes, dispose } = await fixture()
  try {
    const refused = publishWrite(outcomes, vfs, REFUSED_PATH)
    assert.deepEqual(host.mutations().map(mutation => mutation.mseq), [1n])

    // The command fence parks on the write's mseq. The refusal arrives while
    // that wait is in flight, so it must settle both the write ticket and the
    // flush without consuming the mseq or closing the connection.
    const flush = vfs.flush()
    await new Promise<void>((resolve) => { setTimeout(resolve, 20) })
    const refusedFrame = host.received.find(frame => frame.type === FrameType.VFS_MUT)
    assert.notEqual(refusedFrame, undefined, 'the refused VFS_MUT was sent')
    socket.deliver(host.refusal({ mseq: 1n, path: REFUSED_PATH }, (refusedFrame as Frame).seq))

    await assert.rejects(withWatchdog(flush, 'parked flush'), (error: unknown) => {
      assert.ok(error instanceof VfsRefusalError, `expected the sink refusal, got ${String(error)}`)
      assert.equal(error.code, 'EFBIG')
      assert.equal(error.path, REFUSED_PATH)
      return true
    })
    await assert.rejects(
      withWatchdog(outcomes.awaitOutcome(refused), 'refused write'),
      /EFBIG: VFS refused/,
    )
    assert.equal(outcomes.pending, 0, 'the write ticket settled exactly once')
    assert.equal(socket.closeCalls.length, 0, 'the refusal did not close the connection')
    assert.equal(client.admissionOpen, true)
    assert.equal(client.nextMseq(), 1n, 'the refusal consumed no mseq')
  } finally {
    dispose()
    await client.close()
  }
})

test('G2-FIX-103: a refusal seen by both the frame hook and a parked flush settles once', {
  timeout: 30_000,
}, async () => {
  const { client, socket, host, vfs, outcomes, dispose } = await fixture()
  try {
    const refused = publishWrite(outcomes, vfs, REFUSED_PATH)
    const later = publishWrite(outcomes, vfs, LATER_PATH, 4)
    const third = publishWrite(outcomes, vfs, THIRD_PATH, 4)
    assert.deepEqual(host.mutations().map(mutation => mutation.mseq), [1n, 2n, 3n])

    // The command boundary parks on the last emitted mseq. Let its waitAck()
    // register before the host refuses the first mutation: the refusal then
    // reaches the tracker through the frame hook *and* through the rejected
    // wait, which is the double-delivery the repair makes idempotent.
    const flush = vfs.flush()
    await new Promise<void>((resolve) => { setTimeout(resolve, 20) })
    const refusedFrame = host.received.find(frame => frame.type === FrameType.VFS_MUT
      && decodeVfsMutation(frame.payload).mseq === 1n)
    assert.notEqual(refusedFrame, undefined, 'the refused VFS_MUT was sent')
    socket.deliver(host.refusal({ mseq: 1n, path: REFUSED_PATH }, (refusedFrame as Frame).seq))

    await assert.rejects(withWatchdog(flush, 'parked flush'), (error: unknown) => {
      assert.ok(error instanceof VfsRefusalError, `expected the sink refusal, got ${String(error)}`)
      assert.equal(error.code, 'EFBIG')
      assert.equal(error.path, REFUSED_PATH)
      assert.equal(error.limit, HOST_LIMIT)
      return true
    })

    // The refusal consumed mseq 1: the channel renumbers the two in-flight
    // writes to 1 and 2 and re-sends them. A duplicated delivery must not
    // renumber them again or settle one as refused.
    assert.deepEqual(host.mutations().map(mutation => mutation.mseq), [1n, 2n, 3n, 1n, 2n])
    assert.equal(outcomes.pending, 2, 'both concurrent writes still await their own ack')

    socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 1n })))
    await withWatchdog(outcomes.awaitOutcome(later), 'first concurrent write')
    assert.equal(outcomes.pending, 1, 'ack 1 covers only the first renumbered write')

    socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 2n })))
    await withWatchdog(outcomes.awaitOutcome(third), 'second concurrent write')
    assert.equal(outcomes.pending, 0, 'no proxied write stayed pending')

    // The refusal stayed a non-closing diagnostic and the connection is usable.
    assert.equal(socket.closeCalls.length, 0, 'the refusal did not close the connection')
    assert.equal(client.admissionOpen, true)
    assert.equal(client.nextMseq(), 3n, 'the refused mseq was reused by the renumbered writes')
  } finally {
    dispose()
    await client.close()
  }
})

test('G2-FIX-103: a genuine refusal of the write renumbered into a refused slot settles it and keeps the channel', {
  timeout: 30_000,
}, async () => {
  const { client, socket, host, vfs, outcomes, dispose } = await fixture()
  try {
    const refused = publishWrite(outcomes, vfs, REFUSED_PATH)
    const later = publishWrite(outcomes, vfs, LATER_PATH, 4)
    const third = publishWrite(outcomes, vfs, THIRD_PATH, 4)
    assert.deepEqual(host.mutations().map(mutation => mutation.mseq), [1n, 2n, 3n])

    // First refusal: it arrives while the command fence is parked on the last
    // mseq, so the tracker sees it through the frame hook and again through the
    // rejected waitAck. The duplicate delivery must not renumber twice.
    const flush = vfs.flush()
    await new Promise<void>((resolve) => { setTimeout(resolve, 20) })
    const firstFrame = latestMutationFrame(host, 1n, REFUSED_PATH)
    socket.deliver(host.refusal({ mseq: 1n, path: REFUSED_PATH }, firstFrame.seq))
    await assert.rejects(withWatchdog(flush, 'parked flush'), (error: unknown) => {
      assert.ok(error instanceof VfsRefusalError, `expected the sink refusal, got ${String(error)}`)
      assert.equal(error.code, 'EFBIG')
      assert.equal(error.path, REFUSED_PATH)
      return true
    })
    await assert.rejects(withWatchdog(outcomes.awaitOutcome(refused), 'refused write'), /EFBIG: VFS refused/)
    assert.equal(outcomes.pending, 2, 'the duplicate delivery must not settle a survivor')
    assert.deepEqual(host.mutations().map(mutation => mutation.mseq), [1n, 2n, 3n, 1n, 2n],
      'the two surviving writes were renumbered and re-sent exactly once')

    // The channel renumbered `later` into the refused slot 1 and re-sent it. The
    // host now genuinely refuses that mutation: the same slot, a different
    // mutation. A dedupe set keyed by mseq alone would silently drop this
    // diagnostic and leave the write parked until the flow-control window.
    const renumbered = latestMutationFrame(host, 1n, LATER_PATH)
    socket.deliver(host.refusal({ mseq: 1n, path: LATER_PATH }, renumbered.seq))
    await assert.rejects(
      withWatchdog(outcomes.awaitOutcome(later), 'write refused at the reused slot'),
      (error: unknown) => {
        assert.ok(error instanceof VfsProxyError, `expected the tracker refusal, got ${String(error)}`)
        assert.equal(error.code, 'EFBIG')
        assert.equal(error.path, LATER_PATH)
        assert.match(error.message, /1024 bytes/, 'the reused-slot refusal carries its own limit')
        return true
      },
    )
    assert.equal(outcomes.pending, 1, 'only the third write survives the second refusal')

    // The second refusal freed slot 1 again; the third write was renumbered into
    // it and settles on the host's renumbered ack, on the same connection.
    socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 1n })))
    await withWatchdog(outcomes.awaitOutcome(third), 'write renumbered after the second refusal')
    assert.equal(outcomes.pending, 0, 'no proxied write stayed pending')
    assert.equal(socket.closeCalls.length, 0, 'neither refusal closed the connection')
    assert.equal(client.admissionOpen, true)
    assert.equal(client.nextMseq(), 2n, 'the second refused mseq was reused by the survivor')
  } finally {
    dispose()
    await client.close()
  }
})

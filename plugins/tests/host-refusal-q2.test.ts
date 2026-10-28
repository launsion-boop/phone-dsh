// SPDX-License-Identifier: MIT
/**
 * G2-FIX-Q2 regression: a host budget refusal of a VFS mutation
 * (`ERROR VFS_REFUSED`) must reach the write that caused it as the same
 * structured `VfsRefusalError` a Worker-side `EFBIG` pre-check raises.
 *
 * Pre-fix the WebSocket channel client treated every inbound ERROR as fatal;
 * the host's non-closing resource refusal therefore closed the connection from
 * the Worker side, `vfs.flush()` surfaced a channel failure, and the
 * bash/python/write tool step ended in a disconnect instead of a tool error.
 * These tests drive the real `WebSocketChannelClient` plus the real sink over a
 * scripted host socket and pin the whole path: structured refusal to the tool
 * caller, live connection, and the refused mseq reused by the next mutation.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  canonicalStringify, decodeUtf8, decodeVfsMutation, encodeFrame, encodeUtf8, encodeVfsAck,
  FrameDecoder, FrameType, makeHostHello, VfsOp, VfsRefusedError, WebSocketChannelClient,
  type Frame, type WebSocketLike,
} from '../channel/src/index.ts'
import {
  installSink, VfsRefusalError, type WorkerEntryMutation,
} from '../worker-entry/src/entry.ts'
import { parseShellTrailer } from '../shell-ext/src/index.ts'

const BOOT_ID = '00112233445566778899aabbccddeeff'
const FENCE = { owner: 'phone', generation: 0n, wal_seq: 0n } as const
const REFUSED_PATH = '/dsh/workspace/host-refused.bin'
const HOST_LIMIT = 1024

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

/** Host-side connection seq counter and scripted frame replies. */
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

  protocolError(code: string, message: string): Frame {
    return this.frame(FrameType.ERROR, encodeUtf8(canonicalStringify({ code, message })))
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

  remove(path: string): void {
    this.publish({ kind: 'remove', path })
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
  // Scripted host: refuse the budget target, acknowledge everything else.
  socket.onFrame = (frame) => {
    host.received.push(frame)
    if (frame.type !== FrameType.VFS_MUT) return
    const mutation = decodeVfsMutation(frame.payload)
    if (mutation.path === REFUSED_PATH && mutation.op === VfsOp.WRITE) {
      socket.deliver(host.refusal(mutation, frame.seq))
    } else {
      socket.deliver(host.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: mutation.mseq })))
    }
  }
  const connecting = client.connect()
  socket.open()
  socket.deliver(host.hello())
  await connecting
  const vfs = new MemoryVfs()
  const dispose = installSink(vfs, client)
  return { client, socket, host, vfs, dispose }
}

function mutations(host: MockHost): ReturnType<typeof decodeVfsMutation>[] {
  return host.received.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
}

function assertRefusalTrailer(error: VfsRefusalError): void {
  const trailer = parseShellTrailer(error.message.trimEnd().split('\n').at(-1) as string)
  assert.notEqual(trailer, undefined, 'the tool-visible refusal carries the shared trailer')
  assert.equal(trailer?.exitCode, 1)
  assert.equal(trailer?.program, 'vfs')
  assert.equal(trailer?.reason, 'limit-refused')
}

test('G2-FIX-Q2: a host VFS_REFUSED reaches the write as a structured tool error and keeps the channel', async () => {
  const { client, socket, host, vfs, dispose } = await fixture()
  try {
    vfs.write(REFUSED_PATH, new Uint8Array(2 * HOST_LIMIT))
    await assert.rejects(vfs.flush(), (error: unknown) => {
      assert.ok(error instanceof VfsRefusalError)
      assert.equal(error.code, 'EFBIG')
      assert.equal(error.path, REFUSED_PATH)
      assert.equal(error.limit, HOST_LIMIT)
      assert.equal(error.acceptedBytes, 0)
      assertRefusalTrailer(error)
      return true
    })

    // Same connection, no teardown, and the refused mseq is still free.
    assert.equal(socket.closeCalls.length, 0)
    assert.equal(client.admissionOpen, true)
    assert.equal(client.nextMseq(), 1n)
    assert.deepEqual(mutations(host).map(mutation => mutation.mseq), [1n])

    // The poison is persistent like a local EFBIG: another boundary fails the
    // same way without emitting another VFS_MUT.
    await assert.rejects(vfs.flush(), VfsRefusalError)
    assert.deepEqual(mutations(host).map(mutation => mutation.mseq), [1n])

    // Repairing the path (the write tool's cleanup) reuses mseq 1.
    vfs.remove(REFUSED_PATH)
    await vfs.flush()
    assert.deepEqual(mutations(host).map(mutation => mutation.mseq), [1n, 1n])
    assert.equal(mutations(host).at(-1)?.path, REFUSED_PATH)

    // The session keeps writing; the next mutation takes the following mseq.
    vfs.write('/dsh/workspace/after.txt', encodeUtf8('ok'))
    await vfs.flush()
    assert.deepEqual(mutations(host).map(mutation => mutation.mseq), [1n, 1n, 2n])
    assert.equal(decodeUtf8(mutations(host).at(-1)?.data as Uint8Array), 'ok')
    assert.equal(socket.closeCalls.length, 0)
  } finally {
    dispose()
    await client.close()
  }
})

test('G2-FIX-Q2: a genuine protocol ERROR still closes the channel', async () => {
  const { client, socket, host, vfs, dispose } = await fixture()
  try {
    // Script one closing protocol error for an ordinary (non-budget) path.
    socket.onFrame = (frame) => {
      host.received.push(frame)
      if (frame.type !== FrameType.VFS_MUT) return
      socket.deliver(host.protocolError('BAD_MSEQ', 'expected mseq 7, got 1'))
    }
    vfs.write('/dsh/workspace/protocol.bin', encodeUtf8('x'))
    await assert.rejects(vfs.flush(), (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'BAD_MSEQ')
      return true
    })
    assert.equal(socket.closeCalls.length > 0, true)
    assert.equal(client.admissionOpen, false)
    assert.equal(vfs.flush !== undefined, true)
    await assert.rejects(vfs.flush(), /BAD_MSEQ/)
  } finally {
    dispose()
    await client.close()
  }
})

test('VfsRefusedError exposes the wire refusal fields', () => {
  const error = new VfsRefusedError({
    code: 'VFS_REFUSED',
    message: 'EFBIG detail',
    path: '/dsh/workspace/a',
    limit: 16 * 1024 * 1024,
    reason: 'file-too-large',
    mseq: 5n,
    acceptedBytes: 0,
  })
  assert.equal(error.code, 'EFBIG')
  assert.equal(error.path, '/dsh/workspace/a')
  assert.equal(error.limit, 16 * 1024 * 1024)
  assert.equal(error.acceptedBytes, 0)
  assert.equal(error.refusedMseq, 5n)
  assert.equal(error.reason, 'file-too-large')
})

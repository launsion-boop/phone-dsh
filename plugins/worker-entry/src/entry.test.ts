// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import {
  bytesToHex, canonicalStringify, createMemoryChannelPair, decodeUtf8, decodeVfsMutation,
  encodeJournal, encodeUtf8, encodeVfsAck, FrameType, MAX_MUTATION_DATA, VfsOp,
  type Frame, type MemoryChannelClient, type MemoryChannelPair,
} from '../../channel/src/index.ts'
import { FrameDecoder } from '../../channel/src/frames.ts'
import {
  bootFromInit, installConsoleForwarding, installSink, serveApiRequests, startPhoneWorker, workerEvents,
  type PhoneWorkerHostLike, type PhoneWorkerHostOptions, type PhoneWorkerRuntime,
  type WorkerEntryMutation, type WorkerEntryRequestListener, type WorkerEntrySynthesize,
  type WorkerEntryVfs,
} from './entry.ts'

const here = fileURLToPath(new URL('..', import.meta.url))
const encoder = new TextEncoder()

function decodeFrame(bytes: Uint8Array): Frame {
  const frames = new FrameDecoder().push(bytes)
  assert.equal(frames.length, 1)
  return frames[0]!
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
}

function collect(client: MemoryChannelClient): Frame[] {
  const frames: Frame[] = []
  client.onFrame((frame) => frames.push(frame))
  return frames
}

interface TestVfs extends WorkerEntryVfs {
  emit(mutation: WorkerEntryMutation): void
  readonly flushCalls: number
  readonly observerErrors: unknown[]
}

function createTestVfs(): TestVfs {
  const listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  const observerErrors: unknown[] = []
  let flushCalls = 0
  return {
    subscribe(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    async flush() { flushCalls += 1 },
    emit(mutation) {
      for (const listener of [...listeners]) {
        try {
          listener(mutation)
        } catch (error) {
          observerErrors.push(error)
        }
      }
    },
    get flushCalls() { return flushCalls },
    get observerErrors() { return observerErrors },
  }
}

function writeMutation(path: string, text: string): WorkerEntryMutation {
  return { kind: 'write', path, bytes: encodeUtf8(text), mode: 0o644, entryChanged: true }
}

function vfsFrames(frames: readonly Frame[]): Frame[] {
  return frames.filter(frame => frame.type === FrameType.VFS_MUT)
}

function connectPair(options: Parameters<typeof createMemoryChannelPair>[0] = {}): MemoryChannelPair {
  return createMemoryChannelPair({ autoConnect: true, ...options })
}

test('installSink encodes every committed mutation as VFS_MUT and filters roots', async () => {
  const pair = connectPair({ nextMseq: 42n, ackedMseq: 41n, autoAck: false })
  const vfs = createTestVfs()
  const hostFrames = collect(pair.host)
  const dispose = installSink(vfs, pair.worker)
  try {
    vfs.emit(writeMutation('/dsh/home/a.txt', 'hi'))
    // The runtime publishes the complete post-write bytes plus the offset the
    // append started at (storage/types.ts), never a bare suffix.
    vfs.emit({
      kind: 'write',
      path: '/dsh/workspace/b.txt',
      bytes: encodeUtf8('hellolo'),
      mode: 0o644,
      entryChanged: false,
      appendedFrom: 5,
    })
    vfs.emit({ kind: 'mkdir', path: '/dsh/workspace/dir', mode: 0o755 })
    vfs.emit({ kind: 'remove', path: '/dsh/workspace/gone' })
    vfs.emit({ kind: 'chmod', path: '/dsh/home/a.txt', mode: 0o600 })
    // D4: tmp and every other root are never sent, and roots are not targets.
    vfs.emit(writeMutation('/dsh/tmp/scratch', 'x'))
    vfs.emit(writeMutation('/etc/passwd', 'x'))
    vfs.emit(writeMutation('/dsh/home', 'x'))
    await settle()

    const mutations = vfsFrames(hostFrames).map(frame => decodeVfsMutation(frame.payload))
    assert.equal(mutations.length, 5)
    assert.equal(mutations[0]!.mseq, 42n)
    assert.equal(mutations[0]!.op, VfsOp.WRITE)
    assert.equal(mutations[0]!.path, '/dsh/home/a.txt')
    assert.equal(decodeUtf8(mutations[0]!.data), 'hi')
    assert.equal(mutations[0]!.mflags & 1, 1)
    assert.equal(mutations[1]!.mseq, 43n)
    assert.equal(mutations[1]!.mflags & 2, 2)
    assert.equal(mutations[1]!.appendFrom, 5n)
    assert.equal(decodeUtf8(mutations[1]!.data), 'lo')
    assert.equal(mutations[2]!.op, VfsOp.MKDIR)
    assert.equal(mutations[2]!.mode, 0o755)
    assert.equal(mutations[3]!.op, VfsOp.REMOVE)
    assert.equal(mutations[3]!.mode, 0)
    assert.equal(mutations[4]!.op, VfsOp.CHMOD)
    assert.equal(mutations[4]!.mode, 0o600)
    assert.equal(pair.worker.nextMseq(), 47n)
  } finally {
    dispose()
  }
})

test('an append encodes the suffix exactly like the vfs-mut-append-1 golden vector', async () => {
  // P0-1 regression: the runtime's VfsMutation carries the complete post-write
  // bytes; 0x10 carries only data from append_from onward (channel.md §3.1).
  const pair = connectPair({ nextMseq: 43n, ackedMseq: 42n, autoAck: false })
  const vfs = createTestVfs()
  const hostFrames = collect(pair.host)
  const dispose = installSink(vfs, pair.worker)
  try {
    vfs.emit({
      kind: 'write',
      path: '/dsh/workspace/notes.txt',
      bytes: encodeUtf8('hello\nworld\n'),
      mode: 0o644,
      entryChanged: false,
      appendedFrom: 6,
    })
    await settle()
    const frames = vfsFrames(hostFrames)
    assert.equal(frames.length, 1)
    const golden = JSON.parse(readFileSync(
      join(here, '../../spec/v1/golden/frames/vfs-mut-append-1.json'),
      'utf8',
    )) as { payload_hex: string }
    assert.equal(bytesToHex(frames[0]!.payload), golden.payload_hex)
    const mutation = decodeVfsMutation(frames[0]!.payload)
    assert.equal(mutation.appendFrom, 6n)
    assert.equal(decodeUtf8(mutation.data), 'world\n')
  } finally {
    dispose()
  }
})

test('disposing the sink restores flush and keeps other observers subscribed', async () => {
  const pair = connectPair({ nextMseq: 42n, ackedMseq: 41n, autoAck: false })
  const vfs = createTestVfs()
  const seen: WorkerEntryMutation[] = []
  const keep = vfs.subscribe((mutation) => { seen.push(mutation) })
  const dispose = installSink(vfs, pair.worker)
  const wrappedFlush = vfs.flush
  dispose()
  try {
    assert.notEqual(vfs.flush, wrappedFlush, 'the original flush is restored')
    vfs.emit(writeMutation('/dsh/home/kept.txt', 'x'))
    await settle()
    assert.equal(seen.length, 1, 'an unrelated observer survives the sink disposal')
  } finally {
    keep()
  }
})

test('installSink refuses a write above the configured single-file limit without closing the channel', async () => {
  const pair = connectPair({ nextMseq: 1n })
  const vfs = createTestVfs()
  const hostFrames = collect(pair.host)
  const dispose = installSink(vfs, pair.worker, { maxFileBytes: MAX_MUTATION_DATA })
  try {
    const path = '/dsh/workspace/big.bin'
    vfs.emit({
      kind: 'write',
      path,
      bytes: new Uint8Array(MAX_MUTATION_DATA + 1),
      mode: 0o644,
      entryChanged: true,
    })
    assert.equal(vfs.observerErrors.length, 1)
    assert.match(String(vfs.observerErrors[0]), /limited to/)
    assert.equal((vfs.observerErrors[0] as { code?: string }).code, 'EFBIG')
    assert.equal((vfs.observerErrors[0] as { limit?: number }).limit, MAX_MUTATION_DATA)
    await settle()
    assert.equal(pair.worker.nextMseq(), 1n, 'the refused mutation consumes no mseq')
    assert.equal(vfsFrames(hostFrames).length, 0, 'no oversized frame reaches the host')
    const refusal = hostFrames
      .filter(frame => frame.type === FrameType.ERROR)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as Record<string, unknown>)
    assert.equal(refusal.length, 1)
    assert.equal(refusal[0]?.['code'], 'VFS_REFUSED')
    assert.equal(refusal[0]?.['path'], path)
    assert.equal(refusal[0]?.['limit'], MAX_MUTATION_DATA)
    // Resource refusal poisons the flush with a model-visible trailer but
    // leaves the ordered channel open.
    await assert.rejects(vfs.flush(), (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'EFBIG')
      assert.match(String((error as Error).message), /pdsh-shell: exit=1 program=vfs reason=limit-refused/)
      return true
    })
    // The repair mutation (delete) clears the poison and the session continues.
    vfs.emit({ kind: 'remove', path })
    await vfs.flush()
    vfs.emit(writeMutation('/dsh/workspace/after.txt', 'ok'))
    await vfs.flush()
    const mutations = vfsFrames(hostFrames).map(frame => decodeVfsMutation(frame.payload))
    assert.equal(mutations.at(-1)?.path, '/dsh/workspace/after.txt')
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('installSink refuses a small append that would grow a file past the configured single-file limit', async () => {
  const pair = connectPair({ nextMseq: 1n })
  const vfs = createTestVfs()
  const hostFrames = collect(pair.host)
  const dispose = installSink(vfs, pair.worker, { maxFileBytes: MAX_MUTATION_DATA })
  try {
    const path = '/dsh/workspace/big-append.bin'
    // A 1-byte suffix is a legal frame on its own, but the post-write file would
    // be over the D4 15 MiB limit; the runtime publishes the whole file, so the
    // total size is known and must be refused rather than persisted.
    vfs.emit({
      kind: 'write',
      path,
      bytes: new Uint8Array(MAX_MUTATION_DATA + 1),
      mode: 0o644,
      entryChanged: false,
      appendedFrom: MAX_MUTATION_DATA,
    })
    assert.equal(vfs.observerErrors.length, 1)
    assert.match(String(vfs.observerErrors[0]), /limited to/)
    assert.equal((vfs.observerErrors[0] as { code?: string }).code, 'EFBIG')
    assert.equal(pair.worker.nextMseq(), 1n)
    assert.equal(vfsFrames(hostFrames).length, 0, 'the legal-looking suffix is not sent')
    await assert.rejects(vfs.flush(), (error: unknown) => (error as { code?: string }).code === 'EFBIG')
    vfs.emit({ kind: 'remove', path })
    await vfs.flush()
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('vfs.flush() waits for a level-1 ack of the last emitted mseq', async () => {
  const pair = connectPair({ nextMseq: 42n, ackedMseq: 41n, autoAck: false })
  const vfs = createTestVfs()
  const dispose = installSink(vfs, pair.worker)
  try {
    vfs.emit(writeMutation('/dsh/workspace/a.txt', 'hello'))
    await settle()
    let flushed = false
    const flushing = vfs.flush().then(() => { flushed = true })
    await settle()
    assert.equal(flushed, false, 'flush must not resolve before the ack')
    pair.host.send(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: 42n }))
    await flushing
    assert.equal(flushed, true)
    assert.equal(vfs.flushCalls, 1)
  } finally {
    dispose()
  }
})

test('unacked sink mutations are re-sent with the original mseq after a reconnect', async () => {
  const pair = connectPair({ nextMseq: 42n, ackedMseq: 41n, autoAck: false })
  const vfs = createTestVfs()
  const hostFrames = collect(pair.host)
  const dispose = installSink(vfs, pair.worker)
  try {
    // The first VFS_MUT never reaches the host, so the host tail stays at 41.
    pair.setDrop((direction, frame) => direction === 'worker->host' && frame.type === FrameType.VFS_MUT)
    vfs.emit(writeMutation('/dsh/workspace/resend.txt', 'once'))
    await settle()
    assert.equal(vfsFrames(hostFrames).length, 0)
    pair.setDrop(undefined)
    pair.disconnect()
    await pair.reconnect()
    await settle()
    const mutations = vfsFrames(hostFrames)
    assert.equal(mutations.length, 1, 'the buffered mutation is resent exactly once')
    assert.equal(decodeVfsMutation(mutations[0]!.payload).mseq, 42n)
    assert.equal(pair.host.expectedInboundMseq, 43n)
  } finally {
    dispose()
  }
})

/** Minimal IncomingMessage/ServerResponse synthesis for the API bridge tests. */
const testSynthesize: WorkerEntrySynthesize = (request, sink) => {
  const listeners = new Map<string, Set<() => void>>()
  const emit = (event: string): void => {
    for (const callback of [...(listeners.get(event) ?? [])]) callback()
  }
  let status = 200
  let headers: Record<string, string> = {}
  let streaming = false
  let finished = false
  let aborted = false
  const req = {
    method: request.method,
    url: request.path,
    headers: request.headers,
    async *[Symbol.asyncIterator](): AsyncGenerator<Uint8Array> {
      if (request.body.byteLength > 0) yield request.body
    },
  }
  const res: Record<string, unknown> = {
    writeHead(nextStatus: number, nextHeaders?: Record<string, string>): unknown {
      status = nextStatus
      headers = nextHeaders === undefined ? {} : { ...nextHeaders }
      return res
    },
    write(chunk: string | Uint8Array): boolean {
      if (finished) return false
      if (!streaming) {
        streaming = true
        sink.head(status, headers)
      }
      sink.chunk(typeof chunk === 'string' ? encoder.encode(chunk) : chunk)
      return true
    },
    end(body?: string | Uint8Array): unknown {
      if (finished) return res
      finished = true
      if (streaming) {
        if (body !== undefined) sink.chunk(typeof body === 'string' ? encoder.encode(body) : body)
        sink.end()
      } else {
        sink.end({
          status,
          headers,
          body: body === undefined ? undefined : typeof body === 'string' ? encoder.encode(body) : body,
        })
      }
      emit('close')
      return res
    },
    destroy(): void {
      if (finished) return
      finished = true
      sink.fail('response destroyed')
      emit('close')
    },
    on(event: string, callback: () => void): unknown {
      const set = listeners.get(event) ?? new Set()
      set.add(callback)
      listeners.set(event, set)
      return res
    },
    once(event: string, callback: () => void): unknown {
      return (res.on as (type: string, listener: () => void) => unknown)(event, callback)
    },
    off(event: string, callback: () => void): unknown {
      listeners.get(event)?.delete(callback)
      return res
    },
  }
  return {
    req,
    res,
    get aborted(): boolean { return aborted },
    abort(): void {
      if (finished) return
      aborted = true
      finished = true
      emit('aborted')
      emit('close')
    },
  }
}

test('serveApiRequests feeds API_REQ into the captured listener and streams the response', async () => {
  const pair = connectPair()
  const listener: WorkerEntryRequestListener = (req, res) => {
    const request = req as { method: string; url: string }
    const response = res as {
      writeHead: (status: number, headers: Record<string, string>) => void
      write: (chunk: string) => void
      end: (body?: string) => void
    }
    assert.equal(request.method, 'POST')
    assert.equal(request.url, '/api/chat?q=1')
    response.writeHead(200, { 'content-type': 'text/plain' })
    response.write('hello ')
    setTimeout(() => { response.end('world') }, 0)
  }
  const dispose = serveApiRequests(pair.worker, async () => listener, { synthesize: testSynthesize })
  try {
    const chunks: { head: unknown; body: string }[] = []
    for await (const chunk of pair.host.request(
      { method: 'POST', path: '/api/chat?q=1', headers: { host: '127.0.0.1' } },
      encodeUtf8('{"q":1}'),
    )) {
      chunks.push({ head: chunk.head ?? null, body: decodeUtf8(chunk.body) })
    }
    assert.equal(chunks.length, 2)
    assert.deepEqual(chunks[0]!.head, { status: 200, headers: { 'content-type': 'text/plain' } })
    assert.equal(chunks[0]!.body, 'hello ')
    assert.equal(chunks[1]!.body, 'world')
  } finally {
    dispose()
  }
})

test('serveApiRequests answers API_ABORT when the listener destroys the response', async () => {
  const pair = connectPair()
  const listener: WorkerEntryRequestListener = (_req, res) => {
    (res as { destroy: () => void }).destroy()
  }
  const dispose = serveApiRequests(pair.worker, async () => listener, { synthesize: testSynthesize })
  try {
    const iterator = pair.host.request({ method: 'GET', path: '/api/fail', headers: {} }, new Uint8Array(0))[Symbol.asyncIterator]()
    await assert.rejects(iterator.next(), /destroyed/)
  } finally {
    dispose()
  }
})

test('installConsoleForwarding mirrors log/warn/error as CONSOLE frames', async () => {
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const forwarder = installConsoleForwarding(pair.worker)
  try {
    console.log('hello %s', 'world')
    console.warn('careful')
    console.error('broken')
    // stdout is only mirrored for the readiness line, and a console line must
    // not also arrive through the stdout hook.
    process.stdout.write('plain stdout\n')
    await settle()
    const lines = hostFrames
      .filter(frame => frame.type === FrameType.CONSOLE)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as { level: string; text: string })
    assert.deepEqual(lines, [
      { level: 'info', text: 'hello %s world' },
      { level: 'warn', text: 'careful' },
      { level: 'error', text: 'broken' },
    ])
  } finally {
    forwarder.dispose()
  }
})

test('installConsoleForwarding ignores binary stdout before the readiness line', async () => {
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const forwarder = installConsoleForwarding(pair.worker)
  try {
    // A test runner (or a plugin writing a Buffer) puts non-string frames on
    // stdout. They can contain newlines and must not poison the partial-line
    // buffer that the readiness line is read from.
    process.stdout.write(Buffer.from('binary stdout\n') as unknown as string)
    process.stdout.write('XL_DSH_READY 43124\n')
    await settle()
    const lines = hostFrames
      .filter(frame => frame.type === FrameType.CONSOLE)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as { level: string; text: string })
    assert.deepEqual(lines, [{ level: 'info', text: 'XL_DSH_READY 43124' }])
  } finally {
    forwarder.dispose()
  }
})

test('installConsoleForwarding routes the XL_DSH_READY stdout line as a CONSOLE frame', async () => {
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const forwarder = installConsoleForwarding(pair.worker)
  try {
    // `surface-phone` writes readiness with process.stdout.write, not console.*.
    process.stdout.write('XL_DSH_READY 43123\n')
    await settle()
    const lines = hostFrames
      .filter(frame => frame.type === FrameType.CONSOLE)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as { level: string; text: string })
    assert.deepEqual(lines, [{ level: 'info', text: 'XL_DSH_READY 43123' }])
  } finally {
    forwarder.dispose()
  }
})

test('startPhoneWorker installs channel globals, mirrors LIFECYCLE/FENCE and posts pdsh-ready', async () => {
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const vfs = createTestVfs()
  const listener: WorkerEntryRequestListener = (_req, res) => {
    (res as { end: (body?: string) => void }).end('ok')
  }
  const host: PhoneWorkerHostLike = {
    handleMessage: () => {},
    // `surface-phone` prints readiness from a plugin during host startup.
    start: async () => { process.stdout.write('XL_DSH_READY 45001\n') },
    vfs,
  }
  const pageMessages: unknown[] = []
  let hostOptions: PhoneWorkerHostOptions | undefined
  const runtime: PhoneWorkerRuntime = {
    createHost: (options) => {
      hostOptions = options
      return host
    },
    whenRequestListener: async () => listener,
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  const events: unknown[] = []
  const lifecycleListener = (event: Event): void => { events.push((event as CustomEvent).detail) }
  workerEvents.addEventListener('pdsh-lifecycle', lifecycleListener)
  workerEvents.addEventListener('pdsh-fence', lifecycleListener)
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    token: 'token',
    imageURL: 'image.tar.gz',
    overlayURLs: ['deployment-overlay.tar.gz'],
    fence: { owner: 'phone', generation: 3n, wal_seq: 41n },
    bootId: '00112233445566778899aabbccddeeff',
    sessionEpoch: 7n,
    runtime,
    pagePost: (message) => { pageMessages.push(message) },
  })
  try {
    assert.deepEqual(pageMessages, [{ t: 'pdsh-ready' }])
    // The profile stub overlay is applied before every deployment overlay, so
    // a deployment-supplied profile manifest still wins.
    assert.notEqual(hostOptions, undefined)
    assert.equal(hostOptions?.overlays.length, 2)
    const stubOverlay = hostOptions?.overlays[0]
    assert.ok(stubOverlay instanceof Uint8Array)
    assert.deepEqual([...stubOverlay.subarray(0, 2)], [0x1f, 0x8b], 'the profile stub is a gzip member')
    assert.equal(hostOptions?.overlays[1], 'deployment-overlay.tar.gz')
    // The memory channel delivers frames in queued microtasks; let the READY
    // line reach the host side before inspecting it.
    await settle()
    // PLAN §2.2: the readiness line reaches the host as 0x60 CONSOLE.
    const consoleLines = hostFrames
      .filter(frame => frame.type === FrameType.CONSOLE)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as { level: string; text: string })
    assert.ok(consoleLines.some(line => line.text === 'XL_DSH_READY 45001'), 'XL_DSH_READY goes through the CONSOLE frame')
    const globals = globalThis as unknown as {
      __PDSH_CHANNEL__?: unknown
      __PDSH_LIFECYCLE__?: { state: string; admission: string }
      __PDSH_FENCE__?: { fence: { owner: string }; admission: string }
    }
    assert.equal(globals.__PDSH_CHANNEL__, pair.worker)
    assert.equal(globals.__PDSH_FENCE__?.fence.owner, 'phone')
    assert.equal(globals.__PDSH_FENCE__?.admission, 'open')

    pair.host.send(FrameType.LIFECYCLE, encodeUtf8(canonicalStringify({
      state: 'pause', budget: 250, admission: 'closed', reason: 'background',
    })))
    pair.host.send(FrameType.FENCE, encodeUtf8(canonicalStringify({
      fence: { owner: 'phone', generation: 4, wal_seq: 50 },
      admission: 'open',
    })))
    await settle()
    assert.equal(globals.__PDSH_LIFECYCLE__?.state, 'pause')
    assert.equal(globals.__PDSH_LIFECYCLE__?.admission, 'closed')
    assert.equal(globals.__PDSH_FENCE__?.fence.owner, 'phone')
    const lifecycleEvent = events.find((detail) => (detail as { state?: string }).state === 'pause')
    assert.ok(lifecycleEvent !== undefined)
    const fenceEvent = events.find((detail) => (detail as { fence?: unknown }).fence !== undefined)
    assert.ok(fenceEvent !== undefined)
  } finally {
    await handle.stop()
    workerEvents.removeEventListener('pdsh-lifecycle', lifecycleListener)
    workerEvents.removeEventListener('pdsh-fence', lifecycleListener)
    const globals = globalThis as unknown as { __PDSH_LIFECYCLE__?: unknown; __PDSH_FENCE__?: unknown }
    globals.__PDSH_LIFECYCLE__ = undefined
    globals.__PDSH_FENCE__ = undefined
  }
})

test('bootFromInit redacts image token/env from CONSOLE and page errors', async () => {
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const pageMessages: unknown[] = []
  const globals = globalThis as unknown as { self?: unknown }
  const previousSelf = Object.getOwnPropertyDescriptor(globals, 'self')
  Object.defineProperty(globals, 'self', {
    configurable: true,
    value: { postMessage(message: unknown) { pageMessages.push(message) } },
  })
  const token = 'SECRET-TOKEN'
  const envSecret = 'SECRET-ENV'
  const image = `http://127.0.0.1:7411/image.tar.gz?token=${token}`
  const runtime: PhoneWorkerRuntime = {
    createHost: (options) => ({
      handleMessage: () => {},
      vfs: createTestVfs(),
      // The pinned runtime's readImage error repeats the full image URL; the
      // Native page URL appends the launch token. Include the process env too,
      // because channelEnvironment also carries PDSH_CHANNEL_TOKEN.
      start: async () => {
        throw new Error(
          `webworker host: image fetch failed with 503 for ${options.image} `
          + `env=${JSON.stringify(options.env)}`,
        )
      },
    }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  try {
    bootFromInit({
      image,
      overlays: [`http://127.0.0.1:7411/overlay.tar.gz?token=${token}`],
      xl: {
        channelURL: `ws://127.0.0.1:1/channel?token=${token}`,
        token,
        env: { PDSH_LAUNCH_TOKEN: envSecret, PDSH_SANDBOX_MODE: 'read-only' },
        fence: { owner: 'phone', generation: 0, wal_seq: 0 },
      },
    }, runtime)
    await settle()
    await settle()
    const consoleText = hostFrames
      .filter(frame => frame.type === FrameType.CONSOLE)
      .map(frame => (JSON.parse(decodeUtf8(frame.payload)) as { text: string }).text)
    const visible = [...consoleText, JSON.stringify(pageMessages)].join('\n')
    assert.match(visible, /image fetch failed with 503/, 'the useful diagnostic survives')
    assert.match(visible, /\[redacted\]/)
    assert.doesNotMatch(visible, /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
  } finally {
    if (previousSelf === undefined) delete globals.self
    else Object.defineProperty(globals, 'self', previousSelf)
  }
})

test('bootFromInit posts a terminal pdsh-error for pre-host failures', async () => {
  const pageMessages: { t?: unknown; message?: unknown }[] = []
  const globals = globalThis as unknown as { self?: unknown }
  const previousSelf = Object.getOwnPropertyDescriptor(globals, 'self')
  Object.defineProperty(globals, 'self', {
    configurable: true,
    value: { postMessage(message: unknown) { pageMessages.push(message as { t?: unknown; message?: unknown }) } },
  })
  const token = 'SECRET-TOKEN'
  const envSecret = 'SECRET-ENV'
  const runtime: PhoneWorkerRuntime = {
    createHost: () => { throw new Error('host must not start') },
    whenRequestListener: async () => () => {},
    // createChannel runs before the host and before startPhoneWorker's inner
    // try: the outer wrapper must still report to the page.
    createChannel: () => {
      throw new Error(
        `webworker host: channel failed for ?token=${token} `
        + `env=${JSON.stringify({ PDSH_LAUNCH_TOKEN: envSecret })}`,
      )
    },
    synthesize: testSynthesize,
  }
  try {
    // Field validation can fail after the query parsed, before any host exists.
    bootFromInit({
      image: `http://127.0.0.1:7411/image.tar.gz?token=${token}`,
      overlays: [],
      xl: {
        channelURL: `ws://127.0.0.1:1/channel?token=${token}`,
        token,
        env: { PDSH_LAUNCH_TOKEN: envSecret },
        fence: { owner: '', generation: 0, wal_seq: 0 },
      },
    })
    await settle()
    bootFromInit({
      image: `http://127.0.0.1:7411/image.tar.gz?token=${token}`,
      overlays: [],
      xl: {
        channelURL: `ws://127.0.0.1:1/channel?token=${token}`,
        token,
        env: { PDSH_LAUNCH_TOKEN: envSecret },
        fence: { owner: 'phone', generation: 0, wal_seq: 0 },
      },
    }, runtime)
    await settle()
    await settle()
    assert.equal(pageMessages.length, 2)
    assert.equal(pageMessages[0]?.t, 'pdsh-error')
    assert.match(String(pageMessages[0]?.message), /fence\.owner is required/)
    assert.equal(pageMessages[1]?.t, 'pdsh-error')
    assert.match(String(pageMessages[1]?.message), /channel failed/)
    assert.match(String(pageMessages[1]?.message), /\[redacted\]/)
    for (const frame of pageMessages) {
      assert.doesNotMatch(String(frame.message), /SECRET-TOKEN|SECRET-ENV|PDSH_LAUNCH_TOKEN/)
    }
  } finally {
    if (previousSelf === undefined) delete globals.self
    else Object.defineProperty(globals, 'self', previousSelf)
  }
})

test('startPhoneWorker wires the budget-table maxFileBytes into the VFS sink', async () => {
  // G2-ENG-03 repair: the sink's policy override must be reachable from the
  // production boot, not only from tests calling `installSink` directly.
  const pair = connectPair()
  const hostFrames = collect(pair.host)
  const vfs = createTestVfs()
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({ handleMessage: () => {}, start: async () => {}, vfs }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    runtime,
    limits: { maxFileBytes: 1024 },
    pagePost: () => {},
  })
  try {
    vfs.emit({
      kind: 'write',
      path: '/dsh/workspace/policy.bin',
      bytes: new Uint8Array(2048),
      mode: 0o644,
      entryChanged: true,
    })
    await settle()
    const refusals = hostFrames
      .filter(frame => frame.type === FrameType.ERROR)
      .map(frame => JSON.parse(decodeUtf8(frame.payload)) as Record<string, unknown>)
      .filter(payload => payload['code'] === 'VFS_REFUSED')
    assert.equal(refusals.length, 1)
    assert.equal(refusals[0]?.['limit'], 1024, 'the budget bound reaches the sink')
    assert.match(String(refusals[0]?.['message']), /1024 bytes/)
    assert.equal(vfs.observerErrors.length, 1)
    assert.equal((vfs.observerErrors[0] as { code?: string }).code, 'EFBIG')
  } finally {
    await handle.stop()
  }
})

test('startPhoneWorker rejects a non-integer sink limit before boot', async () => {
  const pair = connectPair()
  const vfs = createTestVfs()
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({ handleMessage: () => {}, start: async () => {}, vfs }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  await assert.rejects(startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    runtime,
    limits: { maxFileBytes: 1.5 },
    pagePost: () => {},
  }), /maxFileBytes/)
})

test('startPhoneWorker rejects an invalid flow-control window before boot', async () => {
  const pair = connectPair()
  const vfs = createTestVfs()
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({ handleMessage: () => {}, start: async () => {}, vfs }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize: testSynthesize,
  }
  // D3's bound is a validated config field: a zero/negative/non-integer value
  // fails the boot instead of restoring the unbounded wait it exists to remove.
  for (const flowControlTimeoutMs of [0, -1, 1.5]) {
    await assert.rejects(startPhoneWorker({
      channelURL: 'ws://127.0.0.1:1/channel',
      imageURL: 'image.tar.gz',
      runtime,
      limits: { flowControlTimeoutMs },
      pagePost: () => {},
    }), /flow-control timeout/)
  }
})

test('serveApiRequests aborts in-flight responses on a transport loss', async () => {
  const pair = connectPair()
  let release: (() => void) | undefined
  const listener: WorkerEntryRequestListener = (_req, res) => {
    const response = res as {
      writeHead: (status: number, headers: Record<string, string>) => void
      write: (chunk: string) => void
      end: () => void
    }
    response.writeHead(200, {})
    release = () => { response.end() }
  }
  const dispose = serveApiRequests(pair.worker, async () => listener, { synthesize: testSynthesize })
  try {
    const iterator = pair.host.request({ method: 'GET', path: '/api/slow', headers: {} }, new Uint8Array(0))[Symbol.asyncIterator]()
    const pending = iterator.next()
    await settle()
    pair.disconnect()
    await assert.rejects(pending, /connection_closed|not connected|closed/)
  } finally {
    dispose()
  }
})

test('WS frames and journal frames do not reach the API listener', async () => {
  const pair = connectPair()
  let calls = 0
  const dispose = serveApiRequests(pair.worker, async () => () => { calls += 1 }, { synthesize: testSynthesize })
  try {
    pair.worker.send(FrameType.JOURNAL, encodeJournal({ jseq: 1n, sessionId: 's1', record: encodeUtf8('x') }))
    await settle()
    assert.equal(calls, 0)
  } finally {
    dispose()
  }
})

test('build.mjs --check bundles the entry against the pinned checkout', (t) => {
  const checkout = process.env.PDSH_DSH_CHECKOUT ?? readCheckoutFile()
  if (checkout === undefined || !existsSync(checkout)) {
    t.skip('PDSH_DSH_CHECKOUT is unset and ~/.config/phone-dsh/dsh-checkout has no usable path')
    return
  }
  const result = spawnSync(process.execPath, ['build.mjs', '--check'], {
    cwd: here,
    env: { ...process.env, PDSH_DSH_CHECKOUT: checkout },
    encoding: 'utf8',
    timeout: 180_000,
  })
  assert.equal(result.status, 0, `${result.stdout ?? ''}\n${result.stderr ?? ''}`)
  assert.match(result.stdout, /build check: ok/)
})

function readCheckoutFile(): string | undefined {
  const path = `${homedir()}/.config/phone-dsh/dsh-checkout`
  if (!existsSync(path)) return undefined
  const line = readFileSync(path, 'utf8').trim()
  return line === '' ? undefined : line
}

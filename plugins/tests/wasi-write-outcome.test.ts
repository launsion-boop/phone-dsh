// SPDX-License-Identifier: MIT
/**
 * G2-FIX-103 regression: the WASI interpreter's real large-write path over the
 * VFS proxy must observe the host's outcome.
 *
 * G2-A09 (attempt 7, head 80039e0, after the visible-refusal chain had landed)
 * ended at the toolCall of a `python3` write that crossed the single-file
 * budget: the host answered the `VFS_MUT` with `ERROR VFS_REFUSED`, but nothing
 * on the proxied-write path resolved, so the interpreter sat inside `fd_write`
 * while the tool-journal had a start without an end and `last_mseq ==
 * materialized_upto` showed the host had applied everything the Worker
 * published. The class is "a proxied write has no awaitable outcome": the
 * refusal never became an errno, and a D3 flow-control stall had no fail-loud
 * bound on that surface.
 *
 * This test drives the real `PythonRuntime` (real `WasiToolbox`, real tool
 * worker, real `VfsProxyServer`), a real `WebSocketChannelClient` over a
 * scripted host socket, the real sink and the real `NodeFsBackend`. The guest
 * is the `write-many` WASI client the persistence regression also uses: it
 * writes one 4096-byte file and prints `wrote 1` only when every write
 * returned success. The scripted host either refuses the over-limit mutation
 * with `ERROR VFS_REFUSED` or withholds every `VFS_ACK`.
 *
 * Pre-fix the guest printed `wrote 1` and only the command-boundary flush
 * noticed (refusal vector), or the flush waited on an ack that never came and
 * the test watchdog fired (flow-control vector). Post-fix the write syscall
 * itself fails with the host errno, the command settles as a tool failure with
 * the limit and remediation text, and the channel stays open.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import {
  canonicalStringify,
  decodeVfsMutation,
  encodeFrame,
  encodeUtf8,
  encodeVfsAck,
  FrameDecoder,
  FrameType,
  makeHostHello,
  VFS_MFLAG_APPENDED,
  WebSocketChannelClient,
  type Frame,
  type WebSocketLike,
} from '../channel/src/index.ts'
import {
  createNamespaceVfs,
  NodeFsBackend,
  VfsWriteOutcomes,
  workerTransport,
  WORKER_DEFAULT_CWD,
  WORKER_VFS_NAMESPACE,
  WORKER_VFS_PREOPENS,
} from '../wasi-toolbox/src/index.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/index.ts'
import { PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import { installSink } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { TreeVfs } from './tree-vfs.ts'

/** The WASI client used at the `python3` program name (see its `.rs` source). */
const writeManyWasm = readFileSync(
  new URL('../wasi-toolbox/python/testdata/write-many.wasm', import.meta.url),
)
/** The client never imports the zip; the Python transport just needs bytes. */
const STUB_STDLIB = new Uint8Array(64)
const BOOT_ID = '00112233445566778899aabbccddeeff'
const FENCE = { owner: 'phone', generation: 0n, wal_seq: 0n } as const
/** The host's single-file budget in this scenario: below the Worker's 64 MiB. */
const HOST_FILE_LIMIT = 2048
/** The guest writes 4096-byte files, so the host budget refuses the write. */
const GUEST_FILE_BYTES = 4096

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

/** Fail with a clear message instead of letting a hung session stall the suite. */
function withWatchdog<T>(promise: Promise<T>, what: string, ms = 20_000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`session hung: ${what} did not settle in ${ms} ms`)), ms)
    promise.then(
      (value) => { clearTimeout(timer); resolve(value) },
      (error: unknown) => { clearTimeout(timer); reject(error) },
    )
  })
}

/**
 * Minimal `WebSocket` face with a synchronous scripted host behind `send()`.
 *
 * Delivering the host reply from inside `send()` is deliberate: it is the
 * worst-case ordering for the write-outcome tracker (the ack or refusal can
 * arrive before `channel.send()` returns), and it keeps the scenario
 * deterministic.
 */
class ScriptedSocket implements WebSocketLike {
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
    if (this.readyState !== 1) throw new Error('scripted socket: send() before open')
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

/** `ack`: accept every mutation; `withhold`: never ack; `refuse-over-limit`: budget refusal. */
type HostMode = 'ack' | 'withhold' | 'refuse-over-limit'

/** Host-side seq counter and the scripted per-mode reply table. */
class ScriptedHost {
  mode: HostMode
  limit = HOST_FILE_LIMIT
  readonly received: Frame[] = []
  readonly refusals: { mseq: bigint; path: string; size: number }[] = []
  private seq = 0n

  constructor(mode: HostMode = 'ack') {
    this.mode = mode
  }

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

  /** Answer one outbound frame. Called synchronously from `socket.send()`. */
  handle(frame: Frame, socket: ScriptedSocket): void {
    this.received.push(frame)
    if (frame.type !== FrameType.VFS_MUT) return
    const mutation = decodeVfsMutation(frame.payload)
    if (this.mode === 'withhold') return
    const appended = (mutation.mflags & VFS_MFLAG_APPENDED) !== 0
    const postSize = appended
      ? Number(mutation.appendFrom) + mutation.data.byteLength
      : mutation.data.byteLength
    if (this.mode === 'refuse-over-limit' && postSize > this.limit) {
      this.refusals.push({ mseq: mutation.mseq, path: mutation.path, size: postSize })
      socket.deliver(this.frame(FrameType.ERROR, encodeUtf8(canonicalStringify({
        code: 'VFS_REFUSED',
        message: `host budget refusal: ${mutation.path} would be ${postSize} bytes; limit ${this.limit}`,
        path: mutation.path,
        limit: this.limit,
        reason: 'file-too-large',
        mseq: Number(mutation.mseq),
        accepted_bytes: 0,
        ref_seq: Number(frame.seq),
      }))))
      return
    }
    socket.deliver(this.frame(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: mutation.mseq })))
  }

  mutations(): ReturnType<typeof decodeVfsMutation>[] {
    return this.received
      .filter(frame => frame.type === FrameType.VFS_MUT)
      .map(frame => decodeVfsMutation(frame.payload))
  }
}

/** One booted worker: host VFS, real channel, sink, python runtime and ledger. */
interface Boot {
  readonly vfs: TreeVfs
  readonly runtime: PythonRuntime
  readonly client: WebSocketChannelClient
  readonly socket: ScriptedSocket
  readonly host: ScriptedHost
  readonly ledger: VfsWriteOutcomes
  dispose(): Promise<void>
}

async function boot(mode: HostMode, flowControlTimeoutMs: number): Promise<Boot> {
  const socket = new ScriptedSocket('ws://127.0.0.1:1234/channel')
  const host = new ScriptedHost(mode)
  socket.onFrame = (frame) => { host.handle(frame, socket) }
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
  const connecting = client.connect()
  socket.open()
  socket.deliver(host.hello())
  await connecting

  const root = new TreeVfs()
  const vfs = createNamespaceVfs(root, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const ledger = new VfsWriteOutcomes({ timeoutMs: flowControlTimeoutMs })
  // The sink's own ack backstop stays far out of the way: the write path must
  // be the owner that fails loud, not the command-boundary flush.
  const disposeSink = installSink(vfs, client, { ackTimeoutMs: 120_000, writeOutcomes: ledger })
  const runtime = new PythonRuntime({
    backend: new NodeFsBackend(root.promises, { flush: () => vfs.flush(), writeOutcomes: ledger }),
    wasm: writeManyWasm,
    stdlib: STUB_STDLIB,
    preopens: WORKER_VFS_PREOPENS,
    cwd: WORKER_DEFAULT_CWD,
    crossOriginIsolated: true,
    spawnWorker: spawnPythonWorker,
    workerReadyTimeoutMs: 60_000,
    memoryLimitBytes: 64 * 1024 * 1024,
  })
  let disposed = false
  return {
    vfs: root,
    runtime,
    client,
    socket,
    host,
    ledger,
    async dispose(): Promise<void> {
      if (disposed) return
      disposed = true
      disposeSink()
      await runtime.dispose()
      await client.close()
    },
  }
}

const decoder = new TextDecoder()

interface GuestRun {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
  readonly failureCode: string | undefined
}

async function runGuest(runtime: PythonRuntime, spec: string): Promise<GuestRun> {
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  const result = await runtime.run({
    program: 'python3',
    argv: ['-c', spec],
    cwd: WORKER_DEFAULT_CWD,
    env: { PWD: WORKER_DEFAULT_CWD },
    onStdout: chunk => { stdout.push(chunk) },
    onStderr: chunk => { stderr.push(chunk) },
  })
  return {
    exitCode: result.exitCode,
    stdout: decoder.decode(Buffer.concat(stdout.map(chunk => Buffer.from(chunk)))),
    stderr: decoder.decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk)))),
    failureCode: result.failureCode,
  }
}

test('G2-FIX-103: a host VFS_REFUSED fails the WASI write with EFBIG, the limit and the remediation', {
  timeout: 120_000,
}, async () => {
  const worker = await boot('refuse-over-limit', 5_000)
  try {
    const run = await withWatchdog(
      runGuest(worker.runtime, '1:probe'),
      'python3 over-limit write',
    )
    // The write syscall observed the host refusal: the guest never reports the
    // 4096-byte file as written. Pre-fix stdout is "wrote 1 to probe".
    assert.equal(run.stdout.includes('wrote 1'), false,
      `the guest must not report a host-refused write as successful: ${JSON.stringify(run.stdout)}`)
    assert.notEqual(run.exitCode, 0, 'the over-limit write ends the command non-zero')
    // The WASI host mirrors the actionable errno detail on stderr; the command
    // boundary adds the same structured refusal to the tool result.
    assert.match(run.stderr, /EFBIG: VFS refused/, `stderr names the refusal: ${run.stderr}`)
    assert.match(run.stderr, new RegExp(`${String(HOST_FILE_LIMIT)} bytes`),
      'the visible error carries the host limit in exact bytes')
    assert.match(run.stderr, /chunk/i, 'the visible error carries the split/chunk remediation')
    assert.equal(run.failureCode, 'E_VFS_FLUSH', 'the tool step settles as a structured failure')

    // The refusal consumed no mseq and did not close the channel.
    assert.equal(worker.host.refusals.length, 1, 'exactly the over-limit mutation was refused')
    const refused = worker.host.refusals[0] as { mseq: bigint; path: string; size: number }
    assert.equal(refused.size, GUEST_FILE_BYTES)
    assert.equal(worker.socket.closeCalls.length, 0, 'the connection stayed open')
    assert.equal(worker.client.admissionOpen, true)
    assert.equal(worker.client.nextMseq(), refused.mseq, 'the refused mutation did not consume its mseq')
    assert.equal(worker.ledger.pending, 0, 'no proxied write stayed pending')

    // The still-open channel serves the repair: remove the refused tree, then
    // the next command writes through the same connection.
    worker.host.mode = 'ack'
    worker.vfs.rmSync('/dsh/workspace/probe', { recursive: true, force: true })
    assert.equal(worker.host.mutations().at(-1)?.mseq, refused.mseq,
      'the next mutation reuses the freed mseq slot')
    const repaired = await withWatchdog(runGuest(worker.runtime, '1:probe'), 'repaired python3 write')
    assert.equal(repaired.exitCode, 0, repaired.stderr)
    assert.match(repaired.stdout, /wrote 1 to probe/)
    assert.equal(worker.socket.closeCalls.length, 0)
  } finally {
    await worker.dispose()
  }
})

test('G2-FIX-103: withholding VFS_ACKs fails the proxied write with a typed bound, the channel stays open', {
  timeout: 120_000,
}, async () => {
  const worker = await boot('withhold', 60)
  try {
    const started = Date.now()
    const run = await withWatchdog(runGuest(worker.runtime, '1:probe'), 'python3 stalled write')
    const elapsed = Date.now() - started
    // Pre-fix the write returned success and the command parked in the
    // 120 s flush wait, so this test watchdog fired.
    assert.equal(run.stdout.includes('wrote 1'), false,
      `a write with no host ack must not report success: ${JSON.stringify(run.stdout)}`)
    assert.notEqual(run.exitCode, 0)
    assert.match(run.stderr, /ETIMEDOUT: VFS flow control/, `stderr names the bounded failure: ${run.stderr}`)
    assert.match(run.stderr, /60 ms/, 'the visible error carries the configured bound')
    assert.ok(elapsed < 30_000, `the bound settled the command (${String(elapsed)} ms)`)
    assert.equal(worker.ledger.failure instanceof Error, true)
    assert.equal(worker.socket.closeCalls.length, 0, 'the flow-control failure did not close the channel')
    assert.equal(worker.client.admissionOpen, true)
    assert.equal(worker.ledger.pending, 0, 'no proxied write stayed pending')

    // Acks resume: the same connection drains the failed write's mseq and the
    // next command succeeds without a reconnect.
    worker.host.mode = 'ack'
    const recovered = await withWatchdog(runGuest(worker.runtime, '1:after'), 'python3 after the stall')
    assert.equal(recovered.exitCode, 0, recovered.stderr)
    assert.match(recovered.stdout, /wrote 1 to after/)
    assert.equal(worker.socket.closeCalls.length, 0)
  } finally {
    await worker.dispose()
  }
})

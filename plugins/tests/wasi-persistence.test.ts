// SPDX-License-Identifier: MIT
// G2-FIX-61 regression: a WASI (python3) write is only a completed write once
// the host has the VFS_MUT in its WAL and materialized copy.
//
// The defect: the tool worker applied a Python write to the host VFS through
// the sink, and `python3` reported success as soon as the interpreter exited.
// The sink is asynchronous, so with any channel latency the last mutations of
// a successful command (in the batch run: the 60 frames) were still in flight
// when the Worker was killed. The Worker VFS died with them, the WAL and the
// materialized copy never saw them, and a later Python run got
// FileNotFoundError for the whole `frames/` tree while the same session's
// earlier writes were materialized.
//
// The class fix is the command-boundary durability fence: before a WASI
// dispatch reports success, the VFS sink is flushed and the level-1 ack of
// every mutation the command produced is awaited. The test drives the real
// `WasiToolbox`/`PythonRuntime`, the real `MemoryChannel` and a host-side
// applier stub that keeps a WAL segment ledger and a materialized tree, then
// kills the Worker immediately after the command returns (the seal for a
// late WebContent termination). Crash timing and channel latency are
// randomized from a fixed seed, like the kill matrix.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  decodeWalRecord,
  decodeWalSegmentHeader,
  encodeWalRecord,
  encodeWalSegmentHeader,
  FrameType,
  VfsOp,
  VFS_MFLAG_APPENDED,
  WAL_SEGMENT_HEADER_SIZE,
  type Frame,
  type MemoryChannelPair,
  type VfsMutation,
} from '../channel/src/index.ts'
import {
  createNamespaceVfs,
  NodeFsBackend,
  workerTransport,
  WORKER_DEFAULT_CWD,
  WORKER_VFS_NAMESPACE,
  WORKER_VFS_PREOPENS,
} from '../wasi-toolbox/src/index.ts'
import type { NodeFsPromisesLike, ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/index.ts'
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
/** Segment ledger bound: small enough that a frame run rolls a segment. */
const SEGMENT_RECORDS = 40

function spawnPythonWorker(): ToolWorkerTransport {
  const worker = new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url))
  return workerTransport(worker as unknown as WorkerLike)
}

/** One applied WAL record and the segment it landed in. */
interface WalRecord {
  readonly mutation: VfsMutation
  readonly segment: number
}

/** One WAL segment of the host-side applier stub. */
interface WalSegment {
  readonly index: number
  firstMseq: bigint
  lastMseq: bigint
  records: number
  registered: boolean
}

/**
 * Deterministic PRNG for the randomized kill times (mulberry32). A fixed seed
 * keeps the suite reproducible; the matrix property — the kill lands while
 * mutations are in flight — is what the test asserts, not the exact count.
 */
function seededRandom(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let value = state
    value = Math.imul(value ^ (value >>> 15), value | 1)
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61)
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}

/** Recursively copy one tree (the reboot overlay). */
function cloneTree(source: TreeVfs): TreeVfs {
  const target = new TreeVfs()
  const copy = (path: string): void => {
    for (const entry of source.readdirSync(path)) {
      const child = `${path === '/' ? '' : path}/${entry.name}`
      if (entry.isDirectory()) {
        target.mkdirSync(child, { recursive: true })
        copy(child)
      } else {
        target.writeFileSync(child, source.readFileSync(child) as Uint8Array)
      }
    }
  }
  for (const root of ['/dsh', '/dsh/workspace', '/dsh/home', '/dsh/tmp']) {
    target.mkdirSync(root, { recursive: true })
  }
  copy('/')
  return target
}

/**
 * Host-side applier stub: validates the mseq stream, appends to a WAL segment
 * ledger and applies every record to the materialized copy, exactly the D8
 * order (structural validation -> WAL -> materialized). It never applies a
 * record more than once; a gap in the stream is recorded for the assertions.
 */
class HostApplier {
  readonly materialized = new TreeVfs()
  readonly wal: WalRecord[] = []
  readonly segments: WalSegment[] = [{ index: 0, firstMseq: 1n, lastMseq: 0n, records: 0, registered: false }]
  readonly gaps: bigint[] = []
  expectedMseq = 1n
  lastMseq = 0n
  materializedUpto = 0n

  constructor() {
    for (const root of ['/dsh', '/dsh/workspace', '/dsh/home', '/dsh/tmp']) {
      this.materialized.mkdirSync(root, { recursive: true })
    }
  }

  /** Receive one VFS_MUT frame (the only frame the applier consumes). */
  receive(frame: Frame): void {
    if (frame.type !== FrameType.VFS_MUT) return
    this.apply(decodeVfsMutation(frame.payload))
  }

  /** Apply one already-decoded mutation. */
  apply(mutation: VfsMutation): void {
    if (mutation.mseq !== this.expectedMseq) this.gaps.push(mutation.mseq)
    this.expectedMseq = mutation.mseq + 1n
    const segment = this.segments[this.segments.length - 1] as WalSegment
    if (segment.records >= SEGMENT_RECORDS) {
      const next: WalSegment = {
        index: segment.index + 1,
        firstMseq: mutation.mseq,
        lastMseq: 0n,
        records: 0,
        registered: false,
      }
      this.segments.push(next)
      this.wal.push({ mutation, segment: next.index })
      this.applyRecord(next, mutation)
    } else {
      this.wal.push({ mutation, segment: segment.index })
      this.applyRecord(segment, mutation)
    }
  }

  /** Orderly park: every written segment is closed and named in the manifest. */
  park(): void {
    for (const segment of this.segments) {
      if (segment.records > 0) segment.registered = true
    }
  }

  /** Snapshot of the materialized workspace for diagnostics/assertions. */
  materializedFiles(directory = '/dsh/workspace'): string[] {
    const files: string[] = []
    const walk = (path: string, prefix: string): void => {
      for (const entry of this.materialized.readdirSync(path)) {
        const child = `${path === '/' ? '' : path}/${entry.name}`
        const relative = prefix === '' ? entry.name : `${prefix}/${entry.name}`
        if (entry.isDirectory()) walk(child, relative)
        else files.push(relative)
      }
    }
    walk(directory, '')
    return files
  }

  private applyRecord(segment: WalSegment, mutation: VfsMutation): void {
    this.lastMseq = mutation.mseq
    segment.lastMseq = mutation.mseq
    segment.records += 1
    const materialized = this.materialized
    switch (mutation.op) {
      case VfsOp.MKDIR:
        materialized.mkdirSync(mutation.path, { recursive: true, mode: mutation.mode })
        break
      case VfsOp.REMOVE:
        materialized.rmSync(mutation.path, { recursive: true, force: true })
        break
      case VfsOp.CHMOD:
        materialized.chmodSync(mutation.path, mutation.mode)
        break
      case VfsOp.WRITE: {
        const appended = (mutation.mflags & VFS_MFLAG_APPENDED) !== 0
        if (!appended) {
          materialized.mkdirSync(parentOf(mutation.path), { recursive: true })
          materialized.writeFileSync(mutation.path, mutation.data, { mode: mutation.mode })
          break
        }
        let existing: Uint8Array = new Uint8Array(0)
        try {
          existing = materialized.readFileSync(mutation.path) as Uint8Array
        } catch {
          existing = new Uint8Array(0)
        }
        const offset = Number(mutation.appendFrom)
        if (existing.byteLength > offset) existing = existing.subarray(0, offset)
        const joined = new Uint8Array(offset + mutation.data.byteLength)
        joined.set(existing, 0)
        joined.set(mutation.data, offset)
        materialized.mkdirSync(parentOf(mutation.path), { recursive: true })
        materialized.writeFileSync(mutation.path, joined, { mode: mutation.mode })
        break
      }
    }
    // The applier is the D8 host: records arrive in strict mseq order and no
    // appended base can mismatch here, so the contiguous watermark is the
    // record's own mseq.
    this.materializedUpto = mutation.mseq
  }
}

function parentOf(path: string): string {
  const index = path.lastIndexOf('/')
  return index <= 0 ? '/' : path.slice(0, index)
}

/** Boot identity of the host-side WAL segments the applier stub writes. */
const WAL_BOOT_ID = Uint8Array.from([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])

/** Concatenate encoded WAL pieces. */
function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.byteLength, 0)
  const joined = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    joined.set(part, offset)
    offset += part.byteLength
  }
  return joined
}

/** Encode one applier segment exactly as the host WAL writer lays it out. */
function encodeSegment(applier: HostApplier, segment: WalSegment): Uint8Array {
  const header = encodeWalSegmentHeader({ firstMseq: segment.firstMseq, bootId: WAL_BOOT_ID })
  const records = applier.wal
    .filter(record => record.segment === segment.index)
    .map(record => {
      const { mseq, ...mutation } = record.mutation
      return encodeWalRecord({ kind: 'mutation', mseq, mutation })
    })
  return concatBytes([header, ...records])
}

/** Decode one WAL segment's header and mutation mseqs. */
function decodeSegment(bytes: Uint8Array): { header: { firstMseq: bigint }; mseqs: bigint[] } {
  const header = decodeWalSegmentHeader(bytes.subarray(0, WAL_SEGMENT_HEADER_SIZE))
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const mseqs: bigint[] = []
  let offset = WAL_SEGMENT_HEADER_SIZE
  while (offset < bytes.byteLength) {
    const length = view.getUint32(offset)
    const record = decodeWalRecord(bytes.subarray(offset, offset + 8 + length))
    if (record.kind === 'mutation') mseqs.push(record.mseq)
    offset += 8 + length
  }
  return { header: { firstMseq: header.firstMseq }, mseqs }
}

/** One booted Worker: host VFS, namespace proxy, sink, channel and runtime. */
interface Boot {
  readonly vfs: TreeVfs
  readonly runtime: PythonRuntime
  readonly pair: MemoryChannelPair
  readonly disposeSink: () => void
  dispose(): Promise<void>
}

/**
 * Boot one Worker VFS with the sink installed.
 * @param live - Worker VFS (a fresh tree or a materialized copy after a kill).
 * @param applier - host applier that receives the sink frames.
 * @param nextMseq - first mseq this boot may emit (the host HELLO's
 *   `next_mseq`; the host reassigns after a Worker die).
 * @param ackedMseq - last accepted mseq at handshake.
 * @param delayMs - per-frame channel latency (models a real WSS + group commit).
 * @returns the booted handles; the caller disposes them.
 */
function boot(
  live: TreeVfs,
  applier: HostApplier,
  nextMseq: bigint,
  ackedMseq: bigint,
  delayMs: number,
): Boot {
  const vfs = createNamespaceVfs(live, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const pair = createMemoryChannelPair({ autoConnect: true, nextMseq, ackedMseq })
  pair.setDelay(delayMs)
  pair.host.onFrame(frame => { applier.receive(frame) })
  const disposeSink = installSink(vfs, pair.worker)
  const runtime = new PythonRuntime({
    backend: new NodeFsBackend(live.promises as unknown as NodeFsPromisesLike, { flush: () => vfs.flush() }),
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
    vfs: vfs as unknown as TreeVfs,
    runtime,
    pair,
    disposeSink,
    async dispose(): Promise<void> {
      if (disposed) return
      disposed = true
      disposeSink()
      pair.setDrop(() => true)
      pair.disconnect()
      await runtime.dispose()
    },
  }
}

/** One guest run's captured streams. */
interface GuestRun {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

const decoder = new TextDecoder()

async function runPython(runtime: PythonRuntime, spec: string, cwd = '/dsh/workspace'): Promise<GuestRun> {
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  const result = await runtime.run({
    program: 'python3',
    argv: ['-c', spec],
    cwd,
    env: { PWD: cwd },
    onStdout: chunk => { stdout.push(chunk) },
    onStderr: chunk => { stderr.push(chunk) },
  })
  return {
    exitCode: result.exitCode,
    stdout: decoder.decode(Buffer.concat(stdout.map(chunk => Buffer.from(chunk)))),
    stderr: decoder.decode(Buffer.concat(stderr.map(chunk => Buffer.from(chunk)))),
  }
}

test('wasi: a successful python3 write is level-1 acknowledged before it returns (killed Worker)', {
  timeout: 120_000,
}, async () => {
  const random = seededRandom(0x61_0f_07)
  const delayMs = 1 + Math.floor(random() * 3) // 1..3 ms per frame
  const fileCount = 24 + Math.floor(random() * 17) // 24..40 files → 48..80 mutations
  const applier = new HostApplier()
  const first = boot(new TreeVfs(), applier, 1n, 0n, delayMs)
  try {
    const result = await runPython(first.runtime, `${fileCount}:frames`)
    assert.equal(result.exitCode, 0, result.stderr)

    // The command has returned. The durability fence must already have made
    // every mutation visible to the host applier; a kill now cannot lose it.
    assert.equal(applier.gaps.length, 0, 'the sink stream has no mseq gap')
    assert.equal(applier.expectedMseq, applier.lastMseq + 1n, 'every emitted mseq reached the host')
    assert.equal(applier.materializedUpto, applier.lastMseq, 'materialized_upto is the WAL tail')
    const files = applier.materializedFiles()
    assert.equal(files.filter(path => path.startsWith('frames/')).length, fileCount,
      `the materialized copy has all ${fileCount} files (got ${files.filter(path => path.startsWith('frames/')).length})`)

    // Kill the Worker immediately after the successful command, with a seeded
    // 0–1 ms skew like the kill matrix's randomized timing: the memory VFS is
    // gone and the reboot overlay is the materialized copy only.
    await new Promise(resolve => setTimeout(resolve, Math.floor(random() * 2)))
    const rebootTree = cloneTree(applier.materialized)
    await first.dispose()
    const rebootNext = applier.expectedMseq
    const second = boot(rebootTree, applier, rebootNext, applier.lastMseq, 0)
    try {
      // The earlier command's files survive the reboot, and the next python3
      // invocation can read them.
      assert.equal(rebootTree.readdirSync('/dsh/workspace/frames').length, fileCount,
        'the earlier files survive the Worker rebuild')
      const reread = await runPython(second.runtime, `${fileCount}:frames`)
      assert.equal(reread.exitCode, 0, reread.stderr)
      assert.match(reread.stdout, new RegExp(`wrote ${fileCount} to frames`))
    } finally {
      await second.dispose()
    }
  } finally {
    await first.dispose()
  }
})

test('wasi: an interpreter abort cannot delete the files of an earlier successful command', {
  timeout: 120_000,
}, async () => {
  const random = seededRandom(0x61_c7_a5)
  const delayMs = 1 + Math.floor(random() * 3)
  const fileCount = 12 + Math.floor(random() * 9)
  const applier = new HostApplier()
  const first = boot(new TreeVfs(), applier, 1n, 0n, delayMs)
  try {
    const written = await runPython(first.runtime, `${fileCount}:frames`)
    assert.equal(written.exitCode, 0, written.stderr)

    // A later invocation writes some files and aborts the instance (trap):
    // the earlier command's files must stay readable and materialized.
    const crashed = await runPython(first.runtime, `${1 + Math.floor(random() * 5)}:frames2:trap`)
    assert.notEqual(crashed.exitCode, 0, 'the aborted interpreter reports a failure')
    assert.equal(applier.gaps.length, 0)
    assert.equal(applier.materializedUpto, applier.lastMseq)

    const files = applier.materializedFiles()
    assert.equal(files.filter(path => path.startsWith('frames/')).length, fileCount,
      'the abort did not roll back the earlier materialized files')
    await first.dispose()

    const rebootTree = cloneTree(applier.materialized)
    const second = boot(rebootTree, applier, applier.expectedMseq, applier.lastMseq, 0)
    try {
      const reread = await runPython(second.runtime, '0:frames')
      assert.equal(reread.exitCode, 0, reread.stderr)
      assert.equal(rebootTree.readdirSync('/dsh/workspace/frames').length, fileCount,
        'the earlier files remain readable in the rebooted Worker VFS')
    } finally {
      await second.dispose()
    }
  } finally {
    await first.dispose()
  }
})

test('wasi: a python3 write under /dsh/home enters the same durability chain', {
  timeout: 60_000,
}, async () => {
  const applier = new HostApplier()
  const worker = boot(new TreeVfs(), applier, 1n, 0n, 1)
  try {
    const result = await runPython(worker.runtime, '2:notes', '/dsh/home')
    assert.equal(result.exitCode, 0, result.stderr)
    const homeRecords = applier.wal.filter(record => record.mutation.path.startsWith('/dsh/home/notes/'))
    assert.equal(homeRecords.length >= 2, true, 'the /dsh/home writes reached the VFS sink')
    assert.equal(applier.materializedUpto, applier.lastMseq, 'materialized_upto covers the /dsh/home writes')
    assert.equal(
      applier.materializedFiles('/dsh/home').filter(path => path.startsWith('notes/')).length,
      2,
      'the /dsh/home files are in the materialized copy',
    )
  } finally {
    await worker.dispose()
  }
})

test('wasi: an orderly park closes and registers the WAL tail with no mseq gap', {
  timeout: 120_000,
}, async () => {
  const random = seededRandom(0x61_9a_17)
  const delayMs = 1 + Math.floor(random() * 2)
  const fileCount = 40 + Math.floor(random() * 21) // enough to roll the 40-record ledger
  const applier = new HostApplier()
  const worker = boot(new TreeVfs(), applier, 1n, 0n, delayMs)
  try {
    const result = await runPython(worker.runtime, `${fileCount}:frames`)
    assert.equal(result.exitCode, 0, result.stderr)
    applier.park()
    assert.equal(applier.gaps.length, 0, 'no gap in the mseq stream')
    assert.equal(applier.materializedUpto, applier.lastMseq, 'park materialized the WAL tail')
    assert.ok(applier.segments.length > 1, 'the frame run rolled at least one WAL segment')
    assert.ok(applier.segments.every(segment => segment.records === 0 || segment.registered),
      'every written WAL segment is registered after an orderly park')
    for (let index = 1; index < applier.segments.length; index += 1) {
      const previous = applier.segments[index - 1] as WalSegment
      const current = applier.segments[index] as WalSegment
      assert.equal(current.firstMseq, previous.lastMseq + 1n, 'WAL segments are contiguous')
    }
    assert.equal(applier.materializedFiles().filter(path => path.startsWith('frames/')).length, fileCount)

    // Decode the segment bytes the way the host and the evidence archive do:
    // every record is CRC-checked, the mutation mseq stream is contiguous, and
    // the next-epoch segment the writer leaves behind is a 40-byte header with
    // no mutation record. The G2-F07 evidence showed exactly that segment
    // shape next to manifest `last_mseq == materialized_upto`; a header-only
    // segment cannot be holding the missing frames.
    const writtenSegments = applier.segments.filter(segment => segment.records > 0)
    const decoded = writtenSegments.map(segment => decodeSegment(encodeSegment(applier, segment)))
    assert.deepEqual(
      decoded.flatMap(segment => segment.mseqs),
      applier.wal.map(record => record.mutation.mseq),
      'every WAL record decodes back to the mutation the sink emitted',
    )
    for (let index = 1; index < decoded.length; index += 1) {
      const previous = decoded[index - 1] as { mseqs: bigint[] }
      const current = decoded[index] as { mseqs: bigint[]; header: { firstMseq: bigint } }
      const last = previous.mseqs[previous.mseqs.length - 1] as bigint
      assert.equal(current.header.firstMseq, last + 1n, 'decoded WAL segments cover the mseq stream')
    }
    const nextEpochHeader = encodeWalSegmentHeader({
      firstMseq: applier.lastMseq + 1n,
      bootId: WAL_BOOT_ID,
    })
    assert.equal(nextEpochHeader.byteLength, WAL_SEGMENT_HEADER_SIZE)
    assert.deepEqual(decodeSegment(nextEpochHeader).mseqs, [],
      'the next epoch segment is a header-only orphan, not a holder of unregistered mutations')
  } finally {
    await worker.dispose()
  }
})

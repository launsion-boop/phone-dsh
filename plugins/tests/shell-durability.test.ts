// SPDX-License-Identifier: MIT
// G2-FIX-61 regression: the Worker shell's command boundary must reach the same
// durability fence as the WASI toolbox.
//
// `bash -c` writes into the Worker VFS through the same sink as `python3`; the
// sink's 0x10 publication is asynchronous. If `subprocess-xl` reports the exit
// as soon as the just-bash engine settles, the last writes are still in flight
// and a WebContent kill drops them from the VFS, the WAL and the materialized
// copy. `worker-entry` publishes the sink-wrapped `flush()` as a Worker global;
// `ShellWorkerProcess` awaits it before it settles, so a successful `bash -c`
// implies the host has acknowledged every mutation it produced.
import assert from 'node:assert/strict'
import { test, after } from 'node:test'
import { createMemoryChannelPair, decodeVfsMutation, FrameType, type Frame } from '../channel/src/index.ts'
import type { SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import type { WorkerShell } from '../shell-ext/src/index.ts'
import {
  createNamespaceVfs,
  WORKER_VFS_NAMESPACE,
} from '../wasi-toolbox/src/index.ts'
import { installSink, startPhoneWorker, WORKER_VFS_FLUSH_GLOBAL as ENTRY_FLUSH_GLOBAL } from '../worker-entry/src/entry.ts'
import type { PhoneWorkerRuntime, WorkerEntrySynthesize } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import {
  ShellWorkerProcess,
  WORKER_VFS_FLUSH_GLOBAL as SUBPROCESS_FLUSH_GLOBAL,
  flushWorkerVfs,
} from '../subprocess-xl/src/index.ts'
import { TreeVfs } from './tree-vfs.ts'
import { eventually } from './test-channel.ts'

/** Store/restore the one Worker global this suite manipulates. */
const SAVED_FLUSH = (globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> | void }).__PDSH_VFS_FLUSH__
const WORKER_GLOBAL = globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> | void }

after(() => {
  if (SAVED_FLUSH === undefined) delete WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL]
  else WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL] = SAVED_FLUSH
})

/** The minimal spawn spec the handle reads. */
function spec(cwd: string): SubprocessSpawnSpec {
  return {
    argv: ['bash', '-c', 'true'],
    cwd,
    graceMs: 3_000,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
  }
}

/** A shell engine that writes `files` files into the VFS on every run. */
function writingShell(write: (index: number) => void, files: number): WorkerShell {
  return {
    run: async () => {
      for (let index = 0; index < files; index += 1) write(index)
      return {
        stdout: `wrote ${files}\n`,
        stderr: '',
        exitCode: 0,
        timedOut: false,
        aborted: false,
        stdoutTruncated: false,
        stderrTruncated: false,
      }
    },
  } as unknown as WorkerShell
}

test('shell: the entry and subprocess-xl agree on the flush hook name', () => {
  assert.equal(SUBPROCESS_FLUSH_GLOBAL, ENTRY_FLUSH_GLOBAL)
  assert.equal(SUBPROCESS_FLUSH_GLOBAL, '__PDSH_VFS_FLUSH__')
})

test('shell: a missing flush hook is a no-op (desktop transport or a bare test)', async () => {
  delete WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL]
  await flushWorkerVfs()
})

test('shell: the command does not settle until the sink flush is acknowledged', async () => {
  const flushEntered = Promise.withResolvers<void>()
  const releaseFlush = Promise.withResolvers<void>()
  let flushes = 0
  WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL] = async () => {
    flushes += 1
    flushEntered.resolve()
    await releaseFlush.promise
  }
  const process = new ShellWorkerProcess(spec('/dsh/workspace'), {} as never, writingShell(() => {}, 0))
  let settled = false
  const done = process.done.then(outcome => { settled = true; return outcome })
  try {
    process.begin()
    await flushEntered.promise
    assert.equal(settled, false, 'the shell handle must not report success before the fence resolves')
    releaseFlush.resolve()
    const outcome = await done
    assert.equal(outcome.exitCode, 0)
    assert.equal(flushes, 1)
  } finally {
    releaseFlush.resolve()
    await done.catch(() => {})
  }
})

test('shell: a rejected sink flush fails the command instead of reporting success', async () => {
  WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL] = async () => {
    throw Object.assign(new Error('VFS_REFUSED: EFBIG'), { code: 'EFBIG' })
  }
  const process = new ShellWorkerProcess(spec('/dsh/workspace'), {} as never, writingShell(() => {}, 0))
  process.begin()
  await assert.rejects(process.done, /VFS_REFUSED: EFBIG/)
})

test('shell: a successful command has every write in the host WAL before it settles', {
  timeout: 60_000,
}, async () => {
  const files = 12
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const pair = createMemoryChannelPair({ autoConnect: true })
  pair.setDelay(1)
  const applied: ReturnType<typeof decodeVfsMutation>[] = []
  pair.host.onFrame((frame: Frame) => {
    if (frame.type === FrameType.VFS_MUT) applied.push(decodeVfsMutation(frame.payload))
  })
  const disposeSink = installSink(vfs, pair.worker)
  base.mkdirSync('/dsh/workspace/frames', { recursive: true })
  WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL] = () => vfs.flush()
  const shell = writingShell(index => {
    base.writeFileSync(`/dsh/workspace/frames/f${index}.bin`, new Uint8Array([index]))
  }, files)
  const process = new ShellWorkerProcess(spec('/dsh/workspace'), {} as never, shell)
  try {
    process.begin()
    const outcome = await process.done
    assert.equal(outcome.exitCode, 0)
    const frameMutations = applied.filter(mutation => mutation.path.startsWith('/dsh/workspace/frames/'))
    assert.equal(frameMutations.length, files, 'all shell writes reached the host before the exit')
    let contiguous = true
    for (let index = 1; index < applied.length; index += 1) {
      if ((applied[index] as { mseq: bigint }).mseq !== (applied[index - 1] as { mseq: bigint }).mseq + 1n) contiguous = false
    }
    assert.equal(contiguous, true, 'the sink mseq stream is contiguous')
    assert.equal(base.readdirSync('/dsh/workspace/frames').length, files)
  } finally {
    disposeSink()
    pair.setDrop(() => true)
    pair.disconnect()
    delete WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL]
  }
})

test('shell: a terminated command still flushes what it wrote and keeps the SIGTERM outcome', async () => {
  let flushed = false
  WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL] = async () => { flushed = true }
  const shell = {
    run: async (_argv: readonly string[], options: { readonly signal?: AbortSignal }) => {
      options.signal?.throwIfAborted()
      await eventually(() => options.signal?.aborted === true, 2_000)
      return {
        stdout: '', stderr: '', exitCode: 124, timedOut: true, aborted: true,
        stdoutTruncated: false, stderrTruncated: false,
      }
    },
  } as unknown as WorkerShell
  const process = new ShellWorkerProcess(spec('/dsh/workspace'), {} as never, shell)
  process.begin()
  process.terminate()
  const outcome = await process.done
  assert.equal(outcome.signal, 'SIGTERM')
  assert.equal(flushed, true, 'the writes a cancelled command made are still fenced')
  delete WORKER_GLOBAL[SUBPROCESS_FLUSH_GLOBAL]
})

test('worker entry installs the flush hook and removes it on an orderly stop', {
  timeout: 30_000,
}, async () => {
  const base = new TreeVfs()
  const pair = createMemoryChannelPair({ autoConnect: true })
  const synthesize: WorkerEntrySynthesize = (_request, sink) => {
    const res = {
      writeHead: () => res,
      write: () => true,
      end: () => { sink.end({ status: 200, headers: {}, body: new Uint8Array(0) }); return res },
      destroy: () => { sink.fail('destroyed') },
    }
    return {
      req: {},
      res,
      aborted: false,
      abort: () => { sink.fail('aborted') },
    }
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({
      handleMessage: () => {},
      start: async () => {},
      stop: async () => {},
      get vfs() { return base },
    }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize,
  }
  const handle = await startPhoneWorker({
    imageURL: 'image://test',
    channelURL: 'ws://127.0.0.1:1/channel',
    token: 'token',
    bootId: '00112233445566778899aabbccddeeff',
    fence: { owner: 'phone', generation: 1n, wal_seq: 0n },
    runtime,
    pagePost: () => {},
  })
  try {
    assert.equal(typeof WORKER_GLOBAL[ENTRY_FLUSH_GLOBAL], 'function',
      'the entry publishes the sink flush for the shell provider')
    base.writeFileSync('/dsh/workspace/written-by-bash.txt', new Uint8Array([1, 2, 3]))
    await WORKER_GLOBAL[ENTRY_FLUSH_GLOBAL]!()
    assert.ok(pair.worker.ackedMseq(1) >= 1n, 'the hook waited for the host level-1 ack')
  } finally {
    await handle.stop()
  }
  assert.equal(WORKER_GLOBAL[ENTRY_FLUSH_GLOBAL], undefined,
    'an orderly stop removes the hook before the sink is detached')
})

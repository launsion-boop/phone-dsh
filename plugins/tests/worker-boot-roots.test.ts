// SPDX-License-Identifier: MIT
// G2-FIX regression: the Worker boot owns the namespace roots and proves them
// before the first API request.
//
// The upstream sandbox declares `writableRoots = [workspaceRoot, /tmp,
// os.tmpdir()]` and the runtime's `os.tmpdir()` is `/dsh/tmp`, so both volatile
// spellings must be writable. Before this fix `/tmp` did not exist at all and
// each surface invented its own resolution (G2-D05). The entry now seeds the
// roots right after `host.start()` and runs a loud two-spelling probe; this
// file pins the seeding, the probe failure, and the boot ordering.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  FrameType,
  type Frame,
} from '../channel/src/index.ts'
import {
  WORKER_VFS_NAMESPACE,
  createNamespaceVfs,
  type VfsNamespace,
} from '../wasi-toolbox/src/index.ts'
import {
  installNamespaceAuthority,
  seedNamespaceRoots,
  type NamespaceRuntimeHooks,
} from '../worker-entry/src/namespace-boot.ts'
import {
  startPhoneWorker,
  type PhoneWorkerHostLike,
  type PhoneWorkerRuntime,
  type WorkerEntryRequestListener,
  type WorkerEntryVfs,
} from '../worker-entry/src/entry.ts'
import { TreeVfs } from './tree-vfs.ts'

/** Let queued channel/console work settle. */
async function settle(): Promise<void> {
  await new Promise<void>(resolve => setTimeout(resolve, 0))
  await new Promise<void>(resolve => setTimeout(resolve, 0))
}

test('boot: the volatile roots exist and both spellings name one store', () => {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  const report = seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  assert.equal(report.active, true)
  assert.deepEqual(report.roots, ['/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp'])
  assert.deepEqual(report.probe, ['/tmp->/dsh/tmp'])
  for (const root of report.roots) {
    const canonical = WORKER_VFS_NAMESPACE.storagePath(root)
    assert.equal(base.statSync(canonical).isDirectory(), true, `${root} is a directory`)
  }
  // The probe files are removed again; the roots stay empty.
  assert.deepEqual(base.readdirSync('/dsh/tmp'), [])
  assert.equal(base.existsSync('/tmp'), false, 'the volatile spelling is a canonicalisation, not a second tree')
  assert.equal(base.statSync('/dsh/tmp').mode & 0o777, 0o777, 'the shared tmp root is world-writable')
})

test('boot: a VFS without a synchronous write face is skipped, not failed', () => {
  const readOnly: WorkerEntryVfs = { subscribe: () => () => {}, async flush() {} }
  const report = seedNamespaceRoots(readOnly, WORKER_VFS_NAMESPACE)
  assert.equal(report.active, false)
  assert.match(String(report.reason), /synchronous write face/)
})

test('boot: diverging /tmp and /dsh/tmp spellings fail loud and name the contract gap', () => {
  // An unwrapped VFS: mkdir `/tmp` creates a real `/tmp`, so the two names
  // are different directories — exactly the shape G2-D05 exposed.
  const base = new TreeVfs()
  assert.throws(() => seedNamespaceRoots(base, WORKER_VFS_NAMESPACE), (error: unknown) => {
    const message = (error as Error).message
    assert.match(message, /\/tmp, \/dsh\/tmp/)
    assert.match(message, /upstream contract gap/)
    return true
  })
})

test('boot: installNamespaceAuthority activates the wrapped VFS and installs the policy', () => {
  const base = new TreeVfs()
  const calls: string[] = []
  let activated: unknown
  let namespace: VfsNamespace | undefined
  const runtime: NamespaceRuntimeHooks = {
    activateVfs: vfs => { calls.push('activate'); activated = vfs },
    installExecFsPolicy: (value) => {
      calls.push('policy')
      namespace = value
      return () => { calls.push('dispose') }
    },
    installBoundedDirectoryOpener: (value) => {
      calls.push('bounded')
      assert.equal(value, base, 'the bounded opener receives the real mounted VFS, not the alias proxy')
      return () => { calls.push('dispose-bounded') }
    },
  }
  const authority = installNamespaceAuthority({ vfs: base, runtime })
  assert.deepEqual(calls, ['activate', 'policy', 'bounded'])
  assert.equal(namespace, WORKER_VFS_NAMESPACE)
  const activatedVfs = authority.vfs as WorkerEntryVfs & {
    existsSync(path: string): boolean
    writeFileSync(path: string, data: string, options?: { mode?: number }): void
  }
  assert.equal(activatedVfs.existsSync('/tmp'), true, 'the activated VFS creates the volatile root')
  // The activated object is the same canonicalising view every surface reads.
  activatedVfs.writeFileSync('/tmp/boot.txt', 'x')
  assert.equal(base.existsSync('/dsh/tmp/boot.txt'), true)
  assert.equal(base.existsSync('/tmp/boot.txt'), false)
  authority.dispose()
  assert.deepEqual(calls, ['activate', 'policy', 'bounded', 'dispose-bounded', 'dispose'])
})

test('boot: startPhoneWorker installs the authority after start and before pdsh-ready', async () => {
  const pair = createMemoryChannelPair({ autoConnect: true })
  const hostFrames: Frame[] = []
  pair.host.onFrame(frame => { hostFrames.push(frame) })
  const vfs = new TreeVfs()
  const order: string[] = []
  const listener: WorkerEntryRequestListener = (_req, res) => {
    (res as { end: (body?: string) => void }).end('ok')
  }
  const host: PhoneWorkerHostLike = {
    handleMessage: () => {},
    start: async () => { order.push('start') },
    vfs,
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: () => host,
    whenRequestListener: async () => listener,
    createChannel: () => pair.worker,
    synthesize: () => ({ req: {}, res: {}, aborted: false, abort: () => {} }),
    activateVfs: (activated) => {
      order.push('activate')
      const view = activated as WorkerEntryVfs & { existsSync(path: string): boolean }
      assert.equal(view.existsSync('/tmp'), true, 'the activated VFS already answers the volatile root')
      assert.equal(view.existsSync('/dsh/tmp'), true)
    },
    installExecFsPolicy: () => {
      order.push('policy')
      return () => { order.push('dispose') }
    },
    installBoundedDirectoryOpener: () => {
      order.push('bounded')
      return () => { order.push('dispose-bounded') }
    },
  }
  const pageMessages: unknown[] = []
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    token: 'token',
    imageURL: 'image.tar.gz',
    fence: { owner: 'phone', generation: 1n, wal_seq: 0n },
    runtime,
    pagePost: (message) => { pageMessages.push(message) },
  })
  try {
    assert.deepEqual(order.slice(0, 4), ['start', 'activate', 'policy', 'bounded'])
    assert.deepEqual(pageMessages, [{ t: 'pdsh-ready' }])
    assert.equal(vfs.existsSync('/dsh/workspace'), true)
    assert.equal(vfs.existsSync('/dsh/home'), true)
    // A write the runtime publishes through the wrapper is canonical before
    // the sink sees it: `/tmp` never reaches a VFS_MUT frame.
    const booted = handle.vfs as WorkerEntryVfs & {
      writeFileSync(path: string, data: string): void
    }
    booted.writeFileSync('/tmp/not-durable.txt', 'x')
    booted.writeFileSync('/dsh/workspace/durable.txt', 'x')
    await settle()
    const mutations = hostFrames.filter(frame => frame.type === FrameType.VFS_MUT)
    // G2-ENG-05 adds the two persisted capability files before `pdsh-ready`;
    // the third mutation is the one durable write below. Nothing under /tmp
    // may appear, because the volatile root is never a sink target (D4).
    const paths = mutations.map(frame => decodeVfsMutation(frame.payload).path)
    assert.equal(mutations.length, 3)
    assert.deepEqual(paths.sort(), [
      '/dsh/home/AGENTS.md',
      '/dsh/home/capabilities.json',
      '/dsh/workspace/durable.txt',
    ])
    assert.equal(paths.includes('/dsh/tmp/not-durable.txt'), false)
    assert.equal(vfs.readFileSync('/dsh/tmp/not-durable.txt') instanceof Uint8Array, true)
  } finally {
    await handle.stop()
    assert.equal(order.includes('dispose'), true)
    assert.equal(order.includes('dispose-bounded'), true)
  }
})

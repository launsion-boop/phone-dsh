// SPDX-License-Identifier: MIT
/**
 * Real pinned-runtime integration for the bounded directory bridge.
 *
 * The outer test bundles the fixture with the pinned runtime's own `MemoryVfs`,
 * `node:fs`/`node:fs.promises` bridge, the namespace exec policy, the
 * capture-only bounded opener and the production Worker command capture. It
 * drives a small directory, an over-ceiling tree, flat lazy registrations that
 * `usage()` does not count, ordinary unbounded `opendir` reads, a missing
 * manifest, the `/tmp` alias, the private namespace, disposal, and one real
 * Bash command through `executeWorkerCommandInFork`.
 *
 * This is Linux/Node evidence. There is no WKWebView or actual Worker here, so
 * the real-WK positive/negative run is NOT_RUN on this worker.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { after, before, describe, test } from 'node:test'

import { build } from 'esbuild'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the pinned MemoryVfs and runtime fs bridge come from the checkout'
  : false

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'
const MANIFEST = '/dsh/config/vfs-manifest.json'
const scratch: string[] = []
let harness: Harness | undefined

interface LazyFile {
  readonly path: string
  readonly size: number
}

interface RealVfs {
  seedDirectory(path: string, options?: { readonly mode?: number; readonly mtimeMs?: number }): void
  seed(path: string, data: string | Uint8Array, options?: { readonly mode?: number; readonly mtimeMs?: number }): void
  usage(): { files: number, directories: number, bytes: number }
  readdirSync(path: string): string[]
  readFileSync(path: string, options?: string): string | Uint8Array
  existsSync(path: string): boolean
  deferArchive(archive: {
    readonly name: string
    readonly root: string
    readonly files: readonly LazyFile[]
    readonly load: () => Promise<Uint8Array>
  }): void
}

interface Harness {
  MemoryVfs: new () => RealVfs
  setActiveVfs(vfs: unknown): void
  runtimeFsPromises: Record<string, any>
  EXEC_INTERNAL_ROOTS: readonly string[]
  WORKER_VFS_NAMESPACE: unknown
  installExecFsPolicy(face: object, namespace: unknown): () => void
  WORKER_BOUNDED_DIRECTORY_MATERIALIZATION: symbol
  WORKER_BOUNDED_OPENDIR_MAX_ENTRIES: number
  WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER: symbol
  WORKER_COMMAND_BOUNDED_OPENDIR: symbol
  SURFACE_BOUNDED_DIRECTORY_OPENER: symbol
  SURFACE_BOUNDED_OPENDIR: symbol
  WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES: number
  installBoundedDirectoryOpener(options: {
    vfs: unknown
    fs: object
    maxEntries?: number
    manifestPath?: string
    check?: () => void
  }): () => void
  captureWorkerVfsFork(options: Record<string, unknown>): Promise<unknown>
  executeWorkerCommandInFork(request: unknown, options: Record<string, unknown>): Promise<Record<string, any>>
  validateWorkerCommandRequest(body: Record<string, unknown>): unknown
}

/** Bundle the fixture against the pinned runtime sources. */
async function bundleHarness(outfile: string, pinned: string): Promise<void> {
  const runtimeSrc = join(pinned, 'packages/experimental/webworker-runtime/src')
  const runtimeFs = join(runtimeSrc, 'node/builtin_modules/implemented/fs.ts')
  const runtimeFsPromises = join(runtimeSrc, 'node/builtin_modules/implemented/fs/promises.ts')
  const virtualFs = 'pdsh-runtime-fs'
  const virtualFsPromises = 'pdsh-runtime-fs-promises'
  const virtualReadableStream = 'pdsh-readable-stream'
  await build({
    entryPoints: [join(root, 'tests', 'fixtures', 'bounded-opendir-runtime.ts')],
    outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*'],
    absWorkingDir: root,
    nodePaths: [join(root, 'node_modules')],
    logLevel: 'silent',
    plugins: [{
      name: 'pdsh-bounded-opendir-runtime',
      setup(builder) {
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-experimental-webworker-runtime\/src\// }, args => ({
          path: join(runtimeSrc, args.path.slice(RUNTIME_PREFIX.length)),
        }))
        // The checkout is built against readable-stream 4.x; this workspace's
        // lock carries 3.x. Node's own stream module is the same maintained
        // implementation on the host, and the substitution is test scaffolding.
        builder.onResolve({ filter: /^readable-stream$/ }, () => ({
          path: virtualReadableStream,
          namespace: 'pdsh-virtual',
        }))
        builder.onResolve({ filter: /^node:fs$/ }, () => ({ path: virtualFs, namespace: 'pdsh-virtual' }))
        builder.onResolve({ filter: /^node:fs\/promises$/ }, () => ({
          path: virtualFsPromises,
          namespace: 'pdsh-virtual',
        }))
        builder.onLoad({ filter: /.*/, namespace: 'pdsh-virtual' }, args => {
          if (args.path === virtualFs) {
            return {
              loader: 'ts',
              resolveDir: dirname(runtimeFs),
              contents: 'export * from \'./fs.ts\'\nexport { default } from \'./fs.ts\'\n',
            }
          }
          if (args.path === virtualFsPromises) {
            return {
              loader: 'ts',
              resolveDir: dirname(runtimeFsPromises),
              contents: 'export * from \'./promises.ts\'\nexport { default } from \'./promises.ts\'\n',
            }
          }
          if (args.path === virtualReadableStream) {
            return { loader: 'ts', contents: 'export * from \'node:stream\'\nexport { default } from \'node:stream\'\n' }
          }
          return undefined
        })
      },
    }],
  })
}

before(async () => {
  if (skip !== false) return
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-bounded-opendir-'))
  scratch.push(directory)
  const outfile = join(directory, 'harness.mjs')
  await bundleHarness(outfile, checkout as string)
  harness = await import(pathToFileURL(outfile).href) as Harness
})

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/** One public image manifest with the requested lazy registrations. */
function manifestText(lazy: readonly LazyFile[] = []): string {
  return JSON.stringify({
    root: '/dsh',
    profile: 'test-profile',
    lowered: 'test-lowering',
    javascriptEntries: 0,
    visitedEntries: 0,
    rewrittenEntries: 0,
    lazy: lazy.length === 0 ? [] : [{ archive: 'lazy/test.tar.gz', files: lazy }],
  })
}

function seedManifest(vfs: RealVfs, lazy: readonly LazyFile[] = []): void {
  vfs.seedDirectory('/dsh/config')
  vfs.seed(MANIFEST, manifestText(lazy))
}

/** One small mounted Worker tree with the pinned runtime's manifest record. */
function smallVfs(h: Harness, options: { readonly manifest?: boolean } = {}): RealVfs {
  const vfs = new h.MemoryVfs()
  vfs.seedDirectory('/dsh/workspace')
  vfs.seedDirectory('/dsh/home')
  vfs.seedDirectory('/dsh/tmp')
  vfs.seedDirectory('/dsh/home/sessions')
  vfs.seed('/dsh/workspace/answer.txt', 'worker-source\n')
  vfs.seed('/dsh/tmp/alias.txt', 'tmp-alias\n')
  vfs.seed('/dsh/home/sessions/secret.txt', 'secret\n')
  if (options.manifest !== false) seedManifest(vfs)
  return vfs
}

interface Installed {
  readonly h: Harness
  readonly vfs: RealVfs
  calls(): { readonly opendir: number, readonly readdirSync: number }
  dispose(): void
}

/**
 * Install the real runtime face, the namespace policy and (optionally) the
 * bounded opener, with spies under the policy so the test can prove the
 * original materialising path was never entered.
 */
function installRealFace(
  h: Harness,
  vfs: RealVfs,
  options: { readonly bridge?: boolean, readonly usageVfs?: unknown, readonly maxEntries?: number } = {},
): Installed {
  h.setActiveVfs(vfs)
  const baseOpendir = h.runtimeFsPromises.opendir
  const baseReaddirSync = vfs.readdirSync.bind(vfs)
  let opendirCalls = 0
  let readdirSyncCalls = 0
  h.runtimeFsPromises.opendir = (...args: unknown[]) => {
    opendirCalls += 1
    return baseOpendir(...args)
  }
  vfs.readdirSync = (path: string) => {
    readdirSyncCalls += 1
    return baseReaddirSync(path)
  }
  const disposePolicy = h.installExecFsPolicy(h.runtimeFsPromises, h.WORKER_VFS_NAMESPACE)
  const disposeBridge = options.bridge === false
    ? undefined
    : h.installBoundedDirectoryOpener({
      vfs: options.usageVfs ?? vfs,
      fs: h.runtimeFsPromises,
      ...options.maxEntries === undefined ? {} : { maxEntries: options.maxEntries },
    })
  return {
    h,
    vfs,
    calls: () => ({ opendir: opendirCalls, readdirSync: readdirSyncCalls }),
    dispose: () => {
      if (disposeBridge !== undefined) disposeBridge()
      disposePolicy()
      h.runtimeFsPromises.opendir = baseOpendir
      vfs.readdirSync = baseReaddirSync
    },
  }
}

/** The capture-only opener exposed by the transparent shared wrapper. */
function boundedOpener(h: Harness): (path: string) => Promise<{
  readonly path: string
  read(): Promise<{ readonly name: string } | null>
  close(): Promise<void>
}> {
  const opener = h.runtimeFsPromises.opendir[h.WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER]
  assert.equal(typeof opener, 'function', 'the shared wrapper must expose a separate bounded opener')
  return opener.bind(h.runtimeFsPromises.opendir)
}

/** Install a stable ordered-channel watermark so the receipt can be frozen. */
async function withFrozenChannel<T>(run: () => Promise<T>): Promise<T> {
  const globals = globalThis as { __PDSH_CHANNEL__?: { nextMseq(): bigint } }
  const previous = globals.__PDSH_CHANNEL__
  globals.__PDSH_CHANNEL__ = { nextMseq: () => 8n }
  try {
    return await run()
  } finally {
    if (previous === undefined) delete globals.__PDSH_CHANNEL__
    else globals.__PDSH_CHANNEL__ = previous
  }
}

function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    command: 'printf bounded-ok',
    program: 'bash',
    cwd: '/dsh/workspace',
    scenario_id: 'G2-BOUNDED-DIR',
    session_id: 'session-bounded-dir',
    turn: 1,
    assertion_index: 1,
    ...overrides,
  }
}

describe('bounded directory bridge over the pinned runtime', { skip }, () => {
  test('the marker contract and ceiling match the Worker command capture', async () => {
    if (skip !== false) return
    const h = harness as Harness
    assert.equal(h.WORKER_BOUNDED_OPENDIR_MAX_ENTRIES, h.WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES)
    assert.equal(h.WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER, h.SURFACE_BOUNDED_DIRECTORY_OPENER)
    assert.equal(h.WORKER_COMMAND_BOUNDED_OPENDIR, h.SURFACE_BOUNDED_OPENDIR)
    assert.equal(typeof h.runtimeFsPromises.opendir, 'function')
  })

  test('a small real VFS opens through the capture opener and runs a frozen Bash command', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    const installed = installRealFace(h, vfs)
    try {
      assert.equal(h.runtimeFsPromises.opendir[h.WORKER_COMMAND_BOUNDED_OPENDIR], undefined,
        'the shared opener must not advertise a cap it does not apply')
      const opener = h.runtimeFsPromises.opendir[h.WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER]
      assert.equal(typeof opener, 'function')
      assert.deepEqual(opener[h.WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], {
        mode: 'bounded-materialization',
        upperBound: 'vfs-usage-and-deferred-registrations',
        maxEntries: h.WORKER_BOUNDED_OPENDIR_MAX_ENTRIES,
      })
      const directory = await opener.call(h.runtimeFsPromises.opendir, '/dsh/workspace')
      const names: string[] = []
      for (;;) {
        const child = await directory.read()
        if (child === null) break
        names.push(child.name)
      }
      await directory.close()
      assert.deepEqual(names, ['answer.txt'])

      const receipt = await withFrozenChannel(() => h.executeWorkerCommandInFork(
        h.validateWorkerCommandRequest(request()),
        { fs: h.runtimeFsPromises, root: '' },
      ))
      assert.equal(receipt.location.kind, 'worker')
      assert.equal(receipt.location.fork, 'memory-vfs')
      assert.equal(receipt.location.worker_vfs, true)
      assert.equal(receipt.source.kind, 'worker-vfs-fork')
      assert.equal(receipt.source.fork, true)
      assert.equal(receipt.source.source_frozen, true)
      assert.deepEqual(receipt.source.missing_roots, [])
      assert.match(receipt.source.digest, /^sha256:/)
      assert.ok(receipt.source.entries >= 2, JSON.stringify(receipt.source))
      assert.equal(receipt.execution.program, 'bash')
      assert.equal(receipt.execution.exit_code, 0)
      assert.equal(receipt.execution.stdout, 'bounded-ok')
      assert.equal(receipt.execution.stderr, '')
      assert.equal(receipt.model_requests, 0)
      assert.equal(receipt.live_workspace_unchanged, true)
      assert.equal(receipt.verification.method, 'mseq')
      assert.ok(receipt.side_effects.changes.every((change: { path: string }) => change.path.startsWith('/dsh/')))
      assert.equal(receipt.side_effects.changed, receipt.side_effects.changes.length)
      assert.equal(receipt.side_effects.isolated, true)
      assert.equal(receipt.side_effects.live_workspace, false)
      assert.equal(receipt.side_effects.journal, false)
    } finally {
      installed.dispose()
    }
  })

  test('the production capture re-checks its deadline after the synchronous scans', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    const controller = new AbortController()
    let usageCalls = 0
    // The bridge's synchronous usage scan is the last point before the original
    // materialising opener. Abort the capture there: the check the capture
    // passes into the bounded opener must observe it after the scan and refuse
    // before `opendir`/`readdirSync` runs.
    const usageVfs = {
      usage: () => {
        usageCalls += 1
        const usage = vfs.usage()
        controller.abort(new Error('post-scan deadline check fired'))
        return usage
      },
      existsSync: (path: string) => vfs.existsSync(path),
      readFileSync: (path: string, options?: string) => vfs.readFileSync(path, options),
      deferArchive: (archive: {
        readonly name: string
        readonly root: string
        readonly files: readonly LazyFile[]
        readonly load: () => Promise<Uint8Array>
      }) => vfs.deferArchive(archive),
    }
    const installed = installRealFace(h, vfs, { usageVfs })
    try {
      const before = installed.calls()
      await assert.rejects(
        () => h.captureWorkerVfsFork({
          fs: h.runtimeFsPromises,
          root: '',
          roots: ['/dsh/workspace'],
          deadline: Date.now() + 60_000,
          signal: controller.signal,
        }),
        /post-scan deadline check fired/u,
      )
      assert.equal(usageCalls, 1, 'the production capture must reach the bounded preflight')
      assert.deepEqual(installed.calls(), before,
        'the capture-owned post-scan check must stop the original materialising opener')
    } finally {
      installed.dispose()
    }
  })

  test('a tree over the ceiling is refused before the original opendir or readdirSync', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    vfs.seedDirectory('/dsh/workspace/huge')
    for (let index = 0; index < 1_200; index += 1) {
      vfs.seed(`/dsh/workspace/huge/f-${String(index)}.txt`, 'x')
    }
    const installed = installRealFace(h, vfs, { maxEntries: 1_000 })
    try {
      await assert.rejects(
        () => h.captureWorkerVfsFork({
          fs: h.runtimeFsPromises,
          root: '',
          roots: ['/dsh/workspace'],
          maxEntries: 20_000,
        }),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET'
          && /whole-VFS ceiling/u.test((error as Error).message),
      )
      assert.deepEqual(installed.calls(), { opendir: 0, readdirSync: 0 }, 'neither materialising call may run')

      const receipt = await withFrozenChannel(() => h.executeWorkerCommandInFork(
        h.validateWorkerCommandRequest(request()),
        { fs: h.runtimeFsPromises, root: '' },
      ))
      assert.equal(receipt.location.fork, 'none')
      assert.equal(receipt.source.fork, false)
      assert.equal(receipt.source.source_frozen, false)
      assert.equal(receipt.source.failure, 'worker-command/snapshot-failed')
      assert.match(receipt.source.failure_detail, /whole-VFS ceiling/u)
      assert.equal(receipt.execution.exit_code, 1)
      assert.equal(receipt.execution.stdout, '')
      assert.equal(receipt.side_effects.isolated, true)
      assert.deepEqual(installed.calls(), { opendir: 0, readdirSync: 0 })
    } finally {
      installed.dispose()
    }
  })

  test('flat lazy registrations invisible to usage() are counted before the original opener', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h, { manifest: false })
    const files = Array.from({ length: 1_000 }, (_, index) => ({
      path: `workspace/lazy/f-${String(index)}.txt`,
      size: 1,
    }))
    // The real public registration path: usage() stays tiny because these are
    // in MemoryVfs's deferred map, while readdirSync still enumerates them.
    vfs.deferArchive({
      name: 'lazy/test.tar.gz', root: '/dsh', files, load: async () => new Uint8Array(),
    })
    seedManifest(vfs, files)
    const before = vfs.usage()
    assert.ok(before.files < 10, `usage() must stay small, received ${JSON.stringify(before)}`)
    const installed = installRealFace(h, vfs, { maxEntries: 500 })
    try {
      await assert.rejects(
        () => h.captureWorkerVfsFork({
          fs: h.runtimeFsPromises,
          root: '',
          roots: ['/dsh/workspace'],
          maxEntries: 20_000,
        }),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET'
          && /observed lazy registrations/u.test((error as Error).message),
      )
      assert.deepEqual(installed.calls(), { opendir: 0, readdirSync: 0 },
        'the deferred map must be counted before the original materialises it')
    } finally {
      installed.dispose()
    }
  })

  test('a later public deferArchive call is observed before the next capture', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    const installed = installRealFace(h, vfs, { maxEntries: 100 })
    try {
      vfs.deferArchive({
        name: 'lazy/later.tar.gz',
        root: '/dsh',
        files: Array.from({ length: 200 }, (_, index) => ({
          path: `workspace/later/f-${String(index)}.txt`,
          size: 1,
        })),
        load: async () => new Uint8Array(),
      })
      await assert.rejects(
        () => h.captureWorkerVfsFork({
          fs: h.runtimeFsPromises,
          root: '',
          roots: ['/dsh/workspace'],
          maxEntries: 20_000,
        }),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET',
      )
      assert.deepEqual(installed.calls(), { opendir: 0, readdirSync: 0 })
    } finally {
      installed.dispose()
    }
  })

  test('ordinary shared opendir stays unbounded above the capture ceiling', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    vfs.seedDirectory('/dsh/workspace/huge')
    for (let index = 0; index < 1_200; index += 1) {
      vfs.seed(`/dsh/workspace/huge/f-${String(index)}.txt`, 'x')
    }
    const installed = installRealFace(h, vfs, { maxEntries: 100 })
    try {
      const directory = await h.runtimeFsPromises.opendir('/dsh/workspace/huge')
      const names: string[] = []
      for (;;) {
        const child = await directory.read()
        if (child === null) break
        names.push(child.name)
      }
      await directory.close()
      assert.equal(names.length, 1_200, 'ordinary node:fs reads keep the pinned contract')
      assert.deepEqual(installed.calls(), { opendir: 1, readdirSync: 1 })

      const before = installed.calls()
      await assert.rejects(
        () => boundedOpener(h)('/dsh/workspace/huge'),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET',
      )
      assert.deepEqual(installed.calls(), before,
        'the capture-only opener refuses without entering the original opener')
    } finally {
      installed.dispose()
    }
  })

  test('an unmarked reader, a VFS without usage and a missing manifest fail closed', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const unmarkedVfs = smallVfs(h)
    const unmarked = installRealFace(h, unmarkedVfs, { bridge: false })
    try {
      await assert.rejects(
        () => h.captureWorkerVfsFork({ fs: h.runtimeFsPromises, root: '', roots: ['/dsh/workspace'] }),
        (error: unknown) => (error as { code?: string }).code === 'worker-command/snapshot-unsupported',
      )
      assert.deepEqual(unmarked.calls(), { opendir: 0, readdirSync: 0 })
    } finally {
      unmarked.dispose()
    }

    const noUsageVfs = smallVfs(h)
    const noUsage = installRealFace(h, noUsageVfs, { usageVfs: {} })
    try {
      await assert.rejects(
        () => boundedOpener(h)('/dsh/workspace'),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE'
          && /no public usage\(\)/u.test((error as Error).message),
      )
      await assert.rejects(
        () => h.captureWorkerVfsFork({ fs: h.runtimeFsPromises, root: '', roots: ['/dsh/workspace'] }),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE',
      )
      assert.deepEqual(noUsage.calls(), { opendir: 0, readdirSync: 0 })
    } finally {
      noUsage.dispose()
    }

    const noManifestVfs = smallVfs(h, { manifest: false })
    const noManifest = installRealFace(h, noManifestVfs)
    try {
      await assert.rejects(
        () => h.captureWorkerVfsFork({ fs: h.runtimeFsPromises, root: '', roots: ['/dsh/workspace'] }),
        (error: unknown) => (error as { code?: string }).code === 'ERR_PDSH_BOUNDED_OPENDIR_USAGE'
          && /manifest .* is missing/u.test((error as Error).message),
      )
      assert.deepEqual(noManifest.calls(), { opendir: 0, readdirSync: 0 })
    } finally {
      noManifest.dispose()
    }
  })

  test('/tmp aliases through the capture opener and the private namespace is refused', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const vfs = smallVfs(h)
    const installed = installRealFace(h, vfs)
    try {
      const opener = boundedOpener(h)
      const directory = await opener('/tmp')
      assert.equal(directory.path, '/dsh/tmp')
      const names: string[] = []
      for (;;) {
        const child = await directory.read()
        if (child === null) break
        names.push(child.name)
      }
      await directory.close()
      assert.deepEqual(names, ['alias.txt'])

      const callsBeforePrivate = installed.calls()
      await assert.rejects(
        () => opener('/dsh/home/sessions'),
        (error: unknown) => (error as { code?: string }).code === 'EACCES'
          && /session-internal state/u.test((error as Error).message),
      )
      assert.deepEqual(installed.calls(), callsBeforePrivate,
        'the policy refuses private state before the original opener')

      const receipt = await withFrozenChannel(() => h.executeWorkerCommandInFork(
        h.validateWorkerCommandRequest(request({ command: 'pwd', cwd: '/tmp' })),
        { fs: h.runtimeFsPromises, root: '' },
      ))
      assert.equal(receipt.execution.cwd, '/dsh/tmp')
      assert.equal(receipt.execution.exit_code, 0)
      assert.equal(receipt.execution.stdout, '/dsh/tmp\n')
      assert.equal(receipt.location.fork, 'memory-vfs')
    } finally {
      installed.dispose()
    }
  })

  test('dispose restores the original face and deferArchive and does not leave another Worker marked', async () => {
    if (skip !== false) return
    const h = harness as Harness
    const before = h.runtimeFsPromises.opendir
    const firstVfs = smallVfs(h)
    const firstDefer = firstVfs.deferArchive
    const first = installRealFace(h, firstVfs)
    assert.notEqual(firstVfs.deferArchive, firstDefer,
      'the bridge observes later public lazy registrations')
    first.dispose()
    assert.equal(h.runtimeFsPromises.opendir, before, 'the original real opener is restored exactly')
    assert.equal(firstVfs.deferArchive, firstDefer, 'the original public registration is restored exactly')
    assert.equal(h.runtimeFsPromises.opendir[h.WORKER_COMMAND_BOUNDED_OPENDIR], undefined)
    assert.equal(h.runtimeFsPromises.opendir[h.WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER], undefined)
    assert.equal(h.runtimeFsPromises.opendir[h.WORKER_BOUNDED_DIRECTORY_MATERIALIZATION], undefined)

    const secondVfs = smallVfs(h)
    const second = installRealFace(h, secondVfs)
    try {
      const receipt = await withFrozenChannel(() => h.executeWorkerCommandInFork(
        h.validateWorkerCommandRequest(request({ command: 'printf second-worker' })),
        { fs: h.runtimeFsPromises, root: '' },
      ))
      assert.equal(receipt.execution.stdout, 'second-worker')
      assert.equal(receipt.source.source_frozen, true)
      assert.equal(receipt.side_effects.isolated, true)
    } finally {
      second.dispose()
    }
  })
})

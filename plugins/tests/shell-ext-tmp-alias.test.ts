// SPDX-License-Identifier: MIT
// The Worker execution filesystem surfaces share one volatile tmp storage
// (PLAN D4/D15): `/tmp` and `/dsh/tmp` are two spellings of it, the shell
// adapter resolves `/tmp/x` to the same VFS file, mutations under either
// spelling are never sent (D4), `/tmp` is not a second tree, and a write to
// any other unmapped root fails loud with the usable roots. G2-FIX-23 moved
// the CPython preopen table to the shell's `/dsh` namespace; the G2 namespace
// fix made `/tmp` a first-class identity preopen whose storage the namespace
// canonicalises onto `/dsh/tmp`.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  createMemoryChannelPair,
  decodeVfsMutation,
  FrameType,
  type Frame,
} from '../channel/src/index.ts'
import { createToolboxCommands, guestCwdFor, VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { installSink, type WorkerEntryMutation, type WorkerEntryVfs } from '../worker-entry/src/entry.ts'
import {
  disposePythonToolbox,
  installPythonToolbox,
  PYTHON_PREOPENS,
  PYTHON_STDLIB_IMAGE_PATH,
  PYTHON_WASM_IMAGE_PATH,
} from '../worker-entry/src/python-toolbox.ts'
import {
  MemoryVfsBackend,
  NodeFsBackend,
  WORKER_VFS_NAMESPACE,
  resolveGuestCwd,
  resolveGuestPath,
  workerNamespacePath,
  type NodeFsPromisesLike,
  type WorkerToolbox,
} from '../wasi-toolbox/src/index.ts'

/** The contract roots a Worker command may write to (PLAN D4/D15). */
const WRITABLE_ROOTS = ['/dsh/workspace', '/dsh/home', '/dsh/tmp'] as const

const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

interface Fixture {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/**
 * A real-directory VFS fixture (`root` maps virtual `/`).
 * @param options - `workerPaths: true` enables the Worker alias table; the
 *   default leaves a non-Worker root verbatim.
 * @returns the temp root, adapter and shell.
 */
function fixture(options: { workerPaths?: boolean } = {}): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-tmp-alias-'))
  roots.push(root)
  for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  const fs = new VfsFileSystem({ root, ...options })
  return { root, fs, shell: new WorkerShell({ fs }) }
}

/**
 * `node:fs/promises` face with `root` as virtual `/`, the same prefix mapping
 * the Worker `MemoryVfs` node:fs facade gives the Python backend.
 * @param root - real directory behind virtual `/`.
 * @returns the shaped promises face.
 */
function rootedPromises(root: string): NodeFsPromisesLike {
  const real = (path: string): string => `${root}${path}`
  const face: NodeFsPromisesLike = {
    stat: async (path: string) => fsPromises.stat(real(path)),
    lstat: async (path: string) => fsPromises.lstat(real(path)),
    readdir: async (path: string, options: { withFileTypes: true }) => fsPromises.readdir(real(path), options),
    readFile: async (path: string) => fsPromises.readFile(real(path)),
    writeFile: async (path: string, data: Uint8Array, options?: { readonly mode?: number }) =>
      fsPromises.writeFile(real(path), data, options),
    mkdir: async (path: string, options?: { readonly recursive?: boolean; readonly mode?: number }) =>
      fsPromises.mkdir(real(path), options),
    unlink: async (path: string) => fsPromises.unlink(real(path)),
    rm: async (path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }) =>
      fsPromises.rm(real(path), options),
    rename: async (from: string, to: string) => fsPromises.rename(real(from), real(to)),
    truncate: async (path: string, length?: number) => fsPromises.truncate(real(path), length),
    chmod: async (path: string, mode: number) => fsPromises.chmod(real(path), mode),
  }
  return face
}

/** Write mutation in the runtime's published shape. */
function writeMutation(path: string, text: string): WorkerEntryMutation {
  return { kind: 'write', path, bytes: new TextEncoder().encode(text), mode: 0o644, entryChanged: true }
}

/** Minimal VFS whose observers can be driven directly, as the runtime does. */
function observerVfs(): WorkerEntryVfs & { emit(mutation: WorkerEntryMutation): void } {
  const listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  return {
    subscribe(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    async flush() {},
    emit(mutation) {
      for (const listener of [...listeners]) listener(mutation)
    },
  }
}

/** Let the memory channel deliver frames. */
async function settle(): Promise<void> {
  await new Promise<void>(resolve => setTimeout(resolve, 0))
  await new Promise<void>(resolve => setTimeout(resolve, 0))
}

test('tmp: a heredoc `cat > /tmp/f` is one file at /tmp and /dsh/tmp, and Python guest /dsh/tmp reads it', async () => {
  const { root, fs, shell } = fixture({ workerPaths: true })
  const script = [
    "cat > /tmp/staged.txt <<'EOF'",
    'from the temp root',
    'EOF',
    'cat /tmp/staged.txt',
  ].join('\n')
  const result = await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'from the temp root\n')

  // The alias is a resolution, not a copy: both names are the same VFS file.
  const expected = 'from the temp root\n'
  assert.equal(await fs.readFile('/tmp/staged.txt'), expected)
  assert.equal(await fs.readFile('/dsh/tmp/staged.txt'), expected)
  assert.equal(readFileSync(join(root, 'dsh/tmp/staged.txt'), 'utf8'), expected)
  assert.equal(existsSync(join(root, 'tmp')), false, 'no real /tmp tree may appear below the root')

  // CPython's preopen table is generated from the one root table, so guest and
  // host spellings are identical identities. `/tmp` is a root of its own; the
  // namespace (not the preopen table) makes both spellings one storage path.
  const guest = resolveGuestPath(PYTHON_PREOPENS, undefined, '/dsh/tmp/staged.txt')
  assert.equal(guest.guestPath, '/dsh/tmp/staged.txt')
  assert.equal(guest.hostPath, '/dsh/tmp/staged.txt')
  const volatileGuest = resolveGuestPath(PYTHON_PREOPENS, undefined, '/tmp/staged.txt')
  assert.equal(volatileGuest.guestPath, '/tmp/staged.txt')
  assert.equal(volatileGuest.hostPath, '/tmp/staged.txt')
  assert.equal(workerNamespacePath('/tmp/staged.txt'), '/tmp/staged.txt')
  assert.equal(resolveGuestCwd(PYTHON_PREOPENS, '/tmp/staged.txt'), '/tmp/staged.txt')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath(volatileGuest.hostPath), '/dsh/tmp/staged.txt')
  // The legacy `/workspace` and `/home` spellings stay translations, never
  // second preopen roots.
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/workspace/staged.txt'), '/dsh/workspace/staged.txt')
  assert.throws(
    () => resolveGuestPath(PYTHON_PREOPENS, undefined, '/workspace/staged.txt'),
    /outside the preopened directories/,
  )
  // The production Python backend reads the same bytes through the volatile
  // spelling because its face applies the namespace canonicalisation.
  const python = new NodeFsBackend(rootedPromises(root))
  const bytes = await python.readFile(volatileGuest.hostPath)
  assert.equal(new TextDecoder().decode(bytes), expected)
})

test('tmp: the installed python3 toolbox carries the shell /dsh preopen table', async () => {
  // The production wiring (`installPythonToolbox`) must publish the same
  // `/dsh` roots the shell stages into; the stub wasm is enough because
  // nothing runs yet.
  const files = new Map<string, Uint8Array>([
    [PYTHON_WASM_IMAGE_PATH, readFileSync(new URL('../wasi-toolbox/python/testdata/stub-python.wasm', import.meta.url))],
    [PYTHON_STDLIB_IMAGE_PATH, new Uint8Array(64)],
  ])
  const image: WorkerEntryVfs = {
    subscribe: () => () => {},
    async flush() {},
    readFileSync(path: string): Uint8Array {
      const bytes = files.get(path)
      if (bytes === undefined) {
        throw Object.assign(new Error(`ENOENT: no such file or directory, open '${path}'`), { code: 'ENOENT', path })
      }
      return bytes
    },
  }
  // A mounted host tree: the publish guard verifies that the toolbox's file
  // view resolves the shell's persisted roots before it publishes python3
  // (G2-FIX-54).
  const hostVfs = new MemoryVfsBackend()
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) hostVfs.seedDirectory(directory)
  const wiring = await installPythonToolbox({
    vfs: image,
    backend: hostVfs,
    spawnWorker: () => { throw new Error('the toolbox must not spawn a tool worker before the first run') },
  })
  try {
    assert.ok(wiring !== undefined)
    assert.deepEqual(wiring.toolbox.preopenTable, [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
      { guestPath: '/tmp', hostPath: '/tmp' },
      { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
    ])
    assert.equal(
      wiring.toolbox.preopenTable?.some(preopen => ['/workspace', '/home'].includes(preopen.guestPath)),
      false,
      'the legacy /workspace and /home spellings are translations, not second preopen roots',
    )
    // `guestCwdFor` is the shell adapter's host-to-guest map. With identity
    // preopens it returns the contract path unchanged; `/tmp` is one of those
    // identity roots now, so both volatile spellings dispatch as themselves and
    // the namespace makes them one storage path.
    assert.equal(guestCwdFor(wiring.toolbox, '/dsh/tmp/jobs'), '/dsh/tmp/jobs')
    assert.equal(guestCwdFor(wiring.toolbox, '/tmp'), '/tmp')
    assert.equal(guestCwdFor(wiring.toolbox, '/tmp/jobs'), '/tmp/jobs')
    assert.equal(guestCwdFor(wiring.toolbox, '/dsh/workspace'), '/dsh/workspace')
    assert.equal(guestCwdFor(wiring.toolbox, '/elsewhere'), undefined)
    assert.equal(resolveGuestCwd(PYTHON_PREOPENS, '/tmp/jobs'), '/tmp/jobs')
    assert.equal(resolveGuestCwd(PYTHON_PREOPENS, '/dsh/home'), '/dsh/home')
  } finally {
    await disposePythonToolbox(wiring)
  }
})

test('tmp: `cd /tmp` hands the identity /tmp cwd to a toolbox program', async () => {
  const { fs } = fixture({ workerPaths: true })
  const seen: (string | undefined)[] = []
  const toolbox = {
    preopenTable: PYTHON_PREOPENS,
    list: () => [{ program: 'python3' }],
    run: async (request: { readonly cwd?: string; readonly env?: Readonly<Record<string, string>> }) => {
      // Same resolution the real toolbox performs: the shell adapter maps a
      // covered host cwd, and an uncovered legacy spelling (`/tmp`) comes in
      // through PWD and is translated onto the contract root.
      const candidate = request.cwd ?? request.env?.PWD
      seen.push(candidate === undefined ? undefined : resolveGuestCwd(PYTHON_PREOPENS, candidate))
      return {
        program: 'python3',
        exitCode: 0,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: 0,
        stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
  const shell = new WorkerShell({ fs, commands: createToolboxCommands(toolbox) })
  const result = await shell.run(['bash', '-c', 'cd /tmp && python3 relative-script.py'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(seen, ['/tmp'], 'the program runs in /tmp, the same storage `ls /dsh/tmp` lists')
})

test('tmp: every path-taking member resolves through the alias to the same /dsh/tmp file', async () => {
  const { root, fs } = fixture({ workerPaths: true })
  await fs.mkdir('/tmp/jobs')
  await fs.createExclusive('/tmp/jobs/exclusive.txt', { mode: 0o600 })
  await fs.writeFile('/tmp/jobs/note.txt', 'note')
  await fs.appendFile('/tmp/jobs/note.txt', '\ntail')
  assert.equal(await fs.readFile('/tmp/jobs/note.txt'), 'note\ntail')
  assert.equal(await fs.readFile('/dsh/tmp/jobs/note.txt'), 'note\ntail')
  assert.equal(await fs.readFileBytes('/tmp/jobs/note.txt'), 'note\ntail')
  assert.deepEqual([...await fs.readFileBuffer('/tmp/jobs/note.txt')], [...Buffer.from('note\ntail')])
  assert.equal((await fs.stat('/tmp/jobs/note.txt')).isFile, true)
  assert.equal((await fs.lstat('/tmp/jobs')).isDirectory, true)
  assert.equal(await fs.exists('/tmp/jobs/exclusive.txt'), true)
  assert.deepEqual((await fs.readdir('/tmp')).sort(), ['jobs'])
  assert.deepEqual((await fs.readdirWithFileTypes('/tmp')).map(entry => entry.name), ['jobs'])
  await fs.cp('/tmp/jobs/note.txt', '/tmp/jobs/copied.txt')
  await fs.mv('/tmp/jobs/copied.txt', '/tmp/jobs/moved.txt')
  await fs.chmod('/tmp/jobs/moved.txt', 0o600)
  await fs.link('/tmp/jobs/moved.txt', '/tmp/jobs/linked.txt')
  await fs.rm('/tmp/jobs/exclusive.txt')
  await fs.rm('/tmp/jobs/linked.txt')
  assert.equal(readFileSync(join(root, 'dsh/tmp/jobs/moved.txt'), 'utf8'), 'note\ntail')
  assert.equal(readFileSync(join(root, 'dsh/tmp/jobs/note.txt'), 'utf8'), 'note\ntail')
  assert.equal(existsSync(join(root, 'dsh/tmp/jobs/exclusive.txt')), false)
  assert.equal(existsSync(join(root, 'tmp')), false)
})

test('tmp: stat /tmp is the /dsh/tmp directory and getAllPaths lists it once, with no /tmp view', async () => {
  const { fs } = fixture({ workerPaths: true })
  await fs.mkdir('/tmp/one/two', { recursive: true })
  await fs.writeFile('/tmp/one/two/leaf.txt', 'leaf')
  const stats = await fs.stat('/tmp')
  assert.equal(stats.isDirectory, true)
  assert.equal((await fs.lstat('/tmp')).isDirectory, true)
  const paths = fs.getAllPaths()
  assert.equal(paths.includes('/dsh/tmp'), true)
  assert.equal(paths.includes('/dsh/tmp/one'), true)
  assert.equal(paths.includes('/dsh/tmp/one/two/leaf.txt'), true)
  assert.equal(paths.filter(path => path === '/dsh/tmp').length, 1, 'the tmp root is listed exactly once')
  assert.equal(paths.some(path => path === '/tmp' || path.startsWith('/tmp/')), false, 'the alias is not a second tree')
})

test('tmp: a /tmp write is a real /dsh/tmp mutation that the D4 sink never sends', async () => {
  const { root, fs, shell } = fixture({ workerPaths: true })
  const result = await shell.run(['bash', '-c', "printf 'tmp' > /tmp/dropped.txt; printf 'kept' > /dsh/workspace/kept.txt"], {
    cwd: '/dsh/workspace',
  })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(readFileSync(join(root, 'dsh/tmp/dropped.txt'), 'utf8'), 'tmp')
  assert.equal(readFileSync(join(root, 'dsh/workspace/kept.txt'), 'utf8'), 'kept')

  const pair = createMemoryChannelPair({ autoConnect: true })
  const frames: Frame[] = []
  pair.host.onFrame((frame) => { frames.push(frame) })
  const vfs = observerVfs()
  const dispose = installSink(vfs, pair.worker)
  try {
    // The runtime publishes the mutation at the resolved contract path.
    vfs.emit(writeMutation('/dsh/tmp/dropped.txt', 'tmp'))
    vfs.emit(writeMutation('/dsh/workspace/kept.txt', 'kept'))
    await settle()
    const mutations = frames.filter(frame => frame.type === FrameType.VFS_MUT).map(frame => decodeVfsMutation(frame.payload))
    assert.equal(mutations.length, 1, 'only the workspace twin reaches the sink')
    assert.equal(mutations[0]?.path, '/dsh/workspace/kept.txt')
  } finally {
    dispose()
  }
})

test('tmp: a real-directory root without the option keeps verbatim /tmp, and explicit aliases are the switch', async () => {
  const { root, fs } = fixture()
  assert.deepEqual([...fs.pathAliases], [], 'a non-Worker root has no alias by default')
  await assert.rejects(fs.readFile('/tmp/missing.txt'), (error: unknown) => {
    const coded = error as { code?: string; message?: string }
    assert.equal(coded.code, 'ENOENT')
    assert.doesNotMatch(String(coded.message), /writable roots/, 'a read keeps the verbatim node:fs error')
    return true
  })
  await assert.rejects(fs.writeFile('/tmp/missing.txt', 'x'), (error: unknown) => (error as { code?: string }).code === 'ENOENT')
  assert.equal(existsSync(join(root, 'tmp')), false)
  assert.equal(existsSync(join(root, 'dsh/tmp/missing.txt')), false)

  // The same root with the explicit option resolves /tmp to /dsh/tmp.
  const aliased = new VfsFileSystem({ root, workerPaths: true })
  assert.deepEqual([...aliased.pathAliases], [{ from: '/tmp', to: '/dsh/tmp' }])
  await aliased.writeFile('/tmp/present.txt', 'present')
  assert.equal(readFileSync(join(root, 'dsh/tmp/present.txt'), 'utf8'), 'present')

  // Worker virtual roots are the one default-on configuration.
  assert.deepEqual([...new VfsFileSystem({ root: '/' }).pathAliases], [{ from: '/tmp', to: '/dsh/tmp' }])
  assert.deepEqual([...new VfsFileSystem({ root: '', workerPaths: false }).pathAliases], [])
})

test('tmp: the alias table is configuration-validated and no other root may be redirected', () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-tmp-alias-config-'))
  roots.push(root)
  const invalid: readonly [readonly { from: string; to: string }[], RegExp][] = [
    [[{ from: 'tmp', to: '/dsh/tmp' }], /alias from must be an absolute path/],
    [[{ from: '/tmp/', to: '/dsh/tmp' }], /must not end with/],
    [[{ from: '/', to: '/dsh/tmp' }], /cannot be the virtual root/],
    [[{ from: '/tmp', to: '/' }], /cannot be the virtual root/],
    [[{ from: '/dsh/workspace', to: '/dsh/tmp' }], /only "\/tmp" may be bridged/],
    [[{ from: '/var', to: '/dsh/tmp' }], /only "\/tmp" may be bridged/],
    [[{ from: '/dev', to: '/dsh/tmp' }], /only "\/tmp" may be bridged/],
    [[{ from: '/tmp', to: '/dsh2/tmp' }], /inside the contract root \/dsh/],
    [[{ from: '/tmp', to: '/dsh' }], /inside the contract root \/dsh/],
    [[{ from: '/tmp', to: '/dsh/tmp' }, { from: '/tmp', to: '/dsh/work' }], /overlaps/],
  ]
  for (const [aliases, pattern] of invalid) {
    assert.throws(() => new VfsFileSystem({ root, aliases }), pattern, JSON.stringify(aliases))
  }
  // An explicit table is accepted for any root and only the documented entry exists.
  const explicit = new VfsFileSystem({ root, aliases: [{ from: '/tmp', to: '/dsh/tmp' }] })
  assert.deepEqual([...explicit.pathAliases], [{ from: '/tmp', to: '/dsh/tmp' }])
})

test('errors: a write outside the writable roots fails loud and names the usable roots', async () => {
  const { root, fs, shell } = fixture({ workerPaths: true })
  const result = await shell.run(['bash', '-c', 'echo nope > /var/x'], { cwd: '/dsh/workspace' })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /ENOENT/)
  for (const writable of WRITABLE_ROOTS) assert.match(result.stderr, new RegExp(writable.replace(/[/]/g, '\\/')))
  assert.match(result.stderr, /TMPDIR/)
  assert.equal(existsSync(join(root, 'var')), false, 'the target path is never rewritten')
  // The same class through the adapter itself keeps the code and virtual path.
  await assert.rejects(fs.writeFile('/var/y', 'x'), (error: unknown) => {
    const coded = error as { code?: string; path?: string; message?: string }
    assert.equal(coded.code, 'ENOENT')
    assert.equal(coded.path, '/var/y')
    assert.match(String(coded.message), /writable roots are \/dsh\/workspace, \/dsh\/home, \/dsh\/tmp/)
    return true
  })
})

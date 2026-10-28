// SPDX-License-Identifier: MIT
// G2-FIX-35: Worker-side command acceptance receipts.
//
// These tests pin the route contract and the two facts that distinguish it
// from the Mac-host `workspace_command`:
//   * the command runs on an immutable fork of the Worker VFS, so a write is
//     visible in the receipt and absent from the live tree;
//   * the receipt binds the result to scenario/session/turn/assertion and
//     watermark, carries raw output and the exact budget/cancel/exit facts,
//     and never claims a host process.
//
// The tests use the production fork executor and the real Worker shell. The
// Python dispatch is exercised through an injected runtime so no CPython WASI
// artifact is needed in this container; the production default builds the real
// Python runtime from the image artifacts.

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  promises as fsp,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, describe, test } from 'node:test'

import {
  WORKER_COMMAND_MAX_OUTPUT_BYTES,
  WORKER_COMMAND_PATH,
  WORKER_COMMAND_PROTOCOL,
  WorkerCommandError,
  captureWorkerVfsFork,
  createForkFileSystemFace,
  executeWorkerCommandInFork,
  markBoundedDirectoryOpener,
  registerWorkerCommandRoute,
  validateWorkerCommandRequest,
} from '../surface-phone/src/worker-command-controller.js'
import {
  EXEC_INTERNAL_ROOTS,
  MemoryVfsBackend,
  WORKER_VFS_NAMESPACE,
  wrapFsPromises,
} from '../wasi-toolbox/src/index.ts'

// Node's own `fsp.opendir` is a real incremental directory handle. The capture
// trusts only an explicitly marked opener because the pinned DSH facade
// implements `opendir` by materialising the whole listing; declare this test
// process's native opener bounded so the production default path stays covered.
markBoundedDirectoryOpener(fsp.opendir)

const roots: string[] = []

function makeRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-worker-command-'))
  roots.push(root)
  for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  return root
}

function request(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    command: 'printf worker',
    program: 'bash',
    cwd: '/dsh/workspace',
    scenario_id: 'G2-WC-1',
    session_id: 'session-1',
    turn: 2,
    assertion_index: 3,
    completion_watermark: 2,
    ...overrides,
  }
}

/** Install a mutable ordered-channel watermark for the duration of `run`. */
async function withChannel<T>(
  state: { next: bigint },
  run: (state: { next: bigint }) => Promise<T>,
): Promise<T> {
  const globals = globalThis as { __PDSH_CHANNEL__?: { nextMseq(): bigint } }
  const previous = globals.__PDSH_CHANNEL__
  globals.__PDSH_CHANNEL__ = { nextMseq: () => state.next }
  try {
    return await run(state)
  } finally {
    if (previous === undefined) delete globals.__PDSH_CHANNEL__
    else globals.__PDSH_CHANNEL__ = previous
  }
}

/**
 * A reader with the streaming members the capture requires. Tests override the
 * one method they are exercising; a deliberately non-streaming reader is built
 * inline where that refusal is the assertion.
 */
function streamingReader(overrides: Record<string, unknown> = {}) {
  return {
    lstat: (path: string) => fsp.lstat(path),
    readdir: (path: string, options: { withFileTypes: true }) => fsp.readdir(path, options),
    readFile: (path: string) => fsp.readFile(path),
    opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
    open: (path: string, flags: string) => fsp.open(path, flags),
    ...overrides,
  }
}

function truncationMarkerFacts(text: string): { dropped: number, total: number } | undefined {
  const match = /output truncated: (\d+) of (\d+) bytes elided/u.exec(text)
  return match === null ? undefined : { dropped: Number(match[1]), total: Number(match[2]) }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

describe('worker command request validation', () => {
  test('a complete request binds scenario, session, turn, assertion and watermark', () => {
    const value = validateWorkerCommandRequest(request())
    assert.equal(value.command, 'printf worker')
    assert.equal(value.program, 'bash')
    assert.equal(value.cwd, '/dsh/workspace')
    assert.equal(value.budgetMs, 30_000)
    assert.equal(value.scenarioId, 'G2-WC-1')
    assert.equal(value.sessionId, 'session-1')
    assert.equal(value.turn, 2)
    assert.equal(value.assertionIndex, 3)
    assert.equal(value.completionWatermark, 2)
  })

  test('a missing scenario or session binding is a typed failure', () => {
    for (const field of ['scenario_id', 'session_id']) {
      assert.throws(
        () => validateWorkerCommandRequest(request({ [field]: '' })),
        (error: unknown) => error instanceof WorkerCommandError
          && error.code === 'worker-command/missing-binding')
    }
    assert.throws(
      () => validateWorkerCommandRequest(request({ assertion_index: undefined })),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/missing-binding')
  })

  test('a non-positive budget is rejected, a large one is clamped', () => {
    assert.throws(() => validateWorkerCommandRequest(request({ timeout_ms: 0 })),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/bad-budget')
    const value = validateWorkerCommandRequest(request({ timeout_ms: 999_999 }))
    assert.equal(value.budgetMs, 120_000)
  })

  test('only the documented programs are accepted', () => {
    for (const program of ['bash', 'sh', 'python3', 'python']) {
      assert.equal(validateWorkerCommandRequest(request({ program })).program, program)
    }
    assert.throws(() => validateWorkerCommandRequest(request({ program: 'zsh' })),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/bad-program')
  })

  test('cwd is normalised and alias-mapped exactly like the VFS', () => {
    assert.equal(validateWorkerCommandRequest(request({ cwd: '/tmp' })).cwd, '/dsh/tmp')
    assert.equal(validateWorkerCommandRequest(request({ cwd: '/tmp/' })).cwd, '/dsh/tmp')
    assert.equal(validateWorkerCommandRequest(request({ cwd: '/dsh/workspace/' })).cwd, '/dsh/workspace')
    assert.equal(validateWorkerCommandRequest(request({ cwd: '/dsh/workspace/../home' })).cwd, '/dsh/home')
  })
})

describe('immutable Worker VFS fork', () => {
  test('captures files from the live reader and keeps the source tree unchanged', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/answer.txt'), 'worker-source\n')
    writeFileSync(join(root, 'dsh/home/capabilities.json'), '{"format":"pdsh-capabilities/1"}\n')
    const fork = await captureWorkerVfsFork({ root })
    assert.deepEqual(fork.missing, [])
    assert.equal(Buffer.from(fork.entries.get('/dsh/workspace/answer.txt') ?? new Uint8Array()).toString(), 'worker-source\n')
    assert.equal(Buffer.from(fork.entries.get('/dsh/home/capabilities.json') ?? new Uint8Array()).toString(),
      '{"format":"pdsh-capabilities/1"}\n')
    assert.match(fork.digest, /^sha256:[0-9a-f]{64}$/)
    assert.ok(fork.bytes >= 20)
  })

  test('the memory filesystem face refuses exclusive creation of an existing file', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a')
    const fork = await captureWorkerVfsFork({ root })
    const { face } = createForkFileSystemFace(fork.backend)
    await assert.rejects(
      () => face.writeFile('/dsh/workspace/a.txt', new Uint8Array(), { flag: 'wx' }),
      (error: unknown) => (error as { code?: string }).code === 'EEXIST')
  })

  test('capture skips DSH-internal home roots under the real exec read policy', async () => {
    const root = makeRoot()
    for (const internal of EXEC_INTERNAL_ROOTS) {
      const directory = join(root, internal.slice(1))
      mkdirSync(directory, { recursive: true })
      writeFileSync(join(directory, 'internal.jsonl'), 'not-for-exec')
    }
    writeFileSync(join(root, 'dsh/home/capabilities.json'), '{"format":"pdsh-capabilities/1"}\n')
    // This is the production seam: installExecFsPolicy wraps the Worker's
    // node:fs.promises face with the namespace read policy. The fork capture
    // must observe the same EACCES a Worker command would and skip those roots.
    const real = (path: string): string => join(root, path.replace(/^\/+/, ''))
    const guarded = wrapFsPromises({
      async lstat(path: string) { return fsp.lstat(real(path)) },
      async readdir(path: string, options: { withFileTypes: true }) {
        return fsp.readdir(real(path), options)
      },
      async readFile(path: string) { return fsp.readFile(real(path)) },
      opendir: async (path: string) => fsp.opendir(real(path)),
      async open(path: string, flags: string) { return fsp.open(real(path), flags) },
    }, WORKER_VFS_NAMESPACE)
    // The namespace wrapper returns new functions, so the capability marker
    // has to be applied to the wrapped opener the capture will actually call.
    markBoundedDirectoryOpener(guarded.opendir)
    const fork = await captureWorkerVfsFork({ fs: guarded })
    const backend = fork.backend as MemoryVfsBackend
    assert.deepEqual(fork.missing, [])
    assert.equal(fork.entries.has('/dsh/home/capabilities.json'), true)
    const captured = backend.list()
    for (const internal of EXEC_INTERNAL_ROOTS) {
      assert.equal(fork.entries.has(`${internal}/internal.jsonl`), false, internal)
      assert.equal(captured.some(path => path === internal || path.startsWith(`${internal}/`)),
        false, internal)
    }
  })

  test('capture preserves file and directory modes and mtimes', async () => {
    const root = makeRoot()
    const script = join(root, 'dsh/workspace/tool.sh')
    writeFileSync(script, '#!/bin/sh\nprintf "script-ok\\n"\n')
    chmodSync(script, 0o755)
    const subdirectory = join(root, 'dsh/workspace/sub')
    mkdirSync(subdirectory)
    chmodSync(subdirectory, 0o700)
    const sourceStats = statSync(script)
    const fork = await captureWorkerVfsFork({ root })
    const backend = fork.backend as MemoryVfsBackend
    const fileStats = backend.stat('/dsh/workspace/tool.sh')
    assert.equal(fileStats.mode & 0o777, 0o755)
    assert.equal(fileStats.mtimeMs, sourceStats.mtimeMs)
    assert.equal(backend.stat('/dsh/workspace/sub').mode & 0o777, 0o700)

    const { face } = createForkFileSystemFace(fork.backend)
    await face.chmod('/dsh/workspace/sub', 0o711)
    assert.equal(backend.stat('/dsh/workspace/sub').mode & 0o777, 0o711)

    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'test -x tool.sh && ./tool.sh && chmod 711 sub && test -x sub && stat -c %a sub',
    })), { root })
    assert.equal(receipt.execution.exit_code, 0, receipt.execution.stderr)
    assert.equal(receipt.execution.stdout, 'script-ok\n711\n')
  })

  test('the fork shell reads a real Date mtime, not 1970', async () => {
    const root = makeRoot()
    const script = join(root, 'dsh/workspace/tool.sh')
    writeFileSync(script, '#!/bin/sh\nprintf "script-ok\\n"\n')
    const fixedMs = 1_700_000_000_000
    utimesSync(script, new Date(fixedMs), new Date(fixedMs))
    const sourceStats = statSync(script)
    const fork = await captureWorkerVfsFork({ root })

    // The typed face must expose Date-valued timestamps. The source VFS only
    // has one timestamp, so atime/ctime are the same value, never invalid.
    const { face } = createForkFileSystemFace(fork.backend)
    const stats = (await face.stat('/dsh/workspace/tool.sh')) as {
      mtime?: Date, atime?: Date, ctime?: Date
    }
    assert.ok(stats.mtime instanceof Date)
    assert.equal(stats.mtime?.getTime(), sourceStats.mtimeMs)
    assert.equal(stats.atime?.getTime(), sourceStats.mtimeMs)
    assert.equal(stats.ctime?.getTime(), sourceStats.mtimeMs)

    // The real shell path is the regression: `ls` and the stat/find shims read
    // `FsStat.mtime` directly, so an mtimeMs-only face threw or showed epoch 0.
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: "stat -c '%Y' tool.sh && stat -c '%y' tool.sh "
        + "&& find . -maxdepth 1 -name tool.sh -printf '%T@\\n' && ls -l tool.sh",
    })), { root })
    assert.equal(receipt.execution.exit_code, 0, receipt.execution.stderr)
    const lines = receipt.execution.stdout.trimEnd().split('\n')
    assert.equal(lines[0], String(Math.floor(fixedMs / 1000)))
    assert.match(lines[1] ?? '', /^2023-/)
    assert.equal(lines[2], String(fixedMs / 1000))
    assert.doesNotMatch(receipt.execution.stdout, /1970/)
  })

  test('the fork digest covers directory entries and metadata, not only file bytes', async () => {
    const root = makeRoot()
    const file = join(root, 'dsh/workspace/a.txt')
    const subdirectory = join(root, 'dsh/workspace/sub')
    writeFileSync(file, 'same bytes')
    mkdirSync(subdirectory)
    chmodSync(subdirectory, 0o700)
    const roots = ['/dsh/workspace']
    const first = await captureWorkerVfsFork({ root, roots })

    // Metadata-only changes must move the digest even when no file byte does.
    chmodSync(subdirectory, 0o711)
    const chmodded = await captureWorkerVfsFork({ root, roots })
    assert.notEqual(chmodded.digest, first.digest)
    chmodSync(subdirectory, 0o700)
    const restored = await captureWorkerVfsFork({ root, roots })
    assert.equal(restored.digest, first.digest)

    utimesSync(file, 1_000_000_000, 1_000_000_000)
    const touched = await captureWorkerVfsFork({ root, roots })
    assert.notEqual(touched.digest, restored.digest)

    // An empty directory has no file bytes, but it is still part of the view.
    const empty = join(root, 'dsh/workspace/empty')
    mkdirSync(empty)
    const created = await captureWorkerVfsFork({ root, roots })
    assert.notEqual(created.digest, touched.digest)
    rmSync(empty, { recursive: true })
    const removed = await captureWorkerVfsFork({ root, roots })
    assert.notEqual(removed.digest, created.digest)

  })

  test('capture itself bounds a reader that never settles', async () => {
    const root = makeRoot()
    const never = {
      lstat() { return new Promise(() => {}) },
      readdir() { return new Promise(() => {}) },
      readFile() { return new Promise(() => {}) },
    }
    const started = Date.now()
    await assert.rejects(
      () => captureWorkerVfsFork({ root, fs: never, deadline: Date.now() + 30 }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-timeout')
    assert.ok(Date.now() - started < 2000)
  })

  test('capture cleanup that never settles cannot defeat the capture bound', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a')
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      opendir: markBoundedDirectoryOpener(async (path: string) => {
        const children = await fsp.readdir(path, { withFileTypes: true })
        let index = 0
        return {
          async read() { return index < children.length ? children[index++] : null },
          // A directory close that never settles: cleanup I/O is still I/O.
          close() { return new Promise(() => {}) },
        }
      }),
      open: async (path: string) => {
        const data = await fsp.readFile(path)
        let position = 0
        return {
          async read(buffer: Buffer, _offset: number, length: number) {
            const count = Math.min(length, data.byteLength - position)
            if (count <= 0) return { bytesRead: 0 }
            buffer.set(data.subarray(position, position + count), 0)
            position += count
            return { bytesRead: count }
          },
          // A file close that never settles, for the same reason.
          close() { return new Promise(() => {}) },
        }
      },
      readFile: (path: string) => fsp.readFile(path),
    }
    const started = Date.now()
    await assert.rejects(
      () => captureWorkerVfsFork({
        root, fs: reader, roots: ['/dsh/workspace'], deadline: Date.now() + 50,
      }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-timeout')
    assert.ok(Date.now() - started < 1500, 'a hanging close must not hold the capture')
  })

  test('a capture over its entry or byte budget fails closed with a typed error', async () => {
    const root = makeRoot()
    for (let index = 0; index < 8; index++) {
      writeFileSync(join(root, `dsh/workspace/file-${String(index)}.txt`), 'x')
    }
    await assert.rejects(
      () => captureWorkerVfsFork({ root, maxEntries: 3 }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-budget')
    await assert.rejects(
      () => captureWorkerVfsFork({ root, maxBytes: 4 }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-budget')
    // The ordinary budgets still accept the small tree.
    const fork = await captureWorkerVfsFork({ root })
    assert.equal(fork.entries.size, 8)
  })

  test('a missing required root fails closed instead of producing a partial fork', async () => {
    const root = makeRoot()
    rmSync(join(root, 'dsh/workspace'), { recursive: true, force: true })
    await assert.rejects(
      () => captureWorkerVfsFork({ root }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-missing-root'
        && (error as WorkerCommandError & { missingRoots?: string[] }).missingRoots?.includes('/dsh/workspace') === true)

    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'printf ok',
    })), { root })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.location.worker_vfs, false)
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.source_frozen, false)
    assert.equal(receipt.source.digest, '')
    assert.equal(receipt.source.entries, 0)
    assert.deepEqual(receipt.source.missing_roots, ['/dsh/workspace'])
    assert.equal(receipt.source.failure, 'worker-command/snapshot-missing-root')
    assert.equal(receipt.execution.exit_code, 1)
    assert.equal(receipt.live_workspace_unchanged, false)
  })

  test('a missing requested cwd fails closed even when the roots exist', async () => {
    const root = makeRoot()
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'printf ok',
      cwd: '/dsh/workspace/absent',
    })), { root })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.failure, 'worker-command/snapshot-missing-root')
    assert.deepEqual(receipt.source.missing_roots, ['/dsh/workspace/absent'])
    assert.equal(receipt.execution.exit_code, 1)
  })

  test('a tmp alias and a trailing slash cwd resolve to the captured directory', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/tmp/inside.txt'), 'tmp-root')
    for (const [raw, canonical] of [['/tmp', '/dsh/tmp'], ['/dsh/workspace/', '/dsh/workspace']]) {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'pwd',
        cwd: raw,
      })), { root })
      assert.equal(receipt.execution.exit_code, 0, `${raw}: ${receipt.execution.stderr}`)
      assert.equal(receipt.execution.cwd, canonical)
      assert.equal(receipt.execution.stdout.trim(), canonical)
      assert.equal(receipt.source.fork, true)
      assert.equal(receipt.source.failure, undefined)
    }
    const tmp = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'cat inside.txt',
      cwd: '/tmp',
    })), { root })
    assert.equal(tmp.execution.exit_code, 0, tmp.execution.stderr)
    assert.equal(tmp.execution.stdout, 'tmp-root')
  })

  test('a file cannot be used as the Worker command cwd', async () => {
    const root = makeRoot()
    const file = join(root, 'dsh/workspace/not-a-directory.txt')
    writeFileSync(file, 'file')
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'printf ok',
      cwd: '/dsh/workspace/not-a-directory.txt',
    })), { root })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.source_frozen, false)
    assert.equal(receipt.source.failure, 'worker-command/snapshot-missing-root')
    assert.deepEqual(receipt.source.missing_roots, ['/dsh/workspace/not-a-directory.txt'])
    assert.equal(receipt.execution.exit_code, 1)
    assert.equal(receipt.execution.stdout, '')
  })

  test('a huge directory is rejected before walking its children', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/real.txt'), 'real')
    let lstatCalls = 0
    const children = Array.from({ length: 10_000 }, (_, index) => ({
      name: `f-${String(index)}`,
      isFile: () => true,
      isDirectory: () => false,
      isSymbolicLink: () => false,
    }))
    const reader = {
      lstat: async (path: string) => { lstatCalls += 1; return fsp.lstat(path) },
      opendir: markBoundedDirectoryOpener(async (path: string) => {
        if (path !== join(root, 'dsh/workspace')) return fsp.opendir(path)
        let index = 0
        return {
          async read() { return index < children.length ? children[index++] : null },
          async close() {},
        }
      }),
      readdir: () => { throw new Error('readdir must not be used for a directory') },
      open: (path: string, flags: string) => fsp.open(path, flags),
      readFile: (path: string) => fsp.readFile(path),
    }
    await assert.rejects(
      () => captureWorkerVfsFork({ root, fs: reader, roots: ['/dsh/workspace'], maxEntries: 10 }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-budget')
    assert.equal(lstatCalls, 1, 'the oversized directory must fail before any child lstat')
  })

  test('an unmarked materializing opendir is refused before it can list a huge directory', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/real.txt'), 'real')
    let opendirCalls = 0
    let materialized = 0
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      // The pinned DSH `promises.opendir` is `opendirSync` ->
      // `readdirSync(..., { withFileTypes: true })`: the listing is built
      // inside the call, synchronously, before any `read()` can apply the
      // entry budget or the deadline. It must never be reached.
      opendir: async (path: string) => {
        opendirCalls += 1
        const children = Array.from({ length: 100_000 }, (_, index) => ({
          name: `f-${String(index)}`,
          isFile: () => true,
          isDirectory: () => false,
          isSymbolicLink: () => false,
        }))
        materialized = children.length
        let index = 0
        return {
          async read() { return index < children.length ? children[index++] : null },
          async close() {},
        }
      },
      readdir: () => { throw new Error('readdir must not be used for a directory') },
      open: (path: string, flags: string) => fsp.open(path, flags),
      readFile: (path: string) => fsp.readFile(path),
    }
    const started = Date.now()
    await assert.rejects(
      () => captureWorkerVfsFork({
        root, fs: reader, roots: ['/dsh/workspace'], maxEntries: 10, deadline: Date.now() + 50,
      }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-unsupported'
        && /neither a separate bounded opener nor a legacy verified/u.test(error.message))
    assert.equal(opendirCalls, 0, 'the materializing opener must not be called')
    assert.equal(materialized, 0, 'no directory listing may be allocated before the budget check')
    assert.ok(Date.now() - started < 1500, 'the refusal must return before the deadline')
  })

  test('a directory removed after lstat is reported as a missing root, not an opaque failure', async () => {
    const root = makeRoot()
    const absent = Object.assign(new Error(`ENOENT: no such file or directory, opendir '${join(root, 'dsh/workspace')}'`), {
      code: 'ENOENT',
    })
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      opendir: markBoundedDirectoryOpener(async () => { throw absent }),
      readdir: () => { throw new Error('readdir must not be used for a directory') },
      open: (path: string, flags: string) => fsp.open(path, flags),
      readFile: (path: string) => fsp.readFile(path),
    }
    await assert.rejects(
      () => captureWorkerVfsFork({ root, fs: reader, roots: ['/dsh/workspace'] }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-missing-root'
        && (error as WorkerCommandError & { missingRoots?: string[] }).missingRoots?.includes('/dsh/workspace') === true)

    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'printf ok',
    })), { root, fs: reader })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.source.failure, 'worker-command/snapshot-missing-root')
    assert.deepEqual(receipt.source.missing_roots, ['/dsh/workspace'])
    assert.equal(receipt.execution.exit_code, 1)
    assert.equal(receipt.execution.stdout, '')
  })

  test('a reader without opendir fails closed before materialising a directory', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a')
    let readdirCalls = 0
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      readdir: async () => { readdirCalls += 1; throw new Error('readdir must not run') },
      readFile: (path: string) => fsp.readFile(path),
      open: (path: string, flags: string) => fsp.open(path, flags),
    }
    await assert.rejects(
      () => captureWorkerVfsFork({ root, fs: reader, roots: ['/dsh/workspace'] }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-unsupported')
    assert.equal(readdirCalls, 0)
  })

  test('a reader without open fails closed before materialising a whole file', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a')
    let readFileCalls = 0
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      readFile: async () => { readFileCalls += 1; throw new Error('readFile must not run') },
    }
    await assert.rejects(
      () => captureWorkerVfsFork({ root, fs: reader, roots: ['/dsh/workspace'] }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-unsupported')
    assert.equal(readFileCalls, 0)
  })

  test('a lying file size cannot force an untracked read beyond the byte budget', async () => {
    const root = makeRoot()
    const target = join(root, 'dsh/workspace/large.bin')
    writeFileSync(target, Buffer.alloc(4096, 0x61))
    const readLengths: number[] = []
    const reader = {
      lstat: async (path: string) => {
        if (path === target) {
          return { isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false,
            size: 1, mode: 0o644, mtimeMs: 1 }
        }
        return fsp.lstat(path)
      },
      readdir: (path: string) => fsp.readdir(path, { withFileTypes: true }),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      open: async (path: string) => {
        assert.equal(path, target)
        return {
          async read(buffer: Buffer, _offset: number, length: number) {
            readLengths.push(length)
            const count = Math.min(length, 16)
            buffer.fill(0x61, 0, count)
            return { bytesRead: count }
          },
          async close() {},
        }
      },
      readFile: () => { throw new Error('the bounded open path must be used') },
    }
    await assert.rejects(
      () => captureWorkerVfsFork({
        root, fs: reader, roots: ['/dsh/workspace'], maxBytes: 4,
      }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/snapshot-budget')
    assert.ok(readLengths.length > 0)
    assert.ok(Math.max(...readLengths) <= 5, `read length ${String(Math.max(...readLengths))} exceeded budget + 1`)
  })

  test('a symlink anywhere in the roots fails the capture instead of being dropped', async () => {
    for (const target of ['workspace-file', 'external-file']) {
      const root = makeRoot()
      writeFileSync(join(root, 'dsh/workspace/real.txt'), 'real')
      const outside = join(root, 'outside.txt')
      writeFileSync(outside, 'outside')
      symlinkSync(
        target === 'workspace-file' ? join(root, 'dsh/workspace/real.txt') : outside,
        join(root, 'dsh/workspace/link.txt'))
      await assert.rejects(
        () => captureWorkerVfsFork({ root }),
        (error: unknown) => error instanceof WorkerCommandError
          && error.code === 'worker-command/symlink-unsupported'
          && String(error.message).includes('/dsh/workspace/link.txt'),
        target)
    }
    // A directory link, including one pointing outside the preopens, is the
    // same unrepresentable special entry. The receipt must fail closed rather
    // than silently show a workspace without the linked subtree.
    const root = makeRoot()
    mkdirSync(join(root, 'dsh/workspace/real-dir'), { recursive: true })
    mkdirSync(join(root, 'outside-dir'), { recursive: true })
    symlinkSync(join(root, 'outside-dir'), join(root, 'dsh/workspace/linked-dir'))
    await assert.rejects(
      () => captureWorkerVfsFork({ root }),
      (error: unknown) => error instanceof WorkerCommandError
        && error.code === 'worker-command/symlink-unsupported'
        && String(error.message).includes('/dsh/workspace/linked-dir'))
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'printf ok',
    })), { root })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.source_frozen, false)
    assert.equal(receipt.source.failure, 'worker-command/symlink-unsupported')
    assert.equal(receipt.execution.exit_code, 1)
  })

  test('rm -rf removes the whole subtree and does not resurrect it', async () => {
    const root = makeRoot()
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'mkdir -p dir/sub && printf old > dir/sub/old.txt && printf keep > keep.txt '
        + '&& rm -rf dir && mkdir dir && test ! -e dir/sub/old.txt && test -f keep.txt '
        + '&& printf rebuilt',
    })), { root })
    assert.equal(receipt.execution.exit_code, 0, receipt.execution.stderr)
    assert.equal(receipt.execution.stdout, 'rebuilt')
    const changed = receipt.side_effects.changes.map((change: { path: string }) => change.path)
    assert.equal(changed.includes('/dsh/workspace/dir/sub/old.txt'), false)
    assert.equal(changed.includes('/dsh/workspace/keep.txt'), true)
    assert.equal(changed.some(path => path.startsWith('/dsh/workspace/dir/')), false)
  })
})

describe('fork execution receipt', () => {
  test('runs in the Worker fork, keeps raw output, and contains the write', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/answer.txt'), 'worker-source\n')
    writeFileSync(join(root, 'dsh/home/capabilities.json'), '{"format":"pdsh-capabilities/1"}\n')
    const receipt = await withChannel({ next: 5n }, () =>
      executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'ls *.txt >/dev/null; cat answer.txt; '
          + 'printf " location=%s" "$PDSH_WORKER_COMMAND_LOCATION"; '
          + 'printf " fork=%s" "$PDSH_WORKER_VFS_FORK"; echo leaked > leaked.txt',
      })), { root }))
    assert.equal(receipt.protocol, WORKER_COMMAND_PROTOCOL)
    assert.equal(receipt.location.kind, 'worker')
    assert.equal(receipt.location.worker_vfs, true)
    assert.equal(receipt.location.host_process, false)
    assert.equal(receipt.location.fork, 'memory-vfs')
    assert.equal(receipt.binding.scenario_id, 'G2-WC-1')
    assert.equal(receipt.binding.session_id, 'session-1')
    assert.equal(receipt.binding.turn, 2)
    assert.equal(receipt.binding.assertion_index, 3)
    assert.equal(receipt.binding.completion_watermark, 2)
    assert.equal(receipt.execution.exit_code, 0)
    assert.equal(receipt.execution.timed_out, false)
    assert.equal(receipt.execution.cancelled, false)
    assert.equal(receipt.execution.stdout, 'worker-source\n location=worker fork=1')
    assert.equal(receipt.execution.stderr, '')
    assert.equal(receipt.model_requests, 0)
    assert.equal(receipt.live_workspace_unchanged, true)
    assert.equal(receipt.source.kind, 'worker-vfs-fork')
    assert.equal(receipt.source.fork, true)
    assert.equal(receipt.source.entries, 2)
    assert.ok(receipt.side_effects.changes.some((change: { path: string, change: string }) =>
      change.path === '/dsh/workspace/leaked.txt' && change.change === 'created'))
    // The write happened in the fork, not in the live workspace.
    assert.equal(existsSync(join(root, 'dsh/workspace/leaked.txt')), false)
    assert.equal(readFileSync(join(root, 'dsh/workspace/answer.txt'), 'utf8'), 'worker-source\n')
  })

  test('the host shell does not have the Worker sentinels', () => {
    const root = makeRoot()
    const host = spawnSync('/bin/bash', ['-c', 'printf %s "${PDSH_WORKER_COMMAND_LOCATION:-none}"'],
      { cwd: join(root, 'dsh/workspace'), encoding: 'utf8' })
    assert.equal(host.status, 0)
    assert.equal(host.stdout, 'none',
      'a Mac-host command must not see the Worker-side location sentinel')
  })

  test('a Python command over its budget returns a timeout receipt', async () => {
    const root = makeRoot()
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      program: 'python3',
      command: 'while True: pass',
      timeout_ms: 30,
    })), {
      root,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        run(runRequest: { signal?: AbortSignal }) {
          return new Promise((_resolve, reject) => {
            runRequest.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
          })
        },
      },
    })
    assert.equal(receipt.execution.program, 'python3')
    assert.equal(receipt.execution.exit_code, 124)
    assert.equal(receipt.execution.timed_out, true)
    assert.equal(receipt.execution.budget_ms, 30)
  })

  test('the ordered-channel carrier and VFS watermark are recorded', async () => {
    const root = makeRoot()
    const globals = globalThis as { __PDSH_CHANNEL__?: { nextMseq(): bigint } }
    const previous = globals.__PDSH_CHANNEL__
    globals.__PDSH_CHANNEL__ = { nextMseq: () => 5n }
    try {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'printf channel',
      })), { root })
      assert.equal(receipt.location.carrier, 'ordered-channel')
      assert.equal(receipt.source.source_mseq_start, 4)
      assert.equal(receipt.source.source_mseq_end, 4)
      assert.equal(receipt.source.source_frozen, true)
    } finally {
      if (previous === undefined) delete globals.__PDSH_CHANNEL__
      else globals.__PDSH_CHANNEL__ = previous
    }
  })

  test('a timed-out command reports the Worker budget and exit 124', async () => {
    const root = makeRoot()
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'sleep 1; echo late',
      timeout_ms: 50,
    })), { root })
    assert.equal(receipt.execution.exit_code, 124)
    assert.equal(receipt.execution.timed_out, true)
    assert.equal(receipt.execution.cancelled, false)
    assert.equal(receipt.execution.budget_ms, 50)
    assert.match(receipt.execution.stderr, /wall-clock limit/)
  })

  test('python dispatch runs on the same fork through the Worker toolbox face', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/data.txt'), 'python-source')
    let calls = 0
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      program: 'python3',
      command: 'print("worker-python")',
    })), {
      root,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        async run(runRequest: { argv?: readonly string[], onStdout?: (chunk: Uint8Array) => void }) {
          calls += 1
          assert.deepEqual(runRequest.argv, ['-c', 'print("worker-python")'])
          runRequest.onStdout?.(new TextEncoder().encode('worker-python\n'))
          return {
            program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
            memoryPeakBytes: 1, stdoutBytes: 14, stderrBytes: 0,
          }
        },
      },
    })
    assert.equal(receipt.execution.program, 'python3')
    assert.equal(receipt.execution.exit_code, 0)
    assert.equal(receipt.execution.stdout, 'worker-python\n')
    assert.equal(calls, 1)
  })
  test('an uncooperative reader returns a failed receipt at the snapshot deadline', async () => {
    const root = makeRoot()
    const never = {
      lstat() { return new Promise(() => {}) },
      readdir() { return new Promise(() => {}) },
      readFile() { return new Promise(() => {}) },
    }
    const started = Date.now()
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request()), {
      root,
      fs: never,
      snapshotTimeoutMs: 30,
    })
    assert.ok(Date.now() - started < 2000, 'capture must return at its deadline')
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.location.worker_vfs, false)
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.source_frozen, false)
    assert.equal(receipt.source.failure, 'worker-command/snapshot-timeout')
    assert.equal(receipt.execution.timed_out, true)
    assert.equal(receipt.execution.exit_code, 124)
    assert.equal(receipt.model_requests, 0)
    assert.equal(receipt.live_workspace_unchanged, false)
  })

  test('an over-budget snapshot returns a failed receipt, never an immutable claim', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a')
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request()), {
      root,
      maxEntries: 1,
    })
    assert.equal(receipt.location.fork, 'none')
    assert.equal(receipt.source.fork, false)
    assert.equal(receipt.source.source_frozen, false)
    assert.equal(receipt.source.failure, 'worker-command/snapshot-budget')
    assert.equal(receipt.execution.timed_out, false)
    assert.equal(receipt.execution.exit_code, 1)
    assert.equal(receipt.model_requests, 0)
  })

  test('a runtime exception keeps the captured fork as an execution failure', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/answer.txt'), 'worker-source\n')
    await withChannel({ next: 5n }, async () => {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        program: 'python3',
        command: 'print("worker-python")',
      })), {
        root,
        python: {
          preopenTable: [],
          list: () => [{ program: 'python3', aliases: ['python'] }],
          has: (program: string) => program === 'python3' || program === 'python',
          async run() { throw new Error('python runtime exploded') },
        },
      })
      assert.equal(receipt.location.fork, 'memory-vfs')
      assert.equal(receipt.location.worker_vfs, true)
      assert.equal(receipt.source.fork, true)
      assert.equal(receipt.source.source_frozen, true)
      assert.match(receipt.source.digest, /^sha256:/)
      assert.ok(receipt.source.entries >= 1)
      assert.equal(receipt.source.failure, undefined)
      assert.equal(receipt.execution.exit_code, 1)
      assert.equal(receipt.execution.failure, 'worker-command/execution-failed')
      assert.match(receipt.execution.stderr, /python runtime exploded/)
      assert.equal(receipt.live_workspace_unchanged, true)
      assert.equal(receipt.model_requests, 0)
    })
  })

  test('a large Python stream counts every byte while retaining only the cap', async () => {
    const root = makeRoot()
    const chunk = Buffer.alloc(4096, 0x7a)
    const chunks = 4096
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      program: 'python3',
      command: 'print("large")',
    })), {
      root,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        async run(runRequest: { onStdout?: (chunk: Uint8Array) => void,
          onStderr?: (chunk: Uint8Array) => void }) {
          for (let index = 0; index < chunks; index++) runRequest.onStdout?.(chunk)
          return {
            program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
            memoryPeakBytes: 1, stdoutBytes: chunk.byteLength * chunks, stderrBytes: 0,
          }
        },
      },
    })
    assert.equal(receipt.execution.stdout_bytes, chunk.byteLength * chunks)
    assert.equal(Buffer.byteLength(receipt.execution.stdout), WORKER_COMMAND_MAX_OUTPUT_BYTES)
    assert.equal(receipt.execution.stdout_truncated, true)
    assert.equal(receipt.execution.stderr_bytes, 0)
  })

  test('python output is capped per stream with exact produced byte counts', async () => {
    const root = makeRoot()
    const chunk = Buffer.alloc(WORKER_COMMAND_MAX_OUTPUT_BYTES + 1024, 0x78)
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      program: 'python3',
      command: 'print("large")',
    })), {
      root,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        async run(runRequest: { onStdout?: (chunk: Uint8Array) => void,
          onStderr?: (chunk: Uint8Array) => void }) {
          runRequest.onStdout?.(chunk)
          runRequest.onStdout?.(chunk)
          runRequest.onStderr?.(chunk)
          return {
            program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
            memoryPeakBytes: 1, stdoutBytes: chunk.byteLength * 2, stderrBytes: chunk.byteLength,
          }
        },
      },
    })
    assert.equal(receipt.execution.stdout_bytes, chunk.byteLength * 2)
    assert.equal(receipt.execution.stderr_bytes, chunk.byteLength)
    assert.equal(Buffer.byteLength(receipt.execution.stdout), WORKER_COMMAND_MAX_OUTPUT_BYTES)
    assert.equal(Buffer.byteLength(receipt.execution.stderr), WORKER_COMMAND_MAX_OUTPUT_BYTES)
    assert.equal(receipt.execution.stdout_truncated, true)
    assert.equal(receipt.execution.stderr_truncated, true)
    assert.equal(receipt.execution.exit_code, 0)
  })

  test('an early cancel is bounded even when the Python runtime ignores its signal', async () => {
    const root = makeRoot()
    const controller = new AbortController()
    const chunk = Buffer.alloc(WORKER_COMMAND_MAX_OUTPUT_BYTES + 1, 0x79)
    const started = Date.now()
    const pending = executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      program: 'python3',
      command: 'while True: pass',
      timeout_ms: 5_000,
    })), {
      root,
      signal: controller.signal,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        run(runRequest: { onStdout?: (chunk: Uint8Array) => void }) {
          runRequest.onStdout?.(chunk)
          return new Promise(() => {})
        },
      },
    })
    const timer = setTimeout(() => controller.abort(new Error('caller cancelled')), 30)
    const receipt = await pending
    clearTimeout(timer)
    assert.ok(Date.now() - started < 2000, 'cancel must not wait for an uncooperative runtime')
    assert.equal(receipt.execution.cancelled, true)
    assert.equal(receipt.execution.timed_out, false)
    assert.equal(receipt.execution.exit_code, 130)
    assert.equal(receipt.execution.stdout_bytes, chunk.byteLength)
    assert.equal(Buffer.byteLength(receipt.execution.stdout), WORKER_COMMAND_MAX_OUTPUT_BYTES)
    assert.equal(receipt.execution.stdout_truncated, true)
    assert.equal(receipt.source.source_frozen, false)
  })

  test('nested bash python3 output is bounded before the shell assembles it', async () => {
    const root = makeRoot()
    const chunk = Buffer.alloc(64 * 1024, 0x70)
    const chunks = 64
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      // The top-level program is bash; the bounded path under test is the
      // toolbox command that a nested `python3` invocation reaches.
      command: 'python3 -c pass',
      program: 'bash',
    })), {
      root,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        async run(runRequest: { onStdout?: (chunk: Uint8Array) => void }) {
          for (let index = 0; index < chunks; index++) runRequest.onStdout?.(chunk)
          return {
            program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
            memoryPeakBytes: 1, stdoutBytes: chunk.byteLength * chunks, stderrBytes: 0,
          }
        },
      },
    })
    const produced = chunk.byteLength * chunks
    const retained = Buffer.byteLength(receipt.execution.stdout)
    const marker = truncationMarkerFacts(receipt.execution.stdout)
    assert.equal(receipt.execution.stdout_truncated, true)
    assert.equal(receipt.execution.stdout_bytes, produced)
    assert.ok(retained <= WORKER_COMMAND_MAX_OUTPUT_BYTES,
      `retained ${String(retained)} bytes`)
    assert.ok(marker !== undefined, 'the nested marker must survive the shell bound')
    assert.equal(marker.total, produced, 'the marker must name the real nested stream size')
    assert.equal(marker.dropped, produced - (retained - Buffer.byteLength(
      `\n…[output truncated: ${String(marker.dropped)} of ${String(marker.total)} bytes elided]…\n`)))
    assert.match(receipt.execution.stderr, /output-truncated/u)
    assert.equal(receipt.execution.exit_code, 1)
    assert.equal(receipt.model_requests, 0)
  })

  test('a nested stream follows a shell cap above the 256 KiB default', async () => {
    const root = makeRoot()
    const chunk = Buffer.alloc(64 * 1024, 0x73)
    const shellCap = 512 * 1024
    const runPython = (chunks: number) => ({
      preopenTable: [],
      list: () => [{ program: 'python3', aliases: ['python'] }],
      has: (program: string) => program === 'python3' || program === 'python',
      async run(runRequest: { onStdout?: (chunk: Uint8Array) => void }) {
        for (let index = 0; index < chunks; index++) runRequest.onStdout?.(chunk)
        return {
          program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 1, stdoutBytes: chunk.byteLength * chunks, stderrBytes: 0,
        }
      },
    })
    // 320 KiB is under the configured cap but over the old fixed 256 KiB
    // collector: it must come through complete and untruncated.
    const under = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'python3 -c pass',
    })), { root, maxOutputBytes: shellCap, python: runPython(5) })
    assert.equal(under.execution.exit_code, 0, under.execution.stderr)
    assert.equal(under.execution.stdout_bytes, chunk.byteLength * 5)
    assert.equal(Buffer.byteLength(under.execution.stdout), chunk.byteLength * 5)
    assert.equal(under.execution.stdout_truncated, false)

    // 1 MiB exceeds the configured cap: the marker must still carry the true
    // 1 MiB total, and the shell must not report a clean exit.
    const over = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'python3 -c pass',
    })), { root, maxOutputBytes: shellCap, python: runPython(16) })
    const marker = truncationMarkerFacts(over.execution.stdout)
    assert.equal(over.execution.exit_code, 1)
    assert.equal(over.execution.stdout_truncated, true)
    assert.equal(over.execution.stdout_bytes, chunk.byteLength * 16)
    assert.ok(Buffer.byteLength(over.execution.stdout) <= shellCap)
    assert.ok(marker !== undefined)
    assert.equal(marker.total, chunk.byteLength * 16)
  })

  test('an early cancel bounds a nested python command that ignores its signal', async () => {
    const root = makeRoot()
    const controller = new AbortController()
    const chunk = Buffer.alloc(64 * 1024, 0x71)
    const started = Date.now()
    const pending = executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'python3 -c pass',
      program: 'bash',
      timeout_ms: 5_000,
    })), {
      root,
      signal: controller.signal,
      python: {
        preopenTable: [],
        list: () => [{ program: 'python3', aliases: ['python'] }],
        has: (program: string) => program === 'python3' || program === 'python',
        run(runRequest: { onStdout?: (chunk: Uint8Array) => void }) {
          for (let index = 0; index < 32; index++) runRequest.onStdout?.(chunk)
          // Deliberately ignores the abort signal.
          return new Promise(() => {})
        },
      },
    })
    const timer = setTimeout(() => controller.abort(new Error('caller cancelled')), 30)
    const receipt = await pending
    clearTimeout(timer)
    assert.ok(Date.now() - started < 2000, 'cancel must not wait for a nested toolbox')
    assert.equal(receipt.execution.cancelled, true)
    assert.equal(receipt.execution.timed_out, false)
    assert.equal(receipt.execution.exit_code, 130)
    assert.ok(Buffer.byteLength(receipt.execution.stdout)
      <= WORKER_COMMAND_MAX_OUTPUT_BYTES + 1024)
  })

  test('a 512 MiB nested python stream cannot exhaust a bounded heap', () => {
    const script = `
      import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
      import { join } from 'node:path'
      import { tmpdir } from 'node:os'
      const { executeWorkerCommandInFork, validateWorkerCommandRequest,
        markBoundedDirectoryOpener, WORKER_COMMAND_MAX_OUTPUT_BYTES } =
        await import(${JSON.stringify(new URL('../surface-phone/src/worker-command-controller.js', import.meta.url).href)})
      const { promises: fsp } = await import('node:fs')
      markBoundedDirectoryOpener(fsp.opendir)
      const root = mkdtempSync(join(tmpdir(), 'pdsh-worker-heap-'))
      for (const directory of ['dsh/workspace', 'dsh/home', 'dsh/tmp']) {
        mkdirSync(join(root, directory), { recursive: true })
      }
      const chunk = Buffer.alloc(64 * 1024, 0x72)
      const chunks = 8192 // 512 MiB, as measured by the independent review.
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest({
        command: 'python3 -c pass',
        program: 'bash',
        cwd: '/dsh/workspace',
        scenario_id: 'G2-WC-HEAP',
        session_id: 'session-heap',
        turn: 0,
        assertion_index: 0,
        timeout_ms: 30000,
      }), {
        root,
        python: {
          preopenTable: [],
          list: () => [{ program: 'python3', aliases: ['python'] }],
          has: (program) => program === 'python3' || program === 'python',
          async run(runRequest) {
            for (let index = 0; index < chunks; index++) runRequest.onStdout?.(chunk)
            return {
              program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
              memoryPeakBytes: 1, stdoutBytes: chunk.byteLength * chunks, stderrBytes: 0,
            }
          },
        },
      })
      const retained = Buffer.byteLength(receipt.execution.stdout)
      const produced = chunk.byteLength * chunks
      if (receipt.execution.stdout_truncated !== true) {
        console.error('nested stdout was not marked truncated')
        process.exit(2)
      }
      if (retained > WORKER_COMMAND_MAX_OUTPUT_BYTES) {
        console.error(\`retained \${retained} bytes\`)
        process.exit(3)
      }
      if (receipt.execution.stdout_bytes !== produced) {
        console.error(\`stdout_bytes \${receipt.execution.stdout_bytes} != \${produced}\`)
        process.exit(4)
      }
      const marker = /output truncated: (\\d+) of (\\d+) bytes elided/u.exec(receipt.execution.stdout)
      if (marker === null || Number(marker[2]) !== produced) {
        console.error(\`bad marker: \${marker?.[0]}\`)
        process.exit(5)
      }
      rmSync(root, { recursive: true, force: true })
      console.log(JSON.stringify({
        retained,
        exit: receipt.execution.exit_code,
        stdoutBytes: receipt.execution.stdout_bytes,
        markerDropped: Number(marker[1]),
        markerTotal: Number(marker[2]),
      }))
    `
    const child = spawnSync(process.execPath, [
      '--max-old-space-size=128', '--experimental-strip-types', '--input-type=module', '--eval', script,
    ], { encoding: 'utf8', timeout: 30_000 })
    assert.equal(child.status, 0,
      `bounded heap child failed (${String(child.status)}): ${child.stderr}`)
    const result = JSON.parse(child.stdout) as {
      retained: number, exit: number, stdoutBytes: number, markerDropped: number, markerTotal: number
    }
    assert.equal(result.stdoutBytes, 512 * 1024 * 1024)
    assert.equal(result.markerTotal, 512 * 1024 * 1024)
    assert.ok(result.markerDropped > 0)
    assert.equal(result.exit, 1)
    assert.ok(result.retained <= WORKER_COMMAND_MAX_OUTPUT_BYTES)
  })

  test('bash cannot resolve python3 when the image has no Python artifacts', async () => {
    const root = makeRoot()
    for (const command of ['command -v python3', 'which python3']) {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command,
      })), { root })
      assert.notEqual(receipt.execution.exit_code, 0, command)
      assert.equal(receipt.execution.stdout, '', command)
    }
  })

  test('bash resolves python3 only after the image artifacts exist locally', async () => {
    const root = makeRoot()
    mkdirSync(join(root, 'dsh/bin/python'), { recursive: true })
    writeFileSync(join(root, 'dsh/bin/python/python.wasm'), 'wasm-fixture')
    writeFileSync(join(root, 'dsh/bin/python/python313.zip'), 'stdlib-fixture')
    const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
      command: 'command -v python3',
    })), { root })
    assert.equal(receipt.execution.exit_code, 0, receipt.execution.stderr)
    assert.notEqual(receipt.execution.stdout.trim(), '')
  })

  test('the fork never falls back to the live global toolbox or writes the live VFS', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/answer.txt'), 'worker-source\n')
    const globals = globalThis as { __PDSH_WASI_TOOLBOX__?: unknown }
    const previous = globals.__PDSH_WASI_TOOLBOX__
    let liveCalls = 0
    const liveSecret = 'live-toolbox-only-secret'
    globals.__PDSH_WASI_TOOLBOX__ = {
      preopenTable: [],
      list: () => [{ program: 'python3', aliases: ['python'] }, { program: 'jq-wasi' }],
      has: () => true,
      async run(runRequest: { onStdout?: (chunk: Uint8Array) => void }) {
        liveCalls += 1
        runRequest.onStdout?.(Buffer.from(liveSecret))
        return {
          program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 0, stdoutBytes: Buffer.byteLength(liveSecret), stderrBytes: 0,
        }
      },
    }
    const writes: string[] = []
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      readdir: (path: string, options: { withFileTypes: true }) => fsp.readdir(path, options),
      readFile: (path: string) => fsp.readFile(path),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      open: (path: string, flags: string) => fsp.open(path, flags),
      writeFile: async () => { writes.push('writeFile'); throw new Error('live write refused') },
      appendFile: async () => { writes.push('appendFile'); throw new Error('live write refused') },
      mkdir: async () => { writes.push('mkdir'); throw new Error('live write refused') },
      rm: async () => { writes.push('rm'); throw new Error('live write refused') },
      rename: async () => { writes.push('rename'); throw new Error('live write refused') },
      chmod: async () => { writes.push('chmod'); throw new Error('live write refused') },
    }
    try {
      // `jq` is not just an execute-time failure: its availability probes must
      // not answer a path, or an assertion that only runs `command -v jq`
      // would pass while the program is intentionally unavailable. `allowJq`
      // must not restore the live implementation either.
      for (const command of ['jq -n 1', 'command -v jq', 'which jq', 'type jq']) {
        for (const allowJq of [false, true]) {
          const jq = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
            command,
          })), { root, fs: reader, allowJq })
          assert.notEqual(jq.execution.exit_code, 0, `${command} allowJq=${String(allowJq)}`)
          assert.equal(jq.execution.stdout, '', `${command} allowJq=${String(allowJq)}`)
          assert.equal(jq.execution.stdout.includes(liveSecret), false)
          assert.equal(jq.execution.stderr.includes(liveSecret), false)
          assert.equal(jq.model_requests, 0)
        }
      }

      const python = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        program: 'python3',
        command: 'print("live")',
      })), { root, fs: reader })
      assert.equal(python.execution.exit_code, 127)
      assert.equal(python.execution.stdout, '')
      assert.equal(python.execution.stdout.includes(liveSecret), false)

      const bash = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'cat answer.txt; printf live > /dsh/workspace/leaked.txt',
      })), { root, fs: reader })
      assert.equal(bash.execution.exit_code, 0, bash.execution.stderr)
      assert.equal(bash.execution.stdout, 'worker-source\n')
      assert.equal(bash.execution.stdout.includes(liveSecret), false)
      assert.equal(bash.model_requests, 0)
      assert.equal(existsSync(join(root, 'dsh/workspace/leaked.txt')), false)
      assert.deepEqual(writes, [])
      assert.equal(liveCalls, 0, 'the live global toolbox must not be called')
    } finally {
      if (previous === undefined) delete globals.__PDSH_WASI_TOOLBOX__
      else globals.__PDSH_WASI_TOOLBOX__ = previous
    }
  })

  test('a frozen watermark proves the live tree unchanged without a second full read', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/answer.txt'), 'worker-source\n')
    const globals = globalThis as { __PDSH_CHANNEL__?: { nextMseq(): bigint } }
    const previous = globals.__PDSH_CHANNEL__
    globals.__PDSH_CHANNEL__ = { nextMseq: () => 5n }
    const lstatPaths: string[] = []
    const reader = {
      lstat: (path: string) => { lstatPaths.push(path); return fsp.lstat(path) },
      readdir: (path: string, options: { withFileTypes: true }) => fsp.readdir(path, options),
      readFile: (path: string) => fsp.readFile(path),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      open: (path: string, flags: string) => fsp.open(path, flags),
    }
    try {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'printf ok',
      })), { root, fs: reader })
      assert.equal(receipt.source.source_frozen, true)
      assert.equal(receipt.live_workspace_unchanged, true)
      assert.equal(receipt.verification?.method, 'mseq')
      assert.equal(lstatPaths.filter(path => path === join(root, 'dsh/workspace')).length, 1)
    } finally {
      if (previous === undefined) delete globals.__PDSH_CHANNEL__
      else globals.__PDSH_CHANNEL__ = previous
    }
  })

  test('a live write during digest verification cannot claim the workspace unchanged', async () => {
    const root = makeRoot()
    const target = join(root, 'dsh/workspace/a.txt')
    writeFileSync(target, 'A')
    const state = { next: 5n }
    let targetOpens = 0
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      readdir: (path: string, options: { withFileTypes: true }) => fsp.readdir(path, options),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      open: async (path: string, flags: string) => {
        const handle = await fsp.open(path, flags)
        if (path !== target) return handle
        targetOpens += 1
        if (targetOpens !== 2) return handle
        let mutated = false
        return {
          async read(buffer: Buffer, offset: number, length: number, position: number | null) {
            const result = await handle.read(buffer, offset, length, position)
            // The first capture read the old bytes. The verify re-capture also
            // reads the old bytes, and only then the live writer replaces the
            // file, so the old digest still matches while the watermark moves.
            if (!mutated) {
              mutated = true
              writeFileSync(target, 'B')
              state.next = 7n
            }
            return result
          },
          async close() { await handle.close() },
        }
      },
    }
    await withChannel(state, async () => {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        program: 'python3',
        command: 'print("noop")',
      })), {
        root,
        fs: reader,
        python: {
          preopenTable: [],
          list: () => [{ program: 'python3', aliases: ['python'] }],
          has: (program: string) => program === 'python3' || program === 'python',
          async run() {
            // Move the watermark after the fork was frozen, forcing the
            // digest path instead of the mseq shortcut.
            state.next = 6n
            return {
              program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
              memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 0,
            }
          },
        },
      })
      assert.equal(receipt.source.source_frozen, true)
      assert.equal(receipt.verification?.method, 'digest')
      assert.equal(receipt.live_workspace_unchanged, false)
      assert.equal(receipt.verification?.failure, 'worker-command/live-workspace-changed')
    })
    assert.equal(readFileSync(target, 'utf8'), 'B')
  })

  test('the mseq shortcut requires the fork itself to be frozen', async () => {
    const root = makeRoot()
    const target = join(root, 'dsh/workspace/a.txt')
    writeFileSync(target, 'A')
    const state = { next: 5n }
    let targetOpened = false
    const reader = {
      lstat: (path: string) => fsp.lstat(path),
      readdir: (path: string, options: { withFileTypes: true }) => fsp.readdir(path, options),
      opendir: markBoundedDirectoryOpener((path: string) => fsp.opendir(path)),
      open: async (path: string, flags: string) => {
        const handle = await fsp.open(path, flags)
        if (path !== target || targetOpened) return handle
        targetOpened = true
        let mutated = false
        return {
          async read(buffer: Buffer, offset: number, length: number, position: number | null) {
            const result = await handle.read(buffer, offset, length, position)
            if (!mutated) {
              mutated = true
              // The live tree moves during the fork capture: the fork is not
              // frozen (mseq 4 -> 5) but its digest still has the old bytes.
              writeFileSync(target, 'B')
              state.next = 6n
            }
            return result
          },
          async close() { await handle.close() },
        }
      },
    }
    await withChannel(state, async () => {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        command: 'printf ok',
      })), { root, fs: reader })
      assert.equal(receipt.source.source_frozen, false)
      // The verify watermark equals fork.mseqEnd, so the old shortcut would
      // have passed without looking at the changed live bytes.
      assert.equal(receipt.verification?.method, 'digest')
      assert.equal(receipt.live_workspace_unchanged, false)
      assert.equal(receipt.verification?.failure, 'worker-command/live-workspace-changed')
    })
    assert.equal(readFileSync(target, 'utf8'), 'B')
  })

  test('a live chmod, touch or empty-directory change fails digest verification', async () => {
    const cases: Array<{
      name: string
      setup?: (root: string) => void
      mutate: (root: string, target: string) => void
    }> = [
      {
        name: 'chmod',
        mutate: (_root, target) => chmodSync(target, 0o600),
      },
      {
        name: 'touch',
        mutate: (_root, target) => utimesSync(target, 1_000_000_000, 1_000_000_000),
      },
      {
        name: 'create an empty directory',
        mutate: root => mkdirSync(join(root, 'dsh/workspace/later-empty')),
      },
      {
        name: 'delete an empty directory',
        setup: root => mkdirSync(join(root, 'dsh/workspace/removed-empty')),
        mutate: root => rmSync(join(root, 'dsh/workspace/removed-empty'), { recursive: true }),
      },
    ]
    for (const { name, setup, mutate } of cases) {
      const root = makeRoot()
      const target = join(root, 'dsh/workspace/a.txt')
      writeFileSync(target, 'A')
      setup?.(root)
      const state = { next: 5n }
      await withChannel(state, async () => {
        const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
          program: 'python3',
          command: 'print("noop")',
        })), {
          root,
          python: {
            preopenTable: [],
            list: () => [{ program: 'python3', aliases: ['python'] }],
            has: (program: string) => program === 'python3' || program === 'python',
            async run() {
              // Change the live tree without changing a file's bytes, then
              // move the watermark so the mseq shortcut cannot hide it.
              mutate(root, target)
              state.next = 6n
              return {
                program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
                memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 0,
              }
            },
          },
        })
        assert.equal(receipt.source.source_frozen, true, name)
        assert.equal(receipt.verification?.method, 'digest', name)
        assert.equal(receipt.live_workspace_unchanged, false, name)
        assert.equal(receipt.verification?.failure,
          'worker-command/live-workspace-changed', name)
      })
    }
  })

  test('a frozen digest re-capture still proves the workspace unchanged', async () => {
    const root = makeRoot()
    writeFileSync(join(root, 'dsh/workspace/a.txt'), 'A')
    const state = { next: 5n }
    await withChannel(state, async () => {
      const receipt = await executeWorkerCommandInFork(validateWorkerCommandRequest(request({
        program: 'python3',
        command: 'print("noop")',
      })), {
        root,
        python: {
          preopenTable: [],
          list: () => [{ program: 'python3', aliases: ['python'] }],
          has: (program: string) => program === 'python3' || program === 'python',
          async run() {
            // Force the digest path; no writer follows, so its capture is
            // frozen and its digest is valid evidence.
            state.next = 6n
            return {
              program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
              memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 0,
            }
          },
        },
      })
      assert.equal(receipt.source.source_frozen, true)
      assert.equal(receipt.verification?.method, 'digest')
      assert.equal(receipt.live_workspace_unchanged, true)
      assert.equal(receipt.verification?.failure, undefined)
    })
  })
})

describe('route contract', () => {
  function harness(executor: (value: unknown, options: unknown) => Promise<unknown>) {
    let handler: ((request: Request) => Promise<Response>) | undefined
    const connection = {
      fetch: {
        register(options: { path: string, methods: string[], requestBody: string,
          fetch: (request: Request) => Promise<Response> }) {
          assert.equal(options.path, WORKER_COMMAND_PATH)
          assert.deepEqual(options.methods, ['POST'])
          assert.equal(options.requestBody, 'buffered')
          handler = options.fetch
          return () => {}
        },
      },
    }
    const ctx = { effect: (run: () => unknown) => { run(); return () => {} } }
    registerWorkerCommandRoute(ctx, connection, { executor })
    return async (body: unknown): Promise<Response> => {
      assert.ok(handler)
      return await handler(new Request('http://worker.invalid' + WORKER_COMMAND_PATH, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      }))
    }
  }

  test('a valid receipt is returned with its binding intact', async () => {
    const call = harness(async value => ({
      protocol: WORKER_COMMAND_PROTOCOL,
      binding: { scenario_id: (value as { scenarioId: string }).scenarioId },
    }))
    const response = await call(request())
    assert.equal(response.status, 200)
    const body = await response.json() as { ok: boolean, value: { protocol: string } }
    assert.equal(body.ok, true)
    assert.equal(body.value.protocol, WORKER_COMMAND_PROTOCOL)
  })

  test('a missing receipt is a 500 failure, never a synthesized pass', async () => {
    const call = harness(async () => ({ protocol: 'something-else' }))
    const response = await call(request())
    assert.equal(response.status, 500)
    const body = await response.json() as { ok: boolean, error: { code: string } }
    assert.equal(body.ok, false)
    assert.equal(body.error.code, 'worker-command/missing-receipt')
  })

  test('an executor failure is a 500 failure', async () => {
    const call = harness(async () => { throw new Error('fork failed') })
    const response = await call(request())
    assert.equal(response.status, 500)
    const body = await response.json() as { ok: boolean, error: { code: string } }
    assert.equal(body.error.code, 'worker-command/failed')
  })

  test('a request without a binding is rejected before execution', async () => {
    let executed = 0
    const call = harness(async () => { executed += 1; return { protocol: WORKER_COMMAND_PROTOCOL } })
    const response = await call(request({ session_id: '' }))
    assert.equal(response.status, 400)
    assert.equal(executed, 0)
  })

  test('a non-JSON content type is rejected', async () => {
    let handler: ((request: Request) => Promise<Response>) | undefined
    const connection = { fetch: { register(options: { fetch: typeof handler }) { handler = options.fetch; return () => {} } } }
    const ctx = { effect: (run: () => unknown) => { run(); return () => {} } }
    registerWorkerCommandRoute(ctx, connection as never)
    const response = await handler!(new Request('http://worker.invalid' + WORKER_COMMAND_PATH, {
      method: 'POST',
      headers: { 'content-type': 'text/plain' },
      body: 'x',
    }))
    assert.equal(response.status, 415)
  })
})

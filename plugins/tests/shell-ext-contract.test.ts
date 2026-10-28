// SPDX-License-Identifier: MIT
// ENG-02 class-contract regression tests.
//
// Every test here failed before the class contract landed: the shell had no
// trailer/taxonomy for a failing shim, `stat -c %Q` and `find -printf %q`
// exited 1 with no reason, a cut stream still exited 0, `python` was a 127, a
// short corrupt archive listed as an empty success, `realpath -z` separated
// records with newlines and an invalid ripgrep glob was indistinguishable from
// "no matches".
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { defineCommand } from 'just-bash/browser'
import { getWorkerToolbox, setWorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import { NodeGitFs } from '@phone-dsh/dsh-wasi-toolbox/git'
import type { WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import {
  SHELL_MANIFEST_PATH,
  VfsFileSystem,
  WorkerShell,
  appendShellTrailer,
  createWorkerCommands,
  extractFailureProgram,
  hasShellTrailer,
  isWorkerShellProgram,
  parseShellTrailer,
  trailerLine,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'

interface Fixture {
  readonly shell: WorkerShell
  readonly fs: VfsFileSystem
  readonly root: string
  readonly cleanup: () => void
}

function fixture(options: {
  commands?: ReturnType<typeof createWorkerCommands>
  maxOutputBytes?: number
  maxFileSize?: number
} = {}): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-contract-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true, ...options.maxFileSize === undefined ? {} : { maxFileSize: options.maxFileSize } })
  const shell = new WorkerShell({
    fs,
    commands: options.commands ?? createWorkerCommands({ git: false, toolbox: false, curl: false }),
    ...options.maxOutputBytes === undefined ? {} : { maxOutputBytes: options.maxOutputBytes },
  })
  return { shell, fs, root, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

async function run(shell: WorkerShell, script: string, options: { maxOutputBytes?: number } = {}) {
  return await shell.run(['bash', '-c', script], { cwd: CWD, ...options })
}

test('contract: an unknown program is 127 plus the manifest hint, snapshot locked', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  const result = await run(shell, 'pdsh-definitely-not-a-program')
  assert.equal(result.exitCode, 127)
  assert.equal(result.stdout, '')
  assert.equal(
    result.stderr,
    'bash: pdsh-definitely-not-a-program: command not found\n'
      + `pdsh-shell: exit=127 program=pdsh-definitely-not-a-program reason=not-available hint=not a Worker program; the capability manifest is ${SHELL_MANIFEST_PATH}\n`,
  )
  const trailer = parseShellTrailer(result.stderr.trimEnd().split('\n').at(-1) as string)
  assert.equal(trailer?.reason, 'not-available')
  assert.equal(trailer?.hint?.includes(SHELL_MANIFEST_PATH), true)
})

test('contract: a known gap (unzip) and bare python still name the manifest', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  const unzip = await run(shell, 'unzip archive.zip')
  assert.equal(unzip.exitCode, 127)
  assert.match(unzip.stderr, /^pdsh-shell: exit=127 program=unzip reason=not-available hint=no archiver program/mu)
  assert.match(unzip.stderr, new RegExp(SHELL_MANIFEST_PATH, 'u'))
  const python = await run(shell, 'python -c 1')
  assert.equal(python.exitCode, 127)
  assert.match(python.stderr, /program=python reason=not-available/u)
  assert.match(python.stderr, /python3/u)
  assert.match(python.stderr, new RegExp(SHELL_MANIFEST_PATH, 'u'))
})

test('contract: a cut stream is non-zero and carries reason=output-truncated', async (t) => {
  const { shell, cleanup } = fixture({ maxOutputBytes: 64 })
  t.after(cleanup)
  const cut = await run(shell, 'seq 1 2000')
  assert.equal(cut.stdoutTruncated, true)
  assert.equal(cut.exitCode, 1, 'a partial page must not be reported as success')
  assert.match(cut.stderr, /^pdsh-shell: exit=1 program=bash reason=output-truncated hint=/mu)

  // A file redirect is not part of the captured output: the whole 8893 bytes
  // must reach the VFS and the command must stay 0.
  const redirected = await run(shell, 'seq 1 2000 > large.txt; wc -c < large.txt')
  assert.equal(redirected.exitCode, 0, redirected.stderr)
  assert.equal(redirected.stdout, '8893\n')
  assert.equal(redirected.stdoutTruncated, false)
})

test('contract: stat/find usage errors are exit 2 with reason=unsupported-option', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  await run(shell, 'printf "x\\n" > f.txt')
  for (const [program, script] of [
    ['stat', "stat -c '%Q' f.txt"],
    ['find', "find . -printf '%q\\n'"],
    ['tar', 'tar --bogus'],
    ['gzip', 'gzip -r f.txt'],
  ] as const) {
    const result = await run(shell, script)
    assert.equal(result.exitCode, 2, `${program}: ${result.stderr}`)
    assert.match(result.stderr, new RegExp(`^pdsh-shell: exit=2 program=${program} reason=unsupported-option`, 'mu'), program)
  }
})

test('contract: the toolbox registers python as the python3 alias', async (t) => {
  const requests: Array<{ program: string }> = []
  const toolbox = {
    list: () => [{ program: 'python3', aliases: [], description: 'test interpreter' }],
    has: (program: string) => program === 'python3',
    preopenTable: [{ guestPath: '/workspace', hostPath: CWD }],
    async run(request: { program: string; onStdout?: (bytes: Uint8Array) => void }) {
      requests.push({ program: request.program })
      request.onStdout?.(new TextEncoder().encode('alias-ok\n'))
      return {
        program: request.program,
        exitCode: 0,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: 9,
        stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
  const previous = getWorkerToolbox()
  setWorkerToolbox(toolbox)
  t.after(() => { setWorkerToolbox(previous) })
  const { shell, cleanup } = fixture({ commands: createWorkerCommands({ git: false, toolbox, curl: false }) })
  t.after(cleanup)
  assert.equal(isWorkerShellProgram('python'), true, 'a direct spawn of the alias must route to the shell table')
  const result = await run(shell, "python -c 'print(1)'")
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'alias-ok\n')
  assert.equal(requests[0]?.program, 'python3', 'the alias must dispatch the canonical program')
})

test('contract: a short corrupt archive is an error, not an empty listing', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  await run(shell, 'printf "not a tar archive" > bad.tar')
  const result = await run(shell, 'tar -tf bad.tar')
  assert.equal(result.exitCode, 2)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /^tar: This does not look like a tar archive\npdsh-shell: exit=2 program=tar reason=command-exited/mu)
})

test('contract: realpath -z separates and terminates records with NUL', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  await run(shell, 'printf "a\\n" > a.txt; printf "b\\n" > b.txt')
  const result = await run(shell, 'realpath -z a.txt b.txt')
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, `${CWD}/a.txt\0${CWD}/b.txt\0`)
})

test('contract: an invalid ripgrep glob is a usage error, not "no matches"', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  await run(shell, 'printf "alpha\\n" > a.txt')
  const result = await run(shell, "rg --glob '[' alpha .")
  assert.equal(result.exitCode, 2)
  assert.match(result.stderr, /^rg: error parsing glob '\[': unclosed character class\npdsh-shell: exit=2 program=rg reason=unsupported-option/mu)
})

test('contract: a refused 15 MiB write is reason=limit-refused', async (t) => {
  const big = defineCommand('writebig', async (_args, ctx) => {
    await ctx.fs.writeFile(ctx.fs.resolvePath(ctx.cwd, 'big.bin'), 'x'.repeat(16 * 1024 * 1024))
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  const commands = [...createWorkerCommands({ git: false, toolbox: false, curl: false }), big]
  const { shell, cleanup } = fixture({ commands, maxFileSize: 15 * 1024 * 1024 })
  t.after(cleanup)
  const result = await run(shell, 'writebig')
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /File too large/u)
  assert.match(result.stderr, /^pdsh-shell: exit=\d+ program=writebig reason=limit-refused hint=a single VFS file is limited to 15 MiB/mu)
})

test('contract: a Worker git failure carries a trailer', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-contract-git-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createWorkerCommands({ git: { fs: new NodeGitFs(root) }, toolbox: false, curl: false }),
  })
  const status = await run(shell, 'git status --porcelain')
  assert.notEqual(status.exitCode, 0)
  assert.match(status.stderr, /fatal: /u)
  assert.match(status.stderr, /^pdsh-shell: exit=\d+ program=git reason=command-exited$/mu)
})

test('contract: trailer helpers are idempotent and parseable', () => {
  const line = trailerLine({ exitCode: 7, program: '/usr/bin/x', reason: 'backend-failed', hint: 'a\nb' })
  assert.equal(line, 'pdsh-shell: exit=7 program=x reason=backend-failed hint=a b\n')
  assert.deepEqual(parseShellTrailer(line.trimEnd()), { exitCode: 7, program: 'x', reason: 'backend-failed', hint: 'a b' })
  const once = appendShellTrailer('boom\n', { exitCode: 1, program: 'gzip', reason: 'backend-failed' })
  assert.equal(hasShellTrailer(once), true)
  assert.equal(appendShellTrailer(once, { exitCode: 1, program: 'gzip', reason: 'backend-failed' }), once)
  assert.equal(extractFailureProgram('bash: line 3: unzip: command not found\n'), 'unzip')
  assert.equal(extractFailureProgram('bash: /usr/bin/unzip: No such file or directory\n'), 'unzip')
  assert.equal(extractFailureProgram('tar: Cannot open\n'), 'tar')
})

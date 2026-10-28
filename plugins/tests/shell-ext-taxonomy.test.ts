// SPDX-License-Identifier: MIT
// G2-FIX-58 regression: one owner for the failure decoration and a truthful
// reason taxonomy.
//
// Before this pack the `pdsh-shell:` trailer had no classification contract:
// `stat` on a missing path exited 1 with its own stderr and was still labelled
// `reason=backend-failed` (claiming our execution backend broke when the
// command simply exited), and the not-available hint named
// `/dsh/home/capabilities.json`, a file no Worker boot path ever created, so
// the model burned a tool call reading it (G2-A09 transcript: the 127 hint and
// the `not found` read).
//
// These tests pin the fixed contract at component level:
//   - a Worker program that runs and exits non-zero is `command-exited`;
//   - a program the Worker does not serve is `not-available` and the manifest
//     path its hint names exists in the VFS and is generated from the live
//     command registry;
//   - only a failure of our own execution layer is `backend-failed`.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import type { WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import {
  SHELL_MANIFEST_PATH,
  UNAVAILABLE_PROGRAMS,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  parseShellTrailer,
  unavailableHint,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'

interface Fixture {
  readonly shell: WorkerShell
  readonly fs: VfsFileSystem
  readonly root: string
  readonly cleanup: () => void
}

function fixture(options: { commands?: ReturnType<typeof createWorkerCommands> } = {}): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-taxonomy-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const shell = new WorkerShell({
    fs,
    commands: options.commands ?? createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { shell, fs, root, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

async function run(shell: WorkerShell, script: string) {
  return await shell.run(['bash', '-c', script], { cwd: CWD })
}

/** The one parsed trailer a failing command must end in. */
function trailerOf(stderr: string) {
  const lines = stderr.split('\n').filter(line => line.startsWith('pdsh-shell: exit='))
  assert.equal(lines.length, 1, `expected exactly one trailer in ${JSON.stringify(stderr)}`)
  const trailer = parseShellTrailer(lines[0] as string)
  assert.notEqual(trailer, undefined, `unparseable trailer ${JSON.stringify(lines[0])}`)
  return trailer as NonNullable<typeof trailer>
}

test('taxonomy: stat on a missing path is the command\'s own exit, not backend-failed', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  const result = await run(shell, "stat -c '%n %s' /dsh/workspace/missing.txt")
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdout, '')
  // The command's own diagnostic is the explanation and stays untouched.
  assert.match(result.stderr, /^stat: cannot stat '\/dsh\/workspace\/missing\.txt': No such file or directory\n/u)
  const trailer = trailerOf(result.stderr)
  assert.equal(trailer.reason, 'command-exited', result.stderr)
  assert.equal(trailer.exitCode, 1)
  assert.equal(trailer.program, 'stat')
})

test('taxonomy: another builtin\'s own non-zero exit is command-exited too', async (t) => {
  const { shell, cleanup } = fixture()
  t.after(cleanup)
  await run(shell, "printf 'plain\\n' > top.txt")
  // POSIX readlink prints nothing when the operand is not a link: the exit
  // status is the whole explanation, so only the trailer may be present.
  const readlink = await run(shell, 'readlink top.txt')
  assert.equal(readlink.exitCode, 1)
  assert.equal(readlink.stdout, '')
  assert.equal(trailerOf(readlink.stderr).reason, 'command-exited')

  const tar = await run(shell, 'tar -tf missing.tar')
  assert.notEqual(tar.exitCode, 0)
  assert.match(tar.stderr, /^tar: missing\.tar: /u)
  assert.equal(trailerOf(tar.stderr).reason, 'command-exited')

  // A codec command whose *input* is corrupt ran and explained itself; only a
  // backend that produced bad bytes may say backend-failed (gzip.ts).
  const gunzip = await run(shell, "printf 'not gzip' | gunzip")
  assert.equal(gunzip.exitCode, 1)
  assert.match(gunzip.stderr, /^gunzip: stdin: not in gzip format\n/u)
  assert.equal(trailerOf(gunzip.stderr).reason, 'command-exited')
})

test('taxonomy: an unknown program is not-available and its manifest path exists', async (t) => {
  const { shell, fs, cleanup } = fixture()
  t.after(cleanup)
  const result = await run(shell, 'pdsh-definitely-not-a-program')
  assert.equal(result.exitCode, 127)
  assert.equal(result.stdout, '')
  const trailer = trailerOf(result.stderr)
  assert.equal(trailer.reason, 'not-available')
  assert.equal(trailer.hint?.includes(SHELL_MANIFEST_PATH), true, result.stderr)

  // The advertised referent must exist in the very VFS the hint was printed
  // into, and it must be generated from the live command registry.
  const raw = await fs.readFile(SHELL_MANIFEST_PATH)
  const manifest = JSON.parse(raw) as { format?: number; programs?: string[] }
  assert.equal(manifest.format, 1)
  assert.ok(Array.isArray(manifest.programs), raw)
  for (const program of ['bash', 'stat', 'tar', 'gzip', 'find', 'awk', 'rg']) {
    assert.equal(manifest.programs?.includes(program), true, `${program} missing from ${raw}`)
  }
})

test('taxonomy: a missing script operand also names an existing manifest', async (t) => {
  const { shell, fs, cleanup } = fixture()
  t.after(cleanup)
  // This path (`bash script.sh` with no such file) answers 127 before any
  // command is dispatched, from the script-read failure branch: the manifest
  // must be materialised there too, not only by the exec path.
  const result = await shell.run(['bash', '/dsh/workspace/missing.sh'], { cwd: CWD })
  assert.equal(result.exitCode, 127)
  const trailer = trailerOf(result.stderr)
  assert.equal(trailer.reason, 'not-available')
  assert.equal(trailer.hint?.includes(SHELL_MANIFEST_PATH), true, result.stderr)
  const manifest = JSON.parse(await fs.readFile(SHELL_MANIFEST_PATH)) as { format?: number }
  assert.equal(manifest.format, 1)
})

test('taxonomy: the manifest follows the live registry, toolbox programs included', async (t) => {
  const toolbox = {
    list: () => [{ program: 'python3', aliases: ['python'], description: 'stub interpreter' }],
    has: (program: string) => program === 'python3' || program === 'python',
    preopenTable: [],
    async run(request: { program: string }) {
      return {
        program: request.program,
        exitCode: 0,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: 0,
        stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
  const { shell, fs, cleanup } = fixture({ commands: createWorkerCommands({ git: false, toolbox, curl: false }) })
  t.after(cleanup)
  await run(shell, 'pdsh-definitely-not-a-program')
  const manifest = JSON.parse(await fs.readFile(SHELL_MANIFEST_PATH)) as { programs?: string[] }
  assert.equal(manifest.programs?.includes('python3'), true, 'the toolbox program is part of the registry')
  assert.equal(manifest.programs?.includes('python'), true, 'the registered alias is part of the registry')
})

test('taxonomy: an injected execution-layer failure is the only backend-failed case', async (t) => {
  // A toolbox whose dispatch throws is our execution layer failing: the guest
  // never produced a status of its own, so this is the one class that may say
  // `backend-failed`.
  const brokenToolbox = {
    list: () => [{ program: 'python3', aliases: [], description: 'broken dispatcher' }],
    has: (program: string) => program === 'python3',
    preopenTable: [],
    async run() {
      throw new Error('WASI dispatch exploded')
    },
  } as unknown as WorkerToolbox
  const { shell, cleanup } = fixture({ commands: createWorkerCommands({ git: false, toolbox: brokenToolbox, curl: false }) })
  t.after(cleanup)

  const crashed = await run(shell, 'python3 -c 1')
  assert.equal(crashed.exitCode, 1)
  assert.match(crashed.stderr, /^python3: WASI dispatch exploded\n/u)
  assert.equal(trailerOf(crashed.stderr).reason, 'backend-failed')

  // The other failure classes of the same shell must not borrow that label.
  const missing = await run(shell, 'stat -c %n /dsh/workspace/nope')
  const unknown = await run(shell, 'pdsh-definitely-not-a-program')
  assert.equal(trailerOf(missing.stderr).reason, 'command-exited')
  assert.equal(trailerOf(unknown.stderr).reason, 'not-available')
})

test('taxonomy: a hint without a published manifest never names a path', () => {
  const hint = unavailableHint('pdsh-definitely-not-a-program', null)
  assert.equal(hint.includes(SHELL_MANIFEST_PATH), false, hint)
  const known = unavailableHint('unzip', null)
  assert.equal(known.includes(SHELL_MANIFEST_PATH), false, known)
  assert.match(known, /no archiver program in the Worker/u)
  for (const [program, withPath] of Object.entries(UNAVAILABLE_PROGRAMS)) {
    assert.equal(withPath.includes(SHELL_MANIFEST_PATH), true, program)
  }
})

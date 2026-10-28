// SPDX-License-Identifier: MIT
/**
 * G2-FIX-86 regression: `cmp` is part of the Worker command surface.
 *
 * The G2-D04 transcript (line 490) shows the defect: the idempotency check
 * `cmp -s /tmp/dsh-REPORT-first.md report/REPORT.md` ended in
 * `bash: cmp: command not found` plus the Worker's
 * `pdsh-shell: exit=127 program=cmp reason=not-available` trailer, so the model
 * fell back to `sha256sum` and spent another tool round trip. The command table
 * had no entry for `cmp` and the corpus had no vector that invoked it, so the
 * class gate could not see the hole either.
 *
 * This test drives the committed `cmp/` golden vectors — generated from the
 * host `/usr/bin/cmp` by `tools/shell-corpus/cmp-golden.mjs` — through the real
 * `WorkerShell` and the production `createWorkerCommands` table, and requires
 * the stdout, stderr and 0/1/2 status to match byte for byte. Before the fix
 * every vector ran the unregistered-program path (127 not-available); the
 * "pre-fix table shape" case below keeps that failure mode visible.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import type { CustomCommand } from 'just-bash'
import {
  CMP_USAGE,
  CmpUsageError,
  VfsFileSystem,
  WORKER_SHELL_PROGRAMS,
  WorkerShell,
  createWorkerCommands,
  isWorkerShellProgram,
  parseCmpArguments,
  workerShellIdentity,
} from '../shell-ext/src/index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const goldenFile = join(here, '..', 'tools', 'shell-corpus', 'golden', 'worker-shell.jsonl')

/** One validated golden vector (the subset this test reads). */
interface GoldenVector {
  readonly name: string
  readonly category: string
  readonly script: string
  readonly files?: Record<string, string>
  readonly directories?: readonly string[]
  readonly stdout?: string
  readonly stderr?: string
  readonly stderrIncludes?: string
  readonly stdoutMatches?: string
  readonly exitCode: number
}

/** One golden-vector run result. */
interface GoldenRun {
  readonly name: string
  readonly pass: boolean
  readonly problems: readonly { field: string; expected: unknown; actual: unknown }[]
  readonly actual: { stdout: string; stderr: string; exitCode: number }
}

// The corpus tools are plain ESM with no declaration files; load the same
// helpers the `npm test` corpus gate uses through require (see
// `sink-refusal-a09.test.ts`) so typecheck does not need a second copy.
const requireCorpus = createRequire(import.meta.url)
const { CMP_VECTOR_PREFIX, cmpVectorsFromText } = requireCorpus('../tools/shell-corpus/cmp-golden.mjs') as {
  CMP_VECTOR_PREFIX: string
  cmpVectorsFromText: (text: string) => { name: string }[]
}
const { parseGolden, runGoldenVector } = requireCorpus('../tools/shell-corpus/golden.mjs') as {
  parseGolden: (text: string) => GoldenVector[]
  runGoldenVector: (vector: GoldenVector) => Promise<GoldenRun>
}

const CWD = '/dsh/workspace'
const goldenText = readFileSync(goldenFile, 'utf8')
const allVectors = parseGolden(goldenText)
const cmpVectors = allVectors.filter(vector => vector.name.startsWith(CMP_VECTOR_PREFIX))
const declaredNames = cmpVectorsFromText(goldenText).map(vector => vector.name)

interface Fixture {
  readonly shell: WorkerShell
  readonly root: string
  dispose(): void
}

/** A production-table Worker shell over a throwaway VFS root. */
function fixture(commands?: CustomCommand[]): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-cmp-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: commands ?? createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { shell, root, dispose: () => rmSync(root, { recursive: true, force: true }) }
}

test('cmp: the production table registers it in the shadow/pre-dispatch list', async (t) => {
  assert.ok(WORKER_SHELL_PROGRAMS.includes('cmp'), 'cmp must be in WORKER_SHELL_PROGRAMS')
  assert.equal(isWorkerShellProgram('cmp'), true, 'a direct spawn(["cmp", ...]) must route through the Worker shell table')
  assert.equal(workerShellIdentity('/usr/bin/cmp'), 'cmp')
  assert.equal(workerShellIdentity('/opt/worker/bin/cmp'), 'cmp')
  assert.ok(
    createWorkerCommands({ git: false, toolbox: false, curl: false }).some(command => command.name === 'cmp'),
    'the production command table must carry the cmp command',
  )
  const { shell, dispose } = fixture()
  t.after(dispose)
  const located = await shell.run(['bash', '-c', 'p=$(command -v cmp) && test -n "$p" && test -x "$p" && echo "$p"'], { cwd: CWD })
  assert.equal(located.exitCode, 0, located.stderr)
  assert.match(located.stdout, /^\/usr\/bin\/cmp\n$/u)
})

test('cmp: the committed vector set covers the class-gate shapes', () => {
  assert.ok(cmpVectors.length >= 10, `only ${String(cmpVectors.length)} committed cmp vectors`)
  assert.deepEqual(
    cmpVectors.map(vector => vector.name),
    declaredNames,
    'every declared cmp vector must be committed in the golden file',
  )
  assert.ok(cmpVectors.some(vector => /^cmp \S+ \S+$/u.test(vector.script)), 'plain `cmp a b`')
  assert.ok(cmpVectors.some(vector => /^cmp -s /u.test(vector.script)), 'silent `cmp -s`')
  assert.ok(cmpVectors.some(vector => /^cmp -l /u.test(vector.script)), 'long `cmp -l`')
  assert.ok(cmpVectors.some(vector => vector.exitCode === 0), 'identical files')
  assert.ok(cmpVectors.some(vector => vector.exitCode === 1), 'differing files')
  assert.ok(cmpVectors.some(vector => vector.exitCode === 2), 'usage/operand errors')
})

for (const vector of cmpVectors) {
  test(`cmp: ${vector.name} matches the host-generated golden byte for byte`, async () => {
    const result = await runGoldenVector(vector)
    assert.equal(result.pass, true, JSON.stringify(result.problems, null, 2))
    // The exact comparison is the deliverable: stdout and stderr bytes plus the
    // 0/1/2 status from the host program the corpus tool ran.
    assert.equal(result.actual.stdout, vector.stdout)
    assert.equal(result.actual.stderr, vector.stderr)
    assert.equal(result.actual.exitCode, vector.exitCode)
  })
}

test('cmp: the pre-fix table shape is the 127 not-available this fix removes', async (t) => {
  const withoutCmp = createWorkerCommands({ git: false, toolbox: false, curl: false })
    .filter(command => command.name !== 'cmp')
  const { shell, dispose } = fixture(withoutCmp)
  t.after(dispose)
  const result = await shell.run(['bash', '-c', 'cmp -s notes/a.md notes/b.md'], { cwd: CWD })
  assert.equal(result.exitCode, 127)
  assert.match(result.stderr, /program=cmp reason=not-available/u)
})

test('cmp: -s keeps the host directory diagnostic and stays silent otherwise', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const seeded = await shell.run(['bash', '-c', 'mkdir -p notes/dir && printf "alpha\\n" > notes/a.md'], { cwd: CWD })
  assert.equal(seeded.exitCode, 0, seeded.stderr)
  const directory = await shell.run(['bash', '-c', 'cmp -s notes/dir notes/a.md'], { cwd: CWD })
  assert.equal(directory.exitCode, 2)
  assert.equal(directory.stdout, '')
  assert.equal(directory.stderr, 'cmp: notes/dir: Is a directory\n')
  const missing = await shell.run(['bash', '-c', 'cmp -s notes/missing.md notes/a.md'], { cwd: CWD })
  assert.deepEqual(
    { exitCode: missing.exitCode, stdout: missing.stdout, stderr: missing.stderr },
    { exitCode: 2, stdout: '', stderr: '' },
  )
})

test('cmp: option parsing is the documented surface, not a silent reinterpretation', () => {
  assert.deepEqual(parseCmpArguments(['a', 'b']), { mode: 'default', operands: ['a', 'b'] })
  assert.deepEqual(parseCmpArguments(['-s', 'a', 'b']), { mode: 'silent', operands: ['a', 'b'] })
  assert.deepEqual(parseCmpArguments(['-l', 'a', 'b']), { mode: 'long', operands: ['a', 'b'] })
  assert.deepEqual(parseCmpArguments(['--', '-l', 'b']), { mode: 'default', operands: ['-l', 'b'] })
  assert.throws(() => parseCmpArguments(['-x', 'a', 'b']), CmpUsageError)
  assert.throws(() => parseCmpArguments(['-l', '-s', 'a']), CmpUsageError)
  assert.throws(() => parseCmpArguments(['-']), CmpUsageError, 'stdin is outside the Worker cmp surface')
  assert.match(CMP_USAGE, /^usage: cmp /u)
})

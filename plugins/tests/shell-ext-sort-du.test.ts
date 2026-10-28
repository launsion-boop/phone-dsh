// SPDX-License-Identifier: MIT
/**
 * G2-FIX-106 / G2-FIX-109 regressions: `sort -z` and GNU `du -h`.
 *
 * Both assertions start from the unshadowed engine (`new Bash`), so the
 * pre-fix failure is executable evidence rather than prose:
 *
 * - just-bash 3.6.0 rejects `sort -z` with `sort: invalid option -- 'z'`;
 * - its `du -h` prints a bare byte count below 1 KiB and rejects the long
 *   `--human-readable` spelling.
 *
 * The same cases then run through the production `WorkerShell` +
 * `createWorkerCommands` table, over the same throwaway VFS, for both
 * `bash -c` and direct argv spawns.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Bash, defineCommand } from 'just-bash/browser'
import {
  DU_BLOCK_BYTES,
  VfsFileSystem,
  WORKER_SHELL_PROGRAMS,
  WorkerShell,
  allocatedBytes,
  createWorkerCommands,
  formatHuman,
  isWorkerShellProgram,
  workerShellIdentity,
} from '../shell-ext/src/index.ts'
import { disciplineEnvironment } from '../shell-ext/src/shell.ts'

const CWD = '/dsh/workspace'
const NUL = '\u0000'

interface Fixture {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly root: string
  dispose(): void
}

/** A production-table shell and its throwaway VFS root. */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-sort-du-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell, root, dispose: () => rmSync(root, { recursive: true, force: true }) }
}

/** The unshadowed just-bash shell over the same VFS (pre-fix evidence). */
function baseline(fs: VfsFileSystem): Bash {
  return new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
}

test('sort -z: the unshadowed just-bash engine rejects it (pre-fix)', async () => {
  const { fs, dispose } = fixture()
  try {
    const result = await baseline(fs).exec("printf 'b\\0a\\0' | sort -z", { cwd: CWD })
    assert.notEqual(result.exitCode, 0, 'the bundled sort must fail on -z before the fix')
    assert.match(result.stderr, /sort: invalid option -- 'z'/u)
  } finally {
    dispose()
  }
})

test('du -h: the unshadowed engine prints bare bytes and rejects --human-readable (pre-fix)', async () => {
  const { fs, root, dispose } = fixture()
  try {
    await fs.writeFile(`${CWD}/f5`, 'AAAAA')
    const bash = baseline(fs)
    const short = await bash.exec('du -h f5', { cwd: CWD })
    assert.equal(short.stdout, '5\tf5\n', 'the bundled -h prints the apparent byte count below 1 KiB')
    const long = await bash.exec('du --human-readable f5', { cwd: CWD })
    assert.notEqual(long.exitCode, 0, 'the bundled parser must reject the long spelling')
    assert.match(long.stderr, /du: unrecognized option '--human-readable'/u)
    assert.equal(allocatedBytes(5), DU_BLOCK_BYTES)
    assert.equal(formatHuman(allocatedBytes(5)), '4.0K')
    assert.equal(formatHuman(1536), '1.5K')
    void root
  } finally {
    dispose()
  }
})

test('sort/du: a caller-supplied command still wins over the Worker default', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-sort-du-wins-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const custom = defineCommand('sort', async () => ({ stdout: 'caller-sort\n', stderr: '', exitCode: 0 }))
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: [custom],
  })
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const result = await shell.run(['bash', '-c', 'sort -z f'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'caller-sort\n')
})

test('sort/du: the production table registers both Worker programs', async (t) => {
  assert.ok(WORKER_SHELL_PROGRAMS.includes('sort'))
  assert.ok(WORKER_SHELL_PROGRAMS.includes('du'))
  assert.equal(isWorkerShellProgram('sort'), true)
  assert.equal(isWorkerShellProgram('du'), true)
  assert.equal(workerShellIdentity('/usr/bin/sort'), 'sort')
  assert.equal(workerShellIdentity('/usr/bin/du'), 'du')
  const { shell, dispose } = fixture()
  t.after(dispose)
  const located = await shell.run(['bash', '-c', 'command -v sort && command -v du'], { cwd: CWD })
  assert.equal(located.exitCode, 0, located.stderr)
  assert.match(located.stdout, /^\/usr\/bin\/sort\n\/usr\/bin\/du\n$/u)
})

test('sort -z: bash -c sorts NUL records and terminates every record with NUL', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const result = await shell.run(['bash', '-c', "printf 'b\\0a\\0' | sort -z"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, `a${NUL}b${NUL}`)
})

test('sort -z: direct argv spawn reaches the same NUL record sort', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const result = await shell.run(['sort', '-z'], { cwd: CWD, stdin: `b${NUL}a${NUL}` })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, `a${NUL}b${NUL}`)
})

test('sort -z: -u, -r, combined -rz and -- are the GNU record semantics', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const unique = await shell.run(['bash', '-c', "printf 'b\\0a\\0b\\0' | sort -z -u"], { cwd: CWD })
  assert.equal(unique.stdout, `a${NUL}b${NUL}`)
  const reverse = await shell.run(['bash', '-c', "printf 'a\\0b\\0' | sort -z -r"], { cwd: CWD })
  assert.equal(reverse.stdout, `b${NUL}a${NUL}`)
  const combined = await shell.run(['bash', '-c', "printf 'a\\0b\\0' | sort -rz"], { cwd: CWD })
  assert.equal(combined.stdout, `b${NUL}a${NUL}`)
  await shell.run(['bash', '-c', "printf 'b\\0a\\0' > r.bin"], { cwd: CWD })
  const file = await shell.run(['bash', '-c', 'sort -z -- r.bin'], { cwd: CWD })
  assert.equal(file.exitCode, 0, file.stderr)
  assert.equal(file.stdout, `a${NUL}b${NUL}`)
})

test('sort -z: each file is its own record stream; a read error suppresses output', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  // f1 has no trailing NUL; f2 starts with `a\0`. GNU does not join the last
  // record of f1 to the first record of f2, so the records are `b` and `a`.
  await fs.writeFile(`${CWD}/f1s`, 'b')
  await fs.writeFile(`${CWD}/f2s`, `a${NUL}`)
  const files = await shell.run(['bash', '-c', 'sort -z f1s f2s'], { cwd: CWD })
  assert.equal(files.exitCode, 0, files.stderr)
  assert.equal(files.stdout, `a${NUL}b${NUL}`)
  const direct = await shell.run(['sort', '-z', 'f1s', 'f2s'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(direct.stdout, `a${NUL}b${NUL}`)
  // A missing source makes GNU exit 2 with no output at all, even when the
  // other files were readable; it must not emit a partial sort.
  const missing = await shell.run(['bash', '-c', 'sort -z f1s missing.bin f2s'], { cwd: CWD })
  assert.equal(missing.exitCode, 2)
  assert.equal(missing.stdout, '')
  assert.equal(missing.stderr, 'sort: cannot read: missing.bin: No such file or directory\n')
  // Nor may it create/truncate the -o destination.
  await fs.writeFile(`${CWD}/keep.bin`, 'keep')
  const output = await shell.run(['bash', '-c', 'sort -z f1s missing.bin f2s -o keep.bin'], { cwd: CWD })
  assert.equal(output.exitCode, 2)
  assert.equal(output.stdout, '')
  assert.equal(Buffer.from(await fs.readFileBuffer(`${CWD}/keep.bin`)).toString(), 'keep')
})

test('sort -z -u: keys, not raw bytes, decide duplicates and input order wins', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await fs.writeFile(`${CWD}/numeric.bin`, `01${NUL}1${NUL}`)
  const numeric = await shell.run(['bash', '-c', 'sort -z -n -u numeric.bin'], { cwd: CWD })
  assert.equal(numeric.exitCode, 0, numeric.stderr)
  assert.equal(numeric.stdout, `01${NUL}`)
  await fs.writeFile(`${CWD}/fold.bin`, `a${NUL}A${NUL}`)
  const fold = await shell.run(['bash', '-c', 'sort -z -f -u fold.bin'], { cwd: CWD })
  assert.equal(fold.exitCode, 0, fold.stderr)
  assert.equal(fold.stdout, `a${NUL}`)
  await fs.writeFile(`${CWD}/blank.bin`, `a${NUL}  a${NUL}`)
  const blank = await shell.run(['bash', '-c', 'sort -z -b -u blank.bin'], { cwd: CWD })
  assert.equal(blank.exitCode, 0, blank.stderr)
  assert.equal(blank.stdout, `a${NUL}`)
  // Without -u the last-resort whole-line comparison still orders the same
  // records deterministically (GNU's non-unique behaviour).
  const ordered = await shell.run(['bash', '-c', 'sort -z -f fold.bin'], { cwd: CWD })
  assert.equal(ordered.exitCode, 0, ordered.stderr)
  assert.equal(ordered.stdout, `A${NUL}a${NUL}`)
})

test('sort -z: -o writes NUL records to the output file', async (t) => {
  const { shell, root, dispose } = fixture()
  t.after(dispose)
  const result = await shell.run(['bash', '-c', "printf 'b\\0a\\0' | sort -z -o out.bin"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '')
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const bytes = await fs.readFileBuffer(`${CWD}/out.bin`)
  assert.equal(Buffer.from(bytes).toString('latin1'), `a${NUL}b${NUL}`)
})

test('sort -z: a missing file is a GNU-shaped exit 2 and -k is refused, not mis-sorted', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const missing = await shell.run(['bash', '-c', 'sort -z missing.bin'], { cwd: CWD })
  assert.equal(missing.exitCode, 2)
  assert.match(missing.stderr, /sort: cannot read: missing\.bin: No such file or directory/u)
  const key = await shell.run(['bash', '-c', "printf 'b\\0a\\0' | sort -z -k1"], { cwd: CWD })
  assert.equal(key.exitCode, 2)
  assert.match(key.stderr, /sort: option -k\/--key is not implemented together with -z/u)
})

test('sort without -z: the bundled option surface is delegated unchanged', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const result = await shell.run(['bash', '-c', "printf 'b\\na\\n' | sort -r"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'b\na\n')
})

test('sort -z: find -print0 | sort -z | xargs -0 round-trips NUL names', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  await shell.run(['bash', '-c', 'printf x > f'], { cwd: CWD })
  const result = await shell.run(['bash', '-c', 'find . -type f -print0 | sort -z | xargs -0'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, './f\n')
})

test('du: allocation blocks are 4 KiB units, empty files are zero', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  await shell.run(['bash', '-c', "printf 'AAAAA' > f5; : > f0"], { cwd: CWD })
  const five = await shell.run(['bash', '-c', 'du f5'], { cwd: CWD })
  assert.equal(five.stdout, '4\tf5\n')
  const empty = await shell.run(['bash', '-c', 'du f0'], { cwd: CWD })
  assert.equal(empty.stdout, '0\tf0\n')
  const human = await shell.run(['bash', '-c', 'du -h f5'], { cwd: CWD })
  assert.equal(human.stdout, '4.0K\tf5\n')
})

test('du: 1500 bytes is one allocation block and --human-readable is accepted', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  await shell.run(['bash', '-c', 'seq 1 100000 > s1; head -c 1500 s1 > f1500'], { cwd: CWD })
  const short = await shell.run(['bash', '-c', 'du -h f1500'], { cwd: CWD })
  assert.equal(short.stdout, '4.0K\tf1500\n')
  const long = await shell.run(['bash', '-c', 'du --human-readable f1500'], { cwd: CWD })
  assert.equal(long.exitCode, 0, long.stderr)
  assert.equal(long.stdout, '4.0K\tf1500\n')
})

test('du: a 1 MiB file is 1.0M and -sh sums only file blocks', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  await shell.run(['bash', '-c', 'seq 1 100000 > s1; cat s1 s1 > s2; head -c 1048576 s2 > big; rm s1 s2'], { cwd: CWD })
  const big = await shell.run(['bash', '-c', 'du -h big'], { cwd: CWD })
  assert.equal(big.stdout, '1.0M\tbig\n')
  const summary = await shell.run(['bash', '-c', 'du -sh .'], { cwd: CWD })
  assert.equal(summary.stdout, '1.0M\t.\n')
})

test('du: -a, -c, --max-depth and -- are supported', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  await shell.run(['bash', '-c', 'mkdir -p d; printf z > d/z; printf y > d/y; printf x > f'], { cwd: CWD })
  const all = await shell.run(['bash', '-c', 'du -a d'], { cwd: CWD })
  assert.equal(all.exitCode, 0, all.stderr)
  assert.deepEqual(all.stdout.trimEnd().split('\n').sort(), ['4\td/y', '4\td/z', '8\td'])
  const total = await shell.run(['bash', '-c', 'du -c f f'], { cwd: CWD })
  assert.equal(total.stdout, '4\tf\n4\tf\n8\ttotal\n')
  const depth = await shell.run(['bash', '-c', 'du --max-depth=0 d'], { cwd: CWD })
  assert.equal(depth.stdout, '8\td\n')
  const terminator = await shell.run(['bash', '-c', 'du -- f'], { cwd: CWD })
  assert.equal(terminator.stdout, '4\tf\n')
})

test('du: a missing operand is GNU-shaped exit 1; direct argv spawn works', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  const missing = await shell.run(['bash', '-c', 'du -h missing'], { cwd: CWD })
  assert.equal(missing.exitCode, 1)
  assert.equal(missing.stdout, '')
  assert.equal(missing.stderr, "du: cannot access 'missing': No such file or directory\n")
  await shell.run(['bash', '-c', "printf 'AAAAA' > f5"], { cwd: CWD })
  const direct = await shell.run(['du', '-h', 'f5'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(direct.stdout, '4.0K\tf5\n')
})

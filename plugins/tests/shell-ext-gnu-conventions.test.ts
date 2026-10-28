// SPDX-License-Identifier: MIT
/**
 * G2-FIX-108 / G2-FIX-90 regressions: one owner for GNU `--`, `--version`
 * and `--help`.
 *
 * The baseline is the unshadowed just-bash 3.6.0 engine, where
 * `sha256sum -- f` and `sha256sum --version` are `unrecognized option`
 * failures while `mv --`/`rm --` already work. The production table
 * (`WorkerShell` + `createWorkerCommands`) then runs both a `bash -c` script
 * and a direct argv spawn through the same `applyGnuConventions` wrapper.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Bash } from 'just-bash/browser'
import {
  GNU_CONVENTION_PROGRAMS,
  VfsFileSystem,
  WorkerShell,
  applyGnuConventions,
  applyGnuTerminator,
  createWorkerCommands,
  isGnuConventionWrapper,
  isWorkerShellProgram,
  scanGnuArgv,
} from '../shell-ext/src/index.ts'
import { disciplineEnvironment } from '../shell-ext/src/shell.ts'

const CWD = '/dsh/workspace'
const FILE_TEXT = 'x\n'
const FILE_SHA = createHash('sha256').update(FILE_TEXT).digest('hex')

interface Fixture {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly root: string
  readonly commands: ReturnType<typeof createWorkerCommands>
  dispose(): void
}

/** A production-table shell, a baseline VFS and a few fixture files. */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-gnu-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const commands = createWorkerCommands({ git: false, toolbox: false, curl: false })
  const shell = new WorkerShell({ fs, commands })
  return { fs, shell, root, commands, dispose: () => rmSync(root, { recursive: true, force: true }) }
}

/** The unshadowed just-bash shell over the same VFS. */
function baseline(fs: VfsFileSystem): Bash {
  return new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
}

/** Write the fixture files every terminator case shares. */
async function seed(fs: VfsFileSystem): Promise<void> {
  await fs.writeFile(`${CWD}/f`, FILE_TEXT)
  await fs.writeFile(`${CWD}/g`, 'y\n')
  await fs.writeFile(`${CWD}/-file`, FILE_TEXT)
  await fs.writeFile(`${CWD}/j.json`, '{"a":1}\n')
}

test('GNU --: the unshadowed engine rejects sha256sum -- before the fix', async () => {
  const { fs, dispose } = fixture()
  try {
    await seed(fs)
    const bash = baseline(fs)
    const terminator = await bash.exec('sha256sum -- f', { cwd: CWD })
    assert.notEqual(terminator.exitCode, 0)
    assert.match(terminator.stderr, /sha256sum: unrecognized option '--'/u)
    const version = await bash.exec('sha256sum --version', { cwd: CWD })
    assert.notEqual(version.exitCode, 0)
    assert.match(version.stderr, /sha256sum: unrecognized option '--version'/u)
  } finally {
    dispose()
  }
})

test('GNU conventions: the production table wraps every registry program once', async (t) => {
  const { commands, dispose } = fixture()
  t.after(dispose)
  const names = new Set(commands.map(command => command.name))
  for (const program of GNU_CONVENTION_PROGRAMS) {
    assert.ok(names.has(program), `${program} must be in the production table`)
    assert.equal(isWorkerShellProgram(program), true, `${program} must route a direct spawn`)
    const wrapped = commands.filter(command => command.name === program)
    assert.equal(wrapped.length, 1, `${program} must be registered exactly once`)
    assert.equal(isGnuConventionWrapper(wrapped[0] as never), true)
  }
  // `applyGnuConventions` is idempotent even when both composition layers run.
  const once = applyGnuConventions(commands)
  const twice = applyGnuConventions(once)
  assert.equal(twice.length, once.length)
  assert.deepEqual(twice.map(command => command.name), once.map(command => command.name))
  // A bare table still gets the Worker-owned sort/du shadows, not a wrapper
  // that would send `-z` back to the bundled parser.
  const bare = applyGnuConventions([])
  for (const worker of ['sort', 'du']) {
    const entry = bare.find(command => command.name === worker)
    assert.ok(entry !== undefined)
    assert.equal(isGnuConventionWrapper(entry), true)
  }
})

test('GNU --: e2e/terminator shapes work for the listed programs', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  const cases: readonly (readonly [string, string])[] = [
    ['sha256sum -- f', `${FILE_SHA}  f\n`],
    ['head -- f', FILE_TEXT],
    ['tail -- f', FILE_TEXT],
    ['cut -c1 -- f', FILE_TEXT],
    ['sed -n 1p -- f', FILE_TEXT],
    ['find . -name f --', './f\n'],
    ['comm -- f f', `\t\t${FILE_TEXT}`],
    // The Worker `od` shim (od.ts) owns the formatted bytes; `--` still ends
    // the options before the operand.
    ['od -- f', '0000000 170 012\n0000002\n'],
    ['jq . -- j.json', '{\n  "a": 1\n}\n'],
  ]
  for (const [script, expected] of cases) {
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, expected, script)
  }
  const chmod = await shell.run(['bash', '-c', 'chmod 644 -- f'], { cwd: CWD })
  assert.equal(chmod.exitCode, 0, chmod.stderr)
  const date = await shell.run(['bash', '-c', 'date --'], { cwd: CWD })
  assert.equal(date.exitCode, 0, date.stderr)
  assert.match(date.stdout, /^[A-Z][a-z]{2} [A-Z][a-z]{2} /u)
  const xargs = await shell.run(['bash', '-c', 'xargs -- echo'], { cwd: CWD, stdin: 'a b\n' })
  assert.equal(xargs.exitCode, 0, xargs.stderr)
  assert.equal(xargs.stdout, 'a b\n')
  // After `--` the next word is never an option again: `-u` is an invalid
  // date operand and `-n` is an (unrunnable) command name.
  const invalidDate = await shell.run(['bash', '-c', 'date -- -u'], { cwd: CWD })
  assert.equal(invalidDate.exitCode, 1)
  assert.equal(invalidDate.stderr, "date: invalid date '-u'\n")
  const invalidCommand = await shell.run(['bash', '-c', 'xargs -- -n'], { cwd: CWD, stdin: 'a\n' })
  assert.notEqual(invalidCommand.exitCode, 0)
  assert.doesNotMatch(invalidCommand.stderr, /invalid option/u)
})

test('GNU --: direct argv spawn uses the same table', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  const head = await shell.run(['head', '--', 'f'], { cwd: CWD })
  assert.equal(head.exitCode, 0, head.stderr)
  assert.equal(head.stdout, FILE_TEXT)
  const digest = await shell.run(['sha256sum', '--version'], { cwd: CWD })
  assert.equal(digest.stdout, 'sha256sum (just-bash) 3.6.0\n')
  const xargs = await shell.run(['xargs', '--', 'echo'], { cwd: CWD, stdin: 'a b\n' })
  assert.equal(xargs.stdout, 'a b\n')
})

test('GNU --: a file operand beginning with - is not read as an option', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  const head = await shell.run(['bash', '-c', 'head -- -file'], { cwd: CWD })
  assert.equal(head.exitCode, 0, head.stderr)
  assert.equal(head.stdout, FILE_TEXT)
  const sed = await shell.run(['bash', '-c', 'sed -n 1p -- -file'], { cwd: CWD })
  assert.equal(sed.exitCode, 0, sed.stderr)
  assert.equal(sed.stdout, FILE_TEXT)
  await fs.writeFile(`${CWD}/-json`, '{"a":1}\n')
  const jq = await shell.run(['bash', '-c', 'jq -- . -json'], { cwd: CWD })
  assert.equal(jq.exitCode, 0, jq.stderr)
  assert.equal(jq.stdout, '{\n  "a": 1\n}\n')
  const sum = await shell.run(['bash', '-c', 'sha256sum -- -file'], { cwd: CWD })
  assert.equal(sum.exitCode, 0, sum.stderr)
  // The displayed operand is the rewritten `./-file` (the bytes are of the
  // same file); GNU's own spelling stays unrewritten only when the bundled
  // parser already supports `--`, which this one does not.
  assert.equal(sum.stdout, `${FILE_SHA}  ./-file\n`)
  void jq
})

test('GNU --: sed/jq/chmod treat only operands after the script/filter/mode', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  // `--` before the sed script: the first post-terminator word stays the script.
  const sed = await shell.run(['bash', '-c', 'sed -- s/x/y/ f'], { cwd: CWD })
  assert.equal(sed.exitCode, 0, sed.stderr)
  assert.equal(sed.stdout, 'y\n')
  // An option-shaped script after `--` is still a script, so GNU rejects it.
  // The bundled parser would otherwise read `-n` as an option and silently
  // treat `1p` as the script (exit 0, wrong meaning).
  const sedScript = await shell.run(['bash', '-c', 'sed -- -n 1p f'], { cwd: CWD })
  assert.equal(sedScript.exitCode, 1)
  assert.equal(sedScript.stdout, '')
  assert.equal(sedScript.stderr, "sed: -e expression #1, char 1: unknown command: `-'\n")
  // `--` before the jq filter: the first post-terminator word stays the filter.
  const jq = await shell.run(['bash', '-c', 'jq -- . j.json'], { cwd: CWD })
  assert.equal(jq.exitCode, 0, jq.stderr)
  assert.equal(jq.stdout, '{\n  "a": 1\n}\n')
  // An option-shaped filter cannot be forced through the bundled parser; fail
  // explicitly instead of re-reading it as `-1`/`--` options.
  const jqFilter = await shell.run(['bash', '-c', 'jq -- -1'], { cwd: CWD })
  assert.equal(jqFilter.exitCode, 2)
  assert.equal(jqFilter.stdout, '')
  assert.match(jqFilter.stderr, /^jq: option-shaped filter cannot follow '--': -1\n$/u)
  // chmod keeps the mode and rewrites only the file operand.
  const chmod = await shell.run(['bash', '-c', 'chmod -- 644 -file'], { cwd: CWD })
  assert.equal(chmod.exitCode, 0, chmod.stderr)
})

test('GNU --: an option value that is literally -- is not a terminator', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  // GNU `find . -name --` searches for a file literally named `--`.
  await fs.writeFile(`${CWD}/--`, '')
  const found = await shell.run(['bash', '-c', 'find . -name --'], { cwd: CWD })
  assert.equal(found.exitCode, 0, found.stderr)
  assert.equal(found.stdout, './--\n')
  // GNU `sort -o -- f` writes the sorted f into the file named `--`; f must
  // not be truncated by treating f as the output operand.
  await fs.writeFile(`${CWD}/--`, 'old\n')
  const sorted = await shell.run(['bash', '-c', 'sort -o -- f'], { cwd: CWD })
  assert.equal(sorted.exitCode, 0, sorted.stderr)
  assert.equal(sorted.stdout, '')
  assert.equal(Buffer.from(await fs.readFileBuffer(`${CWD}/f`)).toString(), FILE_TEXT)
  assert.equal(Buffer.from(await fs.readFileBuffer(`${CWD}/--`)).toString(), FILE_TEXT)
  // The same rule for a short option whose value is `--`: head reads it as a
  // line count and fails, rather than losing the terminator.
  const head = await shell.run(['bash', '-c', 'head -n -- f'], { cwd: CWD })
  assert.notEqual(head.exitCode, 0)
  assert.equal(head.stdout, '')
  assert.match(head.stderr, /head: invalid number of lines/u)
  // Direct scan coverage for the value-arity table.
  assert.equal(scanGnuArgv('find', ['.', '-name', '--']).terminator, -1)
  assert.equal(scanGnuArgv('sort', ['-o', '--', 'f']).terminator, -1)
  assert.equal(scanGnuArgv('head', ['-n', '--', 'f']).terminator, -1)
  assert.equal(scanGnuArgv('head', ['-n5', '--', 'f']).terminator, 1)
  assert.equal(scanGnuArgv('find', ['.', '-name', 'f', '--']).terminator, 3)
})

test('GNU --version: every wrapped program prints one line and exits 0', async (t) => {
  const { shell, dispose } = fixture()
  t.after(dispose)
  for (const program of ['sha256sum', 'head', 'tail', 'cut', 'sed', 'find', 'chmod', 'jq', 'date', 'comm', 'xargs', 'od', 'sort', 'du']) {
    const result = await shell.run(['bash', '-c', `${program} --version`], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${program}: ${result.stderr}`)
    assert.equal(result.stdout, `${program} (just-bash) 3.6.0\n`, program)
  }
})

test('GNU --version: jq delegates to the bound engine instead of the shim banner', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-gnu-jq-version-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  try {
    const identity = 'jq-1.6 (pdsh-jaq-wasm; jaq-core test identity)\n'
    let dispatches = 0
    const toolbox = {
      list: () => [{ program: 'jq-wasi', aliases: ['jaq'] }],
      has: (program: string) => program === 'jq-wasi',
      preopenTable: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
      run: async (request: {
        readonly argv?: readonly string[]
        readonly onStdout?: (chunk: Uint8Array) => void
      }) => {
        dispatches += 1
        if (request.argv?.includes('--version') !== true) throw new Error('the version probe must reach the engine')
        const chunk = new TextEncoder().encode(identity)
        request.onStdout?.(chunk)
        return {
          program: 'jq-wasi', exitCode: 0, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 0, stdoutBytes: chunk.byteLength, stderrBytes: 0,
        }
      },
    }
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox: toolbox as never }),
    })
    const throughJq = await shell.run(['bash', '-c', 'jq --version'], { cwd: CWD })
    assert.equal(throughJq.exitCode, 0, throughJq.stderr)
    assert.equal(throughJq.stdout, identity)
    assert.equal(dispatches, 1, 'the GNU wrapper must delegate, not print its own line')
    const throughDirect = await shell.run(['bash', '-c', 'jq-wasi --version'], { cwd: CWD })
    assert.equal(throughDirect.exitCode, 0, throughDirect.stderr)
    assert.equal(throughDirect.stdout, identity)
    assert.equal(dispatches, 2)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('GNU --version: jq delegates from a cwd outside every preopen', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-gnu-jq-version-cwd-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  try {
    const identity = 'jq-1.6 (pdsh-jaq-wasm; jaq-core cwd fallback)\n'
    const requests: { readonly argv: readonly string[]; readonly cwd?: string; readonly stdin?: Uint8Array }[] = []
    const toolbox = {
      list: () => [{ program: 'jq-wasi', aliases: ['jaq'] }],
      has: (program: string) => program === 'jq-wasi',
      // The shell cwd `/` and `/dsh` are legal but outside this preopen table.
      preopenTable: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
      run: async (request: {
        readonly argv?: readonly string[]
        readonly cwd?: string
        readonly stdin?: Uint8Array
        readonly onStdout?: (chunk: Uint8Array) => void
      }) => {
        requests.push({
          argv: request.argv ?? [],
          ...request.cwd === undefined ? {} : { cwd: request.cwd },
          ...request.stdin === undefined ? {} : { stdin: request.stdin },
        })
        const chunk = new TextEncoder().encode(identity)
        request.onStdout?.(chunk)
        return {
          program: 'jq-wasi', exitCode: 0, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 0, stdoutBytes: chunk.byteLength, stderrBytes: 0,
        }
      },
    }
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox: toolbox as never }),
    })
    // The defect: runJqEngine rejected the unmapped cwd before the `--version`
    // probe reached the engine, so a legal `cd /` turned into exit 1 with the
    // mapping diagnostic instead of the real engine identity.
    const fromRoot = await shell.run(['bash', '-c', 'cd / && jq --version'], { cwd: CWD })
    assert.equal(fromRoot.exitCode, 0, fromRoot.stderr)
    assert.equal(fromRoot.stdout, identity)
    assert.equal(fromRoot.stderr, '')
    // cwd `/dsh` is legal but is not itself covered by `/dsh/workspace`.
    const fromDsh = await shell.run(['bash', '-c', 'jq --version'], { cwd: '/dsh' })
    assert.equal(fromDsh.exitCode, 0, fromDsh.stderr)
    assert.equal(fromDsh.stdout, identity)
    assert.equal(fromDsh.stderr, '')
    assert.equal(requests.length, 2)
    // The probe gets a real preopen instead of the unmappable shell cwd, and
    // it never passes stdin (it cannot read a file or block on a pipeline).
    for (const request of requests) {
      assert.deepEqual(request.argv, ['--version'])
      assert.equal(request.cwd, CWD)
      assert.equal(request.stdin, undefined)
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('GNU --help: native help is preserved, a refusal/empty success becomes usage', async (t) => {
  const { fs, shell, dispose } = fixture()
  t.after(dispose)
  await seed(fs)
  // `head --help` already succeeds non-empty: the wrapper must keep its bytes.
  const baselineHelp = await baseline(fs).exec('head --help', { cwd: CWD })
  assert.equal(baselineHelp.exitCode, 0)
  assert.notEqual(baselineHelp.stdout, '')
  const headHelp = await shell.run(['bash', '-c', 'head --help'], { cwd: CWD })
  assert.equal(headHelp.exitCode, 0, headHelp.stderr)
  assert.equal(headHelp.stdout, baselineHelp.stdout)
  // `od --help` is an empty success in the bundled program: never silently lie.
  const odHelp = await shell.run(['bash', '-c', 'od --help'], { cwd: CWD })
  assert.equal(odHelp.exitCode, 0, odHelp.stderr)
  assert.notEqual(odHelp.stdout, '')
  assert.match(odHelp.stdout, /^usage: od /u)
  // `rm --help` is refused by the bundled parser: the wrapper owns the usage.
  const rmHelp = await shell.run(['bash', '-c', 'rm --help'], { cwd: CWD })
  assert.equal(rmHelp.exitCode, 0, rmHelp.stderr)
  assert.equal(rmHelp.stdout, 'usage: rm [OPTION]... [FILE]...\n')
})

test('GNU conventions: echo/printf keep their literal --version output', async (t) => {
  const { shell, commands, dispose } = fixture()
  t.after(dispose)
  assert.equal(commands.some(command => command.name === 'echo'), false)
  assert.equal(commands.some(command => command.name === 'printf'), false)
  const echo = await shell.run(['bash', '-c', 'echo --version'], { cwd: CWD })
  assert.equal(echo.stdout, '--version\n')
  const printf = await shell.run(['bash', '-c', 'printf --version'], { cwd: CWD })
  assert.equal(printf.stdout, '--version')
})

test('GNU --: applyGnuTerminator rewrites only file operands', () => {
  assert.deepEqual(applyGnuTerminator('head', ['-n', '1'], ['-file']), ['-n', '1', './-file'])
  assert.deepEqual(applyGnuTerminator('head', [], ['-']), ['-'])
  assert.deepEqual(applyGnuTerminator('find', ['.'], ['-name', 'f']), ['.', '-name', 'f'])
  assert.deepEqual(applyGnuTerminator('xargs', [], ['echo']), ['echo'])
  assert.deepEqual(applyGnuTerminator('xargs', [], ['-n', '2']), ['./-n', '2'])
  assert.deepEqual(applyGnuTerminator('date', [], ['+%Y']), ['+%Y'])
  assert.deepEqual(applyGnuTerminator('sed', ['-n', '1p'], ['-file']), ['-n', '1p', './-file'])
  assert.deepEqual(applyGnuTerminator('sed', [], ['1p', '-file']), ['1p', './-file'])
  assert.deepEqual(applyGnuTerminator('chmod', ['644'], ['-file']), ['644', './-file'])
  assert.deepEqual(applyGnuTerminator('chmod', [], ['644', '-file']), ['644', './-file'])
  assert.deepEqual(applyGnuTerminator('jq', ['.'], ['-file']), ['.', './-file'])
})

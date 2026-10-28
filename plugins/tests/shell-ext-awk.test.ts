// SPDX-License-Identifier: MIT
// G2-FIX-25: just-bash's `awk` rejects `-f PROGRAM-FILE` (`invalid option --
// 'f'`) and the GNU compatibility switches, so a model that wrote `trim.awk`
// could not run it. The command surface (program files, -F/-v, --version) is
// covered here; the language and `gsub` stay in the built-in.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  AwkUsageError,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  parseAwkArguments,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker shell with an awk program file and a data file. */
async function fixture(): Promise<{ fs: VfsFileSystem; shell: WorkerShell }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-awk-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace', { recursive: true })
  await fs.writeFile('/dsh/workspace/t.txt', 'one:1  two:2\n  padded  \n')
  await fs.writeFile('/dsh/workspace/trim.awk', '{gsub(/^ +| +$/,"",$0); print "[" $0 "]"; print "[" $2 "]"}\n')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell }
}

test('awk: parse reads -f, -F, -v and compatibility switches', () => {
  assert.deepEqual(parseAwkArguments(['-F:', '-v', 'x=1', '-f', 'a.awk', 't.txt']), {
    fieldSeparator: ':',
    assignments: ['x=1'],
    programFiles: ['a.awk'],
    programText: undefined,
    operands: ['t.txt'],
    version: false,
    help: false,
  })
  const inline = parseAwkArguments(['--posix', '{print $1}', 't.txt'])
  assert.equal(inline.programText, '{print $1}')
  assert.deepEqual(inline.operands, ['t.txt'])
  assert.equal(parseAwkArguments(['-V']).version, true)
  assert.throws(() => parseAwkArguments(['-Q']), (error: unknown) => error instanceof AwkUsageError)
  assert.throws(() => parseAwkArguments(['--bogus']), /unrecognized option/u)
})

test('awk: -f runs the program file and gsub trims the record', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'awk -f trim.awk t.txt'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '[one:1  two:2]\n[two:2]\n[padded]\n[]\n')
  assert.equal(result.stderr, '')
})

test('awk: -F and -v reach the built-in through the wrapper', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "awk -F: -v prefix='[' '{print prefix $1 \"]\"}' t.txt"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '[one]\n[  padded  ]\n')
})

test('awk: a missing program file fails loud with status 2', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'awk -f absent.awk t.txt'], { cwd: CWD })
  assert.equal(result.exitCode, 2)
  assert.match(result.stderr, /cannot open program file 'absent\.awk' for reading/u)
})

test('awk: multiple -f programs are concatenated in order', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile('/dsh/workspace/first.awk', 'BEGIN { print "first" }\n')
  await fs.writeFile('/dsh/workspace/second.awk', 'BEGIN { print "second" }\n')
  const result = await shell.run(['bash', '-c', 'awk -f first.awk -f second.awk'], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'first\nsecond\n')
})

test('awk: `--` ends the options and the next word is the program', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "awk -- 'BEGIN { print \"dashdash\" }'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'dashdash\n')
})

test('awk: --version and --help answer without a program', async () => {
  const { shell } = await fixture()
  const version = await shell.run(['bash', '-c', 'awk --version'], { cwd: CWD })
  assert.equal(version.exitCode, 0)
  assert.match(version.stdout, /awk \(Worker shell, just-bash\)/u)
  const help = await shell.run(['bash', '-c', 'awk --help'], { cwd: CWD })
  assert.equal(help.exitCode, 0)
  assert.match(help.stdout, /Usage: awk/u)
})

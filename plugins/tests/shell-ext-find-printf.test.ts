// SPDX-License-Identifier: MIT
// G2-FIX-25: just-bash's `find -printf` expands only `%P`; every other
// directive is echoed literally with exit 0 (G2-A01 printed a literal `%y`).
// These tests pin the GNU directives the Worker shim renders and the
// fail-loud path for one it cannot answer.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  FIND_PRINTF_DIRECTIVES,
  FindFormatError,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  planFindInvocation,
  renderFindFormat,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker shell with a small mixed tree. */
async function fixture(): Promise<{ fs: VfsFileSystem; shell: WorkerShell }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-find-printf-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace/notes/deep', { recursive: true })
  await fs.writeFile('/dsh/workspace/notes/a.md', 'alpha\n')
  await fs.writeFile('/dsh/workspace/notes/deep/b.txt', 'b\n')
  await fs.writeFile('/dsh/workspace/top.txt', 'top\n')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell }
}

test('find -printf: %P and %y render the relative path and the real type', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "find notes -printf '%P\\t%y\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '\td\na.md\tf\ndeep\td\ndeep/b.txt\tf\n')
})

test('find -printf: the GNU directive set expands from FsStat', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "find . -maxdepth 1 -name '*.txt' -printf '%p|%f|%h|%d|%s|%m|%M|%y|%%\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, './top.txt|top.txt|.|1|4|644|-rw-r--r--|f|%\n')
})

test('find -printf: field width and the - flag are honoured', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "find . -maxdepth 1 -name '*.txt' -printf '[%10f][%-10f]\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '[   top.txt][top.txt   ]\n')
})

test('find -printf: an unsupported directive fails loud instead of printing it', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "find . -name '*.txt' -printf '%q\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 2, 'an unsupported format is a usage boundary, not a data failure')
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /find: unsupported format directive '%q'/u)
  assert.match(result.stderr, /^pdsh-shell: exit=2 program=find reason=unsupported-option$/mu)
})

test('find: multiple -printf actions are refused rather than guessed', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', "find . -printf '%p\\n' -printf '%f\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 2)
  assert.match(result.stderr, /multiple -printf actions/u)
  assert.match(result.stderr, /reason=unsupported-option/u)
})

test('find: the plan leaves traversal and predicates to the built-in', () => {
  assert.equal(planFindInvocation(['.', '-type', 'f']), undefined)
  const planned = planFindInvocation(['.', '-type', 'f,d', '-name', '*.txt', '-printf', '%P'])
  assert.ok(planned !== undefined)
  assert.deepEqual(planned.args, ['.', '(', '-type', 'f', '-o', '-type', 'd', ')', '-name', '*.txt', '-print0'])
  assert.equal(planned.format, '%P')
  assert.deepEqual(planned.startingPoints, ['.'])
})

test('find -printf: renderFindFormat is pure and covers the committed directives', () => {
  const stat = {
    isFile: true,
    isDirectory: false,
    isSymbolicLink: false,
    mode: 0o100640,
    size: 12,
    mtime: new Date(0),
    ino: 7,
  }
  const entry = { path: './a.txt', startingPoint: '.', relative: 'a.txt', depth: 1, stat }
  assert.equal(renderFindFormat('%y %Y %s %m %M %i %n %b %k %f %h %p %P %H', entry), 'f f 12 640 -rw-r----- 7 1 1 1 a.txt . ./a.txt a.txt .')
  assert.ok(FIND_PRINTF_DIRECTIVES.includes('y'))
  assert.throws(() => renderFindFormat('%Q', entry), (error: unknown) => error instanceof FindFormatError)
})

test('find -printf: \'%T@\' is the epoch seconds the VFS can answer', async () => {
  const { fs, shell } = await fixture()
  await fs.utimes('/dsh/workspace/top.txt', new Date(1_700_000_000_000), new Date(1_700_000_000_000))
  const result = await shell.run(['bash', '-c', "find . -maxdepth 1 -name 'top.txt' -printf '%T@\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, '1700000000\n')
})

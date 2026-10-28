// SPDX-License-Identifier: MIT
// G2-FIX-11: just-bash's `find` accepts only `-type f|d`; the Worker shell
// shadows it with a shim that keeps the full POSIX `-type` grammar and lets
// the built-in do all traversal, matching, actions and printing. The Worker
// VFS has regular files and directories only, so l/b/c/p/s contribute no
// matches and every other argv passes through untouched.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { Bash } from 'just-bash/browser'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  disciplineEnvironment,
  isWorkerShellProgram,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker VFS over a temp directory, with files, dotfiles and directories. */
function workspace(): { fs: VfsFileSystem; shell: WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-find-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace/sub/deep'), { recursive: true })
  mkdirSync(join(root, 'dsh/workspace/empty'), { recursive: true })
  mkdirSync(join(root, 'dsh/workspace/src'), { recursive: true })
  mkdirSync(join(root, 'dsh/workspace/docs'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a\n')
  writeFileSync(join(root, 'dsh/workspace/.hidden'), 'hidden\n')
  writeFileSync(join(root, 'dsh/workspace/sub/b.md'), '# b\n')
  writeFileSync(join(root, 'dsh/workspace/sub/deep/c.txt'), 'c\n')
  writeFileSync(join(root, 'dsh/workspace/src/index.ts'), 'export const answer = 42\n')
  writeFileSync(join(root, 'dsh/workspace/docs/guide.md'), '# Guide\n')
  const fs = new VfsFileSystem({ root })
  return { fs, shell: new WorkerShell({ fs }) }
}

/** Run one script through the unshadowed just-bash built-in `find`. */
async function builtinFind(fs: VfsFileSystem, script: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const bash = new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
  return await bash.exec(script, { cwd: CWD })
}

test('regression G2-A02: `find . -type l` exits 0 with empty output', async () => {
  const { shell } = workspace()
  const result = await shell.run(['bash', '-c', "find . -type l -printf '%P -> %l\\n'"], { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('find: every POSIX type outside this VFS contributes no matches', async () => {
  const { shell } = workspace()
  for (const types of ['l', 'b', 'c', 'p', 's', 'l,b', 'b,c,p,s', 'l,p,s']) {
    const script = `find . -type ${types} -printf '%P\\n'`
    const result = await shell.runScript(script, { cwd: CWD })
    assert.equal(result.exitCode, 0, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, '', script)
    assert.equal(result.stderr, '', script)
  }
})

test('find: -type f and -type d stay byte-identical to the unshadowed built-in', async () => {
  const { fs, shell } = workspace()
  for (const script of [
    'find . -type f',
    'find . -type d',
    "find . -type f -printf '%P\\n'",
    "find . -type d -printf '%P\\n'",
    "find . -name '*.txt' -type f",
    "find . -maxdepth 2 -type d -print",
  ]) {
    const expected = await builtinFind(fs, script)
    const actual = await shell.runScript(script, { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
  }
})

test('find: comma lists mixing possible and impossible types keep the possible semantics', async () => {
  const { shell } = workspace()
  const files = await shell.runScript("find . -type f -printf '%P\\n'", { cwd: CWD })
  const directories = await shell.runScript("find . -type d -printf '%P\\n'", { cwd: CWD })
  const lines = (stdout: string): string[] => stdout === '' ? [] : stdout.split('\n').slice(0, -1)
  const everything = [...lines(files.stdout), ...lines(directories.stdout)].sort()
  assert.match(files.stdout, /a\.txt\n/)
  assert.match(files.stdout, /sub\/b\.md\n/)
  assert.match(directories.stdout, /sub\n/)

  for (const types of ['f,l', 'l,f', 'f,f,l']) {
    const mixed = await shell.runScript(`find . -type ${types} -printf '%P\\n'`, { cwd: CWD })
    assert.equal(mixed.exitCode, 0, mixed.stderr)
    assert.equal(mixed.stdout, files.stdout, `-type ${types}`)
  }
  for (const types of ['d,l', 'l,d']) {
    const mixed = await shell.runScript(`find . -type ${types} -printf '%P\\n'`, { cwd: CWD })
    assert.equal(mixed.exitCode, 0, mixed.stderr)
    assert.equal(mixed.stdout, directories.stdout, `-type ${types}`)
  }
  for (const types of ['f,d', 'd,f,l', 'l,f,d,b,c,p,s']) {
    const mixed = await shell.runScript(`find . -type ${types} -printf '%P\\n'`, { cwd: CWD })
    assert.equal(mixed.exitCode, 0, mixed.stderr)
    assert.deepEqual(lines(mixed.stdout).sort(), everything, `-type ${types}`)
  }
})

test('find: f,d lists cover every file and directory name, including newlines', async () => {
  const { fs, shell } = workspace()
  await fs.writeFile('/dsh/workspace/weird\nname.txt', 'x\n')
  const nulLines = (stdout: string): string[] => stdout === '' ? [] : stdout.split('\0').slice(0, -1)
  const files = await shell.runScript('find . -type f -print0', { cwd: CWD })
  const directories = await shell.runScript('find . -type d -print0', { cwd: CWD })
  const mixed = await shell.runScript('find . -type f,d -print0', { cwd: CWD })
  assert.equal(mixed.exitCode, 0, mixed.stderr)
  const all = [...nulLines(files.stdout), ...nulLines(directories.stdout)].sort()
  assert.deepEqual(nulLines(mixed.stdout).sort(), all)
  assert.ok(nulLines(mixed.stdout).includes('./weird\nname.txt'))
})

test('find: the rewritten predicate keeps expression, negation and -exec semantics', async () => {
  const { shell } = workspace()
  const files = await shell.runScript("find . -type f -printf '%P\\n'", { cwd: CWD })
  const or = await shell.runScript("find . -type l -o -type f -printf '%P\\n'", { cwd: CWD })
  assert.equal(or.exitCode, 0, or.stderr)
  assert.equal(or.stdout, files.stdout)
  const negated = await shell.runScript("find . ! -type l -type f -printf '%P\\n'", { cwd: CWD })
  assert.equal(negated.exitCode, 0, negated.stderr)
  assert.equal(negated.stdout, files.stdout)

  // `-type` inside an -exec command is argv for the child program, not a
  // predicate: the shim must not rewrite it.
  const exec = await shell.runScript('find . -type f,l -exec echo -type {} \\;', { cwd: CWD })
  assert.equal(exec.exitCode, 0, exec.stderr)
  assert.notEqual(exec.stdout, '')
  for (const line of exec.stdout.trimEnd().split('\n')) assert.match(line, /^-type \./)
})

test('find: non-POSIX type letters still fail exactly like the built-in', async () => {
  const { fs, shell } = workspace()
  const expected = await builtinFind(fs, 'find . -type x')
  const actual = await shell.runScript('find . -type x', { cwd: CWD })
  assert.equal(actual.exitCode, expected.exitCode)
  assert.equal(actual.stdout, expected.stdout)
  assert.equal(actual.stderr, expected.stderr)
  assert.match(actual.stderr, /Unknown argument to -type: x/)
})

test('find: direct argv invocations get the same type grammar', async () => {
  const { shell } = workspace()
  const script = await shell.run(['bash', '-c', 'find . -type l'], { cwd: CWD })
  assert.equal(script.exitCode, 0, script.stderr)
  assert.equal(script.stdout, '')
  assert.equal(script.stderr, '')
  const direct = await shell.run(['find', '.', '-type', 'l'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(direct.stdout, '')
  assert.equal(direct.stderr, '')
})

test('corpus: no find form in the public shell corpus errors on -type', async () => {
  const corpus = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'tools/shell-corpus/corpus/public.jsonl')
  const commands = readFileSync(corpus, 'utf8')
    .split('\n')
    .filter(line => line.trim() !== '')
    .map(line => (JSON.parse(line) as { cmd: string }).cmd)
    .filter(cmd => /^find\s/.test(cmd))
  assert.ok(commands.length >= 6, `expected find forms in the public corpus, got ${String(commands.length)}`)
  assert.ok(commands.some(cmd => cmd.includes('-type')), 'the corpus must exercise -type')
  const { shell } = workspace()
  for (const command of commands) {
    const result = await shell.runScript(command, { cwd: CWD })
    assert.equal(result.exitCode, 0, `${command}: ${result.stderr}`)
    assert.doesNotMatch(result.stderr, /Unknown argument to -type/, command)
  }
})

test('find: the unshadowed built-in exhibits the upstream gap (G2-A02 baseline)', async () => {
  const { fs, shell } = workspace()
  // This is the pre-fix behavior the shim removes: just-bash 3.6.0 parses only
  // `-type f|d`, so the same script exits 1 before reaching the shell table.
  const upstream = await builtinFind(fs, "find . -type l -printf '%P -> %l\\n'")
  assert.equal(upstream.exitCode, 1, 'just-bash 3.6.0 rejects -type l')
  assert.equal(upstream.stdout, '')
  assert.match(upstream.stderr, /Unknown argument to -type: l/)

  const shimmed = await shell.run(['bash', '-c', "find . -type l -printf '%P -> %l\\n'"], { cwd: CWD })
  assert.equal(shimmed.exitCode, 0, shimmed.stderr)
  assert.equal(shimmed.stdout, '')
  assert.equal(shimmed.stderr, '')
})

test('find: every POSIX type letter is accepted; only f and d can match here', async () => {
  const { shell } = workspace()
  for (const letter of ['b', 'c', 'd', 'f', 'l', 'p', 's']) {
    const result = await shell.runScript(`find . -type ${letter} -printf '%P\\n'`, { cwd: CWD })
    assert.equal(result.exitCode, 0, `-type ${letter}: ${result.stderr}`)
    assert.equal(result.stderr, '', letter)
    if (letter === 'f' || letter === 'd') {
      assert.notEqual(result.stdout, '', `-type ${letter} must match the tree`)
    } else {
      assert.equal(result.stdout, '', `-type ${letter} cannot exist in this VFS`)
    }
  }
})

test('find: the production command table registers the shim and the direct-spawn seam', async () => {
  const { fs } = workspace()
  assert.equal(isWorkerShellProgram('find'), true, 'a direct spawn must reach the Worker shell table')
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  assert.ok(commands.some(command => command.name === 'find'), 'createWorkerCommands must carry find')
  const shell = new WorkerShell({ fs, commands })
  const link = await shell.run(['find', '.', '-type', 'l'], { cwd: CWD })
  assert.equal(link.exitCode, 0, link.stderr)
  assert.equal(link.stdout, '')
  for (const script of ['find . -type f', 'find . -type d']) {
    const expected = await builtinFind(fs, script)
    const actual = await shell.runScript(script, { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
  }
  const mixed = await shell.runScript("find . -type f,d -printf '%P\\n'", { cwd: CWD })
  assert.equal(mixed.exitCode, 0, mixed.stderr)
  assert.deepEqual(
    mixed.stdout.split('\n').slice(0, -1).sort(),
    [...(await shell.runScript("find . -type f -printf '%P\\n'", { cwd: CWD })).stdout.split('\n').slice(0, -1),
      ...(await shell.runScript("find . -type d -printf '%P\\n'", { cwd: CWD })).stdout.split('\n').slice(0, -1)].sort(),
  )
})

test('find: malformed POSIX type values keep the built-in error byte for byte', async () => {
  const { fs, shell } = workspace()
  for (const value of ['x', 'F', 'f,x', 'l,', '']) {
    const script = `find . -type '${value}'`
    const expected = await builtinFind(fs, script)
    const actual = await shell.runScript(script, { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, value)
    assert.equal(actual.stdout, expected.stdout, value)
    assert.equal(actual.stderr, expected.stderr, value)
    assert.match(actual.stderr, /Unknown argument to -type/, value)
  }
})

test('find: f,d groups keep AND, OR and negation grouping', async () => {
  const { shell } = workspace()
  const files = await shell.runScript("find . -type f -printf '%P\\n'", { cwd: CWD })
  const directories = await shell.runScript("find . -type d -printf '%P\\n'", { cwd: CWD })
  const andDirectory = await shell.runScript("find . -type f,d -type d -printf '%P\\n'", { cwd: CWD })
  assert.equal(andDirectory.exitCode, 0, andDirectory.stderr)
  assert.equal(andDirectory.stdout, directories.stdout)
  const andFile = await shell.runScript("find . -type f,d -a -type f -printf '%P\\n'", { cwd: CWD })
  assert.equal(andFile.exitCode, 0, andFile.stderr)
  assert.equal(andFile.stdout, files.stdout)
  const negated = await shell.runScript("find . ! -type f,d -printf '%P\\n'", { cwd: CWD })
  assert.equal(negated.exitCode, 0, negated.stderr)
  assert.equal(negated.stdout, '')
  const grouped = await shell.runScript("find . \\( -type l -o -type f \\) -name '*.txt' -printf '%P\\n'", { cwd: CWD })
  assert.equal(grouped.exitCode, 0, grouped.stderr)
  assert.match(grouped.stdout, /(^|\n)a\.txt(\n|$)/)
  assert.doesNotMatch(grouped.stdout, /b\.md/)
})

test('find: -exec batching keeps child argv verbatim and impossible types never run it', async () => {
  const { shell } = workspace()
  const plus = await shell.runScript('find . -type f,l -exec echo -type f {} +', { cwd: CWD })
  assert.equal(plus.exitCode, 0, plus.stderr)
  assert.notEqual(plus.stdout, '')
  for (const line of plus.stdout.trimEnd().split('\n')) assert.match(line, /^-type f \./)
  const impossible = await shell.runScript('find . -type l -exec echo WRONG {} +', { cwd: CWD })
  assert.equal(impossible.exitCode, 0, impossible.stderr)
  assert.equal(impossible.stdout, '')
  const terminator = await shell.runScript('find . -type f,l -exec echo -type {} \\;', { cwd: CWD })
  assert.equal(terminator.exitCode, 0, terminator.stderr)
  for (const line of terminator.stdout.trimEnd().split('\n')) assert.match(line, /^-type \./)
})

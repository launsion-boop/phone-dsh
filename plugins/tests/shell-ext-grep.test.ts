// SPDX-License-Identifier: MIT
// G2-FIX-81: the Worker grep must accept the GNU/BusyBox binary-file option
// `-I` / `--binary-files=without-match`, including inside combined short
// option clusters (`-RIn`). A file whose content contains a NUL byte is
// treated as non-matching and skipped silently; every other option and the
// non-`-I` path stay the built-in's byte-for-byte behavior.
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
  stripGrepBinaryOptions,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/**
 * A Worker VFS with the G2-B05-shaped fixture: one matching text file, one
 * file containing a NUL byte that also matches, one non-matching text file
 * and one matching JSON file the shim must still be able to `--exclude`.
 */
function workspace(): { fs: VfsFileSystem; shell: WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-grep-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace/fixture/text'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/fixture/text/match.txt'), 'needle one\nsecond needle\n')
  writeFileSync(join(root, 'dsh/workspace/fixture/text/binary.dat'), 'needle\0binary payload\n')
  writeFileSync(join(root, 'dsh/workspace/fixture/text/plain.txt'), 'nothing here\n')
  writeFileSync(join(root, 'dsh/workspace/fixture/excluded.json'), '{"needle": true}\n')
  const fs = new VfsFileSystem({ root })
  return {
    fs,
    shell: new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false, toolbox: false }) }),
  }
}

/** Run one script through the unshadowed just-bash built-in grep. */
async function builtinGrep(
  fs: VfsFileSystem,
  script: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const bash = new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
  return await bash.exec(script, { cwd: CWD })
}

test('regression G2-FIX-81: `grep -RIl` skips a NUL file and prints the matching text file', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -RIl needle fixture/text', { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, 'fixture/text/match.txt\n')
  assert.equal(result.stderr, '')
})

test('regression G2-FIX-81: `grep -RIn` prints text lines and silently skips the NUL file', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -RIn needle fixture/text', { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, 'fixture/text/match.txt:1:needle one\nfixture/text/match.txt:2:second needle\n')
  assert.equal(result.stderr, '')
})

test('grep: `-I` on a binary file is a silent no-match (exit 1)', async () => {
  const { shell } = workspace()
  for (const command of [
    'grep -I needle fixture/text/binary.dat',
    'grep --binary-files=without-match needle fixture/text/binary.dat',
    'grep -In needle fixture/text/binary.dat',
  ]) {
    const result = await shell.runScript(command, { cwd: CWD })
    assert.equal(result.exitCode, 1, `${command}: ${result.stderr}`)
    assert.equal(result.stdout, '', command)
    assert.equal(result.stderr, '', command)
  }
})

test('grep: `--binary-files=without-match` keeps mixed text output and exit 0', async () => {
  const { shell } = workspace()
  const result = await shell.runScript(
    'grep --binary-files=without-match -n needle fixture/text/binary.dat fixture/text/plain.txt fixture/text/match.txt',
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, 'fixture/text/match.txt:1:needle one\nfixture/text/match.txt:2:second needle\n')
  assert.equal(result.stderr, '')
})

test('grep: -I keeps the filename prefix for the surviving operand of two explicit files', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -I needle fixture/text/binary.dat fixture/text/match.txt', { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, 'fixture/text/match.txt:needle one\nfixture/text/match.txt:second needle\n')
  assert.equal(result.stderr, '')
})

test('grep: the `-RIn --exclude -E` G2-B05 shape skips the NUL file and keeps the excludes', async () => {
  const { shell } = workspace()
  const result = await shell.runScript("grep -RIn --exclude='*.json' -E 'needle' fixture", { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.equal(result.stdout, 'fixture/text/match.txt:1:needle one\nfixture/text/match.txt:2:second needle\n')
  assert.equal(result.stderr, '')
})

test('grep: every combined short cluster spelling of -I behaves the same', async () => {
  const { shell } = workspace()
  const expected = 'fixture/text/match.txt:1:needle one\nfixture/text/match.txt:2:second needle\n'
  for (const cluster of ['-RIn', '-nRI', '-InR', '-RnI']) {
    const result = await shell.runScript(`grep ${cluster} needle fixture/text`, { cwd: CWD })
    assert.equal(result.exitCode, 0, `${cluster}: ${result.stderr}`)
    assert.equal(result.stdout, expected, cluster)
    assert.equal(result.stderr, '', cluster)
  }
})

test('grep: -I alone, directly on an explicit binary file list, exits 1', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -I needle fixture/text/binary.dat fixture/text/plain.txt', { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('grep: without -I the built-in binary output is unchanged', async () => {
  const { fs, shell } = workspace()
  for (const script of [
    'grep -R needle fixture/text',
    'grep -Rn needle fixture/text',
    'grep -l needle fixture/text',
    'grep needle fixture/text/binary.dat',
  ]) {
    const expected = await builtinGrep(fs, script)
    const actual = await shell.runScript(script, { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
  }
})

test('grep: a pattern value that looks like -I is not rewritten', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -e -I fixture/text/plain.txt', { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '')
  assert.doesNotMatch(result.stderr, /invalid option/u)
})

test('grep: no text match among binary files exits 1 with no output', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -RIl absent fixture/text', { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('grep: a binary file whose name is in --include is still skipped', async () => {
  const { shell } = workspace()
  const result = await shell.runScript("grep -RIl --include='*.dat' needle fixture/text", { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('grep: -I also skips a binary standard input', async () => {
  const { shell } = workspace()
  const result = await shell.runScript('grep -I needle', { cwd: CWD, stdin: 'needle\0tail\n' })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
  const text = await shell.runScript('grep -I needle', { cwd: CWD, stdin: 'needle\n' })
  assert.equal(text.exitCode, 0, text.stderr)
  assert.equal(text.stdout, 'needle\n')
})

test('grep: the binary-option stripper respects --, -e values and unknown flags', () => {
  assert.deepEqual(stripGrepBinaryOptions(['-RIn', 'needle', 'fixture']), {
    args: ['-Rn', 'needle', 'fixture'],
    withoutMatch: true,
  })
  assert.deepEqual(stripGrepBinaryOptions(['--binary-files=without-match', '-n', 'needle', 'file']), {
    args: ['-n', 'needle', 'file'],
    withoutMatch: true,
  })
  assert.deepEqual(stripGrepBinaryOptions(['--binary-files', 'without-match', 'needle']), {
    args: ['needle'],
    withoutMatch: true,
  })
  // `-e -I` names a pattern, not the option; `--` ends option parsing.
  assert.deepEqual(stripGrepBinaryOptions(['-e', '-I', 'file']), { args: ['-e', '-I', 'file'], withoutMatch: false })
  assert.deepEqual(stripGrepBinaryOptions(['--', '-I']), { args: ['--', '-I'], withoutMatch: false })
  // `-If PATTERNS` is `-I` plus the value-taking `-f`, not `-I -f` reordered.
  assert.deepEqual(stripGrepBinaryOptions(['-If', 'patterns.txt']), { args: ['-f', 'patterns.txt'], withoutMatch: true })
  // An unknown flag keeps the built-in's own option error.
  assert.deepEqual(stripGrepBinaryOptions(['-xQ']), { args: ['-xQ'], withoutMatch: false })
})

test('grep: the production command table and direct-spawn seam carry the shim', async () => {
  const { shell } = workspace()
  assert.equal(isWorkerShellProgram('grep'), true, 'a direct spawn must reach the Worker shell table')
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  assert.ok(commands.some(command => command.name === 'grep'), 'createWorkerCommands must carry grep')
  const direct = await shell.run(['grep', '-RIl', 'needle', 'fixture/text'], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(direct.stdout, 'fixture/text/match.txt\n')
})

test('grep: the unshadowed built-in exhibits the upstream option gap (G2-FIX-81 baseline)', async () => {
  const { fs } = workspace()
  // Pre-fix behavior: just-bash 3.6.0 has no -I in its option parser, so the
  // same invocation is a usage failure before the Worker table can help.
  const upstream = await builtinGrep(fs, 'grep -RIn needle fixture/text')
  assert.notEqual(upstream.exitCode, 0, 'just-bash 3.6.0 rejects -I')
  assert.equal(upstream.stdout, '')
  assert.match(upstream.stderr, /invalid option -- 'I'/u)
})

test('corpus: the public shell corpus carries grep option-surface vectors', () => {
  const corpus = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'tools/shell-corpus/corpus/public.jsonl')
  const commands = readFileSync(corpus, 'utf8')
    .split('\n')
    .filter(line => line.trim() !== '')
    .map(line => (JSON.parse(line) as { cmd: string }).cmd)
    .filter(command => /(^|[\s;&|(`])grep\s/u.test(command))
  assert.ok(commands.length >= 12, `expected grep vectors in the public corpus, got ${String(commands.length)}`)
  assert.ok(commands.some(command => /(^|\s)-[A-Za-z]*I[A-Za-z]*\s/u.test(command)), 'the corpus must exercise -I')
  assert.ok(commands.some(command => command.includes('--binary-files=without-match')), 'the corpus must exercise the long option')
})

// SPDX-License-Identifier: MIT
// G2-FIX-18: just-bash 3.6.0's built-in `stat -c` implements only a handful of
// GNU format directives (%n %N %s %F %a %A %u %U %g %G) and echoes every other
// directive literally with exit 0. The Worker shell shadows it with a command
// that renders the metadata the VFS actually reports and fails loud for a
// directive it cannot satisfy. The baseline test below drives the unshadowed
// built-in to pin the defect class, then every case drives the Worker table.
import assert from 'node:assert/strict'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
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

/** A Worker VFS over a temp directory with the corpus-shaped workspace. */
function workspace(): { fs: VfsFileSystem; shell: WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-stat-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace/backup'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/backup/roadmap.md'), `# Roadmap\n${'x'.repeat(35)}`)
  writeFileSync(join(root, 'dsh/workspace/notes.txt'), 'hello\n')
  chmodSync(join(root, 'dsh/workspace/notes.txt'), 0o640)
  writeFileSync(join(root, 'dsh/workspace/a'), 'a\n')
  writeFileSync(join(root, 'dsh/workspace/b'), 'b\n')
  writeFileSync(join(root, 'dsh/workspace/empty.txt'), '')
  const fs = new VfsFileSystem({ root })
  return { fs, shell: new WorkerShell({ fs }) }
}

/** Run one script through the unshadowed just-bash built-in `stat`. */
async function builtinStat(
  fs: VfsFileSystem,
  script: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const bash = new Bash({ fs, cwd: CWD, env: disciplineEnvironment({}, CWD) })
  return await bash.exec(script, { cwd: CWD })
}

test('regression G2-A02 baseline: the unshadowed built-in echoes %i/%h/%y/%z', async () => {
  const { fs } = workspace()
  const upstream = await builtinStat(
    fs,
    "stat -c '%n | %s bytes | inode %i | links %h | mtime %y | ctime %z' backup/roadmap.md",
  )
  // This is the pre-fix behavior the shim removes: no error, no expansion.
  assert.equal(upstream.exitCode, 0)
  assert.equal(upstream.stderr, '')
  assert.match(upstream.stdout, /inode %i \| links %h \| mtime %y \| ctime %z/)
})

test('regression G2-A02: stat -c expands %i/%h/%y/%z instead of echoing them', async () => {
  const { fs, shell } = workspace()
  const format = '%n | %s bytes | inode %i | links %h | mtime %y | ctime %z'
  const result = await shell.run(
    ['bash', '-c', `stat -c '${format}' backup/roadmap.md notes.txt`],
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.doesNotMatch(result.stdout, /%[a-zA-Z]/u, 'no format directive may survive as literal text')
  const stat = await fs.stat('/dsh/workspace/backup/roadmap.md')
  assert.match(
    result.stdout,
    new RegExp(
      '^backup/roadmap\\.md \\| 45 bytes \\| inode '
      + `${String(stat.ino)}`
      + ' \\| links 1 \\| mtime \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{9} [+-]\\d{4}'
      + ' \\| ctime \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{9} [+-]\\d{4}$',
      'mu',
    ),
  )
  assert.match(result.stdout, /^notes\.txt \| 6 bytes \| inode \d+ \| links 1 \| mtime /mu)
})

test('stat -c covers the coreutils directive set, %% and the \\n/\\t escapes', async () => {
  const { fs, shell } = workspace()
  const script = "stat -c '%a|%A|%d|%D|%F|%g|%G|%h|%i|%n|%s|%u|%U|%x|%X|%y|%z|%t|%T|%%|a\\tb\\nc' notes.txt"
  const result = await shell.runScript(script, { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.doesNotMatch(result.stdout, /%[a-zA-Z]/u)
  const stat = await fs.stat('/dsh/workspace/notes.txt')
  const fields = result.stdout.split('|')
  assert.equal(fields.length, 21, result.stdout)
  assert.equal(fields[0], '640')
  assert.equal(fields[1], '-rw-r-----')
  assert.match(fields[2] as string, /^\d+$/u)
  assert.match(fields[3] as string, /^[0-9a-f]+$/u)
  assert.equal(fields[4], 'regular file')
  assert.equal(fields[5], '1000')
  assert.equal(fields[6], 'group')
  assert.equal(fields[7], '1')
  assert.equal(fields[8], String(stat.ino))
  assert.equal(fields[9], 'notes.txt')
  assert.equal(fields[10], '6')
  assert.equal(fields[11], '1000')
  assert.equal(fields[12], 'user')
  assert.match(fields[13] as string, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9} [+-]\d{4}$/u)
  assert.equal(fields[14], String(Math.floor(stat.mtime.getTime() / 1000)))
  assert.match(fields[15] as string, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9} [+-]\d{4}$/u)
  assert.match(fields[16] as string, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9} [+-]\d{4}$/u)
  assert.equal(fields[17], '0')
  assert.equal(fields[18], '0')
  assert.equal(fields[19], '%')
  assert.equal(fields[20], 'a\tb\nc\n')
})

test('stat -c fails loud on a directive the shim cannot satisfy', async () => {
  const { shell } = workspace()
  const result = await shell.run(['bash', '-c', "stat -c '%n %Q' notes.txt"], { cwd: CWD })
  assert.equal(result.exitCode, 2, 'an unsupported format is a usage boundary, not a data failure')
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /^stat: unsupported format specifier '%Q'\npdsh-shell: exit=2 program=stat reason=unsupported-option$/mu)
})

test('G2-FIX-101: --printf renders a literal-prefixed format exactly once', async () => {
  const { shell } = workspace()
  const result = await shell.run(
    ['bash', '-c', "stat --printf='probe: %n size=%s blocks=%b\\n' notes.txt"],
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, 'probe: notes.txt size=6 blocks=1\n')
})

test('G2-FIX-101: --printf does not add a newline after each operand', async () => {
  const { shell } = workspace()
  const concatenated = await shell.run(['bash', '-c', "stat --printf='%n' a b"], { cwd: CWD })
  assert.equal(concatenated.exitCode, 0, concatenated.stderr)
  assert.equal(concatenated.stderr, '')
  assert.equal(concatenated.stdout, 'ab')
  const separated = await shell.run(['bash', '-c', "stat --printf='%n\\n' a b"], { cwd: CWD })
  assert.equal(separated.exitCode, 0, separated.stderr)
  assert.equal(separated.stderr, '')
  assert.equal(separated.stdout, 'a\nb\n')
})

test('G2-FIX-101: --printf FORMAT and --printf=FORMAT share the format source', async () => {
  const { shell } = workspace()
  for (const script of [
    "stat --printf 'probe: %n size=%s blocks=%b\\n' notes.txt",
    "stat --printf='probe: %n size=%s blocks=%b\\n' notes.txt",
  ]) {
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${script}: ${result.stderr}`)
    assert.equal(result.stderr, '', script)
    assert.equal(result.stdout, 'probe: notes.txt size=6 blocks=1\n', script)
  }
})

test('G2-FIX-101: the last format option wins across -c, --format and --printf', async () => {
  const { shell } = workspace()
  const printfLast = await shell.run(['bash', '-c', "stat -c '%n' --printf='%s' notes.txt"], { cwd: CWD })
  assert.equal(printfLast.exitCode, 0, printfLast.stderr)
  assert.equal(printfLast.stdout, '6')
  const formatLast = await shell.run(['bash', '-c', "stat --printf='%s' -c '%n' notes.txt"], { cwd: CWD })
  assert.equal(formatLast.exitCode, 0, formatLast.stderr)
  assert.equal(formatLast.stdout, 'notes.txt\n')
})

test('G2-FIX-101: %b reports 512-byte blocks and %B the block size', async () => {
  const { shell } = workspace()
  const blocks = await shell.run(['bash', '-c', "stat -c 'probe: %n size=%s blocks=%b' notes.txt"], { cwd: CWD })
  assert.equal(blocks.exitCode, 0, blocks.stderr)
  assert.equal(blocks.stderr, '')
  assert.equal(blocks.stdout, 'probe: notes.txt size=6 blocks=1\n')
  const blockSize = await shell.run(['bash', '-c', "stat -c '%B' notes.txt"], { cwd: CWD })
  assert.equal(blockSize.exitCode, 0, blockSize.stderr)
  assert.equal(blockSize.stdout, '512\n')
  const empty = await shell.run(['bash', '-c', "stat -c '%b' empty.txt"], { cwd: CWD })
  assert.equal(empty.exitCode, 0, empty.stderr)
  assert.equal(empty.stdout, '0\n')
})

test('G2-FIX-101: the direct spawn seam renders --printf like the bash path', async () => {
  const { fs } = workspace()
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  const shell = new WorkerShell({ fs, commands })
  const direct = await shell.run(['stat', '--printf', '%n|%s|%b', 'notes.txt'], { cwd: CWD })
  const script = await shell.run(
    ['bash', '-c', "stat --printf='%n|%s|%b' notes.txt"],
    { cwd: CWD },
  )
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(script.exitCode, 0, script.stderr)
  assert.equal(direct.stdout, 'notes.txt|6|1')
  assert.equal(direct.stdout, script.stdout)
  assert.equal(direct.stderr, script.stderr)
})

test('stat -c %n and %s stay byte-identical to the unshadowed built-in', async () => {
  const { fs, shell } = workspace()
  const script = "stat -c '%n|%s' notes.txt backup/roadmap.md"
  const expected = await builtinStat(fs, script)
  const actual = await shell.runScript(script, { cwd: CWD })
  assert.equal(actual.exitCode, expected.exitCode, actual.stderr)
  assert.equal(actual.stdout, expected.stdout)
  assert.equal(actual.stderr, expected.stderr)
  assert.equal(actual.stdout, 'notes.txt|6\nbackup/roadmap.md|45\n')
})

test('stat: the default no-`-c` output is still the built-in output', async () => {
  const { fs, shell } = workspace()
  for (const script of ['stat notes.txt', 'stat backup/roadmap.md', 'stat missing.txt']) {
    const expected = await builtinStat(fs, script)
    const actual = await shell.runScript(script, { cwd: CWD })
    assert.equal(actual.exitCode, expected.exitCode, script)
    assert.equal(actual.stdout, expected.stdout, script)
    assert.equal(actual.stderr, expected.stderr, script)
  }
})

test('stat: the production table registers the shim and the direct-argv seam', async () => {
  const { fs } = workspace()
  assert.equal(isWorkerShellProgram('stat'), true, 'a direct spawn must reach the Worker shell table')
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  assert.ok(commands.some(command => command.name === 'stat'), 'createWorkerCommands must carry stat')
  const shell = new WorkerShell({ fs, commands })
  const format = '%n|%i|%h|%y|%z'
  const direct = await shell.run(['stat', '-c', format, 'notes.txt'], { cwd: CWD })
  const script = await shell.run(['bash', '-c', `stat -c '${format}' notes.txt`], { cwd: CWD })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(script.exitCode, 0, script.stderr)
  assert.equal(direct.stdout, script.stdout)
  assert.doesNotMatch(direct.stdout, /%[a-zA-Z]/u)
})

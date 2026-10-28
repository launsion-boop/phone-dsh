// SPDX-License-Identifier: MIT
// W5-SHELL: the just-bash filesystem adapter, output discipline, cancellation,
// truncation and the PDSH_SHELL selector.
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  VfsFileSystem,
  WorkerShell,
  boundOutput,
  disciplineEnvironment,
  resolveShellMode,
} from '../shell-ext/src/index.ts'

const roots: string[] = []

function fixture(): { root: string; fs: VfsFileSystem } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-ext-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  return { root, fs }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

test('filesystem: reads and writes land in node:fs under the adapter root', async () => {
  const { root, fs } = fixture()
  await fs.mkdir('/dsh/workspace/src', { recursive: true })
  await fs.writeFile('/dsh/workspace/src/index.ts', 'export const answer = 42\n')
  assert.equal(readFileSync(join(root, 'dsh/workspace/src/index.ts'), 'utf8'), 'export const answer = 42\n')
  assert.equal(await fs.readFile('/dsh/workspace/src/index.ts'), 'export const answer = 42\n')
  assert.deepEqual([...new Uint8Array(await fs.readFileBuffer('/dsh/workspace/src/index.ts'))], [...Buffer.from('export const answer = 42\n')])
  assert.equal((await fs.stat('/dsh/workspace/src/index.ts')).isFile, true)
  assert.equal((await fs.stat('/dsh/workspace/src')).isDirectory, true)
  await fs.appendFile('/dsh/workspace/src/index.ts', '// tail\n')
  assert.equal(readFileSync(join(root, 'dsh/workspace/src/index.ts'), 'utf8').split('\n').at(-2), '// tail')
  assert.deepEqual((await fs.readdir('/dsh/workspace/src')).sort(), ['index.ts'])
  assert.deepEqual((await fs.readdirWithFileTypes('/dsh/workspace/src')).map(entry => [entry.name, entry.isFile]), [['index.ts', true]])
  assert.equal(fs.getAllPaths().includes('/dsh/workspace/src/index.ts'), true)
  assert.equal(fs.resolvePath('/dsh/workspace', '../home/notes.txt'), '/dsh/home/notes.txt')
  assert.equal(await fs.exists('/dsh/workspace/src/index.ts'), true)
  assert.equal(await fs.exists('/dsh/workspace/nope'), false)
})

test('filesystem: cp, mv, chmod, createExclusive and rm keep the VFS-visible tree', async () => {
  const { root, fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  await fs.writeFile('/dsh/workspace/a.txt', 'a')
  await fs.cp('/dsh/workspace/a.txt', '/dsh/workspace/b.txt', {})
  assert.equal(readFileSync(join(root, 'dsh/workspace/b.txt'), 'utf8'), 'a')
  await fs.mv('/dsh/workspace/b.txt', '/dsh/workspace/c.txt')
  assert.equal(await fs.exists('/dsh/workspace/b.txt'), false)
  await fs.chmod('/dsh/workspace/c.txt', 0o600)
  assert.equal((statSync(join(root, 'dsh/workspace/c.txt')).mode & 0o777), 0o600)
  await fs.createExclusive('/dsh/workspace/private.txt', { mode: 0o600 })
  await assert.rejects(fs.createExclusive('/dsh/workspace/private.txt', { mode: 0o600 }), (error: unknown) => (error as { code?: string }).code === 'EEXIST')
  await fs.rm('/dsh/workspace/c.txt')
  assert.equal(await fs.exists('/dsh/workspace/c.txt'), false)
  // just-bash's `rmdir` calls rm without `recursive`; an empty directory must go.
  await fs.mkdir('/dsh/workspace/empty')
  await fs.rm('/dsh/workspace/empty')
  assert.equal(await fs.exists('/dsh/workspace/empty'), false)
  await fs.rm('/dsh/workspace/a.txt', { force: true })
  await fs.rm('/dsh/workspace/missing', { force: true })
})

test('filesystem: relative paths and the symlink face fail instead of escaping or lying', async () => {
  const { fs } = fixture()
  await assert.rejects(fs.readFile('relative.txt'), (error: unknown) => (error as { code?: string }).code === 'EINVAL')
  await assert.rejects(fs.symlink('../outside', '/dsh/workspace/link'), (error: unknown) => (error as { code?: string }).code === 'EPERM')
  await assert.rejects(fs.readlink('/dsh/workspace/link'), (error: unknown) => (error as { code?: string }).code === 'EINVAL')
})

test('shell: bash -c runs in just-bash, writes through the VFS and forces the output discipline', async () => {
  const { root, fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const shell = new WorkerShell({ fs })
  const result = await shell.run(['bash', '-c', 'echo "$TERM/$NO_COLOR/$LANG/$LC_ALL"; echo hello > out.txt; cat out.txt'], {
    cwd: '/dsh/workspace',
    env: { TERM: 'xterm-256color', NO_COLOR: '0', LANG: 'en_US.UTF-8' },
  })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'dumb/1/C.UTF-8/C.UTF-8\nhello\n')
  assert.equal(readFileSync(join(root, 'dsh/workspace/out.txt'), 'utf8'), 'hello\n')
})

test('shell: direct argv passes arguments verbatim and reports a missing program', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const shell = new WorkerShell({ fs })
  const result = await shell.run(['printf', '%s-%s\\n', 'a', 'b'], { cwd: '/dsh/workspace' })
  assert.equal(result.stdout, 'a-b\n')
  const missing = await shell.run(['definitely-not-a-program-xl'], { cwd: '/dsh/workspace' })
  assert.equal(missing.exitCode, 127)
  assert.equal(missing.missingProgram, 'definitely-not-a-program-xl')
  const script = await shell.run(['bash', '-c', 'definitely-not-a-program-xl'], { cwd: '/dsh/workspace' })
  assert.equal(script.exitCode, 127)
  assert.equal(script.missingProgram, undefined, 'a bash -c failure is a command result, not a spawn failure')
})

test('shell: the wall-clock limit aborts a running script with status 124', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const shell = new WorkerShell({ fs })
  const started = Date.now()
  const result = await shell.run(['bash', '-c', 'sleep 5; echo never'], { cwd: '/dsh/workspace', timeoutMs: 50 })
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.match(result.stderr, /wall-clock limit/)
  assert.ok(Date.now() - started < 2_000)
})

test('shell: cancellation is cooperative and reports 130', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const shell = new WorkerShell({ fs })
  const controller = new AbortController()
  setTimeout(() => { controller.abort(new Error('test cancel')) }, 20).unref()
  const result = await shell.run(['bash', '-c', 'sleep 5; echo never'], { cwd: '/dsh/workspace', signal: controller.signal })
  assert.equal(result.exitCode, 130)
  assert.equal(result.aborted, true)
})

test('output: truncation keeps both ends and names the dropped byte count', () => {
  const text = Array.from({ length: 1_000 }, (_, index) => `line-${String(index)}`).join('\n')
  const bounded = boundOutput(text, 200)
  assert.equal(bounded.truncated, true)
  assert.ok(Buffer.byteLength(bounded.text, 'utf8') < 320)
  assert.match(bounded.text, /^line-0\nline-1/)
  assert.match(bounded.text, /line-999$/)
  assert.match(bounded.text, /output truncated: \d+ of \d+ bytes elided/)
  const short = boundOutput('hello', 200)
  assert.equal(short.truncated, false)
  assert.equal(short.text, 'hello')
})

test('shell: stdout and stderr are bounded at maxOutputBytes', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const shell = new WorkerShell({ fs })
  const result = await shell.run(['bash', '-c', 'seq 1 2000; seq 1 2000 >&2'], {
    cwd: '/dsh/workspace',
    maxOutputBytes: 120,
  })
  // A cut stream is incomplete data: the command may not report 0 over it.
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdoutTruncated, true)
  assert.equal(result.stderrTruncated, true)
  assert.match(result.stdout, /^1\n2\n/)
  assert.match(result.stdout, /2000\n$/)
  assert.match(result.stdout, /output truncated/)
  assert.match(result.stderr, /^pdsh-shell: exit=1 program=bash reason=output-truncated hint=/mu)
})

test('PDSH_SHELL: just-bash is the default and runtime is the explicit fallback', () => {
  assert.equal(resolveShellMode({}), 'just-bash')
  assert.equal(resolveShellMode({ PDSH_SHELL: 'just-bash' }), 'just-bash')
  assert.equal(resolveShellMode({ PDSH_SHELL: 'runtime' }), 'runtime')
  assert.throws(() => resolveShellMode({ PDSH_SHELL: 'brush' }), /just-bash' or 'runtime/)
})

test('environment: PWD follows cwd and HOME/TMPDIR/PATH get the Worker defaults', () => {
  const env = disciplineEnvironment({ PATH: '/custom/bin', TERM: 'xterm' }, '/dsh/home')
  assert.equal(env.PWD, '/dsh/home')
  assert.equal(env.PATH, '/custom/bin')
  assert.equal(env.TERM, 'dumb')
  assert.equal(env.HOME, '/dsh/home')
  assert.equal(env.TMPDIR, '/dsh/tmp')
})

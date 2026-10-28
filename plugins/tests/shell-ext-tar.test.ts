// SPDX-License-Identifier: MIT
// G2-FIX-25: `tar` was absent from the Worker shell (exit 127). These tests
// drive the POSIX ustar implementation over the VFS: create, list and extract,
// with and without the portable gzip backend, plus the safety and error forms.
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  TarError,
  VfsFileSystem,
  WorkerShell,
  createTarCommand,
  createWorkerCommands,
  parseTarArguments,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A Worker VFS with a notes tree and a shell that serves tar. */
async function fixture(): Promise<{ fs: VfsFileSystem; shell: WorkerShell; root: string }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-tar-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace/notes', { recursive: true })
  await fs.writeFile('/dsh/workspace/notes/a.md', 'alpha\n')
  await fs.writeFile('/dsh/workspace/notes/b.md', 'beta\n')
  await fs.writeFile('/dsh/workspace/notes/c.md', 'gamma\n')
  await fs.writeFile('/dsh/workspace/top.txt', 'top\n')
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return { fs, shell, root }
}

/** Build one uncompressed ustar archive with a single regular-file member. */
function buildUstar(name: string, content: string): Uint8Array {
  const header = new Uint8Array(512)
  const text = (offset: number, length: number, value: string): void => {
    header.set(new TextEncoder().encode(value).subarray(0, length), offset)
  }
  const octal = (offset: number, length: number, value: number): void => {
    text(offset, length, `${value.toString(8).padStart(length - 1, '0')}\0`)
  }
  text(0, 100, name)
  octal(100, 8, 0o644)
  octal(108, 8, 0)
  octal(116, 8, 0)
  octal(124, 12, Buffer.byteLength(content))
  octal(136, 12, 0)
  header.fill(0x20, 148, 156)
  text(156, 1, '0')
  text(257, 6, 'ustar\0')
  text(263, 2, '00')
  text(265, 32, 'root')
  text(297, 32, 'root')
  let sum = 0
  for (const byte of header) sum += byte
  text(148, 8, `${sum.toString(8).padStart(6, '0')}\0 `)
  const data = new TextEncoder().encode(content)
  const padded = new Uint8Array(Math.ceil(data.byteLength / 512) * 512)
  padded.set(data)
  return new Uint8Array([...header, ...padded, ...new Uint8Array(1024)])
}

test('tar: parse recognises traditional, clustered and long options', () => {
  const traditional = parseTarArguments(['czf', 'out.tar.gz', 'notes'])
  assert.equal(traditional.operation, 'create')
  assert.equal(traditional.gzip, true)
  assert.equal(traditional.archive, 'out.tar.gz')
  assert.deepEqual(traditional.actions, [{ kind: 'operand', value: 'notes' }])

  const clustered = parseTarArguments(['-tzf', 'out.tar.gz'])
  assert.equal(clustered.operation, 'list')
  assert.equal(clustered.gzip, true)

  const long = parseTarArguments(['--extract', '--gzip', '--file=out.tar.gz', '--directory', 'restored'])
  assert.equal(long.operation, 'extract')
  assert.deepEqual(long.actions, [{ kind: 'chdir', value: 'restored' }])

  assert.throws(() => parseTarArguments(['-c', '-t']), (error: unknown) => error instanceof TarError)
  assert.throws(() => parseTarArguments(['-cjf', 'x.tar']), /bzip2|not supported/u)
})

test('tar: -czf writes a gzip member and -tzf lists the directory entries first', async () => {
  const { fs, shell } = await fixture()
  const created = await shell.run(['bash', '-c', 'tar -czf notes.tar.gz notes'], { cwd: CWD })
  assert.equal(created.exitCode, 0, created.stderr)
  assert.equal(created.stdout, '')
  const archive = await fs.readFileBuffer('/dsh/workspace/notes.tar.gz')
  assert.deepEqual([...archive.subarray(0, 3)], [0x1f, 0x8b, 0x08])

  const listed = await shell.run(['bash', '-c', 'tar -tzf notes.tar.gz'], { cwd: CWD })
  assert.equal(listed.exitCode, 0, listed.stderr)
  assert.equal(listed.stdout, 'notes/\nnotes/a.md\nnotes/b.md\nnotes/c.md\n')
})

test('tar: -xzf extracts files, creates the target and reproduces the bytes', async () => {
  const { fs, shell } = await fixture()
  assert.equal((await shell.run(['bash', '-c', 'tar -czf notes.tar.gz notes'], { cwd: CWD })).exitCode, 0)
  const extracted = await shell.run(['bash', '-c', 'tar -xzf notes.tar.gz -C restored && cat restored/notes/b.md'], { cwd: CWD })
  assert.equal(extracted.exitCode, 0, extracted.stderr)
  assert.equal(extracted.stdout, 'beta\n')
  assert.equal(await fs.readFile('/dsh/workspace/restored/notes/a.md'), 'alpha\n')
})

test('tar: a plain (uncompressed) roundtrip works and -f - streams bytes', async () => {
  const { shell } = await fixture()
  const piped = await shell.run(['bash', '-c', 'tar -cf - notes/a.md | tar -tf -'], { cwd: CWD })
  assert.equal(piped.exitCode, 0, piped.stderr)
  assert.equal(piped.stdout, 'notes/a.md\n')
})

test('tar: a leading ../ operand is stored as a safe member name', async () => {
  const { fs, shell } = await fixture()
  const created = await shell.run(['bash', '-c', 'cd notes && tar -cf ../parent.tar ../top.txt'], { cwd: CWD })
  assert.equal(created.exitCode, 0, created.stderr)
  const listed = await shell.run(['bash', '-c', 'tar -tf parent.tar'], { cwd: CWD })
  assert.equal(listed.exitCode, 0, listed.stderr)
  assert.equal(listed.stdout, 'top.txt\n')
  assert.equal(await fs.exists('/dsh/workspace/parent.tar'), true)
})

test('tar: a missing archive fails loud with status 2', async () => {
  const { shell } = await fixture()
  const result = await shell.run(['bash', '-c', 'tar -tzf absent.tar.gz'], { cwd: CWD })
  assert.equal(result.exitCode, 2)
  assert.match(result.stderr, /Cannot open/u)
})

test('tar: extraction refuses parent-directory member names', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile('/dsh/workspace/hostile.tar', buildUstar('../escape.txt', 'owned\n'))
  const result = await shell.run(['bash', '-c', 'tar -xf hostile.tar'], { cwd: CWD })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /Member name contains '\.\.'/u)
  assert.equal(await fs.exists('/dsh/workspace/escape.txt'), false)
})

test('tar: a file name too long for ustar fails loud instead of truncating', async () => {
  const { fs, shell } = await fixture()
  const long = `${'a'.repeat(120)}/${'b'.repeat(120)}/${'c'.repeat(30)}.txt`
  await fs.mkdir(`/dsh/workspace/${'a'.repeat(120)}/${'b'.repeat(120)}`, { recursive: true })
  await fs.writeFile(`/dsh/workspace/${long}`, 'x')
  const result = await shell.run(['bash', '-c', `tar -cf long.tar ${'a'.repeat(120)}`], { cwd: CWD })
  assert.equal(result.exitCode, 2)
  assert.match(result.stderr, /too long/u)
})

test('tar: the command is in the Worker table and a direct spawn reaches it', async () => {
  const { shell } = await fixture()
  const table = await shell.run(['bash', '-c', 'command -v tar'], { cwd: CWD })
  assert.equal(table.exitCode, 0)
  assert.match(table.stdout, /\/usr\/bin\/tar/u)
  const custom = createTarCommand()
  assert.equal(custom.name, 'tar')
})

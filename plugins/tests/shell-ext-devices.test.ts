// SPDX-License-Identifier: MIT
// G2-FIX-3 / G2-FIX-112: virtual character-device semantics live in the Worker
// shell filesystem adapter, so every redirection form (`>`, `>>`, `2>`, `2>&1`,
// `<`, `&>`, `&>>` and a command's own open) works without a real file below
// the VFS root and without a sink mutation. `/dev/zero` and `/dev/urandom`
// answer a bounded read window; `/dev/null` stays empty.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { latin1FromBytes } from 'just-bash'
import {
  VfsFileSystem,
  WORKER_DEVICE_PATHS,
  WORKER_DEVICE_READ_BYTES,
  WorkerShell,
} from '../shell-ext/src/index.ts'

const roots: string[] = []

function fixture(): { root: string; fs: VfsFileSystem; shell: WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-devices-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  writeFileSync(join(root, 'dsh/workspace/a.txt'), 'a\n')
  const fs = new VfsFileSystem({ root })
  return { root, fs, shell: new WorkerShell({ fs }) }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** Every path and file content below `root`, so a mutation is visible. */
function snapshot(root: string): Record<string, string> {
  const tree: Record<string, string> = {}
  const walk = (relative: string): void => {
    for (const entry of readdirSync(join(root, relative), { withFileTypes: true })) {
      const child = relative === '' ? entry.name : `${relative}/${entry.name}`
      if (entry.isDirectory()) {
        tree[child] = 'directory'
        walk(child)
      } else {
        tree[child] = readFileSync(join(root, child), 'utf8')
      }
    }
  }
  walk('')
  return tree
}

test('regression: `find . -type f 2>/dev/null` exits 0 instead of ENOENT', async () => {
  const { root, shell } = fixture()
  const before = snapshot(root)
  const result = await shell.run(['bash', '-c', 'find . -type f 2>/dev/null; echo ok'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.match(result.stdout, /(?:^|\n)ok\n$/)
  assert.doesNotMatch(result.stderr, /ENOENT|No such file/)
  assert.equal(existsSync(join(root, 'dev')), false, 'no real /dev tree may be created')
  assert.deepEqual(snapshot(root), before)
})

test('devices: the fixed set is /dev/null, /dev/zero and /dev/urandom, all character devices', async () => {
  assert.deepEqual([...WORKER_DEVICE_PATHS], ['/dev/null', '/dev/zero', '/dev/urandom'])
  const { fs } = fixture()
  for (const path of WORKER_DEVICE_PATHS) {
    assert.equal(await fs.exists(path), true, path)
    const stats = await fs.stat(path)
    assert.equal(stats.isFile, false, `${path} is not a regular file`)
    assert.equal(stats.isDirectory, false, `${path} is not a directory`)
    assert.equal(stats.isSymbolicLink, false, `${path} is not a symlink`)
    assert.equal(stats.mode & 0o170000, 0o020000, `${path} is S_IFCHR`)
    assert.equal(stats.mode & 0o777, 0o666, `${path} mode is 0666`)
    assert.equal(stats.size, 0, `${path} reports POSIX device size 0`)
    const linkStats = await fs.lstat(path)
    assert.equal(linkStats.isSymbolicLink, false, path)
    assert.equal(linkStats.mode & 0o170000, 0o020000, path)
  }
})

test('devices: writes and appends are discarded before node:fs; reads follow the device behavior', async () => {
  const { root, fs } = fixture()
  const before = snapshot(root)
  for (const path of WORKER_DEVICE_PATHS) {
    await fs.writeFile(path, 'discarded')
    await fs.appendFile(path, 'discarded too')
    assert.equal(await fs.exists(path), true, path)
    assert.equal(fs.getAllPaths().includes(path), false, `${path} is not a mutable tree entry`)
  }
  // `/dev/null` is byte-for-byte the pre-G2-FIX-112 device: an empty read.
  assert.equal(await fs.readFile('/dev/null'), '')
  assert.equal(await fs.readFileBytes('/dev/null'), '')
  assert.equal((await fs.readFileBuffer('/dev/null')).length, 0)
  // The bounded window is shared by all three read surfaces.
  assert.equal((await fs.readFile('/dev/zero')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal(latin1FromBytes(await fs.readFileBytes('/dev/zero')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal((await fs.readFileBuffer('/dev/zero')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal(latin1FromBytes(await fs.readFileBytes('/dev/urandom')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal((await fs.readFileBuffer('/dev/urandom')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal(existsSync(join(root, 'dev')), false, 'the devices must not be created in the VFS')
  assert.deepEqual(snapshot(root), before)
})

test('devices: /dev/zero is all zero bytes and /dev/urandom reads differ', async () => {
  const { fs } = fixture()
  const zero = await fs.readFileBuffer('/dev/zero')
  assert.equal(zero.length, WORKER_DEVICE_READ_BYTES)
  assert.equal(zero[0], 0)
  assert.equal(zero[zero.length - 1], 0)
  assert.equal(zero.every(byte => byte === 0), true, '/dev/zero must be all zero bytes')
  const first = latin1FromBytes(await fs.readFileBytes('/dev/urandom'))
  const second = latin1FromBytes(await fs.readFileBytes('/dev/urandom'))
  assert.equal(first.length, WORKER_DEVICE_READ_BYTES)
  assert.equal(second.length, WORKER_DEVICE_READ_BYTES)
  // Equality is astronomically unlikely but not the assertion that matters;
  // the length and the bounded window are the contract.
  assert.notEqual(first, second)
})

test('devices: /dev/urandom fails loud without a crypto source', async () => {
  const { fs } = fixture()
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto')
  Object.defineProperty(globalThis, 'crypto', { value: undefined, configurable: true })
  try {
    for (const read of [
      () => fs.readFile('/dev/urandom'),
      () => fs.readFileBytes('/dev/urandom'),
      () => fs.readFileBuffer('/dev/urandom'),
    ]) {
      await assert.rejects(read, (error: unknown) => {
        const coded = error as { code?: string; message?: string }
        return coded.code === 'ENOSYS' && /crypto\.getRandomValues/u.test(coded.message ?? '')
      })
    }
  } finally {
    if (descriptor === undefined) delete (globalThis as { crypto?: unknown }).crypto
    else Object.defineProperty(globalThis, 'crypto', descriptor)
  }
  // The rest of the device set is unaffected by the missing crypto source.
  assert.equal(await fs.readFile('/dev/null'), '')
  assert.equal((await fs.readFileBuffer('/dev/zero')).length, WORKER_DEVICE_READ_BYTES)
})

test('devices: the adapter never reaches node:fs for a device', async () => {
  // A root that does not exist: any `node:fs` call would fail ENOENT, so these
  // operations succeeding is direct evidence that the device is answered by
  // the adapter before `node:fs` (and therefore before the VFS sink).
  const root = join(tmpdir(), `pdsh-shell-device-absent-${String(process.pid)}-${String(Date.now())}`)
  assert.equal(existsSync(root), false)
  const fs = new VfsFileSystem({ root })
  for (const path of WORKER_DEVICE_PATHS) {
    await fs.writeFile(path, 'discarded')
    await fs.appendFile(path, 'discarded')
    assert.equal(await fs.exists(path), true, path)
    assert.equal((await fs.stat(path)).mode & 0o170000, 0o020000, path)
  }
  assert.equal(await fs.readFile('/dev/null'), '')
  assert.equal((await fs.readFileBuffer('/dev/zero')).length, WORKER_DEVICE_READ_BYTES)
  assert.equal(latin1FromBytes(await fs.readFileBytes('/dev/urandom')).length, WORKER_DEVICE_READ_BYTES)
  // The path outside the set still goes through node:fs and fails loud.
  await assert.rejects(fs.writeFile('/dsh/workspace/out.txt', 'x'), (error: unknown) => (error as { code?: string }).code === 'ENOENT')
  assert.equal(existsSync(root), false)
})

test('shell: >, >>, 2>, 2>&1, <, &> and &>> against /dev/null all succeed silently', async () => {
  const { root, shell } = fixture()
  const before = snapshot(root)
  const scripts = [
    'echo discarded > /dev/null; echo ok',
    'echo discarded >> /dev/null; echo ok',
    'ls /dsh/workspace/missing 2>/dev/null; echo ok',
    '{ echo out; echo err >&2; } > /dev/null 2>&1; echo ok',
    'cat < /dev/null; echo ok',
    '{ echo out; echo err >&2; } &> /dev/null; echo ok',
    'echo out &>> /dev/null; echo ok',
  ]
  for (const script of scripts) {
    const result = await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, `${script} -> ${result.stderr}`)
    assert.equal(result.stdout, 'ok\n', script)
    assert.equal(result.stderr, '', script)
  }
  // A command opening the device itself (not a shell redirection) is the same
  // adapter path: after its same-file check, `cp` reaches the device `cp` branch.
  const copied = await shell.run(['bash', '-c', 'cp a.txt /dev/null; echo ok'], { cwd: '/dsh/workspace' })
  assert.equal(copied.exitCode, 0, copied.stderr)
  assert.equal(copied.stdout, 'ok\n')
  assert.equal(copied.stderr, '')
  assert.equal(existsSync(join(root, 'dev')), false)
  assert.deepEqual(snapshot(root), before)
})

test('shell: head -c reads /dev/zero and /dev/urandom instead of ENOENT', async () => {
  const { root, fs, shell } = fixture()
  const before = snapshot(root)
  const zero = await shell.run(['bash', '-c', 'head -c 4 /dev/zero | wc -c'], { cwd: '/dsh/workspace' })
  assert.equal(zero.exitCode, 0, zero.stderr)
  assert.equal(zero.stdout, '4\n')
  assert.equal(zero.stderr, '')
  const random = await shell.run(['bash', '-c', 'head -c 8 /dev/urandom | wc -c'], { cwd: '/dsh/workspace' })
  assert.equal(random.exitCode, 0, random.stderr)
  assert.equal(random.stdout, '8\n')
  assert.equal(random.stderr, '')
  const again = await shell.run(['bash', '-c', 'head -c 8 /dev/urandom | wc -c'], { cwd: '/dsh/workspace' })
  assert.equal(again.exitCode, 0, again.stderr)
  assert.equal(again.stdout, '8\n')
  // The direct buffer is the byte-level assertion: four zero bytes, not just a
  // length that a NUL-stripping text path could also satisfy.
  const four = (await fs.readFileBuffer('/dev/zero')).subarray(0, 4)
  assert.deepEqual([...four], [0, 0, 0, 0])
  assert.equal(existsSync(join(root, 'dev')), false)
  assert.deepEqual(snapshot(root), before)
})

test('shell: cp from a device stores the bounded window; cp to a device discards', async () => {
  const { root, fs, shell } = fixture()
  const before = snapshot(root)
  const fromZero = await shell.run(['bash', '-c',
    'cp /dev/zero zero.bin; stat -c %s zero.bin'], { cwd: '/dsh/workspace' })
  assert.equal(fromZero.exitCode, 0, fromZero.stderr)
  assert.equal(fromZero.stdout, `${String(WORKER_DEVICE_READ_BYTES)}\n`)
  assert.equal(readFileSync(join(root, 'dsh/workspace/zero.bin')).length, WORKER_DEVICE_READ_BYTES)
  await fs.cp('/dev/urandom', '/dsh/workspace/random.bin')
  assert.equal(readFileSync(join(root, 'dsh/workspace/random.bin')).length, WORKER_DEVICE_READ_BYTES)
  const toZero = await shell.run(['bash', '-c', 'cp a.txt /dev/zero; cp a.txt /dev/urandom; echo ok'], { cwd: '/dsh/workspace' })
  assert.equal(toZero.exitCode, 0, toZero.stderr)
  assert.equal(toZero.stdout, 'ok\n')
  assert.equal(toZero.stderr, '')
  assert.equal(existsSync(join(root, 'dev')), false)
  // Only the two explicit `cp` destinations changed; no device appeared.
  const after = snapshot(root)
  assert.deepEqual(Object.keys(after).sort(), [...Object.keys(before), 'dsh/workspace/random.bin', 'dsh/workspace/zero.bin'].sort())
})

test('shell: file-type checks see character devices, not regular files', async () => {
  const { fs, shell } = fixture()
  const result = await shell.run(['bash', '-c',
    '[ -e /dev/null ] && [ -c /dev/null ] && [ ! -f /dev/null ] && [ ! -d /dev/null ] && echo null; '
    + '[ -e /dev/zero ] && [ -c /dev/zero ] && [ ! -f /dev/zero ] && [ ! -d /dev/zero ] && echo zero; '
    + '[ -e /dev/urandom ] && [ -c /dev/urandom ] && [ ! -f /dev/urandom ] && [ ! -d /dev/urandom ] && echo urandom'],
    { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'null\nzero\nurandom\n')
  assert.equal(result.stderr, '')
  for (const path of WORKER_DEVICE_PATHS) assert.equal((await fs.stat(path)).isFile, false, path)
})

test('devices: a path outside the fixed set still fails loud and creates nothing', async () => {
  const { root, fs, shell } = fixture()
  await assert.rejects(fs.readFile('/dev/nonexistent'), (error: unknown) => (error as { code?: string }).code === 'ENOENT')
  assert.equal(await fs.exists('/dev/nonexistent'), false)
  const result = await shell.run(['bash', '-c', 'echo nope > /dev/nonexistent; echo unreachable'], { cwd: '/dsh/workspace' })
  assert.notEqual(result.exitCode, 0)
  assert.equal(result.stdout.includes('unreachable'), false)
  assert.match(result.stderr, /ENOENT|No such file/)
  assert.equal(existsSync(join(root, 'dev/nonexistent')), false)
  assert.equal(existsSync(join(root, 'dev')), false)
})

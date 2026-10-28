// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { HotInstance, HotInstancePool, EXIT_MEMORY_LIMIT, EXIT_TRAP } from './hot-instance.ts'
import { MemoryWasiVfs } from './memory-wasi-vfs.ts'
import { VfsProxyError, WasiMemoryCeilingError } from './errors.ts'
import { WasiPreview1 } from './wasi-preview1.ts'
import type { WasiVfs } from './types.ts'

const moduleBytes = readFileSync(new URL('./testdata/fd-echo.wasm', import.meta.url))
const wasmModule = new WebAssembly.Module(moduleBytes)
const decoder = new TextDecoder()
const preopens = [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }] as const

function fixture(): { hot: HotInstance; vfs: MemoryWasiVfs } {
  const vfs = new MemoryWasiVfs({ clock: () => 1_700_000_000_000 })
  vfs.seedFile('/dsh/workspace/in.txt', 'hello\n')
  vfs.seedFile('/dsh/workspace/second.txt', 'again\n')
  const hot = new HotInstance({ program: 'fd-echo', module: wasmModule, vfs, preopens })
  return { hot, vfs }
}

test('hot instance: fd_read/fd_write/path_open run through the test module', () => {
  const { hot, vfs } = fixture()
  let stdout = ''
  let stderr = ''
  const result = hot.run({
    argv: ['in.txt', 'out.txt'],
    onStdout: chunk => { stdout += decoder.decode(chunk) },
    onStderr: chunk => { stderr += decoder.decode(chunk) },
  })
  assert.equal(result.exitCode, 0)
  assert.equal(result.instancesCreated, 1)
  assert.equal(stderr, '')
  assert.equal(stdout, '[in.txt] hello\n\n')
  assert.equal(decoder.decode(vfs.readFile('/dsh/workspace/out.txt')), 'echo:hello\n')
  assert.ok(result.memoryPeakBytes >= 1024)
})

test('hot instance: every command gets a fresh instance, cwd/env/fds do not leak', () => {
  const { hot, vfs } = fixture()
  const first = hot.run({ argv: ['in.txt', 'first.txt'] })
  assert.equal(first.exitCode, 0)
  const second = hot.run({ argv: ['second.txt', 'second.out'] })
  assert.equal(second.exitCode, 0)
  assert.equal(second.instancesCreated, 2)
  assert.equal(decoder.decode(vfs.readFile('/dsh/workspace/second.out')), 'echo:again\n')

  const missing = hot.run({ argv: ['absent.txt', 'nope.txt'] })
  assert.equal(missing.exitCode, 4)
  assert.equal(vfs.peek('/dsh/workspace/nope.txt'), undefined)

  // Reset drops the warm memory snapshot; the compiled module stays usable.
  hot.reset()
  const diagnostics = hot.diagnostics()
  assert.equal(diagnostics.resets, 1)
  assert.equal(diagnostics.memoryBytes, 0)
  assert.equal(hot.run({ argv: ['in.txt', 'third.txt'] }).exitCode, 0)
})

test('hot instance: a module that grows past the ceiling exits 137 and resets', () => {
  const { hot, vfs } = fixture()
  const limited = new HotInstance({
    program: 'fd-echo',
    module: wasmModule,
    vfs,
    preopens,
    memoryLimitBytes: 1024 * 1024,
  })
  let stderr = ''
  const result = limited.run({ argv: ['grow', 'out.txt'], onStderr: chunk => { stderr += decoder.decode(chunk) } })
  assert.equal(result.exitCode, EXIT_MEMORY_LIMIT)
  assert.equal(result.memoryExceeded, true)
  assert.ok(result.memoryPeakBytes > 1024 * 1024)
  assert.match(stderr, /memory ceiling/)
  assert.equal(limited.diagnostics().memoryBytes, 0)
  assert.equal(hot.diagnostics().instancesCreated, 0)
  // The same warm worker still serves a normal command afterwards.
  assert.equal(limited.run({ argv: ['in.txt', 'after.txt'] }).exitCode, 0)
})

test('hot instance: the initial memory of a defining module is checked too', () => {
  const { vfs } = fixture()
  const limited = new HotInstance({
    program: 'fd-echo',
    module: wasmModule,
    vfs,
    preopens,
    memoryLimitBytes: 65_536,
  })
  const result = limited.run({ argv: ['in.txt', 'out.txt'] })
  assert.equal(result.exitCode, EXIT_MEMORY_LIMIT)
  assert.equal(result.memoryExceeded, true)
})

test('hot instance: a module without _start is reported as a trap', () => {
  const empty = new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]))
  const hot = new HotInstance({ program: 'empty', module: empty })
  let stderr = ''
  const result = hot.run({ onStderr: chunk => { stderr += decoder.decode(chunk) } })
  assert.equal(result.exitCode, EXIT_TRAP)
  assert.match(stderr, /memory/)
})

test('wasi host: an imported memory over the ceiling is rejected before start', () => {
  const wasi = new WasiPreview1({
    args: [],
    preopens: [],
    vfs: new MemoryWasiVfs(),
    memoryLimitBytes: 65_536,
  })
  assert.throws(
    () => wasi.setMemory(new WebAssembly.Memory({ initial: 2 })),
    (error: unknown) => error instanceof WasiMemoryCeilingError,
  )
})

test('wasi host: a VFS EFBIG refusal also reaches the command stderr', () => {
  const vfs = new MemoryWasiVfs({ clock: () => 1_700_000_000_000 })
  vfs.seedFile('/dsh/workspace/in.txt', 'hello\n')
  const refusal = 'EFBIG: File too large: /dsh/workspace/out.txt would be 16777216 bytes; '
    + 'a file is limited to 15728640 bytes (15 MiB)'
  const refusing = Object.assign(Object.create(vfs) as WasiVfs, {
    write(): number {
      throw new VfsProxyError('EFBIG', refusal, '/dsh/workspace/out.txt')
    },
  })
  const hot = new HotInstance({ program: 'fd-echo', module: wasmModule, vfs: refusing, preopens })
  let stderr = ''
  const result = hot.run({ argv: ['in.txt', 'out.txt'], onStderr: chunk => { stderr += decoder.decode(chunk) } })
  // fd-echo turns a failed fd_write into exit 6 and its own line; the host's
  // errno cannot carry the limit, so the refusal text is mirrored on stderr.
  assert.notEqual(result.exitCode, 0)
  assert.match(stderr, /EFBIG: File too large/)
  assert.match(stderr, /15728640 bytes \(15 MiB\)/)
})

test('hot instance pool: one warm instance per tool, release resets, terminate drops it', () => {
  const vfs = new MemoryWasiVfs({ clock: () => 1_700_000_000_000 })
  vfs.seedFile('/dsh/workspace/in.txt', 'hello\n')
  let created = 0
  const pool = new HotInstancePool({
    create: program => {
      created += 1
      return new HotInstance({ program, module: wasmModule, vfs, preopens })
    },
  })
  const first = pool.acquire('fd-echo')
  assert.equal(pool.acquire('fd-echo'), first)
  assert.equal(created, 1)
  assert.equal(first.run({ argv: ['in.txt', 'pool.txt'] }).exitCode, 0)
  pool.release('fd-echo')
  assert.equal(pool.get('fd-echo')?.diagnostics().resets, 1)
  assert.equal(pool.diagnostics().length, 1)
  pool.terminate('fd-echo')
  assert.equal(pool.get('fd-echo'), undefined)
  assert.equal(pool.diagnostics().length, 0)
  assert.equal(created, 1)
})

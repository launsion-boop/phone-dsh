// SPDX-License-Identifier: MIT
// G2-FIX-47: syscall-surface checklist for the standard-library cleanup path.
//
// `tempfile` (mkdtemp/rmdir/unlink/rename/open) and `shutil.rmtree`
// (readdir/stat/unlink/rmdir) only need a small set of WASI preview1 `path_*`
// calls, but a missing or wrong one surfaces as a Python traceback deep inside
// `tempfile.py` rather than as a toolbox failure (G2-D06: cleanup died with
// EIO). This checklist pins the import surface and each operation's errno at
// the WASI host boundary, so a future gap in this class fails here, loudly,
// instead of in a model scenario.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MemoryWasiVfs } from '../wasi-toolbox/src/memory-wasi-vfs.ts'
import { VfsProxyError } from '../wasi-toolbox/src/errors.ts'
import { WasiPreview1 } from '../wasi-toolbox/src/wasi-preview1.ts'
import type { GuestPreopen } from '../wasi-toolbox/src/types.ts'
import { WASI_ERRNO } from '../wasi-toolbox/src/wasi-errno.ts'

const PREOPEN: GuestPreopen = { guestPath: '/workspace', hostPath: '/dsh/workspace' }
const PREOPEN_FD = 3
const PATH_POINTER = 4096
const SECOND_POINTER = 8192

interface Host {
  readonly host: WasiPreview1
  readonly vfs: MemoryWasiVfs
  /** Call one WASI import with raw numeric arguments. */
  call(name: string, ...args: number[]): number
  /** Copy a guest path into linear memory and return its `(pointer, length)`. */
  write(value: string, pointer: number): { readonly pointer: number; readonly length: number }
  /** Call a `path_*` import with one path under the preopen descriptor. */
  path(name: string, value: string): number
}

/** A WASI host over an in-memory tree whose imports can be called directly. */
function fixture(): Host {
  const vfs = new MemoryWasiVfs()
  vfs.seedDirectory('/dsh/workspace')
  const memory = new WebAssembly.Memory({ initial: 1 })
  const host = new WasiPreview1({ args: [], preopens: [PREOPEN], vfs })
  host.setMemory(memory)
  const table = host.imports.wasi_snapshot_preview1 as unknown as Record<string, (...args: number[]) => number>
  const write = (value: string, pointer: number): { pointer: number; length: number } => {
    const bytes = new TextEncoder().encode(value)
    new Uint8Array(memory.buffer).set(bytes, pointer)
    return { pointer, length: bytes.byteLength }
  }
  return {
    host,
    vfs,
    call(name, ...args) {
      return (table[name] as (...args: number[]) => number)(...args)
    },
    write,
    path(name, value) {
      const target = write(value, PATH_POINTER)
      return (table[name] as (...args: number[]) => number)(PREOPEN_FD, target.pointer, target.length)
    },
  }
}

function errnoOf(error: unknown): string | undefined {
  return error instanceof VfsProxyError ? error.code : undefined
}

test('wasi path syscalls: the tempfile/shutil import surface is implemented', () => {
  const { host } = fixture()
  const table = host.imports.wasi_snapshot_preview1 as Record<string, unknown>
  for (const name of [
    'path_create_directory',
    'path_filestat_get',
    'path_open',
    'path_remove_directory',
    'path_unlink_file',
    'path_rename',
  ]) {
    assert.equal(typeof table[name], 'function', `WASI host is missing ${name}`)
  }
})

test('wasi path syscalls: path_remove_directory is POSIX over the preopen', () => {
  const { vfs, path } = fixture()
  vfs.seedDirectory('/dsh/workspace/empty')
  assert.equal(path('path_remove_directory', '/workspace/empty'), WASI_ERRNO.SUCCESS)
  assert.throws(() => vfs.stat('/dsh/workspace/empty'), (error: unknown) => errnoOf(error) === 'ENOENT')

  vfs.seedDirectory('/dsh/workspace/full/sub')
  assert.equal(path('path_remove_directory', '/workspace/full'), WASI_ERRNO.NOTEMPTY)
  assert.equal(vfs.stat('/dsh/workspace/full/sub').kind, 'directory')

  vfs.seedFile('/dsh/workspace/plain.txt', 'x')
  assert.equal(path('path_remove_directory', '/workspace/plain.txt'), WASI_ERRNO.NOTDIR)
  assert.equal(path('path_remove_directory', '/workspace/absent'), WASI_ERRNO.NOENT)

  // A path outside every preopen never reaches the VFS.
  assert.equal(path('path_remove_directory', '/etc/passwd'), WASI_ERRNO.NOTCAPABLE)
  assert.equal(vfs.stat('/dsh/workspace/plain.txt').kind, 'file')
})

test('wasi path syscalls: path_unlink_file removes a file and refuses a directory', () => {
  const { vfs, path } = fixture()
  vfs.seedFile('/dsh/workspace/file.txt', 'x')
  vfs.seedDirectory('/dsh/workspace/dir')

  // `shutil.rmtree` unlinks each file before it removes the directory.
  assert.equal(path('path_unlink_file', '/workspace/file.txt'), WASI_ERRNO.SUCCESS)
  assert.throws(() => vfs.stat('/dsh/workspace/file.txt'), (error: unknown) => errnoOf(error) === 'ENOENT')
  assert.equal(path('path_unlink_file', '/workspace/dir'), WASI_ERRNO.ISDIR)
  assert.equal(vfs.stat('/dsh/workspace/dir').kind, 'directory')
  assert.equal(path('path_unlink_file', '/workspace/absent'), WASI_ERRNO.NOENT)
})

test('wasi path syscalls: mkdtemp/rename/rmdir sequence keeps parent entries correct', () => {
  const { vfs, call, write, path } = fixture()
  assert.equal(path('path_create_directory', '/workspace/tmpdir'), WASI_ERRNO.SUCCESS)
  assert.equal(vfs.stat('/dsh/workspace/tmpdir').kind, 'directory')
  assert.equal(path('path_create_directory', '/workspace/tmpdir'), WASI_ERRNO.EXIST)

  vfs.seedFile('/dsh/workspace/tmpdir/old.txt', 'payload')
  const from = write('/workspace/tmpdir/old.txt', PATH_POINTER)
  const to = write('/workspace/tmpdir/new.txt', SECOND_POINTER)
  assert.equal(
    call('path_rename', PREOPEN_FD, from.pointer, from.length, PREOPEN_FD, to.pointer, to.length),
    WASI_ERRNO.SUCCESS,
  )
  assert.throws(() => vfs.stat('/dsh/workspace/tmpdir/old.txt'), (error: unknown) => errnoOf(error) === 'ENOENT')
  assert.equal(new TextDecoder().decode(vfs.readFile('/dsh/workspace/tmpdir/new.txt')), 'payload')

  assert.equal(path('path_unlink_file', '/workspace/tmpdir/new.txt'), WASI_ERRNO.SUCCESS)
  assert.equal(path('path_remove_directory', '/workspace/tmpdir'), WASI_ERRNO.SUCCESS)
  assert.deepEqual(vfs.readdir('/dsh/workspace'), [])
})

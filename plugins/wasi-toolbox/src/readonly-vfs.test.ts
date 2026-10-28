// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MemoryWasiVfs } from './memory-wasi-vfs.ts'
import { OverlayWasiVfs, ReadOnlyMemoryVfs } from './readonly-vfs.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

function fixture(): { overlay: OverlayWasiVfs; writable: MemoryWasiVfs; layer: ReadOnlyMemoryVfs } {
  const writable = new MemoryWasiVfs({ clock: () => 1_700_000_000_000 })
  writable.seedFile('/dsh/home/note.txt', 'note')
  writable.seedFile('/dsh/workspace/in.txt', 'hello')
  const layer = ReadOnlyMemoryVfs.fromTree('/dsh/lib', [
    { path: 'os.py', data: encoder.encode('import sys\n') },
    { path: 'json/__init__.py', data: encoder.encode('json\n') },
  ])
  return { writable, layer, overlay: new OverlayWasiVfs({ layers: [layer], writable }) }
}

test('read-only stdlib layer: reads and merged readdir come from the layer', () => {
  const { overlay, layer } = fixture()
  const stat = overlay.stat('/dsh/lib/os.py')
  assert.equal(stat.kind, 'file')
  assert.equal(stat.size, 11)
  assert.equal(decoder.decode(overlay.read('/dsh/lib/os.py', 0, 6)), 'import')
  assert.equal(decoder.decode(layer.peek('/dsh/lib/json/__init__.py')), 'json\n')

  assert.deepEqual(overlay.readdir('/dsh/lib').map(entry => [entry.name, entry.kind]), [
    ['json', 'directory'],
    ['os.py', 'file'],
  ])
  assert.deepEqual(overlay.readdir('/dsh').map(entry => entry.name), ['home', 'lib', 'workspace'])
  assert.deepEqual(overlay.readdir('/dsh/home').map(entry => entry.name), ['note.txt'])
})

test('read-only stdlib layer: every mutation answers EROFS', () => {
  const { overlay, writable } = fixture()
  assert.throws(() => overlay.write('/dsh/lib/os.py', 0, encoder.encode('x'), { append: false, create: false }), /EROFS/)
  assert.throws(() => overlay.truncate('/dsh/lib/os.py', 0), /EROFS/)
  assert.throws(() => overlay.mkdir('/dsh/lib/extra'), /EROFS/)
  assert.throws(() => overlay.unlink('/dsh/lib/os.py', { directory: false }), /EROFS/)
  assert.throws(() => overlay.rename('/dsh/lib/os.py', '/dsh/home/os.py'), /EROFS/)
  assert.throws(() => overlay.rename('/dsh/home/note.txt', '/dsh/lib/note.txt'), /EROFS/)
  assert.throws(
    () => overlay.open('/dsh/lib/os.py', { create: false, truncate: true, exclusive: false, directory: false }),
    /EROFS/,
  )
  assert.equal(decoder.decode(writable.readFile('/dsh/home/note.txt')), 'note')
})

test('read-only stdlib layer: the writable tree still accepts writes', () => {
  const { overlay, writable } = fixture()
  assert.equal(
    overlay.write('/dsh/home/new.txt', 0, encoder.encode('written'), { append: false, create: true }),
    7,
  )
  assert.equal(decoder.decode(writable.readFile('/dsh/home/new.txt')), 'written')
  overlay.mkdir('/dsh/home/dir')
  overlay.rename('/dsh/home/new.txt', '/dsh/home/dir/moved.txt')
  assert.equal(decoder.decode(overlay.read('/dsh/home/dir/moved.txt', 0, 7)), 'written')
  overlay.unlink('/dsh/home/dir/moved.txt', { directory: false })
  overlay.sync()
})

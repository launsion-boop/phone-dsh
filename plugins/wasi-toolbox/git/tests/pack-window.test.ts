// SPDX-License-Identifier: MIT
/**
 * Pack-reader regressions for the pure-JavaScript zlib codec: a compressed
 * object larger than the pack reader's first read window must grow the window
 * until the stream ends, and an empty blob must not be mistaken for a
 * two-to-six-byte zlib prefix (fflate answers an empty array for those).
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pack-window
 */
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { NodeGitFs } from '../fs.ts'
import { ObjectDatabase } from '../objects.ts'
import { buildPack } from '../pack.ts'
import { parsePack } from '../remote.ts'
import { tempDirectory } from './helpers.ts'

/** Deterministic pseudo-random bytes (a cheap LCG) so DEFLATE cannot shrink them. */
function incompressible(length: number): Uint8Array {
  const bytes = new Uint8Array(length)
  let state = 0x12345678
  for (let index = 0; index < length; index += 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0
    bytes[index] = state >>> 24
  }
  return bytes
}

test('a pack object larger than the first read window is inflated by growing it', async () => {
  const temp = tempDirectory()
  try {
    const fs = new NodeGitFs()
    const objectDir = join(temp.path, 'objects')
    mkdirSync(objectDir, { recursive: true })
    // 512 KiB of high-entropy data compresses to ~512 KiB, well past the
    // reader's initial 64 KiB window.
    const payload = incompressible(512 * 1024)
    const pack = buildPack([{ type: 'blob', data: payload }])
    const packDir = join(objectDir, 'pack')
    mkdirSync(packDir)
    writeFileSync(join(packDir, `pack-${pack.id}.pack`), pack.pack)
    writeFileSync(join(packDir, `pack-${pack.id}.idx`), pack.index)
    const database = new ObjectDatabase(fs, { primary: objectDir, alternates: [] })
    const object = await database.read(pack.ids[0] as string)
    assert.equal(object.type, 'blob')
    assert.deepEqual(object.data, payload)
  } finally {
    temp.cleanup()
  }
})

test('an empty blob in a received pack keeps the following object offsets aligned', async () => {
  const pack = buildPack([
    { type: 'blob', data: new Uint8Array(0) },
    { type: 'blob', data: new TextEncoder().encode('after the empty blob\n') },
  ])
  const parsed = await parsePack(pack.pack, async () => undefined)
  assert.equal(parsed.packSha, pack.id)
  assert.equal(parsed.objects.length, 2)
  assert.equal(parsed.objects[0]?.data.byteLength, 0)
  assert.equal(new TextDecoder().decode(parsed.objects[1]?.data), 'after the empty blob\n')
})

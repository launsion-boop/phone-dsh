// SPDX-License-Identifier: MIT
/**
 * Pack-format unit tests: the delta applier, the pack/index writer and the
 * reader that a workspace repository cloned on a host relies on. The golden
 * suite covers packs the system git produced; these tests cover the writer the
 * Worker uses for `push` and for storing a fetched pack.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pack.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { NodeGitFs, encodeText } from '../fs.ts'
import { ObjectDatabase } from '../objects.ts'
import { applyDelta, buildPack, buildPackIndex, readPackIndex } from '../pack.ts'
import { parsePack } from '../remote.ts'
import { tempDirectory } from './helpers.ts'

test('applyDelta copies and inserts', () => {
  const base = encodeText('hello')
  // source size 5, target size 6, copy(0, 5), insert "!"
  const delta = Uint8Array.from([0x05, 0x06, 0x90, 0x05, 0x01, 0x21])
  assert.equal(Buffer.from(applyDelta(base, delta)).toString(), 'hello!')
  // A plain insert-only delta (source size 0) builds a file from nothing.
  const insertOnly = Uint8Array.from([0x00, 0x03, 0x03, 0x61, 0x62, 0x63])
  assert.equal(Buffer.from(applyDelta(new Uint8Array(0), insertOnly)).toString(), 'abc')
})

test('buildPack / buildPackIndex round-trip through the reader', async () => {
  const temp = tempDirectory()
  try {
    const fs = new NodeGitFs()
    const objectDir = join(temp.path, 'objects')
    mkdirSync(objectDir, { recursive: true })
    const objects = [
      { type: 'blob' as const, data: encodeText('alpha\nbeta\n') },
      { type: 'tree' as const, data: Uint8Array.from([0x31, 0x30, 0x30, 0x36, 0x34, 0x34, 0x20, 0x61, 0x00, ...new Array<number>(20).fill(0)]) },
      { type: 'commit' as const, data: encodeText('tree 0000000000000000000000000000000000000000\n\nbase\n') },
    ]
    const pack = buildPack(objects)
    const packDir = join(objectDir, 'pack')
    mkdirSync(packDir)
    writeFileSync(join(packDir, `pack-${pack.id}.pack`), pack.pack)
    writeFileSync(join(packDir, `pack-${pack.id}.idx`), pack.index)
    const index = await readPackIndex(fs, join(packDir, `pack-${pack.id}.idx`))
    assert.equal(index.count, 3)
    const database = new ObjectDatabase(fs, { primary: objectDir, alternates: [] })
    for (const id of pack.ids) {
      assert.equal(await database.has(id), true)
      const object = await database.read(id)
      assert.equal(object.data instanceof Uint8Array, true)
    }
    const blob = await database.read(pack.ids[0] as string)
    assert.equal(Buffer.from(blob.data).toString(), 'alpha\nbeta\n')
    // The same pack parses standalone (the fetch/clone importer path).
    const parsed = await parsePack(pack.pack, async () => undefined)
    assert.equal(parsed.packSha, pack.id)
    assert.equal(parsed.objects.length, 3)
    assert.deepEqual(parsed.objects.map(object => object.type), [3, 2, 1])
    // The written index is accepted by the system git's own tooling when the
    // pack layout is exercised end to end in the golden suite.
    const indexBytes = readFileSync(join(packDir, `pack-${pack.id}.idx`))
    assert.equal(indexBytes.subarray(0, 4).toString('hex'), 'ff744f63')
  } finally {
    temp.cleanup()
  }
})

test('an empty pack index has no entries', () => {
  const index = buildPackIndex([], '0000000000000000000000000000000000000000')
  assert.equal(index.byteLength, 8 + 256 * 4 + 40)
})

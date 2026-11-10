// SPDX-License-Identifier: MIT
/**
 * Oracle test for the one-pass pack inflater.
 *
 * Before this change a pack object's DEFLATE end was found by binary-searching
 * the rest of the pack and running a full `inflate` at every step (about
 * log2(pack size) ≈ 26 passes per object for a phone-sized 64 MiB pack). The
 * replacement asks `fflate`'s streaming decoder where the stream ended.
 *
 * This suite keeps the old binary-search implementation verbatim as an oracle
 * and runs it against real packs produced by the system git: the
 * `git gc --aggressive` pack (ofs-delta, deep chains), an explicit ref-delta
 * pack, an explicit ofs-delta pack and a thin pack whose ref-delta base lives
 * outside the pack (the `readExternal` path used by an incremental fetch).
 * Every raw stream must decode to the same bytes and report the same consumed
 * length, and `parsePack` must produce the same metadata for every object.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pack-inflate
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { inflateWithConsumed } from '../compress.ts'
import { NodeGitFs } from '../fs.ts'
import { ObjectDatabase } from '../objects.ts'
import { crc32Of, sha1Hex } from '../pack.ts'
import { parsePack } from '../remote.ts'
import type { ParsePackStats } from '../remote.ts'
import { oracleInflateObject, oracleParsePack } from './pack-oracle.ts'
import type { OracleObject } from './pack-oracle.ts'
import type { PackedObject } from '../pack.ts'
import {
  HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT


interface RawStream {
  readonly offset: number
  readonly type: number
  readonly consumed: number
  readonly baseOid?: string
}

const TYPE_TEXT: Readonly<Record<number, 'commit' | 'tree' | 'blob' | 'tag'>> = {
  1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag',
}

function readUint32(buffer: Uint8Array, offset: number): number {
  return (((buffer[offset] as number) << 24) | ((buffer[offset + 1] as number) << 16)
    | ((buffer[offset + 2] as number) << 8) | (buffer[offset + 3] as number)) >>> 0
}

/**
 * Walk every raw DEFLATE stream in sequential pack order and compare the new
 * consumed count with the oracle at each one.
 */
function verifyRawStreams(pack: Uint8Array): RawStream[] {
  const count = readUint32(pack, 8)
  const streams: RawStream[] = []
  let offset = 12
  for (let index = 0; index < count; index += 1) {
    let position = offset
    let byte = pack[position++] as number
    const type = (byte >> 4) & 0x07
    let size = byte & 0x0f
    let shift = 4
    while ((byte & 0x80) !== 0) {
      byte = pack[position++] as number
      size += (byte & 0x7f) * 2 ** shift
      shift += 7
    }
    let baseOid: string | undefined
    if (type === 6) {
      let current = pack[position++] as number
      while ((current & 0x80) !== 0) current = pack[position++] as number
    } else if (type === 7) {
      baseOid = Buffer.from(pack.subarray(position, position + 20)).toString('hex')
      position += 20
    }
    const oracle = oracleInflateObject(pack, position, size)
    const fresh = inflateWithConsumed(pack.subarray(position))
    assert.deepEqual(fresh.data, oracle.data, `stream ${index} (type ${type}) decoded differently`)
    assert.equal(fresh.consumed, oracle.length, `stream ${index} (type ${type}) consumed length differs`)
    streams.push({ offset: position, type, consumed: fresh.consumed, ...baseOid === undefined ? {} : { baseOid } })
    offset = position + fresh.consumed
  }
  assert.equal(offset, pack.byteLength - 20, 'the raw walk must stop exactly at the pack trailer')
  assert.equal(streams.length, count)
  return streams
}

/** Compare the new metadata parser with the old full-content parser. */
async function verifyParse(
  pack: Uint8Array,
  readExternal: (oid: string) => Promise<PackedObject | undefined>,
  cacheLimitBytes?: number,
): Promise<{ oids: string[]; stats: ParsePackStats }> {
  const oldObjects = await oracleParsePack(pack, readExternal)
  const fresh = await parsePack(pack, readExternal, cacheLimitBytes)
  assert.equal(fresh.objects.length, oldObjects.length)
  for (const [index, object] of fresh.objects.entries()) {
    const oracle = oldObjects[index] as OracleObject
    const text = TYPE_TEXT[oracle.type] as 'commit' | 'tree' | 'blob' | 'tag'
    assert.equal(object.offset, oracle.offset, `object ${index} offset`)
    assert.equal(object.end, oracle.end, `object ${index} end`)
    assert.equal(object.type, oracle.type, `object ${index} type`)
    assert.equal(
      object.oid,
      sha1Hex(new TextEncoder().encode(`${text} ${oracle.data.byteLength}\0`), oracle.data),
      `object ${index} oid`,
    )
    assert.equal(object.crc, crc32Of(pack.subarray(oracle.offset, oracle.end)), `object ${index} crc`)
  }
  return { oids: fresh.objects.map(object => object.oid), stats: fresh.stats }
}

/** Deterministic pseudo-random bytes so DEFLATE cannot shrink a large blob. */
function incompressible(length: number, seed: number): Uint8Array {
  const bytes = new Uint8Array(length)
  let state = seed >>> 0
  for (let index = 0; index < length; index += 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0
    bytes[index] = state >>> 24
  }
  return bytes
}

test('one-pass inflate matches the binary-search oracle on real git packs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const git = (args: readonly string[], stdin?: Buffer): CommandResult => systemGit(args, repository, env, stdin)
    // `pack-objects --stdout` can exceed Node's 1 MiB `spawnSync` default, so
    // read it with an explicit buffer rather than through the fixture helper.
    const packObjects = (args: readonly string[], stdin?: Buffer): Uint8Array => {
      const result = spawnSync('git', ['-c', 'gc.auto=0', '-c', 'maintenance.auto=0', ...args], {
        cwd: repository,
        env: { ...process.env, ...env },
        ...stdin === undefined ? {} : { input: stdin },
        maxBuffer: 256 * 1024 * 1024,
      })
      assert.equal(result.status, 0, result.stderr?.toString())
      assert.equal(result.error, undefined)
      return new Uint8Array(result.stdout)
    }
    assert.equal(git(['init', '-q', '-b', 'main']).code, 0)

    // A long, slightly changing text file gives the aggressive gc a deep
    // delta chain to build.
    const lines = Array.from({ length: 240 }, (_, index) => `line ${index} of a file used to exercise delta chains`)
    for (let revision = 0; revision < 45; revision += 1) {
      lines[revision % lines.length] = `line ${revision % lines.length} rewritten in revision ${revision}`
      writeFileSync(join(repository, 'history.txt'), `${lines.join('\n')}\n`)
      git(['add', '-A'])
      git(['commit', '-qm', `revision ${revision}`])
    }
    // Large incompressible blobs (two revisions, so one can delta the other),
    // an empty blob and a small binary blob.
    writeFileSync(join(repository, 'big.bin'), incompressible(2 * 1024 * 1024, 0x12345678))
    writeFileSync(join(repository, 'empty.bin'), new Uint8Array(0))
    writeFileSync(join(repository, 'nul.bin'), Uint8Array.from([0x00, 0x01, 0x02, 0xff, 0xfe, 0x00, 0x0a]))
    git(['add', '-A'])
    git(['commit', '-qm', 'large and binary objects'])
    const big = incompressible(2 * 1024 * 1024, 0x12345678)
    big[700_000] = 0x7f
    big[1_500_000] = 0x01
    writeFileSync(join(repository, 'big.bin'), big)
    git(['add', '-A'])
    git(['commit', '-qm', 'large object changed'])
    git(['branch', 'side'])
    git(['tag', '-a', '-m', 'annotated', 'release-v1'])

    assert.equal(git(['gc', '--aggressive', '--prune=now']).code, 0)
    const packDirectory = join(repository, '.git', 'objects', 'pack')
    const packNames = readdirSync(packDirectory).filter(name => name.endsWith('.pack'))
    assert.ok(packNames.length >= 1, 'git gc wrote a pack')
    const gcPack = readFileSync(join(packDirectory, packNames[0] as string))
    const gcStreams = verifyRawStreams(gcPack)
    assert.ok(gcStreams.some(stream => stream.type === 6), 'gc --aggressive pack has ofs-delta objects')
    assert.ok(gcStreams.some(stream => stream.consumed > 64 * 1024), 'a stream is larger than the old first read window')
    await verifyParse(gcPack, async () => undefined)

    // Explicit ref-delta and ofs-delta packs from the same repository.
    const refPack = packObjects(['pack-objects', '--stdout', '--all', '--window=50', '--depth=50'])
    assert.ok(refPack.byteLength > 0)
    const refStreams = verifyRawStreams(refPack)
    assert.ok(refStreams.some(stream => stream.type === 7), 'ref-delta pack has ref-delta objects')
    const refParsed = await verifyParse(refPack, async () => undefined)
    // A one-byte budget caches nothing, so every delta base is re-inflated by
    // offset. The metadata must be identical and the reported peak stays tiny.
    const evicted = await verifyParse(refPack, async () => undefined, 1)
    assert.deepEqual(evicted.oids, refParsed.oids)
    assert.ok(evicted.stats.cacheMisses > 0, 'a zero-sized cache must miss every delta base')
    assert.ok(evicted.stats.peakCacheBytes <= 1, `cache peak ${evicted.stats.peakCacheBytes} exceeds the one-byte test budget`)

    const ofsPack = packObjects(['pack-objects', '--stdout', '--all', '--window=50', '--depth=50', '--delta-base-offset'])
    const ofsStreams = verifyRawStreams(ofsPack)
    assert.ok(ofsStreams.some(stream => stream.type === 6), 'ofs-delta pack has ofs-delta objects')
    await verifyParse(ofsPack, async () => undefined)

    // A thin pack: the changed large blob is a ref-delta against the base
    // commit excluded from the pack, so only `readExternal` can resolve it.
    const thin = packObjects(['pack-objects', '--stdout', '--revs', '--thin', '--window=50', '--depth=50'], Buffer.from('HEAD\n^HEAD~1\n'))
    const thinStreams = verifyRawStreams(thin)
    assert.ok(thinStreams.some(stream => stream.type === 7), 'thin pack has a ref-delta object')
    const database = new ObjectDatabase(new NodeGitFs(), { primary: join(repository, '.git', 'objects'), alternates: [] })
    const readExternal = async (oid: string): Promise<PackedObject | undefined> => {
      try {
        return await database.read(oid)
      } catch {
        return undefined
      }
    }
    const thinParsed = await verifyParse(thin, readExternal)
    const packOids = new Set(thinParsed.oids)
    assert.ok(
      thinStreams.some(stream => stream.baseOid !== undefined && !packOids.has(stream.baseOid)),
      'the thin pack really references an object outside the pack',
    )
    // Both parsers had to read that external base, not just tolerate it.
    const externalCalls: string[] = []
    const tracked = async (oid: string): Promise<PackedObject | undefined> => {
      externalCalls.push(oid)
      return await readExternal(oid)
    }
    const resolved = await parsePack(thin, tracked)
    assert.ok(externalCalls.length > 0, 'parsePack called readExternal for the missing base')
    assert.equal(resolved.objects.length, thinStreams.length)
    const base = await readExternal(externalCalls[0] as string)
    assert.ok(base !== undefined)
  } finally {
    temp.cleanup()
  }
})

// SPDX-License-Identifier: MIT
/**
 * Performance and memory regression for `parsePack`.
 *
 * The fixture is a real pack written by the system git for 3000 blobs whose
 * decompressed size is larger than the delta-base cache. The old parser
 * binary-searched the pack remainder for every object (a full `inflate` per
 * halving) and kept every object in memory; the new parser decodes each
 * stream once and retains at most {@link PACK_DELTA_CACHE_BYTES}.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pack-performance
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { PACK_DELTA_CACHE_BYTES, parsePack } from '../remote.ts'
import { oracleParsePack } from './pack-oracle.ts'
import {
  HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory,
} from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT
const FILE_COUNT = 3000
const FILE_SIZE = 12 * 1024
const TOTAL_BYTES = FILE_COUNT * FILE_SIZE

/** Deterministic, poorly compressible file content (one LCG per seed). */
function payload(seed: number, length: number): Uint8Array {
  const bytes = new Uint8Array(length)
  let state = seed >>> 0
  for (let index = 0; index < length; index += 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0
    bytes[index] = state >>> 24
  }
  return bytes
}

test('parsePack decodes each object once and bounds its retained memory', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const git = (args: readonly string[]): ReturnType<typeof systemGit> => systemGit(args, repository, env)
    assert.equal(git(['init', '-q', '-b', 'main']).code, 0)
    for (let index = 0; index < FILE_COUNT; index += 1) {
      writeFileSync(join(repository, `file-${String(index).padStart(4, '0')}.bin`), payload(index + 1, FILE_SIZE))
    }
    assert.equal(git(['add', '-A']).code, 0)
    assert.equal(git(['commit', '-qm', `${FILE_COUNT} blobs`]).code, 0)
    const packed = spawnSync('git', ['-c', 'gc.auto=0', 'pack-objects', '--stdout', '--all', '--window=0', '--depth=0'], {
      cwd: repository,
      env: { ...process.env, ...env },
      maxBuffer: 256 * 1024 * 1024,
    })
    assert.equal(packed.status, 0, packed.stderr?.toString())
    assert.equal(packed.error, undefined)
    const pack = new Uint8Array(packed.stdout)
    assert.ok(pack.byteLength >= 10 * 1024 * 1024, `pack is ${pack.byteLength} bytes, expected at least 10 MiB`)

    const startedOld = performance.now()
    const oracleObjects = await oracleParsePack(pack, async () => undefined)
    const oldMilliseconds = performance.now() - startedOld

    const startedNew = performance.now()
    const fresh = await parsePack(pack, async () => undefined)
    const newMilliseconds = performance.now() - startedNew

    assert.equal(fresh.objects.length, oracleObjects.length)
    assert.ok(fresh.objects.length >= FILE_COUNT, `expected at least ${FILE_COUNT} objects, got ${fresh.objects.length}`)
    const oldByOffset = new Map(oracleObjects.map(object => [object.offset, object]))
    for (const object of fresh.objects) {
      const oracle = oldByOffset.get(object.offset)
      assert.ok(oracle !== undefined, `object at ${object.offset} is missing from the oracle`)
      assert.equal(object.end, oracle.end)
      assert.equal(object.type, oracle.type)
    }
    assert.ok(
      TOTAL_BYTES > PACK_DELTA_CACHE_BYTES,
      'the fixture must exceed the cache budget so eviction is exercised',
    )
    assert.ok(
      fresh.stats.peakCacheBytes <= PACK_DELTA_CACHE_BYTES,
      `retained cache ${fresh.stats.peakCacheBytes} exceeds the ${PACK_DELTA_CACHE_BYTES} byte budget`,
    )
    assert.ok(
      fresh.stats.peakCacheBytes > 16 * 1024 * 1024,
      `the cache should actually fill before evicting, peaked at ${fresh.stats.peakCacheBytes}`,
    )
    // The old parser did one full inflate per binary-search step; the new one
    // does exactly one. Allow generous noise, but require a large margin.
    assert.ok(
      newMilliseconds * 3 < oldMilliseconds,
      `new parsePack ${newMilliseconds.toFixed(0)}ms is not at least 3x faster than ${oldMilliseconds.toFixed(0)}ms`,
    )
    // eslint-disable-next-line no-console -- the measured numbers are the point of this regression
    console.log(
      `[pack-performance] objects=${fresh.objects.length} pack=${(pack.byteLength / (1024 * 1024)).toFixed(1)}MiB `
      + `unpacked=${(TOTAL_BYTES / (1024 * 1024)).toFixed(1)}MiB old=${oldMilliseconds.toFixed(0)}ms `
      + `new=${newMilliseconds.toFixed(0)}ms speedup=${(oldMilliseconds / newMilliseconds).toFixed(1)}x `
      + `cachePeak=${(fresh.stats.peakCacheBytes / (1024 * 1024)).toFixed(1)}MiB `
      + `cacheBudget=${(PACK_DELTA_CACHE_BYTES / (1024 * 1024)).toFixed(0)}MiB`,
    )
  } finally {
    temp.cleanup()
  }
})

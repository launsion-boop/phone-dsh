// SPDX-License-Identifier: MIT
/**
 * G2-FIX-100 regression: the single-file `EFBIG` diagnostic derives its
 * human-readable MiB label from the same configured limit as its byte count.
 *
 * The defect: `NodeFsBackend`/`MemoryVfsBackend` read the enforced bound from
 * the configurable budget (`MAX_FILE_SIZE`, 64 MiB by default after ENG-07)
 * but rendered the label from a hard-coded `(15 MiB)` literal. A 64 MiB
 * refusal therefore said "limited to 67108864 bytes (15 MiB)" and every model
 * or user reading the tool result got a wrong unit magnitude. The fix routes
 * both numbers through one formatter owned by `limits.ts`; this test pins one
 * configured limit per case and requires the byte count and the MiB spelling
 * to agree with it.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  DEFAULT_SINGLE_FILE_LIMIT,
  MAX_SINGLE_FILE_LIMIT,
  MEBIBYTE,
  MIN_SINGLE_FILE_LIMIT,
  configureSingleFileLimit,
} from './limits.ts'
import { NodeFsBackend } from './vfs-backends.ts'
import type { NodeFsPromisesLike, NodeFsStatsLike } from './vfs-backends.ts'

/**
 * A `node:fs/promises` face that reports one file size and refuses every
 * actual I/O: the size guard must run before the runtime filesystem is
 * touched, so no call beyond `stat` may happen.
 */
function sizeOnlyFace(size: number): NodeFsPromisesLike {
  const unexpected = (name: string): never => {
    throw new Error(`the size guard must not reach fs.${name}`)
  }
  const stats: NodeFsStatsLike = {
    size,
    mode: 0o644,
    mtimeMs: 1,
    ino: 1,
    isFile: () => true,
    isDirectory: () => false,
    isSymbolicLink: () => false,
  }
  return {
    stat: async () => stats,
    readdir: async () => unexpected('readdir'),
    readFile: async () => unexpected('readFile'),
    writeFile: async () => unexpected('writeFile'),
    appendFile: async () => unexpected('appendFile'),
    mkdir: async () => unexpected('mkdir'),
    unlink: async () => unexpected('unlink'),
    rename: async () => unexpected('rename'),
    truncate: async () => unexpected('truncate'),
  }
}

/** The `EFBIG` a write one byte over `limit` raises, with the backend at `limit`. */
async function refusalFor(limit: number): Promise<{ code?: string; message: string }> {
  configureSingleFileLimit(limit)
  const backend = new NodeFsBackend(sizeOnlyFace(limit))
  try {
    // The append branch reports the post-write size from the existing file, so
    // the over-limit case needs no multi-megabyte buffer.
    await backend.writeFile('/dsh/tmp/size_probe.bin', new Uint8Array(1), { append: true, create: true })
  } catch (error) {
    return error as { code?: string; message: string }
  }
  assert.fail(`a write of ${String(limit + 1)} bytes must be refused at limit ${String(limit)}`)
}

test('G2-FIX-100: the EFBIG byte count and MiB label come from the configured limit', async () => {
  const limits = [MIN_SINGLE_FILE_LIMIT, DEFAULT_SINGLE_FILE_LIMIT, MAX_SINGLE_FILE_LIMIT]
  for (const limit of limits) {
    const mib = limit / MEBIBYTE
    const refusal = await refusalFor(limit)
    assert.equal(refusal.code, 'EFBIG')
    assert.equal(
      refusal.message.includes(`${String(limit)} bytes (${String(mib)} MiB)`),
      true,
      `limit ${String(limit)} must render as "${String(limit)} bytes (${String(mib)} MiB)": ${refusal.message}`,
    )
    if (limit !== 15 * MEBIBYTE) {
      assert.equal(
        refusal.message.includes('15 MiB'),
        false,
        `limit ${String(limit)} must not keep the pre-ENG-07 15 MiB label: ${refusal.message}`,
      )
    }
  }
})

test('G2-FIX-100: the label is derived, not a constant', async () => {
  // Two configured limits must produce two different labels. A literal (or a
  // label captured once at module load) would render the same text for both.
  const small = MIN_SINGLE_FILE_LIMIT
  const large = DEFAULT_SINGLE_FILE_LIMIT
  const smallLabel = `${String(small)} bytes (${String(small / MEBIBYTE)} MiB)`
  const largeLabel = `${String(large)} bytes (${String(large / MEBIBYTE)} MiB)`
  assert.notEqual(smallLabel, largeLabel, 'the fixture limits must differ')
  const smallMessage = (await refusalFor(small)).message
  const largeMessage = (await refusalFor(large)).message
  assert.equal(smallMessage.includes(smallLabel), true, smallMessage)
  assert.equal(largeMessage.includes(largeLabel), true, largeMessage)
  assert.notEqual(smallMessage, largeMessage, 'one owner renders each configured limit')
})

test('G2-FIX-100: an over-limit truncate names the same derived limit', async () => {
  const limit = MIN_SINGLE_FILE_LIMIT
  configureSingleFileLimit(limit)
  const backend = new NodeFsBackend(sizeOnlyFace(0))
  await assert.rejects(
    backend.truncate('/dsh/workspace/resize.bin', limit + 1),
    (error: unknown) => {
      const message = (error as Error).message
      assert.equal((error as { code?: string }).code, 'EFBIG')
      assert.equal(message.includes(`${String(limit)} bytes (${String(limit / MEBIBYTE)} MiB)`), true, message)
      assert.equal(message.includes('15 MiB'), false, message)
      return true
    },
  )
})

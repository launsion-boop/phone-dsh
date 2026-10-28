// SPDX-License-Identifier: MIT
// Overlay packer tests: the `home/` + `workspace/` whitelist, symlink refusal,
// and byte-for-byte deterministic output.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { packOverlay, TAR_BLOCK } from './pack-overlay.mjs'

const script = fileURLToPath(new URL('./pack-overlay.mjs', import.meta.url))
const scratch = []

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/** Create a scratch directory tracked for cleanup. */
function scratchDirectory() {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-overlay-test-'))
  scratch.push(directory)
  return directory
}

/** A normal workspace overlay tree. */
function overlayTree() {
  const root = scratchDirectory()
  mkdirSync(join(root, 'home', 'sub'), { recursive: true })
  mkdirSync(join(root, 'home', 'empty'), { recursive: true })
  mkdirSync(join(root, 'workspace'), { recursive: true })
  writeFileSync(join(root, 'home', 'a.txt'), 'alpha\n')
  writeFileSync(join(root, 'home', 'sub', 'b.txt'), 'beta\n')
  writeFileSync(join(root, 'workspace', 'c.txt'), 'gamma\n')
  return root
}

/**
 * Parse a ustar archive with a small independent reader.
 * @param {Buffer} bytes - archive bytes.
 * @returns {Array<{ path: string, type: string, mtime: number, mode: number, body: string }>}
 */
function readTar(bytes) {
  const entries = []
  let offset = 0
  while (offset + TAR_BLOCK <= bytes.length) {
    const header = bytes.subarray(offset, offset + TAR_BLOCK)
    if (header.every(byte => byte === 0)) break
    const name = header.toString('utf8', 0, 100).replace(/\0.*$/s, '')
    const prefix = header.toString('utf8', 345, 500).replace(/\0.*$/s, '')
    const size = Number.parseInt(header.toString('ascii', 124, 136).replace(/\0.*$/s, '').trim() || '0', 8)
    const mtime = Number.parseInt(header.toString('ascii', 136, 148).replace(/\0.*$/s, '').trim() || '0', 8)
    const mode = Number.parseInt(header.toString('ascii', 100, 108).replace(/\0.*$/s, '').trim() || '0', 8)
    const type = header.toString('ascii', 156, 157)
    const stored = header.toString('ascii', 148, 156).replace(/\0.*$/s, '').trim()
    const checksumHeader = Buffer.from(header)
    checksumHeader.fill(0x20, 148, 156)
    const checksum = [...checksumHeader].reduce((sum, byte) => sum + byte, 0)
    assert.equal(Number.parseInt(stored, 8), checksum, `checksum for ${name}`)
    offset += TAR_BLOCK
    const body = bytes.subarray(offset, offset + size)
    offset += Math.ceil(size / TAR_BLOCK) * TAR_BLOCK
    entries.push({ path: prefix === '' ? name : `${prefix}/${name}`, type, mtime, mode, body: body.toString('utf8') })
  }
  return entries
}

test('packs only home/ and workspace/ in deterministic order with fixed mtimes', async () => {
  const root = overlayTree()
  const first = join(scratchDirectory(), 'first.tar')
  const second = join(scratchDirectory(), 'second.tar')
  const facts = await packOverlay(root, first)
  await packOverlay(root, second)

  assert.deepEqual(readFileSync(first), readFileSync(second), 'the same tree must pack to identical bytes')
  assert.equal(facts.entries, 7)
  assert.equal(readFileSync(first).byteLength, 12 * TAR_BLOCK)

  const entries = readTar(readFileSync(first))
  assert.deepEqual(entries.map(entry => entry.path), [
    'home/',
    'home/a.txt',
    'home/empty/',
    'home/sub/',
    'home/sub/b.txt',
    'workspace/',
    'workspace/c.txt',
  ])
  for (const entry of entries) {
    assert.equal(entry.mtime, 0)
    assert.equal(entry.mode, entry.type === '5' ? 0o755 : 0o644)
  }
  assert.equal(entries.find(entry => entry.path === 'home/a.txt').body, 'alpha\n')
  assert.equal(entries.find(entry => entry.path === 'home/sub/b.txt').body, 'beta\n')
})

test('only one of home/ and workspace/ is allowed', async () => {
  const root = scratchDirectory()
  mkdirSync(join(root, 'home'))
  writeFileSync(join(root, 'home', 'only.txt'), 'x')
  const output = join(scratchDirectory(), 'only.tar')
  const facts = await packOverlay(root, output)
  assert.equal(facts.entries, 2)
  assert.deepEqual(readTar(readFileSync(output)).map(entry => entry.path), ['home/', 'home/only.txt'])
})

test('rejects a top-level root other than home/ or workspace/', async () => {
  const root = overlayTree()
  mkdirSync(join(root, 'config'))
  writeFileSync(join(root, 'config', 'x.yml'), 'x: 1\n')
  await assert.rejects(() => packOverlay(root, join(scratchDirectory(), 'x.tar')), /refusing root "config"/)
})

test('rejects a top-level file', async () => {
  const root = overlayTree()
  writeFileSync(join(root, 'README'), 'not overlay content\n')
  await assert.rejects(() => packOverlay(root, join(scratchDirectory(), 'x.tar')), /refusing root "README"/)
})

test('rejects symlinks at the top level and inside a data tree', async () => {
  const nested = overlayTree()
  symlinkSync(join(nested, 'home', 'a.txt'), join(nested, 'home', 'link'))
  await assert.rejects(() => packOverlay(nested, join(scratchDirectory(), 'x.tar')), /refusing symlink/)

  const top = scratchDirectory()
  mkdirSync(join(top, 'home'))
  symlinkSync(join(top, 'home'), join(top, 'workspace'))
  await assert.rejects(() => packOverlay(top, join(scratchDirectory(), 'y.tar')), /refusing symlink workspace/)
})

test('rejects a directory with no overlay roots', async () => {
  const root = scratchDirectory()
  await assert.rejects(() => packOverlay(root, join(scratchDirectory(), 'x.tar')), /neither home\/ nor workspace\//)
})

test('the CLI rejects an invalid tree with a nonzero status', () => {
  const root = overlayTree()
  mkdirSync(join(root, 'other'))
  const result = spawnSync(process.execPath, [script, root, '--out', join(scratchDirectory(), 'cli.tar')], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /refusing root "other"/)
})

// SPDX-License-Identifier: MIT
/**
 * Profile stub overlay tests.
 *
 * The overlay must be a gzip member holding one ustar entry at the profile
 * manifest path, with a bundle list that names only `@deepseek-ai/dsh-base`:
 * that is what keeps app-boot from reporting the image's absent browser bundle
 * as skipped. The template name is cross-checked against the packer constant,
 * so the stub and the image cannot drift apart silently.
 * @module @phone-dsh/dsh-worker-entry/profile-overlay.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { gunzipSync } from 'node:zlib'

import {
  PHONE_IMAGE_PROFILE,
  PHONE_PROFILE_BUNDLES,
  PHONE_PROFILE_MANIFEST_PATH,
  createPhoneProfileOverlay,
  packPhoneProfileOverlay,
  phoneProfileManifest,
} from './profile-overlay.ts'

const TAR_BLOCK = 512
const encoder = new TextEncoder()
const decoder = new TextDecoder()

/** One regular file read from a ustar archive. */
interface TarEntry {
  name: string
  mode: number
  bytes: Uint8Array
}

/**
 * Read the ustar entries this module writes (plain files only).
 * @param archive - Uncompressed archive bytes.
 * @returns Entries in archive order.
 */
function readTar(archive: Uint8Array): TarEntry[] {
  const entries: TarEntry[] = []
  let offset = 0
  while (offset + TAR_BLOCK <= archive.length) {
    const header = archive.subarray(offset, offset + TAR_BLOCK)
    if (header.every(byte => byte === 0)) break
    const field = (start: number, length: number): string => {
      let end = start
      while (end < start + length && header[end] !== 0) end += 1
      return decoder.decode(header.subarray(start, end))
    }
    const name = field(0, 100)
    const mode = Number.parseInt(field(100, 8).trim() || '0', 8) & 0o777
    const size = Number.parseInt(field(124, 12).trim() || '0', 8)
    entries.push({ name, mode, bytes: archive.subarray(offset + TAR_BLOCK, offset + TAR_BLOCK + size) })
    offset += TAR_BLOCK + Math.ceil(size / TAR_BLOCK) * TAR_BLOCK
  }
  return entries
}

test('the profile manifest names only the bundle the image materializes', () => {
  const manifest = JSON.parse(phoneProfileManifest()) as {
    name: string
    private: boolean
    dependencies: Record<string, string>
    dsh: { profile: { bundles: string[] } }
  }
  assert.equal(manifest.name, `dsh-profile-${PHONE_IMAGE_PROFILE}`)
  assert.equal(manifest.private, true)
  assert.deepEqual(manifest.dependencies, {})
  assert.deepEqual(manifest.dsh.profile.bundles, ['@deepseek-ai/dsh-base'])
  assert.deepEqual([...PHONE_PROFILE_BUNDLES], ['@deepseek-ai/dsh-base'])
  assert.ok(!manifest.dsh.profile.bundles.includes('@deepseek-ai/dsh-web-app'))
})

test('the uncompressed overlay carries the profile manifest at the ustar path', () => {
  const archive = packPhoneProfileOverlay()
  const entries = readTar(archive)
  assert.equal(entries.length, 1)
  const entry = entries[0] as TarEntry
  assert.equal(entry.name, PHONE_PROFILE_MANIFEST_PATH)
  assert.equal(entry.mode, 0o644)
  assert.equal(decoder.decode(entry.bytes), phoneProfileManifest())
  const bodyBytes = encoder.encode(phoneProfileManifest()).length
  assert.equal(archive.byteLength, TAR_BLOCK + Math.ceil(bodyBytes / TAR_BLOCK) * TAR_BLOCK + TAR_BLOCK * 2)
})

test('the runtime receives a gzip member holding the same archive', async () => {
  const compressed = await createPhoneProfileOverlay()
  assert.deepEqual([...compressed.subarray(0, 2)], [0x1f, 0x8b])
  assert.deepEqual(new Uint8Array(gunzipSync(compressed)), packPhoneProfileOverlay())
})

test('the stub names the shipped profile template the packer records', async () => {
  // `pack-image.mjs` is a plain .mjs script with no TypeScript declaration;
  // load it by URL and read only its exported constant.
  const packImage = await import(new URL('../../scripts/pack-image.mjs', import.meta.url).href) as {
    IMAGE_PROFILE: string
  }
  assert.equal(PHONE_IMAGE_PROFILE, packImage.IMAGE_PROFILE)
})

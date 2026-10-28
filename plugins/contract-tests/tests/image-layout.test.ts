// SPDX-License-Identifier: MIT
// The image layout contract: platform rows the Worker applies through its HOME
// patch, and the only top-level directories an overlay may populate.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'

test('image layout: PLATFORM_ENTRY_CONFIG keeps session logs plaintext', async (t) => {
  const probe = await loadProbe()
  const rows = probe.PLATFORM_ENTRY_CONFIG
  observe(t, 'platformEntryConfig', rows)
  const session = rows['session-persistence-jsonl']
  assert.notEqual(session, undefined, 'PLATFORM_ENTRY_CONFIG must keep the session-persistence-jsonl row')
  assert.equal(session?.['compression'], 'none', 'the Worker has no zstd codec, so the row must force compression:none')
  for (const [id, fields] of Object.entries(rows)) {
    assert.equal(typeof id, 'string')
    assert.equal(typeof fields, 'object', `PLATFORM_ENTRY_CONFIG row ${id} must carry a config object`)
  }
})

test('image layout: overlay directory whitelist is home/ and workspace/', async (t) => {
  const probe = await loadProbe()
  observe(t, 'imageLayout', {
    overlayDirectories: probe.IMAGE_OVERLAY_DIRECTORIES,
    emptyDirectories: probe.IMAGE_EMPTY_DIRECTORIES,
    homeDirectory: probe.IMAGE_HOME_DIRECTORY,
    manifestPath: probe.IMAGE_MANIFEST_PATH,
    root: probe.DEFAULT_ROOT,
  })
  assert.deepEqual(
    [...probe.IMAGE_OVERLAY_DIRECTORIES],
    ['home', 'workspace'],
    'an overlay may only populate home/ and workspace/',
  )
  assert.deepEqual(
    [...probe.IMAGE_EMPTY_DIRECTORIES],
    ['home/', 'workspace/', 'tmp/'],
    'the image must still carry the home, workspace and tmp working directories',
  )
  assert.equal(probe.IMAGE_HOME_DIRECTORY, 'home')
})

// SPDX-License-Identifier: MIT
// The webworker-runtime root export: the phone host imports these symbols from
// the checkout's index.ts, so a renamed or dropped export breaks the Worker.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'

/** Symbols the phone host and the image packer consume from index.ts. */
const REQUIRED_RUNTIME_EXPORTS = [
  'DEFAULT_ROOT',
  'IMAGE_EMPTY_DIRECTORIES',
  'IMAGE_HOME_DIRECTORY',
  'IMAGE_MANIFEST_PATH',
  'IMAGE_OVERLAY_DIRECTORIES',
  'MemoryVfs',
  'PLATFORM_ENTRY_CONFIG',
  'createSyntheticExchange',
  'createWorkerHost',
  'loadVfsImage',
  'loadVfsOverlay',
  'lowerModuleSource',
  'setActiveVfs',
  'requireActiveVfs',
] as const

test('runtime exports: index.ts exposes the phone host symbols', async (t) => {
  const probe = await loadProbe()
  const observed = Object.keys(probe.runtimeApi).sort()
  observe(t, 'runtimeIndexExports', observed)
  for (const name of REQUIRED_RUNTIME_EXPORTS) {
    assert.ok(observed.includes(name), `webworker-runtime index.ts no longer exports ${name}`)
  }
  assert.equal(typeof probe.runtimeApi['createWorkerHost'], 'function', 'createWorkerHost must stay callable')
  assert.equal(typeof probe.runtimeApi['MemoryVfs'], 'function', 'MemoryVfs must stay constructible')
})

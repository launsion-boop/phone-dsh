// SPDX-License-Identifier: MIT
/**
 * DSH version pin consistency.
 *
 * The pinned checkout and `dsh-pin.json` name one DSH release; app-boot's
 * compatibility preflight compares every plugin manifest's dsh peer ranges
 * against the running runtime version and disables a row on any mismatch. This
 * test keeps the manifests on that exact version.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const pin = JSON.parse(readFileSync(join(root, 'dsh-pin.json'), 'utf8')) as {
  version: string
}
const rootManifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as {
  workspaces?: string[]
}
/** Surface packages the packer stages but npm workspaces do not link. */
const EXTRA_PACKAGES = ['surface-phone']
const DEPENDENCY_FIELDS = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies'] as const
const DSH_PACKAGE = /^@deepseek-ai\/dsh(?:-|$)/

interface Manifest {
  name?: string
  [field: string]: unknown
}

const manifests: Array<{ directory: string; manifest: Manifest }> = [
  { directory: '.', manifest: JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as Manifest },
]
for (const workspace of [...(rootManifest.workspaces ?? []), ...EXTRA_PACKAGES]) {
  const directory = join(root, workspace)
  manifests.push({
    directory: workspace,
    manifest: JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')) as Manifest,
  })
}

test('every @deepseek-ai/dsh range in every workspace manifest equals dsh-pin.json', () => {
  const mismatches: string[] = []
  for (const { directory, manifest } of manifests) {
    for (const field of DEPENDENCY_FIELDS) {
      const dependencies = manifest[field]
      if (typeof dependencies !== 'object' || dependencies === null) continue
      for (const [dependency, range] of Object.entries(dependencies as Record<string, unknown>)) {
        if (!DSH_PACKAGE.test(dependency)) continue
        if (range !== pin.version) {
          mismatches.push(`${directory}/package.json: ${field}.${dependency} is ${JSON.stringify(range)}, expected ${JSON.stringify(pin.version)}`)
        }
      }
    }
  }
  assert.deepEqual(mismatches, [])
})

test('the pin names the 0.2.1 generation', () => {
  assert.match(pin.version, /^0\.2\.1-rc\.\d+$/)
})

// SPDX-License-Identifier: MIT
/**
 * Regression guard for the Worker runtime's compression surface.
 *
 * The DSH Worker's `node:zlib` proxy implements the Zstandard/gzip family but
 * carries no `deflateSync`/`inflateSync`/`crc32` (and a browser has no
 * `node:zlib` at all). Git's object and pack codec therefore must never import
 * it; this test scans every source file under the git package and fails when
 * one does, so the Node-hosted golden suite cannot hide the defect again.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/no-node-zlib
 */
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const packageRoot = fileURLToPath(new URL('..', import.meta.url))
const thisFile = fileURLToPath(import.meta.url)

/** `from 'node:zlib'`, `require('zlib')`, `import('node:zlib')`, dynamic forms. */
const ZLIB_IMPORT = /(?:from\s*|require\s*\(\s*|import\s*\(\s*)['"](?:node:)?zlib['"]/g

function sourceFiles(directory: string): string[] {
  const files: string[] = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules') continue
    const path = join(directory, entry.name)
    if (entry.isDirectory()) files.push(...sourceFiles(path))
    else if (/\.(?:ts|mts|cts|js|mjs|cjs)$/.test(entry.name)) files.push(path)
  }
  return files
}

test('no git source file imports node:zlib (the Worker proxy has no deflate)', () => {
  const offenders: string[] = []
  for (const file of sourceFiles(packageRoot)) {
    // This file necessarily mentions the specifier in its own detector.
    if (file === thisFile) continue
    const source = readFileSync(file, 'utf8')
    for (const match of source.matchAll(ZLIB_IMPORT)) {
      const line = source.slice(0, match.index).split('\n').length
      offenders.push(`${file.slice(packageRoot.length + 1)}:${line}`)
    }
  }
  assert.deepEqual(offenders, [], 'node:zlib has no deflate/inflate in the DSH Worker runtime')
})

test('the codec used by the object database is the pure-JavaScript one', () => {
  // A weaker but independent witness: the three modules that read or write
  // compressed git data name `./compress.ts`, not a Node builtin.
  for (const relative of ['objects.ts', 'pack.ts', 'remote.ts']) {
    const source = readFileSync(join(packageRoot, relative), 'utf8')
    assert.match(source, /from '\.\/compress\.ts'/, `${relative} must import the pure-JS codec`)
  }
})

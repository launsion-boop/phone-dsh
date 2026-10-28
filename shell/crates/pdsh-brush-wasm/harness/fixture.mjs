// SPDX-License-Identifier: MIT
/**
 * Scratch workspace used by the corpus runner.
 *
 * The layout mirrors `plugins/tools/shell-corpus/runtime-evaluator.mjs` so
 * that the brush numbers are comparable with the runtime-js baseline: every
 * command starts from the same small project tree.
 *
 * @module pdsh-brush-wasm/harness/fixture
 */

import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/** Directories created before every command, relative to the host root. */
export const DIRECTORIES = [
  'workspace/src',
  'workspace/docs',
  'workspace/data',
  'workspace/scripts',
  'workspace/empty',
  'home',
  'tmp',
]

/** Files created before every command, relative to the host root. */
export const FILES = new Map([
  ['workspace/README.md', '# Demo workspace\n\nA tiny project used by the shell corpus.\n\nSee docs/guide.md for usage.\n'],
  ['workspace/package.json', '{\n  "name": "demo",\n  "version": "1.0.0",\n  "scripts": {\n    "build": "tsc",\n    "test": "node --test"\n  }\n}\n'],
  ['workspace/docs/guide.md', '# Guide\n\nRun the tests with npm test, then read the output.\n'],
  ['workspace/src/index.ts', "import { answer } from './util.ts'\n\nexport function add(left: number, right: number): number {\n  return left + right + answer\n}\n"],
  ['workspace/src/util.ts', 'export const answer = 42\n'],
  ['workspace/scripts/build.sh', '#!/bin/sh\necho build\n'],
  ['workspace/data/numbers.txt', '3\n1\n2\n'],
  ['workspace/data/words.txt', 'apple\nbanana\napple\n'],
  ['workspace/data/people.csv', 'name,role\nalice,dev\nbob,ops\n'],
  ['workspace/.gitignore', 'node_modules/\ndist/\n'],
  ['home/notes.txt', 'Remember the milk\n'],
])

/**
 * Create a fresh fixture under `root`.
 *
 * @param {string} root - host directory that will be preopened as `/dsh`.
 */
export function resetFixture(root) {
  // Keep the mount directories themselves: the WASI preopens refer to their
  // inodes, so deleting and recreating them would leave the guest with stale
  // directory handles.
  for (const directory of ['workspace', 'home', 'tmp']) {
    const host = join(root, directory)
    mkdirSync(host, { recursive: true })
    for (const entry of readdirSync(host)) {
      rmSync(join(host, entry), { recursive: true, force: true })
    }
  }
  for (const directory of DIRECTORIES) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  for (const [relative, contents] of FILES) {
    writeFileSync(join(root, relative), contents)
  }
}

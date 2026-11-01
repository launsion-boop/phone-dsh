// SPDX-License-Identifier: MIT
// P13 / G2-B: the file budget and the captured-output budget are two
// different budgets.
//
// `spec/v1/channel.md:265-272` says the worker VFS refuses a post-write file
// above `single_file_limit` with `EFBIG`; `executionLimits.maxOutputSize` is
// the memory bound on the bytes a command *returns*. just-bash 3.6 charged a
// redirection target's bytes against `maxOutputSize` before writing them, so
// `cat /dev/zero >> file` hit "total output size exceeded" one chunk before
// the file budget could answer `EFBIG` — the model saw a shell output ceiling
// where the contract promises a file refusal, and the two budgets were
// indistinguishable.
//
// The engine seam (`shell-ext/tools/patch-just-bash.mjs`) removes the
// pre-write redirect charge. These tests pin the split at the shell surface:
//
//   * a redirect that would grow one file over the budget  → EFBIG,
//     `reason=limit-refused`, no `maxOutputSize` text;
//   * a capture that would exceed the same budget           → maxOutputSize,
//     `reason=output-truncated`, no `EFBIG` text;
//   * several legal files in one script                     → no output ceiling
//     (redirect bytes never consume the capture budget).
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { DEFAULT_SINGLE_FILE_LIMIT, configureSingleFileLimit } from '../wasi-toolbox/src/limits.ts'

/**
 * The single-file budget these tests run with: 4 MiB, small enough that a
 * failing case costs five device windows (5 MiB) instead of 129.
 */
const FILE_LIMIT = 4 * 1024 * 1024

/** The per-stream capture cap; the engine bound is FILE_LIMIT + this. */
const CAPTURE_LIMIT = 512 * 1024

/** The context a shell case runs in: a scratch tree that is never `/`. */
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  configureSingleFileLimit(DEFAULT_SINGLE_FILE_LIMIT)
})

interface Fixture {
  readonly root: string
  readonly shell: WorkerShell
}

/** One Worker-shaped shell over a real scratch tree. */
async function fixture(): Promise<Fixture> {
  configureSingleFileLimit(FILE_LIMIT)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-output-budgets-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace', { recursive: true })
  return { root, shell: new WorkerShell({ fs, maxOutputBytes: CAPTURE_LIMIT }) }
}

/** File size of a virtual path below the fixture root, or -1 when absent. */
function sizeOf(root: string, path: string): number {
  const real = `${root}${path}`
  return existsSync(real) ? statSync(real).size : -1
}

/** Run one bash script and return its result. */
async function bash(shell: WorkerShell, script: string) {
  return await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
}

test('budgets: a redirect over the single-file limit is EFBIG, not a shell output ceiling', async () => {
  const { root, shell } = await fixture()
  // Each `cat /dev/zero` contributes the device's 1 MiB window; the fifth
  // append would take the file to 5 MiB, one MiB over the budget.
  const result = await bash(shell, 'for i in {1..12}; do cat /dev/zero >> /dsh/workspace/limit.bin || break; done')
  const size = sizeOf(root, '/dsh/workspace/limit.bin')
  assert.equal(size, FILE_LIMIT, 'the file stops exactly at the budget; no over-limit fragment is published')
  assert.notEqual(result.exitCode, 0, 'a refused write is not a success')
  assert.match(result.stderr, /^EFBIG: File too large: \/dsh\/workspace\/limit\.bin would be 5242880 bytes/mu)
  assert.match(result.stderr, /a file is limited to 4194304 bytes \(4 MiB\)/u)
  assert.match(result.stderr, /reason=limit-refused/u, 'the trailer names the file budget')
  assert.match(result.stderr, /split the output across files/u, 'the trailer carries an action')
  assert.doesNotMatch(result.stderr, /maxOutputSize/u, 'the capture budget is not the file budget')
  assert.doesNotMatch(result.stderr, /total output size exceeded/u)
})

test('budgets: a capture over the same bound is still the maxOutputSize ceiling, not EFBIG', async () => {
  const { root, shell } = await fixture()
  // No redirection: these bytes are the command result, which is what
  // `maxOutputSize` bounds. Five windows exceed FILE_LIMIT + CAPTURE_LIMIT.
  const result = await bash(shell, 'for i in {1..12}; do cat /dev/zero; done')
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /total output size exceeded \(>\d+ bytes\), increase executionLimits\.maxOutputSize/u)
  assert.match(result.stderr, /reason=output-truncated/u)
  assert.doesNotMatch(result.stderr, /EFBIG/u, 'a capture never reports the file budget')
  assert.doesNotMatch(result.stderr, /a file is limited to/u)
  assert.equal(sizeOf(root, '/dsh/workspace/limit.bin'), -1, 'nothing was written')
})

test('budgets: several legal files in one script do not consume the capture budget', async () => {
  const { root, shell } = await fixture()
  // 3 MiB per file (under the 4 MiB budget) and 6 MiB of redirected bytes in
  // total, which is over FILE_LIMIT + CAPTURE_LIMIT. With one shared budget
  // this script failed at the fifth write; with two budgets each file is legal.
  const result = await bash(shell, [
    'for name in a b; do',
    '  for i in {1..3}; do cat /dev/zero >> /dsh/workspace/$name.bin || exit 7; done',
    'done',
    'printf done',
  ].join('\n'))
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'done')
  assert.equal(result.stderr, '')
  assert.equal(sizeOf(root, '/dsh/workspace/a.bin'), 3 * 1024 * 1024)
  assert.equal(sizeOf(root, '/dsh/workspace/b.bin'), 3 * 1024 * 1024)
})

test('budgets: an ordinary small redirection and an ordinary small capture are unaffected', async () => {
  const { root, shell } = await fixture()
  const redirected = await bash(shell, 'printf hello > /dsh/workspace/small.txt; cat /dsh/workspace/small.txt')
  assert.equal(redirected.exitCode, 0, redirected.stderr)
  assert.equal(redirected.stdout, 'hello')
  assert.equal(sizeOf(root, '/dsh/workspace/small.txt'), 5)
  const captured = await bash(shell, 'printf captured')
  assert.equal(captured.exitCode, 0, captured.stderr)
  assert.equal(captured.stdout, 'captured')
  assert.equal(captured.stderr, '')
})

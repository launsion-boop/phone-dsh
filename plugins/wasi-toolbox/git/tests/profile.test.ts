// SPDX-License-Identifier: MIT
/**
 * The profile side of W7-GIT: the worker layer must enable the
 * `workspace-changes` row the changed-files card needs, and the row must carry
 * the comment that says where its git comes from. This is a repository file
 * assertion, not a DSH load: `scripts/profile.test.mjs` already loads the patch
 * through DSH's own reader.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/profile.test
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const profileUrl = new URL('../../../profile/phone.worker.cordis.patch.yml', import.meta.url)

test('the worker profile enables the workspace-changes row with a Worker-git comment', () => {
  const text = readFileSync(profileUrl, 'utf8')
  const index = text.indexOf('- id: workspace-changes')
  assert.notEqual(index, -1, 'workspace-changes row is present')
  const block = text.slice(index, text.indexOf('\n\n', index) === -1 ? undefined : text.indexOf('\n\n', index))
  assert.match(block, /name: '@deepseek-ai\/dsh-workspace-changes'/)
  assert.doesNotMatch(block, /disabled:/, 'the row is enabled')
  const commentStart = text.lastIndexOf('\n\n', index)
  const comment = text.slice(commentStart, index)
  assert.match(comment, /wasi-toolbox\/git/, 'the row comment names the Worker git program')
  assert.match(comment, /D12/, 'the row comment cites the executor inversion decision')
  assert.match(comment, /rev-parse/, 'the row comment lists the snapshot subcommands')
})

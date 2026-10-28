// SPDX-License-Identifier: MIT
/**
 * `.gitignore` semantics used by `check-ignore`, `status` and `add --all`:
 * anchoring, directory-only patterns, `**`, negation, last-match-wins and the
 * rule that a tracked path is never reported as ignored.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/ignore.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { compilePattern, isIgnored } from '../ignore.ts'
import type { IgnoreRules } from '../ignore.ts'

function rules(lines: readonly string[], tracked: readonly string[] = [], base = ''): IgnoreRules {
  const patterns = lines
    .map(line => compilePattern(line, base))
    .filter((pattern): pattern is NonNullable<typeof pattern> => pattern !== undefined)
  return { patterns, tracked: new Set(tracked) }
}

test('gitignore globs compile to git-compatible matches', () => {
  const root = rules(['*.log', 'build/', '/root.txt', 'sub/*.tmp', '**/deep', 'doc/**', '?ingle.txt', '[ab].md', '!keep.log'])
  assert.equal(isIgnored(root, 'x.log'), true)
  assert.equal(isIgnored(root, 'a/b/x.log'), true)
  assert.equal(isIgnored(root, 'x.log.txt'), false)
  assert.equal(isIgnored(root, 'keep.log'), false, 'negation wins in file order')
  assert.equal(isIgnored(root, 'keep.log.bak'), false)
  assert.equal(isIgnored(root, 'root.txt'), true)
  assert.equal(isIgnored(root, 'nested/root.txt'), false, 'a leading slash anchors to the root')
  assert.equal(isIgnored(root, 'sub/x.tmp'), true)
  assert.equal(isIgnored(root, 'sub/nested/x.tmp'), false, '* does not cross a slash')
  assert.equal(isIgnored(root, 'here/deep'), true)
  assert.equal(isIgnored(root, 'deep/file.txt'), true, 'a matched directory covers its contents')
  assert.equal(isIgnored(root, 'doc/readme.md'), true)
  assert.equal(isIgnored(root, 'single.txt'), true)
  assert.equal(isIgnored(root, 'nope.txt'), false)
  assert.equal(isIgnored(root, 'a.md'), true)
  assert.equal(isIgnored(root, 'c.md'), false)
})

test('directory-only patterns and tracked paths', () => {
  const root = rules(['build/', 'cache'], ['build/kept.txt'])
  assert.equal(isIgnored(root, 'build', true), true)
  assert.equal(isIgnored(root, 'build', false), false, 'a trailing slash matches directories only')
  assert.equal(isIgnored(root, 'build/kept.txt'), false, 'a tracked path is never ignored, even below an ignored directory')
  assert.equal(isIgnored({ patterns: root.patterns, tracked: new Set() }, 'build/other.txt'), true)
  assert.equal(isIgnored(root, 'cache'), true)
  const tracked = rules(['*.log'], ['debug.log'])
  assert.equal(isIgnored(tracked, 'debug.log'), false, 'tracked paths are never ignored')
  assert.equal(isIgnored(tracked, 'other.log'), true)
})

test('patterns in a nested .gitignore apply below their own directory only', () => {
  const nested = rules(['*.tmp', '/local.txt'], [], 'sub')
  assert.equal(isIgnored(nested, 'sub/x.tmp'), true)
  assert.equal(isIgnored(nested, 'sub/deep/x.tmp'), true)
  assert.equal(isIgnored(nested, 'x.tmp'), false)
  assert.equal(isIgnored(nested, 'sub/local.txt'), true)
  assert.equal(isIgnored(nested, 'other/local.txt'), false)
})

// SPDX-License-Identifier: MIT
// Unit coverage for the argv rewrite behind the `find -type` shim. The
// component tests exercise the command through just-bash; these pin the exact
// mapping so an over-eager rewrite cannot silently change non-type argv.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  POSIX_FIND_TYPE_LETTERS,
  rewriteFindTypeArguments,
} from '../shell-ext/src/index.ts'

test('find rewrite: the exported set is the full POSIX -type grammar', () => {
  assert.deepEqual([...POSIX_FIND_TYPE_LETTERS].sort(), ['b', 'c', 'd', 'f', 'l', 'p', 's'])
})

test('find rewrite: a single f or d returns undefined so argv is untouched', () => {
  assert.equal(rewriteFindTypeArguments(['.', '-type', 'f']), undefined)
  assert.equal(rewriteFindTypeArguments(['.', '-type', 'd', '-name', '*.txt']), undefined)
  assert.equal(rewriteFindTypeArguments(['src', '-maxdepth', '2', '-type', 'f']), undefined)
})

test('find rewrite: impossible letters become a never-matching primary', () => {
  for (const value of ['l', 'b', 'c', 'p', 's', 'l,b', 'b,c,p,s', 'l,l']) {
    assert.deepEqual(rewriteFindTypeArguments(['.', '-type', value]), ['.', '-name', ''], value)
  }
})

test('find rewrite: comma lists narrow to the letters this VFS can hold', () => {
  assert.deepEqual(rewriteFindTypeArguments(['.', '-type', 'f,l']), ['.', '-type', 'f'])
  assert.deepEqual(rewriteFindTypeArguments(['.', '-type', 'l,f']), ['.', '-type', 'f'])
  assert.deepEqual(rewriteFindTypeArguments(['.', '-type', 'f,f,l']), ['.', '-type', 'f'])
  assert.deepEqual(rewriteFindTypeArguments(['.', '-type', 'd,b']), ['.', '-type', 'd'])
})

test('find rewrite: f,d becomes the built-in f-or-d expression exactly once', () => {
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '-type', 'f,d']),
    ['.', '(', '-type', 'f', '-o', '-type', 'd', ')'],
  )
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '-type', 'd,f,l', '-print']),
    ['.', '(', '-type', 'f', '-o', '-type', 'd', ')', '-print'],
  )
})

test('find rewrite: invalid values return undefined so the built-in errors', () => {
  for (const value of ['x', 'F', 'f,x', 'l,', '', '-o']) {
    assert.equal(rewriteFindTypeArguments(['.', '-type', value]), undefined, value)
  }
  assert.equal(rewriteFindTypeArguments(['.', '-type']), undefined)
})

test('find rewrite: -exec, -printf and option values are not type predicates', () => {
  assert.equal(rewriteFindTypeArguments(['.', '-printf', '-type', '%s']), undefined)
  assert.equal(
    rewriteFindTypeArguments(['.', '-exec', 'echo', '-type', 'l', '{}', ';']),
    undefined,
  )
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '-name', '-type', '-type', 'l']),
    ['.', '-name', '-type', '-name', ''],
  )
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '-exec', 'echo', '-type', 'l', '{}', '+', '-type', 'l']),
    ['.', '-exec', 'echo', '-type', 'l', '{}', '+', '-name', ''],
  )
})

test('find rewrite: nested, negated and OR-ed predicates keep grouping', () => {
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '!', '-type', 'l']),
    ['.', '!', '-name', ''],
  )
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '(', '-type', 'l', '-o', '-type', 'f', ')']),
    ['.', '(', '-name', '', '-o', '-type', 'f', ')'],
  )
  assert.deepEqual(
    rewriteFindTypeArguments(['.', '-type', 'l', '-o', '-type', 'f,d']),
    ['.', '-name', '', '-o', '(', '-type', 'f', '-o', '-type', 'd', ')'],
  )
})

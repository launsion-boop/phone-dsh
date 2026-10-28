// SPDX-License-Identifier: MIT
/**
 * Invariants of the committed public corpus: size, categories, provenance and
 * absence of machine-specific data.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { test } from 'node:test'
import { parseCorpus } from './runners.mjs'

const CORPUS_URL = new URL('./corpus/public.jsonl', import.meta.url)
const CATEGORIES = new Set(['files', 'text', 'git', 'package', 'build-test', 'script', 'network'])

/** Build the path prefixes that must never appear in a public corpus. */
function forbiddenPrefixes() {
  const separator = '/'
  return [['', 'Users', ''].join(separator), ['', 'home', ''].join(separator)]
}

test('the public corpus has at least 400 unique, categorised commands', () => {
  const text = readFileSync(CORPUS_URL, 'utf8')
  const records = text.split('\n').filter((line) => line.trim() !== '').map((line) => JSON.parse(line))
  assert.ok(records.length >= 400, `expected at least 400 commands, found ${records.length}`)
  const seen = new Set()
  for (const record of records) {
    assert.equal(typeof record.cmd, 'string')
    assert.equal(record.cmd, record.cmd.trim())
    assert.notEqual(record.cmd, '')
    assert.equal(record.source, 'public')
    assert.ok(CATEGORIES.has(record.category), `unknown category ${record.category}`)
    assert.equal(seen.has(record.cmd), false, `duplicate command ${record.cmd}`)
    seen.add(record.cmd)
  }
})

test('every category is represented', () => {
  const entries = parseCorpus(readFileSync(CORPUS_URL, 'utf8'))
  const counts = {}
  for (const entry of entries) counts[entry.category] = (counts[entry.category] ?? 0) + 1
  for (const category of CATEGORIES) {
    assert.ok((counts[category] ?? 0) >= 40, `${category} has only ${counts[category] ?? 0} commands`)
  }
})

test('the corpus keeps DSH-repository provenance for adapted commands', () => {
  const records = readFileSync(CORPUS_URL, 'utf8')
    .split('\n')
    .filter((line) => line.trim() !== '')
    .map((line) => JSON.parse(line))
  const adapted = records.filter((record) => record.origin === 'dsh-repo')
  assert.ok(adapted.length >= 10, `expected at least 10 DSH-derived commands, found ${adapted.length}`)
})

test('the corpus contains no home-directory paths or machine-specific data', () => {
  const text = readFileSync(CORPUS_URL, 'utf8')
  for (const prefix of forbiddenPrefixes()) assert.equal(text.includes(prefix), false)
  const home = homedir()
  if (home !== '/') assert.equal(text.includes(home), false)
  assert.equal(text.includes('\u0000'), false)
})

test('every corpus command is valid JSONL', () => {
  const text = readFileSync(CORPUS_URL, 'utf8')
  assert.doesNotThrow(() => parseCorpus(text))
})

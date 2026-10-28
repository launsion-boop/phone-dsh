// SPDX-License-Identifier: MIT
/**
 * G2-FIX-86 corpus-tool tests: the `cmp` goldens are generated, not authored.
 *
 * The committed `cmp/` vectors must keep covering the six shapes the class gate
 * names (plain comparison, `-s`, `-l`, identical files, differing files, missing
 * operands), and on a host whose `cmp` is the shape the file was generated from
 * their bytes must still equal what that program prints. A host with GNU `cmp`
 * skips the regeneration comparison (the committed file is the BSD host shape)
 * instead of failing on a deliberate platform difference.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  CMP_VECTORS,
  CMP_VECTOR_PREFIX,
  DEFAULT_CMP,
  DEFAULT_GOLDEN,
  cmpVectorsFromText,
  generateCmpGoldens,
  replaceCmpVectors,
} from './cmp-golden.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const tool = resolve(here, 'cmp-golden.mjs')
const pluginRoot = resolve(here, '..', '..')
const committed = readFileSync(DEFAULT_GOLDEN, 'utf8')
const committedVectors = cmpVectorsFromText(committed)

/**
 * The local host's cmp flavour, from the first-difference wording.
 * @returns {'bsd'|'gnu'|'unavailable'|'unknown'} the flavour.
 */
function hostFlavor() {
  if (!existsSync(DEFAULT_CMP)) return 'unavailable'
  const sample = generateCmpGoldens().find(vector => vector.name === 'cmp/default-first-difference')
  const stdout = sample?.expect?.stdout ?? ''
  if (stdout.includes('differ: char ')) return 'bsd'
  if (stdout.includes('differ: byte ')) return 'gnu'
  return 'unknown'
}

const flavor = hostFlavor()
const bsdHost = flavor === 'bsd'

test('cmp goldens: the committed vectors cover the required POSIX surface', () => {
  const names = committedVectors.map(vector => vector.name)
  assert.deepEqual(names, CMP_VECTORS.map(vector => vector.name), 'the committed file must carry every declared vector')
  assert.equal(committedVectors.length, CMP_VECTORS.length)
  for (const vector of committedVectors) {
    assert.ok(vector.name.startsWith(CMP_VECTOR_PREFIX), vector.name)
    assert.equal(typeof vector.cmd, 'string')
    assert.equal(typeof vector.expect?.stdout, 'string', `${vector.name} stdout`)
    assert.equal(typeof vector.expect?.stderr, 'string', `${vector.name} stderr`)
    assert.ok([0, 1, 2].includes(vector.expect?.exit), `${vector.name} exit`)
  }
  const cmds = committedVectors.map(vector => vector.cmd)
  assert.ok(cmds.some(cmd => /^cmp \S+ \S+$/u.test(cmd)), 'a plain `cmp a b` vector is required')
  assert.ok(cmds.some(cmd => /^cmp -s /u.test(cmd)), 'a `cmp -s` vector is required')
  assert.ok(cmds.some(cmd => /^cmp -l /u.test(cmd)), 'a `cmp -l` vector is required')
  assert.ok(committedVectors.some(vector => vector.expect.exit === 0), 'an identical-files vector is required')
  assert.ok(committedVectors.some(vector => vector.expect.exit === 1), 'a differing-files vector is required')
  assert.ok(committedVectors.some(vector => vector.cmd === 'cmp' && vector.expect.exit === 2), 'a missing-operands vector is required')
})

test('cmp goldens: regeneration is deterministic', { skip: flavor === 'unavailable' ? 'no host cmp' : false }, () => {
  assert.deepEqual(generateCmpGoldens(), generateCmpGoldens())
})

test('cmp goldens: the committed bytes are the host cmp output', {
  skip: flavor === 'unavailable' ? 'no host cmp' : flavor === 'gnu' ? 'committed goldens are the BSD host shape' : flavor === 'unknown' ? 'unrecognised host cmp flavour' : false,
}, () => {
  const generated = generateCmpGoldens()
  assert.equal(replaceCmpVectors(committed, generated), committed)
  assert.equal(committedVectors.find(vector => vector.name === 'cmp/default-first-difference')?.expect.stdout, generated.find(vector => vector.name === 'cmp/default-first-difference')?.expect.stdout)
  assert.equal(committedVectors.find(vector => vector.name === 'cmp/long-lists-bytes')?.expect.stdout, generated.find(vector => vector.name === 'cmp/long-lists-bytes')?.expect.stdout)
  assert.equal(committedVectors.find(vector => vector.name === 'cmp/missing-operands')?.expect.stderr, generated.find(vector => vector.name === 'cmp/missing-operands')?.expect.stderr)
})

test('cmp goldens: --write and --check round-trip through the CLI', {
  skip: !bsdHost ? `host cmp is ${flavor}; the CLI comparison needs the generated shape` : false,
}, (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-cmp-golden-cli-'))
  const file = join(directory, 'worker-shell.jsonl')
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  // A stale expectation in the copy: --write must replace it, --check must
  // notice it before the write.
  writeFileSync(file, committed.replace('"stdout":"notes/a.md notes/b.md differ: char 7, line 2\\n"', '"stdout":"stale\\n"'), 'utf8')
  const drift = spawnSync(process.execPath, [tool, '--check', '--golden', file, '--quiet'], { cwd: pluginRoot, encoding: 'utf8', timeout: 120_000 })
  assert.equal(drift.status, 1, `${drift.stdout}\n${drift.stderr}`)
  const write = spawnSync(process.execPath, [tool, '--write', '--golden', file, '--quiet'], { cwd: pluginRoot, encoding: 'utf8', timeout: 120_000 })
  assert.equal(write.status, 0, `${write.stdout}\n${write.stderr}`)
  assert.equal(readFileSync(file, 'utf8'), committed)
  const clean = spawnSync(process.execPath, [tool, '--check', '--golden', file, '--quiet'], { cwd: pluginRoot, encoding: 'utf8', timeout: 120_000 })
  assert.equal(clean.status, 0, `${clean.stdout}\n${clean.stderr}`)
})

test('cmp goldens: --write replaces the cmp block in place and preserves every non-cmp vector', () => {
  const before = { name: 'fixture/before', category: 'files', cmd: 'echo before', expect: { stdout: 'before\n', exit: 0 } }
  const after = { name: 'fixture/after', category: 'files', cmd: 'echo after', expect: { stdout: 'after\n', exit: 0 } }
  const sample = [
    JSON.stringify(before),
    JSON.stringify({ name: 'cmp/old', category: 'files', cmd: 'cmp a b', expect: { stdout: '', stderr: '', exit: 0 } }),
    JSON.stringify(after),
    '',
  ].join('\n')
  const generated = committedVectors.map(vector => ({
    name: vector.name,
    category: vector.category,
    cmd: vector.cmd,
    fixture: vector.fixture,
    expect: vector.expect,
  }))
  const next = replaceCmpVectors(sample, generated)
  const lines = next.trimEnd().split('\n')
  assert.deepEqual(JSON.parse(lines[0]), before)
  assert.deepEqual(lines.slice(1, 1 + generated.length), generated.map(vector => JSON.stringify(vector)))
  assert.deepEqual(JSON.parse(lines[1 + generated.length]), after)
  assert.equal(next.includes('cmp/old'), false)
})

test('cmp goldens: --write is stable when another group appends after the cmp block', () => {
  const before = { name: 'fixture/before', category: 'files', cmd: 'echo before', expect: { stdout: 'before\n', exit: 0 } }
  const after = { name: 'fixture/after', category: 'files', cmd: 'echo after', expect: { stdout: 'after\n', exit: 0 } }
  const later = { name: 'fixture/later', category: 'files', cmd: 'echo later', expect: { stdout: 'later\n', exit: 0 } }
  const sample = [
    JSON.stringify(before),
    ...committedVectors.map(vector => JSON.stringify(vector)),
    JSON.stringify(after),
    JSON.stringify(later),
    '',
  ].join('\n')
  const generated = committedVectors.map(vector => ({
    name: vector.name,
    category: vector.category,
    cmd: vector.cmd,
    fixture: vector.fixture,
    expect: vector.expect,
  }))
  const once = replaceCmpVectors(sample, generated)
  assert.equal(replaceCmpVectors(once, generated), once, 'a second write must not move the block')
  const records = once.trimEnd().split('\n').map(line => JSON.parse(line))
  assert.deepEqual(records.filter(record => !record.name.startsWith(CMP_VECTOR_PREFIX)), [before, after, later])
})

// SPDX-License-Identifier: MIT
// Pin verification tests: the success fact and the failure paths the image
// tooling must never paper over (wrong HEAD, tracked modifications, untracked
// files the packer would read, an unset checkout).
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { PIN_PATH, REQUIRED_BUILDS, readPin, verifyCheckout } from './dsh-checkout.mjs'

const script = fileURLToPath(new URL('./dsh-checkout.mjs', import.meta.url))
const pin = readPin()
const scratch = []

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/** Run git in a fake checkout and return trimmed stdout. */
function git(directory, ...args) {
  return execFileSync('git', ['-C', directory, ...args], { encoding: 'utf8' }).trim()
}

/** Commit every change and return the new HEAD. */
function commitAll(directory, message) {
  execFileSync('git', ['-C', directory, 'add', '-A'])
  execFileSync('git', ['-C', directory, 'commit', '-q', '-m', message])
  return git(directory, 'rev-parse', 'HEAD')
}

/**
 * Build a minimal fake checkout with a real git history.
 * @param {string} [head] - commit sha to report; the new commit when omitted.
 * @returns {{ directory: string, commit: string }}
 */
function fakeCheckout(head) {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-pin-test-'))
  scratch.push(directory)
  execFileSync('git', ['-C', directory, 'init', '-q'])
  execFileSync('git', ['-C', directory, 'config', 'user.email', 'worker@example.invalid'])
  execFileSync('git', ['-C', directory, 'config', 'user.name', 'worker'])
  for (const file of REQUIRED_BUILDS) {
    mkdirSync(dirname(join(directory, file)), { recursive: true })
    writeFileSync(join(directory, file), '// built\n')
  }
  mkdirSync(join(directory, 'apps', 'cli'), { recursive: true })
  writeFileSync(join(directory, 'apps', 'cli', 'package.json'), '{"name":"@deepseek-ai/dsh","version":"0.2.1-rc.2"}\n')
  writeFileSync(join(directory, 'tracked.txt'), 'pinned\n')
  const commit = commitAll(directory, 'pinned tree')
  return { directory, commit: head ?? commit }
}

test('the repository pin names the full commit and the 0.2.1 profile', () => {
  assert.equal(pin.repo, 'https://github.com/deepseek-ai/deepseek-harness')
  assert.equal(pin.version, '0.2.1-rc.2')
  assert.match(pin.commit, /^[0-9a-f]{40}$/)
  assert.equal(resolve(PIN_PATH, '..'), fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, ''))
})

test('a clean checkout at the pinned commit verifies', () => {
  const { directory, commit } = fakeCheckout()
  const facts = verifyCheckout({ checkout: directory, pin: { ...pin, commit } })
  assert.equal(facts.head, commit)
  assert.equal(facts.clean, true)
  assert.equal(facts.pin.commit, commit)
  for (const file of REQUIRED_BUILDS) assert.equal(facts.built[file], true)
})

test('a different HEAD fails before any other fact is trusted', () => {
  const { directory } = fakeCheckout()
  const unrelated = '0'.repeat(40)
  assert.throws(
    () => verifyCheckout({ checkout: directory, pin: { ...pin, commit: unrelated } }),
    /HEAD is .*but dsh-pin\.json pins/,
  )
})

test('a checkout whose installation version differs from the pin fails', () => {
  const { directory, commit } = fakeCheckout()
  writeFileSync(join(directory, 'apps', 'cli', 'package.json'), '{"name":"@deepseek-ai/dsh","version":"9.9.9"}\n')
  commitAll(directory, 'different version')
  assert.throws(
    () => verifyCheckout({ checkout: directory, pin: { ...pin, commit: git(directory, 'rev-parse', 'HEAD') } }),
    /checkout version is 9\.9\.9, but dsh-pin\.json pins/,
  )
})

test('a tracked modification fails the clean-tree check', () => {
  const { directory, commit } = fakeCheckout()
  writeFileSync(join(directory, 'tracked.txt'), 'locally modified\n')
  assert.throws(() => verifyCheckout({ checkout: directory, pin: { ...pin, commit } }), /tracked modifications/)
})

test('an untracked file under a materialized package fails the clean-tree check', () => {
  const { directory } = fakeCheckout()
  // A tracked package admits extra locale files through its `files` allowlist;
  // the packer reads the live directory, so HEAD alone is not enough.
  const packageDirectory = join(directory, 'packages', 'host', 'webserver')
  mkdirSync(join(packageDirectory, 'locale'), { recursive: true })
  writeFileSync(join(packageDirectory, 'package.json'), JSON.stringify({
    name: '@deepseek-ai/dsh-host-webserver',
    files: ['locale/*.json'],
  }))
  writeFileSync(join(packageDirectory, 'locale', 'base.json'), '{}\n')
  const commit = commitAll(directory, 'add materialized package')
  writeFileSync(join(packageDirectory, 'locale', 'extra.json'), '{"injected":true}\n')
  assert.throws(
    () => verifyCheckout({ checkout: directory, pin: { ...pin, commit } }),
    /untracked files under a root the image packer reads/,
  )
})

test('an untracked workspace package directory fails the clean-tree check', () => {
  const { directory, commit } = fakeCheckout()
  // indexWorkspacePackages would pick this package up even though it is not in
  // the pinned tree.
  mkdirSync(join(directory, 'packages', 'new-package'), { recursive: true })
  writeFileSync(join(directory, 'packages', 'new-package', 'package.json'), '{"name":"@scope/new"}\n')
  assert.throws(
    () => verifyCheckout({ checkout: directory, pin: { ...pin, commit } }),
    /untracked files under a root the image packer reads/,
  )
})

test('unrelated untracked scratch outside image roots is reported but tolerated', () => {
  const { directory, commit } = fakeCheckout()
  mkdirSync(join(directory, 'notes'), { recursive: true })
  writeFileSync(join(directory, 'notes', 'scratch.txt'), 'unrelated\n')
  writeFileSync(join(directory, 'datasheet.pdf'), 'unrelated\n')
  const facts = verifyCheckout({ checkout: directory, pin: { ...pin, commit } })
  assert.equal(facts.clean, true)
  assert.deepEqual(facts.untrackedOutsideImageRoots, ['datasheet.pdf', 'notes/scratch.txt'])
})

test('an unset PDSH_DSH_CHECKOUT fails with the environment variable named', () => {
  assert.throws(() => verifyCheckout({ checkout: undefined, pin }), /PDSH_DSH_CHECKOUT is not set/)
  assert.throws(() => verifyCheckout({ checkout: '   ', pin }), /PDSH_DSH_CHECKOUT is not set/)
})

test('a checkout without the built runtime and packer fails', () => {
  const { directory } = fakeCheckout()
  rmSync(join(directory, REQUIRED_BUILDS[0]))
  // Commit the removal so the tree is clean and the missing build is the only
  // failure under test.
  execFileSync('git', ['-C', directory, 'add', '-A'])
  execFileSync('git', ['-C', directory, 'commit', '-q', '-m', 'drop build'])
  const head = execFileSync('git', ['-C', directory, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  assert.throws(
    () => verifyCheckout({ checkout: directory, pin: { ...pin, commit: head } }),
    /missing built artifacts/,
  )
})

test('the CLI exits nonzero with a clear message when PDSH_DSH_CHECKOUT is unset', () => {
  const env = { ...process.env }
  delete env.PDSH_DSH_CHECKOUT
  const result = spawnSync(process.execPath, [script, '--verify'], { env, encoding: 'utf8' })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /PDSH_DSH_CHECKOUT is not set/)
})

test('the CLI exits nonzero when HEAD differs from the pin', () => {
  const { directory } = fakeCheckout()
  const result = spawnSync(process.execPath, [script, '--verify'], {
    env: { ...process.env, PDSH_DSH_CHECKOUT: directory },
    encoding: 'utf8',
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /HEAD is/)
})

test('the CLI explicit commit/version pair verifies and keeps the canonical pin', () => {
  const { directory, commit } = fakeCheckout()
  const result = spawnSync(process.execPath, [
    script, '--print-json', '--commit', commit, '--version', pin.version,
  ], {
    env: { ...process.env, PDSH_DSH_CHECKOUT: directory },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  const facts = JSON.parse(result.stdout)
  assert.equal(facts.head, commit)
  assert.equal(facts.pin.commit, commit)
  assert.equal(facts.canonicalPin.commit, pin.commit)
  assert.equal(facts.canonicalPin.version, pin.version)
})

test('the CLI rejects a lone --commit before touching the checkout', () => {
  const result = spawnSync(process.execPath, [
    script, '--print-json', '--commit', pin.commit,
  ], {
    env: { ...process.env, PDSH_DSH_CHECKOUT: '/nonexistent' },
    encoding: 'utf8',
  })
  assert.equal(result.status, 2)
  assert.match(result.stderr, /--commit and --version must be supplied together/)
})

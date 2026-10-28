// SPDX-License-Identifier: MIT
/**
 * G2-FIX-31 component corpus: option handling in the Worker git porcelain.
 *
 * The G2 scenario batch found the class of defect this gate covers: a
 * subcommand accepted an option it did not implement (`git log --format=…`
 * printed the default long format with exit 0), and the porcelain was missing
 * options the models reach for (`git config`, `git log -1`). The vectors below
 * are the permanent gate:
 *
 * - formatted/limited logs are compared byte-for-byte with the system git;
 * - `git config` writes `.git/config` that the system git reads back;
 * - an unimplemented option exits non-zero, prints nothing on stdout and names
 *   the unsupported word, instead of returning output for a different request.
 *
 * Fixtures are produced by the system git (fixed HOME, identities and dates),
 * so the expected bytes never come from the implementation under test.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/porcelain-corpus.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, adaptStrictIsoOracle, diffResults, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

interface FixtureRepository {
  readonly repository: string
  readonly env: Record<string, string>
}

/** A two-commit repository whose second commit has a multi-line message. */
function buildRepository(root: string): FixtureRepository {
  const environment = fixtureEnvironment(root)
  const repository = join(root, 'repo')
  mkdirSync(repository)
  const git = (args: readonly string[]): CommandResult => systemGit(args, repository, environment.env)
  git(['init', '-q', '-b', 'main'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base commit'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\nbeta\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'second commit\n\nbody line'])
  return { repository, env: environment.env }
}

/** Vector shape: one argv whose bytes must equal the system git's. */
interface LogVector {
  readonly name: string
  readonly args: readonly string[]
}

/** Formatting and limiting vectors: each must be byte-identical to the system git. */
export const LOG_VECTORS: readonly LogVector[] = [
  { name: 'limit/-1', args: ['log', '-1'] },
  { name: 'limit/-2', args: ['log', '-2'] },
  { name: 'limit/-n-2', args: ['log', '-n', '2'] },
  { name: 'format/short-hash-name-email', args: ['log', '--format=%h %an <%ae>', '-2'] },
  { name: 'format/hash-newline-subject', args: ['log', '--format=%H%n%s', '-1'] },
  { name: 'format/hash-subject-limit', args: ['log', '--format=%h %s', '-2'] },
  { name: 'format/author-date', args: ['log', '--format=%h %s %ad', '-1'] },
  { name: 'format/strict-iso-date', args: ['log', '--format=%h %aI', '-1'] },
  { name: 'format/body-placeholder', args: ['log', '--format=%s|%b', '-1'] },
  { name: 'format/raw-placeholder', args: ['log', '--format=%B', '-1'] },
  { name: 'format/format-colon', args: ['log', '--format=format:%h', '-2'] },
  { name: 'format/style-short', args: ['log', '--format=short', '-2'] },
  { name: 'format/style-full', args: ['log', '--format=full', '-1'] },
  { name: 'format/style-fuller', args: ['log', '--format=fuller', '-1'] },
  { name: 'format/style-raw', args: ['log', '--format=raw', '-1'] },
  { name: 'format/pretty-oneline', args: ['log', '--pretty=oneline', '-2'] },
  // `--pretty` without `=` is git's valid request for the default medium style;
  // `--format` is not a synonym and a bare form is a loud usage error.
  { name: 'format/pretty-no-value', args: ['log', '--pretty'] },
  { name: 'format/tformat-stat', args: ['log', '--format=%h', '--stat', '-2'] },
  { name: 'format/oneline-patch', args: ['log', '--oneline', '-p', '-2'] },
  { name: 'show/patch-option', args: ['show', '--patch'] },
  { name: 'show/name-only', args: ['show', '--name-only', 'HEAD~1'] },
  { name: 'show/name-status', args: ['show', '--name-status', 'HEAD~1'] },
  { name: 'diff-tree/no-commit-id', args: ['diff-tree', '--no-commit-id', '-r', '--name-status', 'HEAD'] },
]

/** Requests the Worker git does not implement: they must fail loud and print nothing. */
export const UNSUPPORTED_VECTORS: readonly LogVector[] = [
  { name: 'format/unknown-placeholder', args: ['log', '--format=%q'] },
  { name: 'format/unsupported-decoration-placeholder', args: ['log', '--format=%d %s'] },
  { name: 'format/style-email', args: ['log', '--format=email'] },
  { name: 'format/style-reference', args: ['log', '--format=reference'] },
  { name: 'log/graph', args: ['log', '--graph', '--oneline'] },
  { name: 'log/decorate', args: ['log', '--decorate', '--oneline'] },
  { name: 'log/follow', args: ['log', '--follow', '--oneline'] },
  { name: 'show/follow', args: ['show', '--follow'] },
  { name: 'status/ignored', args: ['status', '--ignored'] },
  { name: 'diff/binary', args: ['diff', '--binary'] },
  { name: 'diff-tree/copies', args: ['diff-tree', '-C', 'HEAD'] },
  // Remote porcelain options the Worker git does not implement. They must fail
  // with a usage error naming the option before any repository or network
  // action, never silently run a different remote command and exit 0.
  { name: 'clone/single-branch', args: ['clone', '--single-branch', 'https://example.test/repository.git', 'worker-clone'] },
  { name: 'clone/no-tags', args: ['clone', '--no-tags', 'https://example.test/repository.git', 'worker-clone'] },
  { name: 'clone/origin-short', args: ['clone', '-o', 'upstream', 'https://example.test/repository.git', 'worker-clone'] },
  { name: 'clone/origin-long', args: ['clone', '--origin', 'upstream', 'https://example.test/repository.git', 'worker-clone'] },
  { name: 'fetch/prune', args: ['fetch', '--prune', 'origin'] },
  { name: 'fetch/all', args: ['fetch', '--all'] },
  { name: 'fetch/tags', args: ['fetch', '--tags'] },
  { name: 'push/set-upstream-short', args: ['push', '-u', 'origin', 'main'] },
  { name: 'push/set-upstream-long', args: ['push', '--set-upstream', 'origin', 'main'] },
  { name: 'remote/add-write', args: ['remote', 'add', 'origin', 'https://example.test/repository.git'] },
  { name: 'global/unknown-option', args: ['--exec-path=/usr/lib/git-core', 'status'] },
  { name: 'global/literal-pathspecs', args: ['--literal-pathspecs', 'status'] },
]

test('porcelain corpus: formatting and -n limits match the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const fixture = buildRepository(temp.path)
    for (const vector of LOG_VECTORS) {
      const actual = await workerGit(vector.args, fixture.repository, fixture.env)
      const oracle = systemGit(vector.args, fixture.repository, fixture.env)
      // Git 2.45 changed strict ISO UTC to `Z`; only this one vector's oracle
      // is adapted for an older system git. Every other byte still compares.
      const expected = vector.name === 'format/strict-iso-date' ? adaptStrictIsoOracle(oracle) : oracle
      const difference = diffResults(expected, actual)
      assert.equal(difference, undefined, `${vector.name}: ${difference}`)
    }
  } finally {
    temp.cleanup()
  }
})

test('porcelain corpus: a bare --format is a loud usage error like the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const fixture = buildRepository(temp.path)
    const actual = await workerGit(['log', '--format'], fixture.repository, fixture.env)
    const expected = systemGit(['log', '--format'], fixture.repository, fixture.env)
    const difference = diffResults(expected, actual)
    assert.equal(difference, undefined, `format/no-value: ${difference}`)
    assert.notEqual(actual.code, 0, 'format/no-value: does not fall back to the default format')
    assert.equal(actual.stdout.byteLength, 0, 'format/no-value: prints no log')
    assert.match(actual.stderr.toString(), /--format/, 'format/no-value: names --format')
  } finally {
    temp.cleanup()
  }
})

test('porcelain corpus: unimplemented options fail loud instead of printing a different result', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const fixture = buildRepository(temp.path)
    for (const vector of UNSUPPORTED_VECTORS) {
      const result = await workerGit(vector.args, fixture.repository, fixture.env)
      assert.notEqual(result.code, 0, `${vector.name}: exits non-zero`)
      assert.equal(result.stdout.byteLength, 0, `${vector.name}: writes nothing to stdout (${JSON.stringify(result.stdout.toString())})`)
      assert.match(result.stderr.toString(), /unsupported/i, `${vector.name}: names the unsupported option`)
    }
  } finally {
    temp.cleanup()
  }
})

test('porcelain corpus: git config set/get round-trips through .git/config', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const fixture = buildRepository(temp.path)
    const ourGit = async (args: readonly string[]): Promise<CommandResult> => workerGit(args, fixture.repository, fixture.env)
    const system = (args: readonly string[]): CommandResult => systemGit(args, fixture.repository, fixture.env)

    // Unset keys answer with exit 1 and no output, like git.
    const unset = await ourGit(['config', 'user.name'])
    assert.equal(unset.code, 1)
    assert.equal(unset.stdout.byteLength, 0)

    const name = await ourGit(['config', 'user.name', 'Worker Author'])
    assert.equal(name.code, 0, name.stderr.toString())
    assert.equal(name.stdout.byteLength, 0)
    assert.equal((await ourGit(['config', '--get', 'user.name'])).stdout.toString(), 'Worker Author\n')
    assert.equal(system(['config', '--local', '--get', 'user.name']).stdout.toString(), 'Worker Author\n')

    const email = await ourGit(['config', '--local', 'user.email', 'worker@localhost'])
    assert.equal(email.code, 0, email.stderr.toString())
    assert.equal((await ourGit(['config', '--local', '--get', 'user.email'])).stdout.toString(), 'worker@localhost\n')
    assert.equal(system(['config', '--local', '--get', 'user.email']).stdout.toString(), 'worker@localhost\n')

    const remote = await ourGit(['config', 'remote.origin.url', 'https://example.test/repository.git'])
    assert.equal(remote.code, 0, remote.stderr.toString())
    assert.equal(system(['config', '--local', '--get', 'remote.origin.url']).stdout.toString(), 'https://example.test/repository.git\n')

    const overridden = await ourGit(['-c', 'user.name=Override', 'config', '--get', 'user.name'])
    assert.equal(overridden.stdout.toString(), 'Override\n')

    const listed = await ourGit(['remote', '-v'])
    assert.equal(listed.code, 0, listed.stderr.toString())
    assert.equal(listed.stdout.toString(), 'origin\thttps://example.test/repository.git (fetch)\norigin\thttps://example.test/repository.git (push)\n')

    // The writer preserves sections it does not model.
    const configText = readFileSync(join(fixture.repository, '.git', 'config'), 'utf8')
    assert.match(configText, /\[core\]/)
    assert.match(configText, /\[user\]/)
    assert.match(configText, /\[remote "origin"\]/)

    const missing = await ourGit(['config', '--get', 'does.not.exist'])
    assert.equal(missing.code, 1)
    assert.equal(missing.stdout.byteLength, 0)

    for (const args of [
      ['config', '--global', 'user.name', 'x'],
      ['config', '--unset', 'user.name'],
      ['config', '-h'],
    ] as const) {
      const result = await ourGit(args)
      assert.notEqual(result.code, 0, `${args.join(' ')}: exits non-zero`)
    }
    const help = await ourGit(['config', '-h'])
    assert.match(help.stdout.toString(), /^usage: git config/)
    const logHelp = await ourGit(['log', '-h'])
    assert.equal(logHelp.code, 129)
    assert.match(logHelp.stdout.toString(), /^usage: git log/)
  } finally {
    temp.cleanup()
  }
})

// SPDX-License-Identifier: MIT
/**
 * Golden tests for the history/branch option surface: `branch -a/-r/-v/-vv/-avv`,
 * `log --date=short/--reverse`, `show <rev>:<path>` and `diff --no-index`.
 *
 * Every expectation is captured from the system git on a fixture it built
 * itself. The vectors that already worked on the baseline (`branch --list` and
 * `log --oneline <rev>`) stay here as NO_ACTION regression coverage.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/history-options.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, symlinkSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, adaptStrictIsoOracle, copyRepository, diffResults, fixtureEnvironment, systemGit, tempDirectory, workerGit,
  writeFile,
} from './helpers.ts'
import type { CommandResult, FixtureEnvironment } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

interface HistoryFixture {
  readonly repository: string
  readonly environment: FixtureEnvironment
  readonly baseCommit: string
  readonly secondCommit: string
  readonly featureCommit: string
  readonly divergeCommit: string
  readonly invalidTreeOid: string
  readonly invalidTreeCommit: string
}

/** Build a history fixture with branches, remote refs, upstreams and tags. */
function buildHistoryFixture(root: string): HistoryFixture {
  const environment = fixtureEnvironment(root)
  const repository = join(root, 'history-fixture')
  mkdirSync(repository)
  const env = environment.env
  const git = (args: readonly string[], stdin?: Buffer | string): CommandResult => {
    const result = systemGit(args, repository, env, stdin)
    assert.equal(result.code, 0, `fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
    return result
  }
  const oid = (expression: string): string => git(['rev-parse', expression]).stdout.toString().trim()

  git(['init', '-q', '-b', 'main'])
  writeFile(join(repository, 'a.txt'), 'alpha\nbeta\ngamma\n')
  // A real binary blob: the NUL byte makes git treat a diff as binary, and the
  // 0xff byte proves `show` does not round-trip through a string decoder.
  writeFile(join(repository, 'bin.dat'), Uint8Array.from([0x62, 0x00, 0x69, 0xff, 0x01, 0x02]))
  writeFile(join(repository, 'unicodé.txt'), 'héllo\n')
  mkdirSync(join(repository, 'dir', 'deep'), { recursive: true })
  writeFile(join(repository, 'dir', 'n.txt'), 'nested\n')
  writeFile(join(repository, 'dir', 'deep', 'd.txt'), 'deep\n')
  writeFile(join(repository, 'exec.sh'), '#!/bin/sh\necho hi\n', 0o755)
  git(['add', '-A'])
  git(['commit', '-qm', 'base commit'])
  const baseCommit = oid('HEAD')

  writeFile(join(repository, 'a.txt'), 'alpha\nBETA\ngamma\ndelta\n')
  git(['add', 'a.txt'])
  git(['commit', '-qm', 'second commit'])
  const secondCommit = oid('HEAD')

  git(['checkout', '-q', '-b', 'feature', baseCommit])
  writeFile(join(repository, 'feature.txt'), 'feature only\n')
  git(['add', 'feature.txt'])
  git(['commit', '-qm', 'feature work'])
  const featureCommit = oid('HEAD')

  git(['checkout', '-q', 'main'])
  git(['branch', 'topic', baseCommit])
  git(['branch', 'behind', baseCommit])
  git(['branch', 'noupstream', secondCommit])
  // A CJK branch name is four terminal columns wide but two UTF-16 code units;
  // `branch -v` aligns its oid column by display width, not string length.
  git(['branch', '分支', baseCommit])
  git(['branch', '分支-上游', baseCommit])
  // One- and two-byte ASCII names make the wildmatch/UTF-16 difference
  // observable: `??` selects `zz`, never the six-byte CJK name, and `[z-a]`
  // follows git's descending-range behaviour instead of throwing.
  git(['branch', 'z', baseCommit])
  git(['branch', 'zz', baseCommit])
  git(['checkout', '-q', '-b', 'diverge', baseCommit])
  writeFile(join(repository, 'diverge.txt'), 'diverge only\n')
  git(['add', 'diverge.txt'])
  git(['commit', '-qm', 'diverge work'])
  const divergeCommit = oid('HEAD')
  git(['checkout', '-q', 'main'])

  git(['update-ref', 'refs/remotes/origin/main', secondCommit])
  git(['update-ref', 'refs/remotes/origin/feature', baseCommit])
  git(['update-ref', 'refs/remotes/origin/behind', secondCommit])
  git(['update-ref', 'refs/remotes/origin/diverge', secondCommit])
  // A normal clone materialises refs/remotes/origin/HEAD as a symbolic ref;
  // `git branch -r`/`-a` must show it as `origin/HEAD -> origin/main`.
  git(['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
  // System git only treats `branch.<name>.remote` as an upstream when that
  // remote is configured, so the fixture configures one without network use.
  git(['config', 'remote.origin.url', 'https://example.invalid/fixture.git'])
  git(['config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*'])
  git(['config', 'branch.main.remote', 'origin'])
  git(['config', 'branch.main.merge', 'refs/heads/main'])
  git(['config', 'branch.feature.remote', 'origin'])
  git(['config', 'branch.feature.merge', 'refs/heads/feature'])
  git(['config', 'branch.behind.remote', 'origin'])
  git(['config', 'branch.behind.merge', 'refs/heads/main'])
  git(['config', 'branch.diverge.remote', 'origin'])
  git(['config', 'branch.diverge.merge', 'refs/heads/main'])
  git(['config', 'branch.分支-上游.remote', 'origin'])
  git(['config', 'branch.分支-上游.merge', 'refs/heads/main'])
  git(['tag', 'v1.0', baseCommit])
  git(['tag', '-a', 'v2.0', '-m', 'tag two', secondCommit])
  git(['checkout', '-q', 'main'])

  // Build a tree whose entry name is not valid UTF-8 through plumbing only:
  // several file systems cannot store such a name, but git tree objects can.
  // `show <tree>` must copy the raw 0xff byte, not a U+FFFD replacement.
  const badBlob = git(['hash-object', '-w', '--stdin'], Buffer.from('bad contents\n')).stdout.toString().trim()
  const invalidTreeOid = git(['mktree', '-z'], Buffer.concat([
    Buffer.from(`40000 tree ${oid('HEAD:dir/deep')}\tdeep\0`),
    Buffer.from(`100644 blob ${badBlob}\tf`),
    Buffer.from([0xff]),
    Buffer.from('.txt\0'),
    Buffer.from(`100644 blob ${oid('HEAD:dir/n.txt')}\tn.txt\0`),
  ])).stdout.toString().trim()
  const invalidRootTree = git(['mktree', '-z'], Buffer.from(`40000 tree ${invalidTreeOid}\tdir\0`)).stdout.toString().trim()
  const invalidTreeCommit = git(['commit-tree', invalidRootTree, '-m', 'invalid name tree']).stdout.toString().trim()
  git(['branch', 'invalid-tree', invalidTreeCommit])

  return {
    repository, environment, baseCommit, secondCommit, featureCommit, divergeCommit,
    invalidTreeOid, invalidTreeCommit,
  }
}

test('history options match the system git', { skip }, async t => {
  const temp = tempDirectory()
  try {
    const fixture = buildHistoryFixture(temp.path)
    const env = fixture.environment.env
    const root = fixture.repository

    await t.test('branch -a lists local then remote refs, never tags', async () => {
      const expected = systemGit(['branch', '-a'], root, env)
      const actual = await workerGit(['branch', '-a'], root, env)
      expectSame('branch -a', expected, actual)
      assert.match(actual.stdout.toString(), /^ {2}remotes\/origin\/main$/m)
      assert.match(actual.stdout.toString(), /^ {2}remotes\/origin\/HEAD -> origin\/main$/m)
      assert.doesNotMatch(actual.stdout.toString(), /refs\/tags|tags\//)
    })

    await t.test('branch -r lists remote refs without the remotes/ prefix', async () => {
      const expected = systemGit(['branch', '-r'], root, env)
      const actual = await workerGit(['branch', '-r'], root, env)
      expectSame('branch -r', expected, actual)
      assert.match(actual.stdout.toString(), /^ {2}origin\/main$/m)
      assert.match(actual.stdout.toString(), /^ {2}origin\/HEAD -> origin\/main$/m)
    })

    await t.test('branch -v aligns names and prints the subject', async () => {
      const expected = systemGit(['branch', '-v'], root, env)
      const actual = await workerGit(['branch', '-v'], root, env)
      expectSame('branch -v', expected, actual)
      assert.match(actual.stdout.toString(), /^ {2}feature\s+[0-9a-f]{7} \[ahead 1\] feature work$/m)
      assert.match(actual.stdout.toString(), /^ {2}behind\s+[0-9a-f]{7} \[behind 1\] base commit$/m)
    })

    await t.test('branch -vv prints the upstream and divergence', async () => {
      const expected = systemGit(['branch', '-vv'], root, env)
      const actual = await workerGit(['branch', '-vv'], root, env)
      expectSame('branch -vv', expected, actual)
      assert.match(actual.stdout.toString(), /\[origin\/main\] second commit/)
      assert.match(actual.stdout.toString(), /\[origin\/feature: ahead 1\] feature work/)
      assert.match(actual.stdout.toString(), /\[origin\/main: behind 1\] base commit/)
      assert.match(actual.stdout.toString(), /\[origin\/main: ahead 1, behind 1\] diverge work/)
    })

    await t.test('branch -v aligns CJK branch names by display width', async () => {
      for (const [label, args] of [
        ['CJK branch -v', ['branch', '-v']],
        ['CJK branch -vv', ['branch', '-vv']],
        ['CJK branch -avv', ['branch', '-avv']],
      ] as const) {
        const expected = systemGit([...args], root, env)
        const actual = await workerGit([...args], root, env)
        expectSame(label, expected, actual)
      }
      const verbose = (await workerGit(['branch', '-vv'], root, env)).stdout.toString()
      // The widest local name is `invalid-tree` (12 columns), so `分支` (4
      // columns) has eight padding spaces plus the one-column separator and
      // `分支-上游` (9) has three plus the separator.
      assert.match(verbose, /^ {2}分支 {9}[0-9a-f]{7} base commit$/m)
      assert.match(verbose, /^ {2}分支-上游 {4}[0-9a-f]{7} \[origin\/main: behind 1\] base commit$/m)
    })

    await t.test('branch -avv combines all and verbose', async () => {
      expectSame(
        'branch -avv',
        systemGit(['branch', '-avv'], root, env),
        await workerGit(['branch', '-avv'], root, env),
      )
      expectSame(
        'branch -av',
        systemGit(['branch', '-av'], root, env),
        await workerGit(['branch', '-av'], root, env),
      )
      expectSame(
        'branch -vv --list',
        systemGit(['branch', '-vv', '--list', 'm*'], root, env),
        await workerGit(['branch', '-vv', '--list', 'm*'], root, env),
      )
    })

    await t.test('branch renders detached HEAD in every verbose shape', async () => {
      const detached = join(temp.path, 'detached-fixture')
      copyRepository(root, detached)
      systemGit(['checkout', '-q', '--detach', 'HEAD~1'], detached, env)
      for (const [label, args] of [
        ['detached branch -v', ['branch', '-v']],
        ['detached branch -vv', ['branch', '-vv']],
        ['detached branch -av', ['branch', '-av']],
        ['detached branch -avv', ['branch', '-avv']],
        ['detached branch --list HEAD', ['branch', '-v', '--list', 'HEAD']],
        ['detached branch --list main', ['branch', '-v', '--list', 'main']],
        ['detached branch --list no match', ['branch', '-v', '--list', 'nomatch*']],
        ['detached branch -a --list HEAD', ['branch', '-a', '--list', 'HEAD']],
        ['detached branch -r --list HEAD', ['branch', '-r', '--list', 'HEAD']],
      ] as const) {
        expectSame(label, systemGit([...args], detached, env), await workerGit([...args], detached, env))
      }
      const detachedVerbose = await workerGit(['branch', '-v'], detached, env)
      assert.match(
        detachedVerbose.stdout.toString(),
        /^\* \(HEAD detached at [0-9a-f]{7}\) [0-9a-f]{7} base commit$/m,
      )
      assert.equal((await workerGit(['branch', '-v', '--list', 'nomatch*'], detached, env)).stdout.length, 0)
      const detachedOnly = await workerGit(['branch', '-a', '--list', 'HEAD'], detached, env)
      assert.match(detachedOnly.stdout.toString(), /^\* \(HEAD detached at [0-9a-f]{7}\)\n$/)
      assert.equal(detachedOnly.stdout.toString().trimEnd().split('\n').length, 1)
    })

    await t.test('branch --list matches remote names without the remotes/ prefix', async () => {
      for (const [label, args] of [
        ['branch -a --list origin*', ['branch', '-a', '--list', 'origin*']],
        ['branch -a --list origin/*', ['branch', '-a', '--list', 'origin/*']],
        ['branch -a --list origin/main', ['branch', '-a', '--list', 'origin/main']],
        ['branch -a --list remotes/*', ['branch', '-a', '--list', 'remotes/*']],
        ['branch -r --list origin*', ['branch', '-r', '--list', 'origin*']],
        ['branch -r --list origin/*', ['branch', '-r', '--list', 'origin/*']],
        ['branch -r --list remotes/*', ['branch', '-r', '--list', 'remotes/*']],
        ['branch -a --list main', ['branch', '-a', '--list', 'main']],
        ['branch -a --list feature', ['branch', '-a', '--list', 'feature']],
      ] as const) {
        expectSame(label, systemGit([...args], root, env), await workerGit([...args], root, env))
      }
      assert.equal((await workerGit(['branch', '-a', '--list', 'remotes/*'], root, env)).stdout.length, 0)
      assert.equal((await workerGit(['branch', '-r', '--list', 'remotes/*'], root, env)).stdout.length, 0)
      assert.match(
        (await workerGit(['branch', '-a', '--list', 'origin*'], root, env)).stdout.toString(),
        /^ {2}remotes\/origin\/main$/m,
      )
    })

    await t.test('branch --list stays byte-for-byte (NO_ACTION)', async () => {
      const expected = systemGit(['branch', '--list', 't*'], root, env)
      const actual = await workerGit(['branch', '--list', 't*'], root, env)
      expectSame('branch --list', expected, actual)
      assert.equal(actual.stdout.toString(), '  topic\n')
    })

    await t.test('branch --list matches ref-name bytes like tag -l', async () => {
      for (const pattern of [
        '?', '??', '[z-a]', '[a-c]', '[!a]', '[^a]', '[]', '[]]', '[!]]', '[a-',
        '[[:alpha:]]', '[[:digit:]]', '[[:bogus:]]', '[[:alpha:]', '*',
      ]) {
        expectSame(
          `branch --list ${pattern}`,
          systemGit(['branch', '--list', pattern], root, env),
          await workerGit(['branch', '--list', pattern], root, env),
        )
      }
      // `?` consumes one UTF-8 byte. The old UTF-16 RegExp also selected the
      // six-byte CJK branch for `??`; git only selects the two-byte `zz`.
      const twoBytes = await workerGit(['branch', '--list', '??'], root, env)
      assert.equal(twoBytes.code, 0)
      assert.equal(twoBytes.stdout.toString(), '  zz\n')
      assert.doesNotMatch(twoBytes.stdout.toString(), /分支/)

      // `[z-a]` is a descending range. Git's wildmatch aborts the range test
      // but keeps the first endpoint literal, so only `z` matches; it does
      // not throw a JavaScript SyntaxError and does not exit 128.
      const descending = await workerGit(['branch', '--list', '[z-a]'], root, env)
      assert.equal(descending.code, 0)
      assert.equal(descending.stdout.toString(), '  z\n')
      assert.equal(descending.stderr.byteLength, 0)
      assert.doesNotMatch(descending.stderr.toString(), /SyntaxError/)
    })

    await t.test('branch -vv ignores a remote that has only a url', async () => {
      const urlOnly = join(temp.path, 'url-only-fixture')
      copyRepository(root, urlOnly)
      systemGit(['branch', 'url-only', fixture.secondCommit], urlOnly, env)
      systemGit(['config', 'remote.url-only.url', 'https://example.invalid/url-only.git'], urlOnly, env)
      systemGit(['config', 'branch.url-only.remote', 'url-only'], urlOnly, env)
      systemGit(['config', 'branch.url-only.merge', 'refs/heads/main'], urlOnly, env)
      for (const [label, args] of [
        ['url-only branch -v', ['branch', '-v']],
        ['url-only branch -vv', ['branch', '-vv']],
      ] as const) {
        const expected = systemGit([...args], urlOnly, env)
        const actual = await workerGit([...args], urlOnly, env)
        expectSame(label, expected, actual)
      }
      const verbose = await workerGit(['branch', '-vv'], urlOnly, env)
      assert.match(verbose.stdout.toString(), /^ {2}url-only\s+[0-9a-f]{7} second commit$/m)
      assert.doesNotMatch(verbose.stdout.toString(), /url-only\/main/)
    })

    await t.test('branch rejects unsupported combinations loudly', async () => {
      const result = await workerGit(['branch', '-az'], root, env)
      assert.equal(result.code, 129)
      assert.match(result.stderr.toString(), /unsupported branch option '-az'/)
      assert.equal(result.stdout.length, 0)
    })

    await t.test('log --date=short renders the default and custom dates', async () => {
      expectSame(
        'log --date=short -n2',
        systemGit(['log', '--date=short', '-n2'], root, env),
        await workerGit(['log', '--date=short', '-n2'], root, env),
      )
      expectSame(
        'log --date=short --format=%h %ad',
        systemGit(['log', '--date=short', '--format=%h %ad', '-n2'], root, env),
        await workerGit(['log', '--date=short', '--format=%h %ad', '-n2'], root, env),
      )
      expectSame(
        'log --date=short --format=%cd',
        systemGit(['log', '--date=short', '--format=%cd', '-n1'], root, env),
        await workerGit(['log', '--date=short', '--format=%cd', '-n1'], root, env),
      )
    })

    await t.test('log --date=short applies to fuller AuthorDate and CommitDate', async () => {
      expectSame(
        'log --date=short --pretty=fuller -n2',
        systemGit(['log', '--date=short', '--pretty=fuller', '-n2'], root, env),
        await workerGit(['log', '--date=short', '--pretty=fuller', '-n2'], root, env),
      )
      expectSame(
        'log --pretty=fuller -n1',
        systemGit(['log', '--pretty=fuller', '-n1'], root, env),
        await workerGit(['log', '--pretty=fuller', '-n1'], root, env),
      )
      const fuller = (await workerGit(['log', '--date=short', '--pretty=fuller', '-n1'], root, env)).stdout.toString()
      assert.match(fuller, /^AuthorDate: 2023-11-14$/m)
      assert.match(fuller, /^CommitDate: 2023-11-14$/m)
    })

    await t.test('log %aI/%cI uses canonical UTC Z and exact numeric offsets', async () => {
      // Git 2.45 made the strict ISO spelling of UTC `Z` (the release note
      // "iso-strict ... Z suffix, instead of +00:00"). The Worker always emits
      // that modern form; only an old system-git oracle is adapted above.
      const utc = await workerGit(['log', '--format=%aI %cI', '-1'], root, env)
      assert.equal(utc.stdout.toString(), '2023-11-14T22:13:20Z 2023-11-14T22:13:20Z\n')
      expectSame(
        'strict ISO UTC',
        adaptStrictIsoOracle(systemGit(['log', '--format=%aI %cI', '-1'], root, env)),
        utc,
      )

      const offsetRoot = join(temp.path, 'iso-offset')
      copyRepository(root, offsetRoot)
      const offsetEnv = {
        ...env,
        GIT_AUTHOR_DATE: '1700000000 +0530',
        GIT_COMMITTER_DATE: '1700000000 +0530',
      }
      const commit = systemGit(['commit', '--allow-empty', '-qm', 'offset date'], offsetRoot, offsetEnv)
      assert.equal(commit.code, 0, commit.stderr.toString())
      const expected = systemGit(['log', '--format=%aI %cI', '-1'], offsetRoot, offsetEnv)
      const actual = await workerGit(['log', '--format=%aI %cI', '-1'], offsetRoot, offsetEnv)
      expectSame('strict ISO nonzero offset', expected, actual)
      assert.equal(actual.stdout.toString(), '2023-11-15T03:43:20+05:30 2023-11-15T03:43:20+05:30\n')
    })

    await t.test('log rejects date formats it cannot render', async () => {
      const unsupported = await workerGit(['log', '--date=iso', '-n1'], root, env)
      assert.equal(unsupported.code, 129)
      assert.match(unsupported.stderr.toString(), /--date/)
      assert.equal(unsupported.stdout.length, 0)
      const missing = await workerGit(['log', '--date'], root, env)
      assert.equal(missing.code, 129)
      assert.match(missing.stderr.toString(), /--date/)
      assert.equal(missing.stdout.length, 0)
    })

    await t.test('log --reverse reverses after the limit', async () => {
      expectSame(
        'log --reverse -n2',
        systemGit(['log', '--reverse', '-n2'], root, env),
        await workerGit(['log', '--reverse', '-n2'], root, env),
      )
      expectSame(
        'log --reverse --oneline -n2',
        systemGit(['log', '--reverse', '--oneline', '-n2'], root, env),
        await workerGit(['log', '--reverse', '--oneline', '-n2'], root, env),
      )
    })

    await t.test('log --oneline <rev> stays byte-for-byte (NO_ACTION)', async () => {
      const expected = systemGit(['log', '--oneline', 'HEAD~1'], root, env)
      const actual = await workerGit(['log', '--oneline', 'HEAD~1'], root, env)
      expectSame('log --oneline HEAD~1', expected, actual)
      assert.equal(actual.stdout.toString(), `${fixture.baseCommit.slice(0, 7)} base commit\n`)
    })

    await t.test('show <rev>:<path> emits blob bytes unchanged', async () => {
      const blob = systemGit(['rev-parse', 'HEAD:bin.dat'], root, env).stdout.toString().trim()
      for (const [label, args] of [
        ['show HEAD:bin.dat', ['show', 'HEAD:bin.dat']],
        ['show blob oid', ['show', blob]],
        ['show HEAD:unicodé.txt', ['show', 'HEAD:unicodé.txt']],
        ['show HEAD:exec.sh', ['show', 'HEAD:exec.sh']],
      ] as const) {
        const expected = systemGit([...args], root, env)
        const actual = await workerGit([...args], root, env)
        expectSame(label, expected, actual)
      }
      const binary = await workerGit(['show', 'HEAD:bin.dat'], root, env)
      assert.deepEqual([...binary.stdout], [0x62, 0x00, 0x69, 0xff, 0x01, 0x02])
      const unicode = await workerGit(['show', 'HEAD:unicodé.txt'], root, env)
      assert.deepEqual([...unicode.stdout], [...Buffer.from('héllo\n')])
    })

    await t.test('show <rev>:<tree> prints the tree header and direct entries', async () => {
      expectSame(
        'show HEAD:dir',
        systemGit(['show', 'HEAD:dir'], root, env),
        await workerGit(['show', 'HEAD:dir'], root, env),
      )
      const treeOid = systemGit(['rev-parse', 'HEAD:dir'], root, env).stdout.toString().trim()
      expectSame(
        'show tree oid',
        systemGit(['show', treeOid], root, env),
        await workerGit(['show', treeOid], root, env),
      )
      const result = await workerGit(['show', 'HEAD:dir'], root, env)
      assert.equal(result.stdout.toString(), 'tree HEAD:dir\n\ndeep/\nn.txt\n')
    })

    await t.test('show <tree> preserves non-UTF-8 entry name bytes', async () => {
      for (const [label, args] of [
        ['show invalid tree oid', ['show', fixture.invalidTreeOid]],
        ['show invalid tree path', ['show', `${fixture.invalidTreeCommit}:dir`]],
      ] as const) {
        expectSame(label, systemGit([...args], root, env), await workerGit([...args], root, env))
      }
      const raw = await workerGit(['show', fixture.invalidTreeOid], root, env)
      assert.ok(raw.stdout.includes(Buffer.from([0x66, 0xff, 0x2e, 0x74, 0x78, 0x74, 0x0a])))
      assert.equal(raw.stdout.includes(Buffer.from([0xef, 0xbf, 0xbd])), false)
    })

    await t.test('show an annotated tag prints the tag header before the commit', async () => {
      for (const [label, args] of [
        ['show v2.0', ['show', 'v2.0']],
        ['show --oneline v2.0', ['show', '--oneline', 'v2.0']],
        ['show -s v2.0', ['show', '-s', 'v2.0']],
      ] as const) {
        expectSame(label, systemGit([...args], root, env), await workerGit([...args], root, env))
      }
      const result = await workerGit(['show', 'v2.0'], root, env)
      assert.match(result.stdout.toString(), /^tag v2\.0$/m)
      assert.match(result.stdout.toString(), /^Tagger: Fixture Author <fixture@localhost>$/m)
      assert.match(result.stdout.toString(), /^Date:   /m)
      assert.match(result.stdout.toString(), /^tag two$/m)
      const oneline = await workerGit(['show', '--oneline', 'v2.0'], root, env)
      assert.match(oneline.stdout.toString(), /^tag v2\.0$/m)
      assert.doesNotMatch(oneline.stdout.toString(), /^Tagger:/m)
    })

    await t.test('show a missing path keeps the fatal 128', async () => {
      expectSame(
        'show missing path',
        systemGit(['show', 'HEAD:missing.txt'], root, env),
        await workerGit(['show', 'HEAD:missing.txt'], root, env),
      )
    })

    await t.test('diff --no-index matches the system git for regular files', async () => {
      const files = join(temp.path, 'no-index')
      mkdirSync(files)
      writeFile(join(files, 'a.txt'), 'a\nb\nc\n')
      writeFile(join(files, 'b.txt'), 'a\nB\nc\nd\n')
      writeFile(join(files, 'same1.txt'), 'same\n')
      writeFile(join(files, 'same2.txt'), 'same\n')
      writeFile(join(files, 'bin1.dat'), Uint8Array.from([0x62, 0x00, 0x69, 0x01]))
      writeFile(join(files, 'bin2.dat'), Uint8Array.from([0x62, 0x00, 0x69, 0x02]))
      writeFile(join(files, 'unicodé-1.txt'), 'héllo\n')
      writeFile(join(files, 'unicodé-2.txt'), 'héllo!\n')
      writeFile(join(files, 'exec1.sh'), 'x\n', 0o755)
      writeFile(join(files, 'exec2.sh'), 'y\n', 0o644)

      const cSource = [
        'static int foo(void)',
        '{',
        ...Array.from({ length: 20 }, (_, index) => `\tint v${index + 1} = ${index + 1};`),
        '\treturn 0;',
        '}',
        '',
      ].join('\n')
      writeFile(join(files, 'c1.c'), cSource)
      writeFile(join(files, 'c2.c'), cSource.replace('int v10 = 10;', 'int v10 = 100;'))
      writeFile(join(files, 'crlf1.c'), cSource.replaceAll('\n', '\r\n'))
      writeFile(join(files, 'crlf2.c'), cSource.replace('int v10 = 10;', 'int v10 = 100;').replaceAll('\n', '\r\n'))
      writeFile(join(files, 'insert-old.txt'), 'a\nb\nc\n')
      writeFile(join(files, 'insert-new.txt'), 'a\nb\nc\nd\n')
      writeFile(join(files, 'delete-old.txt'), 'a\nb\nc\n')
      writeFile(join(files, 'delete-new.txt'), 'a\nb\n')

      for (const [label, args] of [
        ['no-index text', ['diff', '--no-index', 'a.txt', 'b.txt']],
        ['no-index equal', ['diff', '--no-index', 'same1.txt', 'same2.txt']],
        ['no-index binary', ['diff', '--no-index', 'bin1.dat', 'bin2.dat']],
        ['no-index unicode', ['diff', '--no-index', 'unicodé-1.txt', 'unicodé-2.txt']],
        ['no-index mode change', ['diff', '--no-index', 'exec1.sh', 'exec2.sh']],
        ['no-index context', ['diff', '--no-index', '-U1', 'a.txt', 'b.txt']],
        ['no-index C context', ['diff', '--no-index', 'c1.c', 'c2.c']],
        ['no-index C context -U0', ['diff', '--no-index', '-U0', 'c1.c', 'c2.c']],
        ['no-index CRLF context', ['diff', '--no-index', 'crlf1.c', 'crlf2.c']],
        ['no-index -U0 pure insert', ['diff', '--no-index', '-U0', 'insert-old.txt', 'insert-new.txt']],
        ['no-index -U0 pure delete', ['diff', '--no-index', '-U0', 'delete-old.txt', 'delete-new.txt']],
      ] as const) {
        expectSame(label, systemGit([...args], files, env), await workerGit([...args], files, env))
      }
      const equal = await workerGit(['diff', '--no-index', 'same1.txt', 'same2.txt'], files, env)
      assert.equal(equal.code, 0)
      assert.equal(equal.stdout.length, 0)
      const different = await workerGit(['diff', '--no-index', 'a.txt', 'b.txt'], files, env)
      assert.equal(different.code, 1)
      const pureInsert = await workerGit(
        ['diff', '--no-index', '-U0', 'insert-old.txt', 'insert-new.txt'],
        files,
        env,
      )
      assert.match(pureInsert.stdout.toString(), /^@@ -3,0 \+4 @@ c$/m)
    })

    await t.test('repository diff -U0 keeps zero-length hunk ranges and context', async () => {
      const diffRoot = join(temp.path, 'diff-u0-fixture')
      copyRepository(root, diffRoot)
      for (const [label, content, header] of [
        ['repo -U0 append', 'alpha\nBETA\ngamma\ndelta\nepsilon\n', '@@ -4,0 +5 @@ delta'],
        ['repo -U0 insert', 'alpha\nBETA\ninserted\ngamma\ndelta\n', '@@ -2,0 +3 @@ BETA'],
        ['repo -U0 delete', 'alpha\nBETA\ngamma\n', '@@ -4 +3,0 @@ gamma'],
      ] as const) {
        writeFile(join(diffRoot, 'a.txt'), content)
        const expected = systemGit(['diff', '-U0'], diffRoot, env)
        const actual = await workerGit(['diff', '-U0'], diffRoot, env)
        expectSame(label, expected, actual)
        assert.match(actual.stdout.toString(), new RegExp(`^${header.replaceAll('+', '\\+')}$`, 'm'))
      }
    })

    await t.test('diff --no-index keeps default-context multi-hunk boundaries', async () => {
      const files = join(temp.path, 'no-index-multihunk')
      mkdirSync(files)
      const lines = Array.from({ length: 21 }, (_value, index) => `line${index + 1}`)
      const changed = [...lines]
      changed[0] = 'LINE1'
      changed[10] = 'LINE11'
      writeFile(join(files, 'multi-old.txt'), `${lines.join('\n')}\n`)
      writeFile(join(files, 'multi-new.txt'), `${changed.join('\n')}\n`)
      for (const args of [
        ['diff', '--no-index', 'multi-old.txt', 'multi-new.txt'],
        ['diff', '--no-index', '-U3', 'multi-old.txt', 'multi-new.txt'],
      ] as const) {
        expectSame(
          `no-index multi-hunk ${args.join(' ')}`,
          systemGit([...args], files, env),
          await workerGit([...args], files, env),
        )
      }
      const actual = await workerGit(
        ['diff', '--no-index', 'multi-old.txt', 'multi-new.txt'],
        files,
        env,
      )
      assert.match(actual.stdout.toString(), /^@@ -1,4 \+1,4 @@$/m)
      assert.match(actual.stdout.toString(), /^@@ -8,7 \+8,7 @@ line7$/m)
      assert.equal(actual.stdout.toString().match(/^@@/gm)?.length, 2)
    })

    await t.test('diff --no-index splits exactly when the gap exceeds 2 * context', async () => {
      const files = join(temp.path, 'no-index-boundary')
      mkdirSync(files)
      const lines = Array.from({ length: 21 }, (_value, index) => `line${index + 1}`)
      for (const [name, secondChange, hunkCount] of [
        ['gap6', 7, 1],
        ['gap7', 8, 2],
      ] as const) {
        const changed = [...lines]
        changed[0] = 'FIRST'
        changed[secondChange] = 'SECOND'
        writeFile(join(files, `${name}-old.txt`), `${lines.join('\n')}\n`)
        writeFile(join(files, `${name}-new.txt`), `${changed.join('\n')}\n`)
        const args = ['diff', '--no-index', `${name}-old.txt`, `${name}-new.txt`]
        const expected = systemGit([...args], files, env)
        const actual = await workerGit([...args], files, env)
        expectSame(`no-index ${name}`, expected, actual)
        assert.equal(actual.stdout.toString().match(/^@@/gm)?.length, hunkCount)
      }
    })

    await t.test('repository diff keeps default-context multi-hunk boundaries', async () => {
      const diffRoot = join(temp.path, 'diff-multihunk-fixture')
      copyRepository(root, diffRoot)
      const lines = Array.from({ length: 21 }, (_value, index) => `line${index + 1}`)
      writeFile(join(diffRoot, 'multi.txt'), `${lines.join('\n')}\n`)
      const add = systemGit(['add', 'multi.txt'], diffRoot, env)
      assert.equal(add.code, 0, add.stderr.toString())
      const commit = systemGit(['commit', '-qm', 'multi-hunk base'], diffRoot, env)
      assert.equal(commit.code, 0, commit.stderr.toString())
      const changed = [...lines]
      changed[0] = 'LINE1'
      changed[10] = 'LINE11'
      writeFile(join(diffRoot, 'multi.txt'), `${changed.join('\n')}\n`)
      const expected = systemGit(['diff'], diffRoot, env)
      const actual = await workerGit(['diff'], diffRoot, env)
      expectSame('repository multi-hunk diff', expected, actual)
      assert.match(actual.stdout.toString(), /^@@ -1,4 \+1,4 @@$/m)
      assert.match(actual.stdout.toString(), /^@@ -8,7 \+8,7 @@ line7$/m)
      assert.equal(actual.stdout.toString().match(/^@@/gm)?.length, 2)
    })

    await t.test('diff --no-index renders symbolic links as 120000 link targets', async () => {
      const files = join(temp.path, 'no-index-symlink')
      mkdirSync(files)
      writeFile(join(files, 'target-one.txt'), 'target one\n')
      writeFile(join(files, 'target-two.txt'), 'target two\n')
      symlinkSync('target-one.txt', join(files, 'link-one'))
      symlinkSync('target-two.txt', join(files, 'link-two'))
      expectSame(
        'no-index symlinks',
        systemGit(['diff', '--no-index', 'link-one', 'link-two'], files, env),
        await workerGit(['diff', '--no-index', 'link-one', 'link-two'], files, env),
      )
      const actual = await workerGit(['diff', '--no-index', 'link-one', 'link-two'], files, env)
      assert.match(actual.stdout.toString(), /^index [0-9a-f]+\.\.[0-9a-f]+ 120000$/m)
      assert.match(actual.stdout.toString(), /^-target-one\.txt$/m)
      assert.doesNotMatch(actual.stdout.toString(), /target one/)
      // A symlink and a regular file are different object shapes; real git
      // renders them as one deletion and one addition. This program does not,
      // so it must fail loud instead of following the link and silently
      // treating the target contents as a 100644 diff.
      const mixed = await workerGit(['diff', '--no-index', 'target-one.txt', 'link-one'], files, env)
      assert.equal(mixed.code, 129)
      assert.match(mixed.stderr.toString(), /symbolic link/i)
      assert.equal(mixed.stdout.length, 0)
    })

    await t.test('diff --no-index works outside a repository and with absolute paths', async () => {
      const files = join(temp.path, 'no-index')
      const old = join(files, 'a.txt')
      const updated = join(files, 'b.txt')
      expectSame(
        'no-index absolute',
        systemGit(['diff', '--no-index', old, updated], temp.path, env),
        await workerGit(['diff', '--no-index', old, updated], temp.path, env),
      )
      const result = await workerGit(['diff', '--no-index', old, updated], temp.path, env)
      assert.match(result.stdout.toString(), new RegExp(`^diff --git a/${old.slice(1)} b/${updated.slice(1)}$`, 'm'))
    })

    await t.test('diff --no-index appends a tab to space-bearing ---/+++ paths', async () => {
      const files = join(temp.path, 'no-index-spaces')
      mkdirSync(files)
      writeFile(join(files, 'sp ace.txt'), 'one\n')
      writeFile(join(files, 'sp ace2.txt'), 'two\n')
      writeFile(join(files, 'unicodé sp.txt'), 'héllo\n')
      writeFile(join(files, 'unicodé sp2.txt'), 'héllo!\n')
      for (const [label, args] of [
        ['no-index space path', ['diff', '--no-index', 'sp ace.txt', 'sp ace2.txt']],
        ['no-index unicode+space path', ['diff', '--no-index', 'unicodé sp.txt', 'unicodé sp2.txt']],
      ] as const) {
        const expected = systemGit([...args], files, env)
        const actual = await workerGit([...args], files, env)
        expectSame(label, expected, actual)
        assert.match(actual.stdout.toString(), /^--- .*\t$/m)
        assert.match(actual.stdout.toString(), /^\+\+\+ .*\t$/m)
      }
      const old = join(files, 'sp ace.txt')
      const updated = join(files, 'sp ace2.txt')
      expectSame(
        'no-index absolute space path',
        systemGit(['diff', '--no-index', old, updated], temp.path, env),
        await workerGit(['diff', '--no-index', old, updated], temp.path, env),
      )

      const spacedRoot = join(temp.path, 'diff-space-fixture')
      copyRepository(root, spacedRoot)
      writeFile(join(spacedRoot, 'sp ace.txt'), 'alpha\n')
      const add = systemGit(['add', 'sp ace.txt'], spacedRoot, env)
      assert.equal(add.code, 0, add.stderr.toString())
      const commit = systemGit(['commit', '-qm', 'space path base'], spacedRoot, env)
      assert.equal(commit.code, 0, commit.stderr.toString())
      writeFile(join(spacedRoot, 'sp ace.txt'), 'beta\n')
      expectSame(
        'repository diff space path',
        systemGit(['diff'], spacedRoot, env),
        await workerGit(['diff'], spacedRoot, env),
      )
    })

    await t.test('diff --no-index missing and directory shapes', async () => {
      const files = join(temp.path, 'no-index')
      expectSame(
        'no-index missing',
        systemGit(['diff', '--no-index', 'a.txt', 'missing.txt'], files, env),
        await workerGit(['diff', '--no-index', 'a.txt', 'missing.txt'], files, env),
      )
      mkdirSync(join(files, 'sub'))
      const directory = await workerGit(['diff', '--no-index', 'sub', 'a.txt'], files, env)
      assert.equal(directory.code, 129)
      assert.match(directory.stderr.toString(), /director/i)
      assert.match(directory.stderr.toString(), /not implemented/i)
      assert.equal(directory.stdout.length, 0)
      const single = await workerGit(['diff', '--no-index', 'a.txt'], files, env)
      assert.equal(single.code, 129)
      assert.equal(single.stdout.length, 0)
    })

    await t.test('diff recognizes --no-index only before the -- separator', async () => {
      const dashRoot = join(temp.path, 'dash-no-index-fixture')
      copyRepository(root, dashRoot)
      writeFile(join(dashRoot, '--no-index'), 'alpha\n')
      const add = systemGit(['add', '--', '--no-index'], dashRoot, env)
      assert.equal(add.code, 0, add.stderr.toString())
      const commit = systemGit(['commit', '-qm', 'dash file'], dashRoot, env)
      assert.equal(commit.code, 0, commit.stderr.toString())
      writeFile(join(dashRoot, '--no-index'), 'beta\n')
      // After `--` this is a path, not the option: the command must stay on
      // the repository diff route and print the index-vs-work-tree hunk.
      expectSame(
        'diff -- --no-index',
        systemGit(['diff', '--', '--no-index'], dashRoot, env),
        await workerGit(['diff', '--', '--no-index'], dashRoot, env),
      )
      // Before `--` the same word is the option and routes to --no-index.
      expectSame(
        'diff --no-index -- --no-index a.txt',
        systemGit(['diff', '--no-index', '--', '--no-index', 'a.txt'], dashRoot, env),
        await workerGit(['diff', '--no-index', '--', '--no-index', 'a.txt'], dashRoot, env),
      )
    })

    await t.test('diff without --no-index keeps its repository path', async () => {
      expectSame(
        'diff plain',
        systemGit(['diff'], root, env),
        await workerGit(['diff'], root, env),
      )
    })

    // Keep the fixture's commit ids referenced so a future edit that changes
    // the shape fails the compile-time contract instead of silently drifting.
    assert.ok(fixture.featureCommit.length === 40 && fixture.divergeCommit.length === 40)
  } finally {
    temp.cleanup()
  }
})

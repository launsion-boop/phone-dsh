// SPDX-License-Identifier: MIT
/**
 * G2-FIX-70 golden fidelity: `commit`'s precondition and the commit object
 * timestamps, compared byte-for-byte with the system git.
 *
 * The G2 scenario batch found two wrong outputs on the correct path:
 *
 * - `git commit` with only unstaged work-tree modifications printed
 *   "nothing to commit, working tree clean" (exit 1); the precondition compared
 *   the index tree with HEAD and never looked at the work tree (G2-B07);
 * - `git cat-file -p HEAD` printed a committer timestamp divided by 1000
 *   (`1792960 +0000` beside the author's `1792960425 +0000`), because the
 *   committer date fallback passed already-parsed seconds through the
 *   millisecond branch of the date parser (G2-B06).
 *
 * Both are golden paths: the system git builds the fixture and the Worker git
 * must emit the same bytes. When author/committer dates are unset or only one
 * side is set, each implementation uses its own wall clock; those cases are
 * compared against a bounded time window and the local timezone rather than
 * forcing unstable timestamps or OIDs to be identical.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/golden-fidelity.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, copyRepository, diffResults, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

/** Read one header from a commit object printed by `cat-file -p`. */
function commitHeader(pretty: string, name: 'author' | 'committer'): string {
  const match = new RegExp(`^${name} (.*)$`, 'm').exec(pretty)
  assert.notEqual(match, null, `cat-file -p output has a ${name} line`)
  return (match as RegExpExecArray)[1] as string
}

/** The epoch-seconds field of one `Name <email> <seconds> <tz>` header. */
function signatureSeconds(line: string): string {
  const match = /^.* <[^>]*> (-?\d+) [+-]\d{4}$/.exec(line)
  assert.notEqual(match, null, `header has git's signature shape: ${JSON.stringify(line)}`)
  return (match as RegExpExecArray)[1] as string
}

/** Parse the epoch seconds and timezone from one commit signature. */
function signatureFields(line: string): { seconds: number; timezone: string } {
  const match = /^.* <[^>]*> (-?\d+) ([+-]\d{4})$/.exec(line)
  assert.notEqual(match, null, `header has git's signature shape: ${JSON.stringify(line)}`)
  return { seconds: Number((match as RegExpExecArray)[1]), timezone: (match as RegExpExecArray)[2] as string }
}

/** The local offset git should store for a current-time signature. */
function localTimezone(seconds: number): string {
  const offset = -new Date(seconds * 1000).getTimezoneOffset()
  const sign = offset < 0 ? '-' : '+'
  const absolute = Math.abs(offset)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${sign}${pad(Math.floor(absolute / 60))}${pad(absolute % 60)}`
}

function assertCurrentDateField(
  signature: string,
  earliestSeconds: number,
  latestSeconds: number,
  label: string,
): void {
  const fields = signatureFields(signature)
  assert.ok(
    fields.seconds >= earliestSeconds && fields.seconds <= latestSeconds,
    `${label}: ${fields.seconds} is outside [${earliestSeconds}, ${latestSeconds}]`,
  )
  assert.equal(fields.timezone, localTimezone(fields.seconds), `${label}: local timezone`)
}

/**
 * A two-commit repository built by the system git. The worker copy starts from
 * the same objects, index and refs, so every later output is comparable.
 */
function buildBase(root: string, env: Record<string, string>): { repository: string; head: string } {
  const repository = join(root, 'base')
  mkdirSync(repository)
  const git = (args: readonly string[]): CommandResult => systemGit(args, repository, env)
  git(['init', '-q', '-b', 'main'])
  writeFileSync(join(repository, 'recipes.py'), 'def search(recipes):\n    return sorted(recipes)\n')
  writeFileSync(join(repository, 'pantry.py'), 'PANTRY = ["salt", "rice"]\n')
  mkdirSync(join(repository, 'tests'))
  writeFileSync(join(repository, 'tests', 'test_search.py'), 'def test_search():\n    pass\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base commit'])
  writeFileSync(join(repository, 'recipes.py'), 'def search(recipes):\n    return sorted(recipes)\n\ndef rank(recipes, pantry):\n    return recipes\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'second commit'])
  return { repository, head: git(['rev-parse', 'HEAD']).stdout.toString().trim() }
}

test('golden: a dirty work tree is not reported as clean by commit', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const base = buildBase(temp.path, env)
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(base.repository, systemRepo)
    copyRepository(base.repository, workerRepo)
    const edit = 'def search(recipes):\n    return sorted(recipes, key=lambda recipe: recipe.name)\n'
    for (const repository of [systemRepo, workerRepo]) writeFileSync(join(repository, 'recipes.py'), edit)

    const expected = systemGit(['commit', '-m', 'rank by pantry overlap'], systemRepo, env)
    const actual = await workerGit(['commit', '-m', 'rank by pantry overlap'], workerRepo, env)
    expectSame('commit with an unstaged modification', expected, actual)
    assert.equal(actual.code, 1, 'real git refuses a commit with nothing staged')
    assert.match(actual.stdout.toString(), /Changes not staged for commit:/)
    assert.doesNotMatch(actual.stdout.toString(), /working tree clean/, 'a dirty tree is not called clean')

    const workerHead = await workerGit(['rev-parse', 'HEAD'], workerRepo, env)
    assert.equal(workerHead.stdout.toString().trim(), base.head, 'the failed commit moved no ref')
    expectSame('status after the refused commit', systemGit(['status', '--porcelain'], systemRepo, env), await workerGit(['status', '--porcelain'], workerRepo, env))
    assert.equal((await workerGit(['status', '--porcelain'], workerRepo, env)).stdout.toString(), ' M recipes.py\n')

    // Staging the edit makes the same command succeed on both implementations.
    for (const repository of [systemRepo, workerRepo]) systemGit(['add', '-A'], repository, env)
    const committed = await workerGit(['commit', '-m', 'rank by pantry overlap'], workerRepo, env)
    assert.equal(committed.code, 0, committed.stderr.toString())
    const systemCommitted = systemGit(['commit', '-m', 'rank by pantry overlap'], systemRepo, env)
    assert.equal(systemCommitted.code, 0, systemCommitted.stderr.toString())
    expectSame('status after the commit', systemGit(['status', '--porcelain'], systemRepo, env), await workerGit(['status', '--porcelain'], workerRepo, env))
    expectSame('cat-file after the commit', systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env), await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env))
    expectSame('log after the commit', systemGit(['log', '-n', '1'], systemRepo, env), await workerGit(['log', '-n', '1'], workerRepo, env))
    assert.equal((await workerGit(['status', '--porcelain'], workerRepo, env)).stdout.toString(), '', 'the committed tree is clean')

    // A truly clean tree keeps real git's exact status line.
    const cleanSystem = systemGit(['commit', '-m', 'again'], systemRepo, env)
    const cleanWorker = await workerGit(['commit', '-m', 'again'], workerRepo, env)
    expectSame('commit on a clean tree', cleanSystem, cleanWorker)
    assert.equal(cleanWorker.code, 1)
    assert.equal(cleanWorker.stdout.toString(), 'On branch main\nnothing to commit, working tree clean\n')
  } finally {
    temp.cleanup()
  }
})

test('golden: commit status covers deletions and untracked files like real git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const base = buildBase(temp.path, env)
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(base.repository, systemRepo)
    copyRepository(base.repository, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      rmSync(join(repository, 'pantry.py'))
      mkdirSync(join(repository, 'drafts'))
      writeFileSync(join(repository, 'drafts', 'notes.md'), 'draft\n')
    }
    // The deleted path switches the hint to `git add/rm`; the untracked
    // directory is collapsed exactly as `status` collapses it.
    expectSame(
      'commit with a deletion and an untracked directory',
      systemGit(['commit', '-m', 'x'], systemRepo, env),
      await workerGit(['commit', '-m', 'x'], workerRepo, env),
    )
    expectSame('long status with a deletion', systemGit(['status', '--long'], systemRepo, env), await workerGit(['status', '--long'], workerRepo, env))
    expectSame('short status with a deletion', systemGit(['status', '--porcelain'], systemRepo, env), await workerGit(['status', '--porcelain'], workerRepo, env))

    // An unstaged modification that is committed with `-a` still commits.
    for (const repository of [systemRepo, workerRepo]) writeFileSync(join(repository, 'recipes.py'), 'def search(recipes):\n    return []\n')
    const systemCommit = systemGit(['commit', '-a', '-m', 'search change'], systemRepo, env)
    const workerCommit = await workerGit(['commit', '-a', '-m', 'search change'], workerRepo, env)
    assert.equal(systemCommit.code, 0, systemCommit.stderr.toString())
    assert.equal(workerCommit.code, 0, workerCommit.stderr.toString())
    expectSame('status after commit -a', systemGit(['status', '--porcelain'], systemRepo, env), await workerGit(['status', '--porcelain'], workerRepo, env))
    expectSame('cat-file after commit -a', systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env), await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env))
  } finally {
    temp.cleanup()
  }
})

test('golden: cat-file -p prints full epoch seconds for author and committer', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = { ...environment.env, GIT_AUTHOR_DATE: '1792960425 +0000', GIT_COMMITTER_DATE: '1792960425 +0000' }
    const base = buildBase(temp.path, env)
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(base.repository, systemRepo)
    copyRepository(base.repository, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      writeFileSync(join(repository, 'recipes.py'), 'def search(recipes):\n    return list(reversed(sorted(recipes)))\n')
      systemGit(['add', '-A'], repository, env)
    }
    assert.equal(systemGit(['commit', '-qm', 'dated'], systemRepo, env).code, 0)
    assert.equal((await workerGit(['commit', '-m', 'dated'], workerRepo, env)).code, 0)

    const expected = systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env)
    const actual = await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env)
    expectSame('cat-file -p HEAD', expected, actual)
    const pretty = actual.stdout.toString()
    assert.equal(signatureSeconds(commitHeader(pretty, 'author')), '1792960425')
    assert.equal(signatureSeconds(commitHeader(pretty, 'committer')), '1792960425')
    assert.equal(commitHeader(pretty, 'committer'), commitHeader(pretty, 'author'), 'author and committer use the same signature format')

  } finally {
    temp.cleanup()
  }
})

test('golden: unset author and committer dates use independent current local time', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const base = buildBase(temp.path, environment.env)
    const noDateEnv: Record<string, string | undefined> = {
      ...environment.env,
      GIT_AUTHOR_DATE: undefined,
      GIT_COMMITTER_DATE: undefined,
    }
    const fixed = '1700000000 +0000'
    const vectors: readonly {
      readonly label: string
      readonly authorDate?: string
      readonly committerDate?: string
    }[] = [
      { label: 'both dates unset' },
      { label: 'only author date set', authorDate: fixed },
      { label: 'only committer date set', committerDate: fixed },
    ]

    for (const [index, vector] of vectors.entries()) {
      const systemRepo = join(temp.path, `system-current-${index}`)
      const workerRepo = join(temp.path, `worker-current-${index}`)
      copyRepository(base.repository, systemRepo)
      copyRepository(base.repository, workerRepo)
      for (const repository of [systemRepo, workerRepo]) {
        writeFileSync(join(repository, 'current-date.txt'), `${vector.label}\n`)
        systemGit(['add', '-A'], repository, noDateEnv)
      }
      const commitEnv: Record<string, string | undefined> = { ...noDateEnv }
      if (vector.authorDate !== undefined) commitEnv.GIT_AUTHOR_DATE = vector.authorDate
      if (vector.committerDate !== undefined) commitEnv.GIT_COMMITTER_DATE = vector.committerDate

      const earliestSeconds = Math.floor(Date.now() / 1000) - 1
      const expected = systemGit(['commit', '-qm', vector.label], systemRepo, commitEnv)
      const actual = await workerGit(['commit', '-m', vector.label], workerRepo, commitEnv)
      const latestSeconds = Math.floor(Date.now() / 1000) + 1
      assert.equal(expected.code, 0, `${vector.label}: system git: ${expected.stderr.toString()}`)
      assert.equal(actual.code, 0, `${vector.label}: Worker git: ${actual.stderr.toString()}`)

      const expectedPretty = systemGit(['cat-file', '-p', 'HEAD'], systemRepo, commitEnv).stdout.toString()
      const actualPretty = (await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, commitEnv)).stdout.toString()
      for (const name of ['author', 'committer'] as const) {
        const expectedSignature = commitHeader(expectedPretty, name)
        const actualSignature = commitHeader(actualPretty, name)
        const dateWasSet = name === 'author'
          ? vector.authorDate !== undefined
          : vector.committerDate !== undefined
        if (dateWasSet) {
          assert.equal(actualSignature, expectedSignature, `${vector.label}: ${name} fixed signature`)
          assert.equal(signatureSeconds(actualSignature), '1700000000')
          assert.equal(signatureFields(actualSignature).timezone, '+0000')
        } else {
          assertCurrentDateField(expectedSignature, earliestSeconds, latestSeconds, `${vector.label}: system ${name}`)
          assertCurrentDateField(actualSignature, earliestSeconds, latestSeconds, `${vector.label}: Worker ${name}`)
        }
      }
    }
  } finally {
    temp.cleanup()
  }
})

test('golden: status, cat-file -p and log -n match real git on one fixture', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const base = buildBase(temp.path, env)
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(base.repository, systemRepo)
    copyRepository(base.repository, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      writeFileSync(join(repository, 'recipes.py'), 'def search(recipes):\n    return []\n')
      writeFileSync(join(repository, 'staged.txt'), 'staged\n')
      systemGit(['add', 'staged.txt'], repository, env)
      rmSync(join(repository, 'pantry.py'))
      mkdirSync(join(repository, 'drafts'))
      writeFileSync(join(repository, 'drafts', 'notes.md'), 'draft\n')
    }
    const vectors: readonly (readonly string[])[] = [
      ['status'],
      ['status', '--long'],
      ['status', '--short'],
      ['status', '--porcelain'],
      ['status', '--porcelain', '-z'],
      ['cat-file', '-p', 'HEAD'],
      ['cat-file', '-p', 'HEAD~1'],
      ['cat-file', '-t', 'HEAD'],
      ['log', '-n', '1'],
      ['log', '--oneline', '-n', '2'],
      ['log', '-n', '1', '--format=%H %an %ae %at %ct'],
    ]
    for (const args of vectors) {
      expectSame(args.join(' '), systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
    }
  } finally {
    temp.cleanup()
  }
})

test('golden: an unborn branch reports Initial commit instead of committing an empty root', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    mkdirSync(systemRepo)
    mkdirSync(workerRepo)
    systemGit(['init', '-q', '-b', 'main'], systemRepo, env)
    assert.equal((await workerGit(['init', '-q', '-b', 'main'], workerRepo, env)).code, 0)

    // Empty unborn repository: both refuse, no commit object is created.
    expectSame('commit in an empty repository', systemGit(['commit', '-m', 'x'], systemRepo, env), await workerGit(['commit', '-m', 'x'], workerRepo, env))
    expectSame('status in an empty repository', systemGit(['status'], systemRepo, env), await workerGit(['status'], workerRepo, env))
    assert.notEqual((await workerGit(['rev-parse', '--verify', 'HEAD'], workerRepo, env)).code, 0, 'no root commit was created')

    // Untracked files only: the report lists them and still refuses.
    for (const repository of [systemRepo, workerRepo]) writeFileSync(join(repository, 'u.txt'), 'u\n')
    expectSame('commit with untracked files only', systemGit(['commit', '-m', 'x'], systemRepo, env), await workerGit(['commit', '-m', 'x'], workerRepo, env))
    expectSame('status with untracked files only', systemGit(['status'], systemRepo, env), await workerGit(['status'], workerRepo, env))

    // A staged file creates the root commit on both; compare the resulting
    // object and tree rather than git's summary rendering.
    for (const repository of [systemRepo, workerRepo]) systemGit(['add', '-A'], repository, env)
    assert.equal(systemGit(['commit', '-qm', 'root'], systemRepo, env).code, 0)
    assert.equal((await workerGit(['commit', '-m', 'root'], workerRepo, env)).code, 0)
    expectSame('cat-file after the root commit', systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env), await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env))
    expectSame('status after the root commit', systemGit(['status', '--porcelain'], systemRepo, env), await workerGit(['status', '--porcelain'], workerRepo, env))
  } finally {
    temp.cleanup()
  }
})

test('golden: fallback date forms keep the offset the caller supplied', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const base = buildBase(temp.path, environment.env)
    // The `%ai`/`%ci` shape and RFC 2822 both reach the Date.parse fallback.
    // Their trailing offset must survive: replacing it with the local zone
    // changes the commit signature (and therefore the object id) whenever the
    // caller's offset differs from the host's. +0000/+0530 differ for every
    // fixed local zone, so this vector is not environment-dependent.
    const vectors: readonly { readonly label: string; readonly author: string; readonly committer: string }[] = [
      { label: 'git %ai shape', author: '2023-11-14 22:13:20 +0000', committer: '2023-11-14 22:13:20 +0530' },
      { label: 'RFC 2822', author: 'Tue, 14 Nov 2023 22:13:20 +0000', committer: 'Tue, 14 Nov 2023 22:13:20 +0530' },
      { label: 'RFC 2822 named UTC', author: 'Tue, 14 Nov 2023 22:13:20 GMT', committer: 'Tue, 14 Nov 2023 22:13:20 UTC' },
      { label: 'RFC named EST', author: 'Thu, 07 Apr 2005 22:13:13 EST', committer: 'Thu, 07 Apr 2005 22:13:13 EST' },
      { label: 'RFC named PDT', author: 'Thu, 07 Apr 2005 22:13:13 PDT', committer: 'Thu, 07 Apr 2005 22:13:13 PDT' },
      { label: 'RFC named CET', author: 'Thu, 07 Apr 2005 22:13:13 CET', committer: 'Thu, 07 Apr 2005 22:13:13 CET' },
    ]
    for (const [index, vector] of vectors.entries()) {
      const systemRepo = join(temp.path, `system-${index}`)
      const workerRepo = join(temp.path, `worker-${index}`)
      copyRepository(base.repository, systemRepo)
      copyRepository(base.repository, workerRepo)
      const env = { ...environment.env, GIT_AUTHOR_DATE: vector.author, GIT_COMMITTER_DATE: vector.committer }
      for (const repository of [systemRepo, workerRepo]) {
        writeFileSync(join(repository, 'dated.txt'), `${vector.label}\n`)
        systemGit(['add', '-A'], repository, env)
      }
      const systemCommit = systemGit(['commit', '-qm', vector.label], systemRepo, env)
      const workerCommit = await workerGit(['commit', '-m', vector.label], workerRepo, env)
      assert.equal(systemCommit.code, 0, `${vector.label}: system git: ${systemCommit.stderr.toString()}`)
      assert.equal(workerCommit.code, 0, `${vector.label}: worker git: ${workerCommit.stderr.toString()}`)
      const systemHead = systemGit(['rev-parse', 'HEAD'], systemRepo, env).stdout.toString()
      const workerHead = (await workerGit(['rev-parse', 'HEAD'], workerRepo, env)).stdout.toString()
      assert.equal(workerHead, systemHead, `${vector.label}: identical commit object`)
      expectSame(`${vector.label}: cat-file`, systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env), await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env))
      expectSame(`${vector.label}: dates`, systemGit(['log', '-1', '--format=%ai|%ci|%at|%ct'], systemRepo, env), await workerGit(['log', '-1', '--format=%ai|%ci|%at|%ct'], workerRepo, env))
    }
  } finally {
    temp.cleanup()
  }
})

test('golden: git date edge offsets and unsupported forms fail safely', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const base = buildBase(temp.path, environment.env)
    const vectors: readonly { readonly label: string; readonly date: string }[] = [
      { label: 'negative zero epoch offset', date: '1700000000 -0000' },
      { label: 'RFC comment after numeric offset', date: 'Thu, 07 Apr 2005 22:13:13 +0200 (CEST)' },
    ]
    for (const [index, vector] of vectors.entries()) {
      const systemRepo = join(temp.path, `system-edge-${index}`)
      const workerRepo = join(temp.path, `worker-edge-${index}`)
      copyRepository(base.repository, systemRepo)
      copyRepository(base.repository, workerRepo)
      const env = {
        ...environment.env,
        GIT_AUTHOR_DATE: vector.date,
        GIT_COMMITTER_DATE: vector.date,
      }
      for (const repository of [systemRepo, workerRepo]) {
        writeFileSync(join(repository, 'edge-date.txt'), `${vector.label}\n`)
        systemGit(['add', '-A'], repository, env)
      }
      const expected = systemGit(['commit', '-qm', vector.label], systemRepo, env)
      const actual = await workerGit(['commit', '-m', vector.label], workerRepo, env)
      assert.equal(expected.code, 0, `${vector.label}: ${expected.stderr.toString()}`)
      assert.equal(actual.code, 0, `${vector.label}: ${actual.stderr.toString()}`)
      const expectedHead = systemGit(['rev-parse', 'HEAD'], systemRepo, env)
      const actualHead = await workerGit(['rev-parse', 'HEAD'], workerRepo, env)
      expectSame(`${vector.label}: commit oid`, expectedHead, actualHead)
      expectSame(
        `${vector.label}: commit bytes`,
        systemGit(['cat-file', '-p', 'HEAD'], systemRepo, env),
        await workerGit(['cat-file', '-p', 'HEAD'], workerRepo, env),
      )
    }

    const systemRepo = join(temp.path, 'system-date-only')
    const workerRepo = join(temp.path, 'worker-date-only')
    copyRepository(base.repository, systemRepo)
    copyRepository(base.repository, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      writeFileSync(join(repository, 'date-only.txt'), 'date-only rejection\n')
      systemGit(['add', '-A'], repository, environment.env)
    }
    const dateOnlyEnv = {
      ...environment.env,
      GIT_AUTHOR_DATE: '2023-11-14',
      GIT_COMMITTER_DATE: '2023-11-14',
    }
    expectSame(
      'date-only date is rejected like the system git',
      systemGit(['commit', '-qm', 'date only'], systemRepo, dateOnlyEnv),
      await workerGit(['commit', '-m', 'date only'], workerRepo, dateOnlyEnv),
    )

    // Git accepts some undocumented timezone words but their offset is
    // ambiguous. The Worker rejects an unknown suffix instead of silently
    // substituting the host's local timezone.
    const unknownZoneEnv = {
      ...environment.env,
      GIT_AUTHOR_DATE: 'Thu, 07 Apr 2005 22:13:13 XYZ',
      GIT_COMMITTER_DATE: 'Thu, 07 Apr 2005 22:13:13 XYZ',
    }
    const unknownZone = await workerGit(['commit', '-m', 'unknown timezone'], workerRepo, unknownZoneEnv)
    assert.equal(unknownZone.code, 128)
    assert.equal(unknownZone.stdout.byteLength, 0)
    assert.match(unknownZone.stderr.toString(), /invalid date format: .* XYZ/)
  } finally {
    temp.cleanup()
  }
})

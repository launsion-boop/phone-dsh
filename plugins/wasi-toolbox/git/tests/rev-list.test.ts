// SPDX-License-Identifier: MIT
/**
 * Golden tests for `git rev-list`.
 *
 * The fixture is created by the system git with an isolated HOME, fixed
 * identity and fixed commit dates. Two tips share a committer timestamp and the
 * annotated tag peels to one of them, so `--all` exercises the tie order as
 * well as tag peeling. Every supported vector is compared byte-for-byte with
 * the system git (exit status, stdout, stderr); the merge fixture covers the
 * histories the command must refuse rather than print a simplified history it
 * cannot reproduce.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/rev-list.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, diffResults, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

/** Copy the fixture environment with one fixed commit timestamp. */
function dated(env: Record<string, string>, timestamp: number): Record<string, string> {
  return {
    ...env,
    GIT_AUTHOR_DATE: `${timestamp} +0000`,
    GIT_COMMITTER_DATE: `${timestamp} +0000`,
  }
}

interface Scenario {
  readonly repository: string
  readonly env: Record<string, string>
  readonly base: string
  readonly second: string
  readonly sideTagged: string
  readonly sideTip: string
  readonly mainTip: string
}

/**
 * Five commits in two branches: a linear base, a side branch whose first
 * commit carries the annotated tag, and a main-branch commit that shares the
 * tagged commit's timestamp. `mainTip` is HEAD.
 */
function buildScenario(root: string): Scenario {
  const environment = fixtureEnvironment(root)
  const env = environment.env
  const repository = join(root, 'scenario')
  mkdirSync(repository)
  const git = (args: readonly string[], timestamp?: number): CommandResult =>
    systemGit(args, repository, timestamp === undefined ? env : dated(env, timestamp))
  const oid = (expression: string): string => {
    const result = git(['rev-parse', expression])
    assert.equal(result.code, 0, result.stderr.toString())
    return result.stdout.toString().trim()
  }
  git(['init', '-q', '-b', 'main'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\n')
  mkdirSync(join(repository, 'dir'))
  writeFileSync(join(repository, 'dir', 'keep.txt'), 'keep\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base commit'], 1700000000)
  const base = oid('HEAD')
  writeFileSync(join(repository, 'a.txt'), 'alpha\nbeta\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'second commit'], 1700000100)
  const second = oid('HEAD')
  git(['checkout', '-q', '-b', 'side'])
  writeFileSync(join(repository, 'side.txt'), 'side\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'side commit'], 1700000200)
  const sideTagged = oid('HEAD')
  git(['tag', '-a', 'v1', '-m', 'annotated tag'], 1700000200)
  writeFileSync(join(repository, 'side.txt'), 'side\nmore\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'side tip'], 1700000300)
  const sideTip = oid('HEAD')
  git(['checkout', '-q', 'main'])
  writeFileSync(join(repository, 'main.txt'), 'main\n')
  git(['add', '-A'])
  // Same committer timestamp as the tagged side commit: --all must keep the
  // ref-name insertion order instead of falling back to an oid tiebreak.
  git(['commit', '-qm', 'main commit'], 1700000200)
  const mainTip = oid('HEAD')
  return { repository, env, base, second, sideTagged, sideTip, mainTip }
}

const VECTORS: readonly { readonly args: readonly string[]; readonly count?: boolean; readonly empty?: boolean }[] = [
  { args: ['HEAD'] },
  { args: ['HEAD~2'] },
  { args: ['--all'] },
  { args: ['v1'] },
  { args: ['--count', 'HEAD'], count: true },
  { args: ['--count', '--max-count=2', 'HEAD'], count: true },
  { args: ['--max-count=2', 'HEAD'] },
  { args: ['--max-count=0', 'HEAD'], empty: true },
  { args: ['-n2', 'HEAD'] },
  { args: ['-2', 'HEAD'] },
  { args: ['--reverse', 'HEAD'] },
  { args: ['--reverse', '--max-count=2', 'HEAD'] },
  { args: ['--first-parent', 'HEAD'] },
  { args: ['HEAD~1..HEAD'] },
  { args: ['main..side'] },
  { args: ['v1..side'] },
  { args: ['--all', 'v1'] },
  { args: ['v1', '--all'] },
  { args: ['--all', 'v1', '--max-count=2'] },
  { args: ['v1', '--all', '--max-count=2'] },
  { args: ['HEAD', '--', 'a.txt'] },
  { args: ['--count', 'HEAD', '--', 'a.txt'], count: true },
  { args: ['HEAD', '--', 'dir'] },
  { args: ['HEAD', '--', 'dir/'] },
  { args: ['HEAD', '--', ':(exclude)a.txt'] },
  { args: ['--count', 'HEAD', '--', ':(exclude)a.txt'], count: true },
  { args: ['HEAD', '--', ':(exclude)dir'] },
  { args: ['--count', 'HEAD', '--', ':(exclude)dir'], count: true },
  { args: ['--max-count=2', 'HEAD', '--', ':(exclude)a.txt'] },
  { args: ['--reverse', 'HEAD', '--', ':(exclude)a.txt'] },
  { args: ['HEAD', '--', 'a.txt', ':(exclude)dir'] },
  { args: ['--max-count=1', 'HEAD', '--', 'a.txt'] },
  { args: ['--reverse', '--max-count=2', 'HEAD', '--', 'a.txt'] },
]

test('rev-list vectors match the system git byte-for-byte', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const scenario = buildScenario(temp.path)
    const { repository, env } = scenario
    for (const vector of VECTORS) {
      const args = ['rev-list', ...vector.args]
      const expected = systemGit(args, repository, env)
      const actual = await workerGit(args, repository, env)
      expectSame(args.join(' '), expected, actual)
      assert.equal(actual.stderr.byteLength, 0, `${args.join(' ')} writes nothing to stderr`)
      const stdout = actual.stdout.toString()
      if (vector.empty === true) {
        assert.equal(stdout, '', `${args.join(' ')} prints nothing`)
      } else if (vector.count === true) {
        assert.match(stdout, /^\d+\n$/, `${args.join(' ')} prints one count line`)
      } else {
        const lines = stdout.split('\n').filter(line => line !== '')
        assert.ok(lines.length > 0, `${args.join(' ')} prints at least one commit`)
        for (const line of lines) {
          assert.match(line, /^[0-9a-f]{40}$/, `${args.join(' ')} prints only full object ids`)
        }
      }
    }
    // The --all tie order: both tips have the same timestamp and insertion
    // order (main before the tag) must decide. The fixture is chosen so an oid
    // descending tiebreak would put the tagged side commit first.
    assert.ok(
      scenario.mainTip < scenario.sideTagged,
      'fixture: the oid tiebreak would disagree with ref-name insertion order',
    )
    const all = (await workerGit(['rev-list', '--all'], repository, env)).stdout.toString().trim().split('\n')
    const mainIndex = all.indexOf(scenario.mainTip)
    const tagIndex = all.indexOf(scenario.sideTagged)
    assert.ok(mainIndex >= 0 && tagIndex >= 0, '--all contains both tied tips')
    assert.ok(mainIndex < tagIndex, '--all keeps ref-name insertion order for equal timestamps')
    assert.ok(all.indexOf(scenario.sideTip) < mainIndex, '--all starts with the newest side tip')

    // An explicit revision keeps its argv position relative to --all. Both
    // tips share a timestamp, so the insertion sequence decides which one the
    // walk emits first; an implementation that always appends --all after the
    // explicit revisions emits the same order for both forms.
    const lines = async (args: readonly string[]): Promise<string[]> =>
      (await workerGit(['rev-list', ...args], repository, env)).stdout.toString().trim().split('\n')
    const allFirst = await lines(['--all', 'v1'])
    const revisionFirst = await lines(['v1', '--all'])
    assert.notEqual(allFirst.join('\n'), revisionFirst.join('\n'), 'argv position of --all changes the tie order')
    assert.ok(allFirst.indexOf(scenario.mainTip) < allFirst.indexOf(scenario.sideTagged), '--all before v1 inserts the refs first')
    assert.ok(revisionFirst.indexOf(scenario.sideTagged) < revisionFirst.indexOf(scenario.mainTip), 'v1 before --all inserts v1 first')
    expectSame('--all v1 --max-count=2', systemGit(['rev-list', '--all', 'v1', '--max-count=2'], repository, env), await workerGit(['rev-list', '--all', 'v1', '--max-count=2'], repository, env))
    expectSame('v1 --all --max-count=2', systemGit(['rev-list', 'v1', '--all', '--max-count=2'], repository, env), await workerGit(['rev-list', 'v1', '--all', '--max-count=2'], repository, env))

    // An exclude-only pathspec defaults to every other path, so the commit
    // that only touched a.txt disappears instead of selecting the opposite.
    const excluded = await lines(['HEAD', '--', ':(exclude)a.txt'])
    assert.ok(!excluded.includes(scenario.second), 'an exclude-only pathspec does not select a.txt')
    assert.ok(excluded.includes(scenario.mainTip) && excluded.includes(scenario.base), 'an exclude-only pathspec keeps the other paths')
  } finally {
    temp.cleanup()
  }
})

test('rev-list pathspecs work in a bare repository and non-commit tips are empty', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const scenario = buildScenario(temp.path)
    const { repository, env } = scenario
    const bare = join(temp.path, 'scenario.git')
    const clone = systemGit(['clone', '-q', '--bare', repository, bare], temp.path, env)
    assert.equal(clone.code, 0, clone.stderr.toString())
    const canonicalBare = realpathSync(bare)

    for (const args of [
      ['rev-list', 'HEAD'],
      ['rev-list', 'HEAD', '--', 'a.txt'],
      ['rev-list', '--count', 'HEAD', '--', 'a.txt'],
      ['rev-list', 'HEAD', '--', 'dir'],
      ['rev-list', 'HEAD', '--', 'dir/'],
      ['rev-list', 'HEAD', '--', ':(exclude)a.txt'],
      ['rev-list', '--all'],
    ] as const) {
      const expected = systemGit([...args], bare, env)
      const actual = await workerGit([...args], bare, env)
      expectSame(args.join(' '), expected, actual)
      assert.equal(actual.stderr.byteLength, 0, `${args.join(' ')} writes nothing to stderr`)
    }

    // A bare repository is discoverable from its child directories, not only
    // when cwd is the repository root.
    const refsDirectory = join(canonicalBare, 'refs')
    expectSame(
      'bare repository discovered from refs/',
      systemGit(['rev-list', '--count', 'HEAD'], refsDirectory, env),
      await workerGit(['rev-list', '--count', 'HEAD'], refsDirectory, env),
    )

    // Keep the native absolute-path diagnostic, including its path prefix and
    // the `/.` repository-root spelling, byte-for-byte.
    const outside = join(realpathSync(temp.path), 'outside.txt')
    expectSame(
      'bare absolute path outside repository',
      systemGit(['rev-list', 'HEAD', '--', outside], canonicalBare, env),
      await workerGit(['rev-list', 'HEAD', '--', outside], canonicalBare, env),
    )

    // git rev-list accepts any object tip, but only commits enter the walk:
    // a tree, a blob or HEAD:path yields no commits and exit 0, and does not
    // suppress a real commit tip in the same invocation.
    const tree = systemGit(['rev-parse', 'HEAD^{tree}'], bare, env).stdout.toString().trim()
    const blob = systemGit(['rev-parse', 'HEAD:a.txt'], bare, env).stdout.toString().trim()
    for (const args of [
      ['rev-list', tree],
      ['rev-list', blob],
      ['rev-list', 'HEAD:a.txt'],
      ['rev-list', tree, '--', 'a.txt'],
    ] as const) {
      const expected = systemGit([...args], bare, env)
      const actual = await workerGit([...args], bare, env)
      expectSame(args.join(' '), expected, actual)
      assert.equal(actual.stderr.byteLength, 0, `${args.join(' ')} writes nothing to stderr`)
      assert.equal(actual.stdout.byteLength, 0, `${args.join(' ')} lists no commits`)
    }
    const mixed = systemGit(['rev-list', tree, 'HEAD'], bare, env)
    const mixedActual = await workerGit(['rev-list', tree, 'HEAD'], bare, env)
    expectSame('rev-list <tree> HEAD', mixed, mixedActual)
    assert.ok(mixedActual.stdout.toString().split('\n').includes(scenario.mainTip), 'the real commit tip is still walked')
  } finally {
    temp.cleanup()
  }
})

test('rev-list fails loud for a malformed annotated tag object', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const { repository, env } = buildScenario(temp.path)
    const payload = join(temp.path, 'malformed-tag-object.txt')
    writeFileSync(payload, 'not a valid tag object\n')
    const malformedTag = systemGit(
      ['hash-object', '-w', '--literally', '-t', 'tag', payload],
      repository,
      env,
    )
    assert.equal(malformedTag.code, 0, malformedTag.stderr.toString())
    const oid = malformedTag.stdout.toString().trim()
    assert.match(oid, /^[0-9a-f]{40}$/)
    mkdirSync(join(repository, '.git', 'refs', 'tags'), { recursive: true })
    writeFileSync(join(repository, '.git', 'refs', 'tags', 'corrupt'), `${oid}\n`)

    const expected = systemGit(['rev-list', 'corrupt'], repository, env)
    const actual = await workerGit(['rev-list', 'corrupt'], repository, env)
    assert.equal(expected.code, 128, expected.stderr.toString())
    assert.equal(actual.code, expected.code, actual.stderr.toString())
    assert.equal(actual.stdout.byteLength, 0, 'a corrupt tag must not produce commits')
    assert.match(actual.stderr.toString(), /fatal:/)
  } finally {
    temp.cleanup()
  }
})

test('rev-list failures are loud and print nothing', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const scenario = buildScenario(temp.path)
    const { repository, env } = scenario

    const bad = await workerGit(['rev-list', 'nope'], repository, env)
    const badExpected = systemGit(['rev-list', 'nope'], repository, env)
    assert.equal(badExpected.code, 128)
    assert.equal(bad.code, 128, bad.stderr.toString())
    assert.equal(bad.stdout.byteLength, 0)
    assert.equal(
      bad.stderr.toString().split('\n')[0],
      badExpected.stderr.toString().split('\n')[0],
      'the bad revision reports git\'s first fatal line',
    )

    const outside = await workerGit(['rev-list', 'HEAD'], temp.path, env)
    // The Docker mount boundary changes system git's discovery diagnostic
    // ("stopping at filesystem boundary" versus the standard parent-directory
    // line). The Worker cannot emulate the host mount topology, so the oracle
    // only asks system git to continue discovery across filesystems; the
    // standard not-a-repository stderr is still compared byte-for-byte.
    const outsideEnv = { ...env, GIT_DISCOVERY_ACROSS_FILESYSTEM: '1' }
    expectSame('outside a repository', systemGit(['rev-list', 'HEAD'], temp.path, outsideEnv), outside)

    for (const args of [
      ['--objects', 'HEAD'],
      ['--pretty=oneline', 'HEAD'],
      ['main...side'],
      ['--frobnicate', 'HEAD'],
    ]) {
      const result = await workerGit(['rev-list', ...args], repository, env)
      assert.equal(result.code, 129, `${args.join(' ')} exits 129`)
      assert.equal(result.stdout.byteLength, 0, `${args.join(' ')} prints nothing to stdout`)
      assert.match(result.stderr.toString(), /^fatal: /, `${args.join(' ')} states the failure`)
      assert.match(result.stderr.toString(), new RegExp(args[0] as string), `${args.join(' ')} names the request`)
    }
  } finally {
    temp.cleanup()
  }
})

/** A true merge on main, used for the histories rev-list must refuse. */
function buildMergeScenario(root: string): { repository: string; env: Record<string, string> } {
  const environment = fixtureEnvironment(root)
  const env = environment.env
  const repository = join(root, 'merge')
  mkdirSync(repository)
  const git = (args: readonly string[], timestamp?: number): CommandResult =>
    systemGit(args, repository, timestamp === undefined ? env : dated(env, timestamp))
  git(['init', '-q', '-b', 'main'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\n')
  writeFileSync(join(repository, 'b.txt'), 'beta\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base'], 1700000000)
  git(['checkout', '-q', '-b', 'side'])
  writeFileSync(join(repository, 's.txt'), 'side\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'side'], 1700000100)
  git(['checkout', '-q', 'main'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\nmain\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'main'], 1700000200)
  git(['merge', '-q', '--no-ff', 'side', '-m', 'merge'], 1700000300)
  return { repository, env }
}

test('rev-list walks merges but refuses a pathspec simplification it cannot match', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const { repository, env } = buildMergeScenario(temp.path)
    for (const args of [['--all'], ['--first-parent', 'HEAD'], ['HEAD']]) {
      expectSame(args.join(' '), systemGit(['rev-list', ...args], repository, env), await workerGit(['rev-list', ...args], repository, env))
    }
    for (const pathspec of ['a.txt', 's.txt']) {
      const result = await workerGit(['rev-list', 'HEAD', '--', pathspec], repository, env)
      assert.equal(result.code, 129, `merge history with ${pathspec} exits 129`)
      assert.equal(result.stdout.byteLength, 0, `merge history with ${pathspec} prints nothing`)
      assert.match(result.stderr.toString(), /merge/, `merge history with ${pathspec} names the limitation`)
    }
  } finally {
    temp.cleanup()
  }
})

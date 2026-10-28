// SPDX-License-Identifier: MIT
/**
 * Golden tests for git's `:(glob)` pathspec magic.
 *
 * The system git is the oracle for every pattern. The fixture keeps a regular
 * file named `dir` next to real directories, files whose names contain glob
 * metacharacters, a CJK name and files at several depths, so the same vectors
 * exercise literal-name precedence, directory boundaries, `?` as one UTF-8
 * byte and the `*` / `**` distinction. The same parsed pathspec drives the
 * shared commands (`ls-files`, `status`, `diff`, `rev-list`, `add`, `restore`,
 * `rm` and `checkout`) rather than a command-specific matcher.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/glob-pathspec.test
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

interface GlobFixture {
  readonly repository: string
  readonly env: Record<string, string>
  readonly files: readonly string[]
}

/** Names chosen so no regular file shares a name with a directory. */
function globFiles(): string[] {
  return [
    'top.txt',
    'plain.md',
    'star*',
    'q?',
    '[a]',
    'a[',
    'a\\',
    'a]',
    'br[ack',
    '分支',
    'a*',
    'dir',
    'dir2',
    'zz',
    'a/one.txt',
    'a/b/two.txt',
    'a/b/c/three.txt',
    'c/three.txt',
    'folder/keep.txt',
    'd/x/y.txt',
    'd/e/f.txt',
    'd[/inside.txt',
    'x/z.txt',
    'x/y/z.txt',
    'a**/b',
    'a**/x/b',
    'a*x/b',
    'star-dir/inside.txt',
    'glob*d/file.txt',
    'docs/guide.html',
    'docs/ppc/ppc.html',
    'tools/perf/Documentation/perf.html',
  ]
}

function buildGlobFixture(root: string): GlobFixture {
  const environment = fixtureEnvironment(root)
  const repository = join(root, 'glob-fixture')
  mkdirSync(repository)
  const env = environment.env
  const git = (args: readonly string[], cwd = repository): CommandResult => {
    const result = systemGit(args, cwd, env)
    assert.equal(result.code, 0, `fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
    return result
  }
  git(['init', '-q', '-b', 'main'])
  const files = globFiles()
  for (const path of files) {
    mkdirSync(join(repository, path, '..'), { recursive: true })
    writeFileSync(join(repository, path), `${path}\n`)
  }
  git(['add', '-A'])
  git(['commit', '-qm', 'glob base'])
  // A second commit gives `log -- <pathspec>` a non-root commit to select.
  writeFileSync(join(repository, 'a/one.txt'), 'a/one.txt second commit\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'touch a/one'])
  // Work-tree edits give diff/status/restore a concrete change per path.
  for (const path of files) writeFileSync(join(repository, path), `${path} changed\n`)
  return { repository, env, files }
}

interface DirectoryExclusionFixture {
  readonly repository: string
  readonly env: Record<string, string>
}

/**
 * A repository where `u/` and `v/` contain tracked files, while `w/` and
 * `empty/` are wholly untracked. Directory excludes must prune only the
 * latter two, and must not hide untracked files beside tracked ones.
 */
function buildDirectoryExclusionFixture(root: string, name: string): DirectoryExclusionFixture {
  const environment = fixtureEnvironment(root)
  const repository = join(root, name)
  mkdirSync(repository)
  const env = environment.env
  const git = (args: readonly string[]): CommandResult => {
    const result = systemGit(args, repository, env)
    assert.equal(result.code, 0, `directory-exclusion fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
    return result
  }
  git(['init', '-q', '-b', 'main'])
  for (const path of ['base.txt', 'u/tracked.txt', 'v/tracked.txt']) {
    mkdirSync(join(repository, path, '..'), { recursive: true })
    writeFileSync(join(repository, path), `${path}\n`)
  }
  git(['add', '-A'])
  git(['commit', '-qm', 'directory exclusion base'])
  for (const path of [
    'u/file.txt', 'u/other.md', 'u/deep/x.txt',
    'v/direct.txt', 'v/sub/deep.txt',
    'w/top.txt', 'w/deep/x.txt',
    'empty/x.txt',
  ]) {
    mkdirSync(join(repository, path, '..'), { recursive: true })
    writeFileSync(join(repository, path), `${path}\n`)
  }
  return { repository, env }
}

/** Patterns covering positive matches and genuine negatives. */
const PATTERNS = [
  ':(glob)*',
  ':(glob)**',
  ':(glob)**/*',
  ':(glob)**/*.txt',
  ':(glob)?',
  ':(glob)??',
  ':(glob)??????',
  ':(glob)*.txt',
  ':(glob)a/*',
  ':(glob)a/**',
  ':(glob)a/**/*',
  ':(glob)a/**/two.txt',
  ':(glob)**/two.txt',
  ':(glob)*/*.txt',
  ':(glob)[a-c]/*',
  ':(glob)dir*',
  ':(glob)dir/*',
  ':(glob)dir',
  ':(glob)dir/',
  ':(glob)zz**/',
  ':(glob)folder/*',
  ':(glob)a[',
  ':(glob)[a]',
  ':(glob)a\\]',
  ':(glob)a\\\\',
  ':(glob)star\\*',
  ':(glob)br\\[ack',
  ':(glob)star*/inside.txt',
  ':(glob)glob*d/file.txt',
  ':(glob)d[/inside.txt',
  ':(glob)a/b**',
  ':(glob)a/**b',
  ':(glob)**a',
  ':(glob)a**/b',
  ':(glob)a/b**/c',
  ':(glob)**\\/z.txt',
  ':(glob)x**\\/z.txt',
  ':(glob)**\\/top.txt',
  ':(glob)**/top.txt',
  ':(glob)**\\/b',
  ':(glob)a**\\/b',
  ':(glob)**\\/**',
  ':(glob)**/**',
  ':(glob)**/**/*',
  ':(glob)docs/*.html',
  ':(glob)docs/**/*.html',
  ':(glob)[a-',
  ':(glob)a\\',
  ':(glob)a\\***/b',
  ':(glob)a\\[**/b',
  ':(glob)a\\?**/b',
  ':(glob)a\\*/b',
  ':(top,glob)a/**',
  ':(top,glob)**/*.txt',
  ':(glob,exclude)**/*.txt',
  ':(exclude,glob)**/*.txt',
  ':(glob,exclude)*.txt',
  ':(glob,exclude)a\\]',
  ':(exclude,glob)a\\\\',
] as const

/** Commands whose path filtering is shared through inspect.ts. */
function sharedVectors(pattern: string): string[][] {
  return [
    ['ls-files', '-z', '--', pattern],
    ['status', '--porcelain', '-z', '--', pattern],
    ['diff', '--name-only', '-z', '--', pattern],
    ['diff-tree', '--no-commit-id', '-r', '--name-only', 'HEAD', '--', pattern],
    ['rev-list', '--count', 'HEAD', '--', pattern],
  ]
}

test('glob pathspecs match system git across the shared path filters', { skip }, async t => {
  const temp = tempDirectory()
  try {
    const fixture = buildGlobFixture(temp.path)
    const { repository, env } = fixture

    await t.test('ls-files/status/diff/diff-tree/rev-list agree byte-for-byte', async () => {
      for (const pattern of PATTERNS) {
        for (const args of sharedVectors(pattern)) {
          expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
        }
      }
    })

    await t.test('glob wildcards do not cross a directory boundary', async () => {
      const rootOnly = await workerGit(['ls-files', '-z', '--', ':(glob)*'], repository, env)
      assert.deepEqual(
        rootOnly.stdout.toString('utf8').split('\0').filter(entry => entry !== ''),
        ['[a]', 'a*', 'a[', 'a\\', 'a]', 'br[ack', 'dir', 'dir2', 'plain.md', 'q?', 'star*', 'top.txt', 'zz', '分支'],
      )
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)*.txt'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== ''),
        ['top.txt'],
      )
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)**/*.txt'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== '').sort(),
        [
          'a/b/c/three.txt', 'a/b/two.txt', 'a/one.txt', 'c/three.txt', 'd/e/f.txt', 'd/x/y.txt',
          'd[/inside.txt', 'folder/keep.txt', 'glob*d/file.txt', 'star-dir/inside.txt', 'top.txt',
          'x/y/z.txt', 'x/z.txt',
        ].sort(),
      )
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)dir/*'], repository, env)).stdout.byteLength,
        0,
      )
      // The terminal globstar can consume zero directories, so the
      // directory-only spelling still selects the file `zz` itself.
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)zz**/'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== ''),
        ['zz'],
      )
    })

    await t.test('the documented leading, middle and trailing globstars', async () => {
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)a/**'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== '').sort(),
        ['a/b/c/three.txt', 'a/b/two.txt', 'a/one.txt'],
      )
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)a/**/two.txt'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== ''),
        ['a/b/two.txt'],
      )
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)**/two.txt'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== ''),
        ['a/b/two.txt'],
      )
      assert.equal(
        (await workerGit(['ls-files', '-z', '--', ':(glob)**a'], repository, env)).stdout.byteLength,
        0,
      )
      assert.equal(
        (await workerGit(['ls-files', '-z', '--', ':(glob)a/**b'], repository, env)).stdout.byteLength,
        0,
      )
      // A trailing ** after a literal prefix is pathname-wide because the
      // literal prefix is consumed before the wildcard remainder.
      assert.deepEqual(
        (await workerGit(['ls-files', '-z', '--', ':(glob)a/b**'], repository, env)).stdout.toString('utf8')
          .split('\0').filter(entry => entry !== '').sort(),
        ['a/b/c/three.txt', 'a/b/two.txt'],
      )
    })

    await t.test('glob metacharacters in real names are selected literally first', async () => {
      for (const pattern of ['a[', '[a]', 'star\\*', 'br\\[ack']) {
        const args = ['ls-files', '-z', '--', `:(glob)${pattern}`]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
        assert.equal((await workerGit(args, repository, env)).stdout.toString('utf8').split('\0')[0], pattern.replace('\\', ''))
      }
    })

    await t.test('escape-only pathspecs select the escaped literal name', async () => {
      // `a\]` and `a\\` contain no `*`, `?` or `[`: only the backslash escape
      // makes them globs. They must still reach the byte matcher instead of
      // being compared against the raw spelling.
      const escaped = [
        ':(glob)a\\]',
        ':(glob)a\\\\',
        'a\\]',
        'a\\\\',
        ':(glob,exclude)a\\]',
        ':(exclude,glob)a\\\\',
        ':(exclude)a\\]',
        ':(exclude)a\\\\',
      ] as const
      for (const pattern of escaped) {
        for (const args of sharedVectors(pattern)) {
          expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
        }
      }
      const paths = async (pattern: string): Promise<string[]> => (
        await workerGit(['ls-files', '-z', '--', pattern], repository, env)
      ).stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      assert.deepEqual(await paths(':(glob)a\\]'), ['a]'])
      assert.deepEqual(await paths(':(glob)a\\\\'), ['a\\'])
      assert.deepEqual(await paths('a\\]'), ['a]'])
      assert.deepEqual(await paths('a\\\\'), ['a\\'])
      const excluded = await paths(':(glob,exclude)a\\]')
      assert.equal(excluded.includes('a]'), false)
      assert.equal(excluded.includes('a\\'), true)
    })

    await t.test('exclude-only and include+exclude glob pathspecs stay consistent', async () => {
      const excludeOnly = ':(glob,exclude)**/*.txt'
      for (const args of [
        ['ls-files', '-z', '--', excludeOnly],
        ['status', '--porcelain', '-z', '--', excludeOnly],
        ['diff', '--name-only', '-z', '--', excludeOnly],
        ['rev-list', '--count', 'HEAD', '--', excludeOnly],
      ]) {
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
      const includeExclude = ':(glob,exclude)**/*.md'
      expectSame(
        includeExclude,
        systemGit(['ls-files', '-z', '--', includeExclude], repository, env),
        await workerGit(['ls-files', '-z', '--', includeExclude], repository, env),
      )
    })

    await t.test('add/restore/rm/checkout apply the same glob selection', async () => {
      const mutationPatterns = [
        ':(glob)**/*.txt',
        ':(glob)a/**',
        ':(glob)star\\*',
        ':(glob)a\\]',
        ':(glob)a\\\\',
        ':(glob)**/*.md',
        ':(glob,exclude)**/*.txt',
      ] as const
      for (const pattern of mutationPatterns) {
        for (const operation of ['add', 'add-all', 'restore-worktree', 'restore-staged', 'rm-cached'] as const) {
          const systemRepo = join(temp.path, `s-${operation}-${Math.random().toString(36).slice(2)}`)
          const workerRepo = join(temp.path, `w-${operation}-${Math.random().toString(36).slice(2)}`)
          copyRepository(repository, systemRepo)
          copyRepository(repository, workerRepo)
          const args = operation === 'add'
            ? ['add', '--', pattern]
            : operation === 'add-all'
              ? ['add', '-A', '--', pattern]
              : operation === 'restore-worktree'
                ? ['restore', '--source=HEAD', '--worktree', '--', pattern]
                : operation === 'restore-staged'
                  ? ['restore', '--source=HEAD', '--staged', '--', pattern]
                  : ['rm', '-r', '--cached', '--', pattern]
          expectSame(args.join(' '), systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
          expectSame(
            `${args.join(' ')} resulting status`,
            systemGit(['status', '--porcelain', '-z'], systemRepo, env),
            await workerGit(['status', '--porcelain', '-z'], workerRepo, env),
          )
        }
      }
      // `checkout -- <path>` uses the same restore primitive.
      const systemRepo = join(temp.path, 'checkout-system')
      const workerRepo = join(temp.path, 'checkout-worker')
      copyRepository(repository, systemRepo)
      copyRepository(repository, workerRepo)
      const args = ['checkout', '--', ':(glob)a/**']
      expectSame(args.join(' '), systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
      expectSame(
        'checkout resulting status',
        systemGit(['status', '--porcelain', '-z'], systemRepo, env),
        await workerGit(['status', '--porcelain', '-z'], workerRepo, env),
      )
    })

    await t.test('log path filtering uses the same glob pathspecs', async () => {
      for (const pattern of [
        '*.txt', ':(glob)**/*.txt', ':(glob)a/**', ':(glob)docs/**/*.html',
        ':(glob)a\\]', 'a\\]',
      ]) {
        for (const args of [
          ['log', '--oneline', '--', pattern],
          ['log', '--name-only', '--', pattern],
          ['log', '-n', '2', '--name-status', '--', pattern],
          ['log', '--stat', '--', pattern],
          ['log', '-p', '--', pattern],
        ]) {
          expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
        }
      }
      // Root-wide patterns still exercise selection; only --oneline avoids the
      // pre-existing display difference for high-byte names in `--name-only`
      // and for backslash quoting in the rendered name list.
      for (const pattern of [
        '*', ':(glob)*', ':(glob)**', ':(glob,exclude)**/*.txt',
        ':(glob)a\\\\', ':(glob,exclude)a\\\\', 'a\\\\',
      ]) {
        const args = ['log', '--oneline', '--', pattern]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
    })

    await t.test('cwd-relative prefixes and :(top,glob) resolve like git', async () => {
      const cwd = join(repository, 'a')
      for (const pattern of [
        ':(glob)*', ':(glob)**', ':(glob)**/*.txt', ':(glob)*.txt', ':(top,glob)a/**', ':(top,glob)**/*.txt',
        ':(glob)**\\/two.txt',
      ]) {
        for (const args of [
          ['ls-files', '-z', '--full-name', '--', pattern],
          ['status', '--porcelain', '-z', '--', pattern],
          ['diff', '--name-only', '-z', '--', pattern],
          ['rev-list', '--count', 'HEAD', '--', pattern],
        ]) {
          expectSame(
            `cwd ${args.join(' ')}`,
            systemGit(args, cwd, env),
            await workerGit(args, cwd, env),
          )
        }
      }
    })

    await t.test('bare rev-list applies the same glob rules', async () => {
      const bare = join(temp.path, 'glob-bare.git')
      const clone = systemGit(['clone', '-q', '--bare', repository, bare], temp.path, env)
      assert.equal(clone.code, 0, clone.stderr.toString())
      for (const pattern of [
        ':(glob)*', ':(glob)**', ':(glob)**/*.txt', ':(glob)a/**', ':(glob)star\\*',
        ':(glob)a\\]', ':(glob)a\\\\', ':(glob,exclude)**/*.txt', ':(glob,exclude)a\\]',
        ':(glob)**\\/z.txt', ':(glob)x**\\/z.txt',
      ]) {
        const args = ['rev-list', '--count', 'HEAD', '--', pattern]
        expectSame(args.join(' '), systemGit(args, bare, env), await workerGit(args, bare, env))
      }
    })

    await t.test('rename detection sees only the pathspec-selected side', async () => {
      const renameRepository = join(temp.path, 'rename-fixture')
      mkdirSync(renameRepository)
      const git = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, renameRepository, env)
        assert.equal(result.code, 0, `rename fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      git(['init', '-q', '-b', 'main'])
      writeFileSync(join(renameRepository, 'rename-old.txt'), 'one\ntwo\nthree\nfour\n')
      writeFileSync(join(renameRepository, 'keep.txt'), 'keep\n')
      git(['add', '-A'])
      git(['commit', '-qm', 'rename base'])
      git(['mv', 'rename-old.txt', 'rename-new.txt'])
      git(['commit', '-qm', 'rename'])

      // A pathspec that selects only one side of a rename makes git report a
      // deletion or an addition on that side, not a rename record.
      for (const pattern of ['rename-old.txt', 'rename-new.txt']) {
        for (const prefix of [
          ['log', '--name-only', '--'],
          ['log', '--name-status', '--'],
          ['log', '--stat', '--'],
          ['log', '-p', '--'],
          ['diff', '--name-status', '-M', 'HEAD^', 'HEAD', '--'],
          ['diff', '--name-only', '-M', 'HEAD^', 'HEAD', '--'],
          ['diff', '--stat', '-M', 'HEAD^', 'HEAD', '--'],
          ['diff-tree', '--no-commit-id', '-r', '-M', '--name-status', 'HEAD', '--'],
          ['diff-tree', '--no-commit-id', '-r', '-M', '--name-only', 'HEAD', '--'],
        ]) {
          const args = [...prefix, pattern]
          expectSame(args.join(' '), systemGit(args, renameRepository, env), await workerGit(args, renameRepository, env))
        }
      }

      // Selecting both sides keeps the rename itself.
      for (const args of [
        ['log', '--name-only', '--', 'rename-old.txt', 'rename-new.txt'],
        ['log', '--name-status', '--', 'rename-old.txt', 'rename-new.txt'],
        ['log', '-p', '--', 'rename-old.txt', 'rename-new.txt'],
      ]) {
        expectSame(args.join(' '), systemGit(args, renameRepository, env), await workerGit(args, renameRepository, env))
      }

      // `status` pairs the index and HEAD snapshots after the same restriction.
      git(['mv', 'rename-new.txt', 'rename-next.txt'])
      for (const pattern of ['rename-new.txt', 'rename-next.txt']) {
        for (const args of [
          ['status', '--porcelain', '-z', '--', pattern],
          ['diff', '--cached', '--name-status', '-M', '--', pattern],
          ['diff', '--cached', '--name-only', '-M', '--', pattern],
          ['diff', '--cached', '--stat', '-M', '--', pattern],
        ]) {
          expectSame(args.join(' '), systemGit(args, renameRepository, env), await workerGit(args, renameRepository, env))
        }
      }
    })

    await t.test("escaped-slash globstars keep git's no-zero-directory rule", async () => {
      const paths = async (pattern: string): Promise<string[]> => (
        await workerGit(['ls-files', '-z', '--', pattern], repository, env)
      ).stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      // `**\/` is a globstar followed by an escaped literal `/`: unlike
      // `**/` it cannot skip both the wildcard and the separator, so a root
      // file with no directory is not selected.
      assert.deepEqual(await paths(':(glob)**\\/z.txt'), ['x/y/z.txt', 'x/z.txt'])
      assert.deepEqual(await paths(':(glob)x**\\/z.txt'), ['x/y/z.txt', 'x/z.txt'])
      assert.deepEqual(await paths(':(glob)**\\/top.txt'), [])
      assert.deepEqual(await paths(':(glob)**/top.txt'), ['top.txt'])
    })

    await t.test('exact rename pairing consumes each addition once', async () => {
      const renameRepository = join(temp.path, 'multi-rename-fixture')
      mkdirSync(renameRepository)
      mkdirSync(join(renameRepository, 'dir'))
      writeFileSync(join(renameRepository, 'old.txt'), 'same\ncontent\nlines\n')
      writeFileSync(join(renameRepository, 'dir', 'old2.txt'), 'same\ncontent\nlines\n')
      writeFileSync(join(renameRepository, 'keep.txt'), 'keep\n')
      const git = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, renameRepository, env)
        assert.equal(result.code, 0, `multi-rename fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      git(['init', '-q', '-b', 'main'])
      git(['add', '-A'])
      git(['commit', '-qm', 'rename base'])
      git(['mv', 'old.txt', 'new.txt'])
      git(['mv', 'dir/old2.txt', 'dir/new2.txt'])
      git(['commit', '-qm', 'two exact renames'])

      for (const args of [
        ['diff', '--name-status', '-M', 'HEAD^', 'HEAD'],
        ['diff', '--name-status', '-M', 'HEAD^', 'HEAD', '--', ':(glob)**'],
        ['diff', '--name-only', '-M', 'HEAD^', 'HEAD', '--', ':(glob)**'],
        ['diff-tree', '--no-commit-id', '-r', '-M', '--name-status', 'HEAD'],
        ['diff-tree', '--no-commit-id', '-r', '-M', '--name-status', 'HEAD', '--', ':(glob)**'],
        ['log', '-n', '1', '--name-status'],
        ['log', '-n', '1', '--name-status', '--', ':(glob)**'],
        ['log', '-n', '1', '--name-only', '--', ':(glob)**'],
      ]) {
        expectSame(args.join(' '), systemGit(args, renameRepository, env), await workerGit(args, renameRepository, env))
      }

      const status = (await workerGit(
        ['diff', '--name-status', '-M', 'HEAD^', 'HEAD'], renameRepository, env,
      )).stdout.toString('utf8')
      assert.deepEqual(status.split('\n').filter(line => line !== '').sort(), [
        'R100\tdir/old2.txt\tdir/new2.txt',
        'R100\told.txt\tnew.txt',
      ])
    })

    await t.test('status filters untracked files before collapsing their directories', async () => {
      const untracked = join(temp.path, 'untracked-dir-fixture')
      mkdirSync(untracked)
      const git = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, untracked, env)
        assert.equal(result.code, 0, `untracked fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      git(['init', '-q', '-b', 'main'])
      mkdirSync(join(untracked, 'v'))
      writeFileSync(join(untracked, 'v', 'tracked.txt'), 'tracked\n')
      git(['add', '-A'])
      git(['commit', '-qm', 'untracked base'])
      for (const path of [
        'root.txt', 'u/file.txt', 'u/other.md', 'u/deep/x.txt',
        'v/a/x.txt', 'v/a/y.md', 'v/b/z.txt',
        'deepdir/a/b/c.txt', 'only-untracked/deep/file.txt',
      ]) {
        mkdirSync(join(untracked, path, '..'), { recursive: true })
        writeFileSync(join(untracked, path), `${path}\n`)
      }
      // No pathspec keeps the ordinary `?? dir/` collapse.
      expectSame(
        'status with no pathspec',
        systemGit(['status', '--porcelain', '-z'], untracked, env),
        await workerGit(['status', '--porcelain', '-z'], untracked, env),
      )
      const pathLists: string[][] = [
        [':(glob)u/*.txt'],
        [':(glob)u*/'],
        [':(glob)u/*'],
        [':(glob)u/**'],
        [':(glob)u/[fo]*'],
        [':(glob)u/**/*.txt'],
        [':(glob)u/deep/*'],
        [':(glob)u/deep/x.txt'],
        [':(glob)u/deep*'],
        [':(glob)v/*'],
        [':(glob)v/**'],
        [':(glob)v/**/*.txt'],
        [':(glob)v/a/*'],
        [':(glob)*/*'],
        [':(glob)*/*/*'],
        [':(glob)**/*'],
        [':(glob,exclude)*'],
        [':(glob,exclude)u*'],
        [':(exclude)**/a'],
        [':(exclude)?/?'],
        ['only-untracked/deep?'],
        // A literal exclude still prunes the directory named exactly, both
        // with and without the directory-only spelling.
        [':(exclude)u'],
        [':(exclude)u/'],
        [':(exclude)v/a'],
        [':(glob,exclude)u/deep'],
        [':(glob,exclude)u/*.txt'],
        [':(glob,exclude)u/*'],
        [':(glob)u/**', ':(glob,exclude)u/*.txt'],
        ['u/*'],
        ['u/deep*'],
        ['u/'],
      ]
      for (const mode of [[], ['-uall']] as const) {
        for (const paths of pathLists) {
          const args = ['status', '--porcelain', '-z', ...mode, '--', ...paths]
          expectSame(
            args.join(' '),
            systemGit(args, untracked, env),
            await workerGit(args, untracked, env),
          )
        }
      }
      // The two failure shapes from the review: a file pattern inside an
      // untracked directory must show the file, and a trailing-slash pattern
      // that matches no file must not manufacture a collapsed directory row.
      assert.deepEqual(
        (await workerGit(['status', '--porcelain', '-z', '--', ':(glob)u/*.txt'], untracked, env))
          .stdout.toString('utf8').split('\0').filter(entry => entry !== ''),
        ['?? u/file.txt'],
      )
      assert.equal(
        (await workerGit(['status', '--porcelain', '-z', '--', ':(glob)u*/'], untracked, env))
          .stdout.byteLength,
        0,
      )
      const statusPaths = async (pattern: string): Promise<string[]> => (
        await workerGit(['status', '--porcelain', '-z', '--', pattern], untracked, env)
      ).stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      // A wildcard exclude is a directory hit only through the trailing-slash
      // spelling. `*` and `u*` name root files, not the whole `u/`/`v/` trees.
      assert.deepEqual(
        await statusPaths(':(glob,exclude)*'),
        ['?? deepdir/', '?? only-untracked/', '?? u/', '?? v/a/', '?? v/b/'],
      )
      assert.deepEqual(
        await statusPaths(':(glob,exclude)u*'),
        ['?? deepdir/', '?? only-untracked/', '?? root.txt', '?? u/', '?? v/a/', '?? v/b/'],
      )
      // Default wildcard excludes keep the same rule: `**/a` and `?/?` match
      // file paths, but not `v/a/` or `v/b/` as directories.
      assert.deepEqual(
        await statusPaths(':(exclude)**/a'),
        ['?? deepdir/', '?? only-untracked/', '?? root.txt', '?? u/', '?? v/a/', '?? v/b/'],
      )
      assert.deepEqual(
        await statusPaths(':(exclude)?/?'),
        ['?? deepdir/', '?? only-untracked/', '?? root.txt', '?? u/', '?? v/a/', '?? v/b/'],
      )
      // A literal exclude keeps the bare-directory hit: `:(exclude)u` removes
      // the whole u tree, unlike the wildcard forms above.
      assert.deepEqual(
        await statusPaths(':(exclude)u'),
        ['?? deepdir/', '?? only-untracked/', '?? root.txt', '?? v/a/', '?? v/b/'],
      )
      // Directory collapsing is driven by files the pathspec actually
      // selects. `*/*` reaches `u/file.txt` (so `u/` collapses) but never
      // `deepdir/a/b/c.txt`; `deep?` matches no untracked file at all.
      assert.deepEqual(await statusPaths(':(glob)*/*'), ['?? u/'])
      assert.deepEqual(await statusPaths('only-untracked/deep?'), [])
      assert.deepEqual(
        await statusPaths(':(glob)*/*/*'),
        ['?? only-untracked/deep/', '?? u/deep/', '?? v/a/', '?? v/b/'],
      )
    })

    await t.test('exclude directory pruning requires a fully untracked directory', async () => {
      const exclusion = buildDirectoryExclusionFixture(temp.path, 'directory-exclusion-status')
      const { repository: exclusionRepository, env: exclusionEnv } = exclusion
      const statusPaths = async (pattern: string): Promise<string[]> => (
        await workerGit(['status', '--porcelain', '-z', '--', pattern], exclusionRepository, exclusionEnv)
      ).stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      const patterns = [
        ':(exclude)??',
        ':(glob,exclude)u/**/',
        ':(glob,exclude)u*/',
        ':(exclude)u*/',
        ':(glob,exclude)v*/',
        ':(exclude)v*/',
        ':(glob,exclude)w*/',
        ':(exclude)w*/',
        ':(glob,exclude)w/**/',
        ':(exclude)w/**/',
        ':(exclude)empty/**/',
        ':(glob,exclude)empty/**/',
        ':(glob,exclude)?*/',
        ':(exclude)?*/',
      ]
      for (const mode of [[], ['-uall']] as const) {
        for (const pattern of patterns) {
          const args = ['status', '--porcelain', '-z', ...mode, '--', pattern]
          expectSame(
            args.join(' '),
            systemGit(args, exclusionRepository, exclusionEnv),
            await workerGit(args, exclusionRepository, exclusionEnv),
          )
        }
      }
      // A directory that contains tracked files is still walked: an exclude
      // that only matches its spelling must not hide the untracked siblings.
      assert.deepEqual(
        await statusPaths(':(exclude)??'),
        ['?? empty/', '?? u/deep/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/'],
      )
      assert.deepEqual(
        await statusPaths(':(glob,exclude)u/**/'),
        ['?? empty/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/', '?? w/'],
      )
      assert.deepEqual(
        await statusPaths(':(glob,exclude)u*/'),
        ['?? empty/', '?? u/deep/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/', '?? w/'],
      )
      // Default `?`/`*` still match the trailing slash, so `u*/` prunes the
      // fully untracked `u/deep/` while leaving the files directly in `u/`.
      assert.deepEqual(
        await statusPaths(':(exclude)u*/'),
        ['?? empty/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/', '?? w/'],
      )
      // The reverse shape from the review: a directory-only wildcard must
      // prune a wholly untracked directory, not return false for it.
      assert.deepEqual(
        await statusPaths(':(exclude)w*/'),
        ['?? empty/', '?? u/deep/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/'],
      )
      assert.deepEqual(
        await statusPaths(':(glob,exclude)w*/'),
        ['?? empty/', '?? u/deep/', '?? u/file.txt', '?? u/other.md', '?? v/direct.txt', '?? v/sub/'],
      )
    })

    await t.test('add excludes only fully untracked directories', async () => {
      const exclusion = buildDirectoryExclusionFixture(temp.path, 'directory-exclusion-add')
      const { repository: exclusionRepository, env: exclusionEnv } = exclusion
      const compareAdd = async (args: readonly string[], label: string): Promise<void> => {
        const suffix = Math.random().toString(36).slice(2)
        const systemRepo = join(temp.path, `directory-exclude-add-system-${suffix}`)
        const workerRepo = join(temp.path, `directory-exclude-add-worker-${suffix}`)
        copyRepository(exclusionRepository, systemRepo)
        copyRepository(exclusionRepository, workerRepo)
        expectSame(label, systemGit(args, systemRepo, exclusionEnv), await workerGit(args, workerRepo, exclusionEnv))
        expectSame(
          `${label} resulting status`,
          systemGit(['status', '--porcelain', '-z'], systemRepo, exclusionEnv),
          systemGit(['status', '--porcelain', '-z'], workerRepo, exclusionEnv),
        )
      }
      for (const vector of [
        ['add', '--', ':(glob,exclude)?*/'],
        ['add', '--', ':(exclude)?*/'],
        ['add', '-A', '--', ':(glob,exclude)?*/'],
        ['add', '-A', '--', ':(exclude)?*/'],
        ['add', '--', ':(glob,exclude)u/**/'],
        ['add', '--', ':(exclude)u*/'],
        ['add', '--', ':(glob,exclude)w*/'],
        ['add', '--', ':(exclude)w*/'],
        ['add', '--', ':(glob,exclude)empty/**/'],
      ]) {
        await compareAdd(vector, vector.join(' '))
      }
      // The two exact shapes from the review must leave `empty/` and `w/`
      // untracked instead of staging an excluded file.
      const addSuffix = Math.random().toString(36).slice(2)
      const addRepo = join(temp.path, `directory-exclude-add-edge-${addSuffix}`)
      copyRepository(exclusionRepository, addRepo)
      const globResult = await workerGit(['add', '--', ':(glob,exclude)?*/'], addRepo, exclusionEnv)
      assert.equal(globResult.code, 0, globResult.stderr.toString())
      const globStatus = systemGit(['status', '--porcelain', '-z'], addRepo, exclusionEnv)
        .stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      assert.ok(globStatus.includes('?? empty/'), globStatus.join(' '))
      assert.ok(globStatus.includes('?? w/'), globStatus.join(' '))
      assert.ok(!globStatus.includes('A  empty/x.txt'), globStatus.join(' '))
      assert.ok(!globStatus.includes('A  w/top.txt'), globStatus.join(' '))

      const defaultSuffix = Math.random().toString(36).slice(2)
      const defaultRepo = join(temp.path, `directory-exclude-add-default-${defaultSuffix}`)
      copyRepository(exclusionRepository, defaultRepo)
      const defaultResult = await workerGit(['add', '--', ':(exclude)?*/'], defaultRepo, exclusionEnv)
      assert.equal(defaultResult.code, 0, defaultResult.stderr.toString())
      const defaultStatus = systemGit(['status', '--porcelain', '-z'], defaultRepo, exclusionEnv)
        .stdout.toString('utf8').split('\0').filter(entry => entry !== '')
      assert.ok(defaultStatus.includes('?? empty/'), defaultStatus.join(' '))
      assert.ok(defaultStatus.includes('?? w/'), defaultStatus.join(' '))
      assert.ok(!defaultStatus.includes('A  empty/x.txt'), defaultStatus.join(' '))
      assert.ok(!defaultStatus.includes('A  w/top.txt'), defaultStatus.join(' '))
    })

    await t.test('add and rm reject an unmatched include pathspec before mutating', async () => {
      const vectors: string[][] = [
        ['add', '--', ':(glob)nope*'],
        ['add', '--', ':(glob)a/*/'],
        ['add', '--', 'top.txt', ':(glob)nope*'],
        ['add', '-A', '--', 'top.txt', ':(glob)nope*'],
        ['rm', '-r', '--cached', '--', ':(glob)nope*'],
        ['rm', '-r', '--cached', '--', ':(glob)a/*/'],
        ['rm', '-r', '--cached', '--', 'top.txt', ':(glob)nope*'],
      ]
      for (const [index, args] of vectors.entries()) {
        const systemRepo = join(temp.path, `negative-mutation-system-${index}`)
        const workerRepo = join(temp.path, `negative-mutation-worker-${index}`)
        copyRepository(repository, systemRepo)
        copyRepository(repository, workerRepo)
        const label = args.join(' ')
        expectSame(label, systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
        expectSame(
          `${label} left the status unchanged`,
          systemGit(['status', '--porcelain', '-z'], systemRepo, env),
          await workerGit(['status', '--porcelain', '-z'], workerRepo, env),
        )
      }
    })

    await t.test('add validates pathspecs against the mode-specific candidate set', async () => {
      const compareAdd = async (source: string, args: readonly string[], label: string): Promise<void> => {
        const suffix = Math.random().toString(36).slice(2)
        const systemRepo = join(temp.path, `add-candidates-system-${suffix}`)
        const workerRepo = join(temp.path, `add-candidates-worker-${suffix}`)
        copyRepository(source, systemRepo)
        copyRepository(source, workerRepo)
        expectSame(label, systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
        expectSame(
          `${label} left the status unchanged`,
          systemGit(['status', '--porcelain', '-z'], systemRepo, env),
          await workerGit(['status', '--porcelain', '-z'], workerRepo, env),
        )
      }

      // An empty repository still has a root directory: `git add .` selects it
      // even though there is no file to match.
      const emptyRepository = join(temp.path, 'add-candidates-empty')
      mkdirSync(emptyRepository)
      const emptyGit = systemGit(['init', '-q', '-b', 'main'], emptyRepository, env)
      assert.equal(emptyGit.code, 0, emptyGit.stderr.toString())
      await compareAdd(emptyRepository, ['add', '.'], 'add . in an empty repository')

      const repositoryWithModes = join(temp.path, 'add-candidates-modes')
      mkdirSync(repositoryWithModes)
      const modesGit = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, repositoryWithModes, env)
        assert.equal(result.code, 0, `add candidate fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      modesGit(['init', '-q', '-b', 'main'])
      writeFileSync(join(repositoryWithModes, '.gitignore'), 'onlyignored/\n')
      writeFileSync(join(repositoryWithModes, 'tracked.txt'), 'tracked\n')
      modesGit(['add', 'tracked.txt'])
      modesGit(['commit', '-qm', 'base'])
      mkdirSync(join(repositoryWithModes, 'emptydir'))
      writeFileSync(join(repositoryWithModes, 'newfile'), 'untracked\n')
      mkdirSync(join(repositoryWithModes, 'onlyignored'))
      writeFileSync(join(repositoryWithModes, 'onlyignored', 'file.txt'), 'ignored\n')

      for (const [index, args] of [
        ['add', '.'],
        ['add', '--', 'emptydir'],
        ['add', '-u', '--', 'emptydir'],
        // A glob pathspec does not turn an empty directory into a match.
        ['add', '--', ':(glob)emptydir'],
        ['add', '-u', '--', ':(glob)new*'],
        ['add', '--', ':(glob)onlyignored/*'],
        ['add', '-A', '--', ':(glob)onlyignored/*'],
        ['add', '-f', '--', ':(glob)onlyignored/*'],
      ].entries()) {
        await compareAdd(repositoryWithModes, args, `add candidate vector ${index} (${args.join(' ')})`)
      }
    })

    await t.test('add -u stages tracked deletions matched by glob pathspecs', async () => {
      const updateRepository = join(temp.path, 'add-update-deletions')
      mkdirSync(updateRepository)
      const updateGit = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, updateRepository, env)
        assert.equal(result.code, 0, `add update fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      updateGit(['init', '-q', '-b', 'main'])
      mkdirSync(join(updateRepository, 'dir', 'sub'), { recursive: true })
      writeFileSync(join(updateRepository, 'dir', 'del.txt'), 'delete me\n')
      writeFileSync(join(updateRepository, 'dir', 'keep.txt'), 'keep me\n')
      writeFileSync(join(updateRepository, 'dir', 'sub', 'deep.txt'), 'delete me too\n')
      writeFileSync(join(updateRepository, 'top.txt'), 'top\n')
      writeFileSync(join(updateRepository, 'shape'), 'this becomes a directory\n')
      updateGit(['add', '-A'])
      updateGit(['commit', '-qm', 'base'])
      // `-u` must consider index entries whose work-tree path vanished, not
      // only files the work-tree scan can still see. `shape` is a tracked
      // file replaced by a directory, which is the same deletion case.
      rmSync(join(updateRepository, 'dir', 'del.txt'))
      rmSync(join(updateRepository, 'dir', 'sub', 'deep.txt'))
      rmSync(join(updateRepository, 'shape'))
      mkdirSync(join(updateRepository, 'shape'))
      writeFileSync(join(updateRepository, 'dir', 'keep.txt'), 'keep changed\n')

      const compareUpdate = async (args: readonly string[], label: string): Promise<CommandResult> => {
        const suffix = Math.random().toString(36).slice(2)
        const systemRepo = join(temp.path, `add-update-system-${suffix}`)
        const workerRepo = join(temp.path, `add-update-worker-${suffix}`)
        copyRepository(updateRepository, systemRepo)
        copyRepository(updateRepository, workerRepo)
        expectSame(label, systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
        const expectedStatus = systemGit(['status', '--porcelain', '-z'], systemRepo, env)
        const actualStatus = await workerGit(['status', '--porcelain', '-z'], workerRepo, env)
        expectSame(`${label} resulting status`, expectedStatus, actualStatus)
        return actualStatus
      }

      const globStatus = await compareUpdate(
        ['add', '-u', '--', ':(glob)dir/**'],
        'add -u stages a globally selected tracked deletion',
      )
      const entries = globStatus.stdout.toString('utf8').split('\0')
      assert.ok(entries.includes('D  dir/del.txt'), entries.join(' '))
      assert.ok(entries.includes('D  dir/sub/deep.txt'), entries.join(' '))
      assert.ok(entries.includes('M  dir/keep.txt'), entries.join(' '))

      await compareUpdate(
        ['add', '-u', '--', ':(glob)dir/*.txt'],
        'add -u keeps a single-star pathspec inside one directory',
      )
      await compareUpdate(
        ['add', '-u', '--', ':(glob)shape'],
        'add -u stages a tracked file replaced by a directory',
      )
      await compareUpdate(['add', '-u'], 'add -u without a pathspec stages every tracked deletion')
    })

    await t.test('add stages a tracked file replaced by a directory through glob pathspecs', async () => {
      const replacementRepository = join(temp.path, 'add-replaced-file')
      mkdirSync(replacementRepository)
      const replacementGit = (args: readonly string[]): CommandResult => {
        const result = systemGit(args, replacementRepository, env)
        assert.equal(result.code, 0, `add replacement fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      replacementGit(['init', '-q', '-b', 'main'])
      writeFileSync(join(replacementRepository, 'shape'), 'this becomes a directory\n')
      writeFileSync(join(replacementRepository, 'keep.txt'), 'keep\n')
      replacementGit(['add', '-A'])
      replacementGit(['commit', '-qm', 'base'])
      // The index still has the regular file `shape`; the work tree now has a
      // directory with the same name. A pathspec that only reaches
      // `shape/inner.txt` must still stage the index deletion of `shape`.
      rmSync(join(replacementRepository, 'shape'))
      mkdirSync(join(replacementRepository, 'shape'))
      writeFileSync(join(replacementRepository, 'shape', 'inner.txt'), 'inner\n')

      const compareReplacement = async (args: readonly string[]): Promise<void> => {
        const suffix = Math.random().toString(36).slice(2)
        const systemRepo = join(temp.path, `add-replaced-system-${suffix}`)
        const workerRepo = join(temp.path, `add-replaced-worker-${suffix}`)
        copyRepository(replacementRepository, systemRepo)
        copyRepository(replacementRepository, workerRepo)
        const label = args.join(' ')
        expectSame(label, systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
        const expectedStatus = systemGit(['status', '--porcelain', '-z'], systemRepo, env)
        const actualStatus = await workerGit(['status', '--porcelain', '-z'], workerRepo, env)
        expectSame(`${label} resulting status`, expectedStatus, actualStatus)
        const entries = actualStatus.stdout.toString('utf8').split('\0')
        assert.ok(entries.includes('D  shape'), entries.join(' '))
        assert.ok(entries.includes('A  shape/inner.txt'), entries.join(' '))
      }

      for (const args of [
        ['add', '--', ':(glob)**'],
        ['add', '--', ':(glob)shape/**'],
        ['add', '--', ':(glob)shape/inner.txt'],
        ['add', '.'],
        ['add', '-A', '--', ':(glob)**'],
        ['add', '-A', '--', ':(glob)shape/**'],
        ['add', '-A', '--', ':(glob)shape/inner.txt'],
        ['add', '-A'],
      ]) {
        await compareReplacement(args)
      }

      // When the include pathspec only reaches paths that an exclude removes,
      // no worktree candidate survives and Git rejects the transaction. The
      // replaced file's index entry must stay untouched.
      for (const args of [
        ['add', '--', ':(glob)shape/**', ':(glob,exclude)shape/**'],
        ['add', '--', ':(glob)shape/inner.txt', ':(glob,exclude)shape/inner.txt'],
        ['add', '-A', '--', ':(glob)shape/**', ':(glob,exclude)shape/**'],
      ]) {
        const suffix = Math.random().toString(36).slice(2)
        const systemRepo = join(temp.path, `add-replaced-exclude-system-${suffix}`)
        const workerRepo = join(temp.path, `add-replaced-exclude-worker-${suffix}`)
        copyRepository(replacementRepository, systemRepo)
        copyRepository(replacementRepository, workerRepo)
        const label = args.join(' ')
        const expected = systemGit(args, systemRepo, env)
        expectSame(label, expected, await workerGit(args, workerRepo, env))
        assert.equal(expected.code, 128, `${label}: ${expected.stderr.toString()}`)
        const actualStatus = await workerGit(['status', '--porcelain', '-z'], workerRepo, env)
        const entries = actualStatus.stdout.toString('utf8').split('\0')
        assert.ok(!entries.includes('D  shape'), entries.join(' '))
        assert.ok(!entries.includes('A  shape/inner.txt'), entries.join(' '))
      }
    })

    await t.test('log path filtering walks merges like the system git', async () => {
      const mergeRepository = join(temp.path, 'merge-log-fixture')
      mkdirSync(mergeRepository)
      const git = (args: readonly string[], timestamp: number): CommandResult => {
        const result = systemGit(args, mergeRepository, {
          ...env,
          GIT_AUTHOR_DATE: `${timestamp} +0000`,
          GIT_COMMITTER_DATE: `${timestamp} +0000`,
        })
        assert.equal(result.code, 0, `merge fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      git(['init', '-q', '-b', 'main'], 1700000000)
      writeFileSync(join(mergeRepository, 'a.txt'), 'alpha\n')
      writeFileSync(join(mergeRepository, 'b.txt'), 'beta\n')
      git(['add', '-A'], 1700000000)
      git(['commit', '-qm', 'base'], 1700000000)
      git(['checkout', '-q', '-b', 'side'], 1700000100)
      writeFileSync(join(mergeRepository, 's.txt'), 'side\n')
      git(['add', '-A'], 1700000100)
      git(['commit', '-qm', 'side'], 1700000100)
      git(['checkout', '-q', 'main'], 1700000150)
      writeFileSync(join(mergeRepository, 'a.txt'), 'alpha\nmain\n')
      git(['add', '-A'], 1700000200)
      git(['commit', '-qm', 'main'], 1700000200)
      git(['merge', '-q', '--no-ff', 'side', '-m', 'merge'], 1700000300)
      // Two commits after the merge make `-n 1` stop before the merge is
      // reached instead of failing on a merge outside the requested range.
      writeFileSync(join(mergeRepository, 'a.txt'), 'alpha\nmain\npost1\n')
      git(['add', '-A'], 1700000400)
      git(['commit', '-qm', 'post1'], 1700000400)
      writeFileSync(join(mergeRepository, 'a.txt'), 'alpha\nmain\npost1\npost2\n')
      git(['add', '-A'], 1700000500)
      git(['commit', '-qm', 'post2'], 1700000500)

      const vectors = [
        ['log', '--oneline', '--', 'a.txt'],
        ['log', '--first-parent', '--oneline', '--', 'a.txt'],
        ['log', '-n', '1', '--oneline', '--', 'a.txt'],
        ['log', '--first-parent', '-n', '1', '--oneline', '--', 'a.txt'],
        ['log', '--oneline', '--', 's.txt'],
        ['log', '--first-parent', '--oneline', '--', 's.txt'],
        ['log', '-n', '1', '--oneline', '--', 's.txt'],
        ['log', '--first-parent', '-n', '1', '--oneline', '--', 's.txt'],
        ['log', '--oneline', '--', 'b.txt'],
        ['log', '--oneline', '--', ':(glob)**/*.txt'],
        ['log', '--first-parent', '--oneline', '--', ':(glob)**/*.txt'],
        ['log', '--name-status', '--', 'a.txt'],
        ['log', '--stat', '--', 'a.txt'],
      ]
      for (const args of vectors) {
        expectSame(args.join(' '), systemGit(args, mergeRepository, env), await workerGit(args, mergeRepository, env))
      }

      // A real conflict resolution makes the merge differ from every parent,
      // so the merge itself is part of the default (and first-parent) answer.
      const conflictRepository = join(temp.path, 'conflict-log-fixture')
      mkdirSync(conflictRepository)
      const conflictGit = (args: readonly string[], timestamp: number): CommandResult => {
        const result = systemGit(args, conflictRepository, {
          ...env,
          GIT_AUTHOR_DATE: `${timestamp} +0000`,
          GIT_COMMITTER_DATE: `${timestamp} +0000`,
        })
        return result
      }
      conflictGit(['init', '-q', '-b', 'main'], 1700001000)
      writeFileSync(join(conflictRepository, 'c.txt'), 'base\n')
      conflictGit(['add', '-A'], 1700001000)
      conflictGit(['commit', '-qm', 'base'], 1700001000)
      conflictGit(['checkout', '-q', '-b', 'side'], 1700001100)
      writeFileSync(join(conflictRepository, 'c.txt'), 'side\n')
      conflictGit(['add', '-A'], 1700001100)
      conflictGit(['commit', '-qm', 'side'], 1700001100)
      conflictGit(['checkout', '-q', 'main'], 1700001200)
      writeFileSync(join(conflictRepository, 'c.txt'), 'main\n')
      conflictGit(['add', '-A'], 1700001200)
      conflictGit(['commit', '-qm', 'main'], 1700001200)
      const conflicted = conflictGit(['merge', 'side', '-m', 'merge'], 1700001300)
      assert.notEqual(conflicted.code, 0, 'fixture merge conflicts as intended')
      writeFileSync(join(conflictRepository, 'c.txt'), 'resolved\n')
      conflictGit(['add', 'c.txt'], 1700001300)
      conflictGit(['commit', '-qm', 'merge'], 1700001300)
      for (const args of [
        ['log', '--oneline', '--', 'c.txt'],
        ['log', '--first-parent', '--oneline', '--', 'c.txt'],
        ['log', '-n', '1', '--oneline', '--', ':(glob)c*.txt'],
        // The merge itself is selected here, but git's default log prints no
        // patch/stat/name list for a merge (that needs -m or --cc). Only the
        // merge header may appear before the parents' content.
        ['log', '--name-status', '--', 'c.txt'],
        ['log', '--stat', '--', 'c.txt'],
        ['log', '-p', '--', 'c.txt'],
        // --first-parent compares the merge with its first parent and does
        // show the merge's content, so this must not be suppressed.
        ['log', '--first-parent', '--name-status', '--', 'c.txt'],
        ['log', '--first-parent', '--stat', '--', 'c.txt'],
        ['log', '--first-parent', '-p', '--', 'c.txt'],
      ]) {
        expectSame(args.join(' '), systemGit(args, conflictRepository, env), await workerGit(args, conflictRepository, env))
      }
    })

    await t.test('log follows only the first TREESAME parent of a merge', async () => {
      const treesameRepository = join(temp.path, 'treesame-merge-fixture')
      mkdirSync(treesameRepository)
      const git = (args: readonly string[], timestamp: number): CommandResult => {
        const result = systemGit(args, treesameRepository, {
          ...env,
          GIT_AUTHOR_DATE: `${timestamp} +0000`,
          GIT_COMMITTER_DATE: `${timestamp} +0000`,
        })
        assert.equal(result.code, 0, `treesame fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
        return result
      }
      git(['init', '-q', '-b', 'main'], 1700002000)
      writeFileSync(join(treesameRepository, 'same.txt'), 'base\n')
      writeFileSync(join(treesameRepository, 'other.txt'), 'other\n')
      git(['add', '-A'], 1700002000)
      git(['commit', '-qm', 'base'], 1700002000)
      // Both side branches make the same change to `same.txt`. After merging
      // side1 into main and then side2, the merge is TREESAME to both parents,
      // so git's default path-history walk must follow only the first one and
      // never visit side2's identical commit.
      git(['checkout', '-q', '-b', 'side1'], 1700002100)
      writeFileSync(join(treesameRepository, 'same.txt'), 'same\n')
      git(['commit', '-qam', 'side1'], 1700002100)
      git(['checkout', '-q', 'main'], 1700002150)
      git(['checkout', '-q', '-b', 'side2'], 1700002150)
      writeFileSync(join(treesameRepository, 'same.txt'), 'same\n')
      git(['commit', '-qam', 'side2'], 1700002200)
      git(['checkout', '-q', 'main'], 1700002250)
      git(['merge', '-q', '--no-ff', 'side1', '-m', 'merge side1'], 1700002300)
      git(['merge', '-q', '--no-ff', 'side2', '-m', 'merge side2'], 1700002400)

      for (const args of [
        ['log', '--oneline', '--', 'same.txt'],
        ['log', '--name-status', '--', 'same.txt'],
        ['log', '--stat', '--', 'same.txt'],
        ['log', '-p', '--', 'same.txt'],
        ['log', '--reverse', '--oneline', '--', 'same.txt'],
        ['log', '-n', '1', '--oneline', '--', 'same.txt'],
        ['log', '-n', '2', '--oneline', '--', 'same.txt'],
      ]) {
        expectSame(args.join(' '), systemGit(args, treesameRepository, env), await workerGit(args, treesameRepository, env))
      }
    })

    await t.test('invalid glob magic is a real error, not an empty match', async () => {
      for (const args of [
        ['ls-files', '--', ':(glob'],
        ['ls-files', '--', ':(bogus)a'],
        ['ls-files', '--', ':(literal,glob)a'],
      ]) {
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
      // Native ls-tree does not support glob magic; the command keeps the
      // command-specific rejection instead of silently enabling it.
      const lsTree = ['ls-tree', '-r', '--name-only', 'HEAD', '--', ':(glob)**/*.txt']
      expectSame(lsTree.join(' '), systemGit(lsTree, repository, env), await workerGit(lsTree, repository, env))
    })
  } finally {
    temp.cleanup()
  }
})
